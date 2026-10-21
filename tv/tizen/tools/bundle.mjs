// Tizen web apps run from file://, where Chromium refuses ES modules. This joins js/main.js and everything it
// imports into one classic script (dependencies first) and points index.html at it.
// Usage: node tools/bundle.mjs <staged app dir>
import fs from 'node:fs';
import path from 'node:path';

const appDir = process.argv[2];
const order = [];
const seen = new Set();

function visit(file) {
  if (seen.has(file)) return;
  seen.add(file);
  const source = fs.readFileSync(file, 'utf8');
  for (const match of source.matchAll(/^import\s+[^;]*?from\s+'([^']+)';?\s*$/gm)) {
    visit(path.resolve(path.dirname(file), match[1]));
  }
  if (/^\s*import\s/m.test(source.replace(/^import\s+[^;]*?from\s+'[^']+';?\s*$/gm, ''))) {
    throw new Error(`${file}: unsupported import form`);
  }
  order.push(file);
}

visit(path.join(appDir, 'js', 'main.js'));
const declared = new Map();
const parts = order.map((file) => {
  const relative = path.relative(appDir, file);
  const body = fs.readFileSync(file, 'utf8')
    .replace(/^import\s+[^;]*?from\s+'[^']+';?\s*$/gm, '')
    .replace(/^export\s+(?=(async\s+)?function|const|let|class)/gm, '');
  if (/^export\b/m.test(body)) throw new Error(`${relative}: unsupported export form`);
  for (const match of body.matchAll(/^(?:async\s+)?(?:function\*?|const|let|class)\s+([A-Za-z_$][\w$]*)/gm)) {
    if (declared.has(match[1])) throw new Error(`${match[1]} declared in ${declared.get(match[1])} and ${relative}`);
    declared.set(match[1], relative);
  }
  return `// ${relative}\n${body}`;
});
fs.writeFileSync(path.join(appDir, 'js', 'app.js'), `(function () {\n'use strict';\n${parts.join('\n')}\n})();\n`);
for (const file of order) fs.rmSync(file);
fs.rmSync(path.join(appDir, 'js', 'views'), { recursive: true, force: true });
const indexFile = path.join(appDir, 'index.html');
const html = fs.readFileSync(indexFile, 'utf8');
const script = '<script type="module" src="js/main.js"></script>';
if (!html.includes(script)) throw new Error('index.html: module script tag not found');
fs.writeFileSync(indexFile, html.replace(script, '<script src="js/app.js"></script>'));
console.log(`Bundled ${order.length} modules into js/app.js`);
