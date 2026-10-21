#!/usr/bin/env node
// Dependency-free compatibility gate for TV sources; Node itself validates syntax as well.
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
const base = dirname(fileURLToPath(import.meta.url));

export function violations(source, extension = ".js") {
  const problems = [];
  // Scan templates too: unsupported APIs and CSS can hide inside runtime strings.
  const rules = [
    [/\bObject\s*\.\s*fromEntries\s*\(/g, 'Object.fromEntries'], [/\bglobalThis\b/g, 'globalThis'],
    [/\bPromise\s*\.\s*allSettled\s*\(/g, 'Promise.allSettled'], [/\.\s*replaceAll\s*\(/g, 'String.replaceAll'],
    [/\bqueueMicrotask\s*\(/g, 'queueMicrotask'], [/\.\s*replaceChildren\s*\(/g, 'replaceChildren'],
    [/\.\s*at\s*\(/g, 'Array.at'], [/\bloading\s*=\s*["']lazy["']/gi, 'native lazy images'],
    [/\b(?:gap|row-gap|column-gap)\s*:/gi, 'CSS gap (use margins for TV flex layouts)'],
    [/\binset(?:-(?:block|inline)(?:-start|-end)?)?\s*:/gi, 'CSS inset'],
    [/\baspect-ratio\s*:/gi, 'CSS aspect-ratio'], [/:is\s*\(/gi, 'CSS :is()'],
    [/\bbackdrop-filter\s*:/gi, 'CSS backdrop-filter']
  ];
  if (extension === '.js') rules.push(
    [/\?\./g, 'optional chaining'], [/\?\?/g, 'nullish coalescing'],
    [/#\s*[A-Za-z_$][\w$]*/g, 'private field'], [/\.\s*flat\s*\(/g, 'Array.flat']
  );
  rules.forEach(rule => {
    let match;
    while ((match = rule[0].exec(source))) problems.push({ index: match.index, reason: rule[1] });
  });
  if (extension !== '.js') return problems;
  // Strip literals/comments before inspecting class members. Keep offsets for useful line numbers.
  const clean = source.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`/g,
    value => value.replace(/[^\n]/g, ' '));
  const tokens = Array.from(clean.matchAll(/[A-Za-z_$][\w$]*|[{}()[\];=*]|\S/g)).map(match => ({ value: match[0], index: match.index }));
  const classScopes = [];
  let depth = 0;
  let waitingClass = false;
  for (let i = 0; i < tokens.length; i++) {
    const token = tokens[i].value;
    if (token === 'class') waitingClass = true;
    if (token === '{') {
      depth++;
      if (waitingClass) { classScopes.push({ depth: depth, member: true }); waitingClass = false; }
      continue;
    }
    const scope = classScopes[classScopes.length - 1];
    if (token === '}') {
      if (scope && scope.depth === depth) classScopes.pop();
      depth--;
      const parent = classScopes[classScopes.length - 1];
      if (parent && parent.depth === depth) parent.member = true;
      continue;
    }
    if (!scope || depth !== scope.depth || !scope.member) continue;
    if (token === ';') continue;
    let j = i;
    while (tokens[j] && /^(static|async|get|set|\*)$/.test(tokens[j].value) && tokens[j + 1] && tokens[j + 1].value !== '(') j++;
    if (tokens[j] && tokens[j].value === '[') {
      let brackets = 1; j++;
      while (tokens[j] && brackets) { if (tokens[j].value === '[') brackets++; if (tokens[j].value === ']') brackets--; j++; }
    } else j++;
    if (!tokens[j] || tokens[j].value !== '(') problems.push({ index: tokens[i].index, reason: 'class field or static block' });
    scope.member = false;
  }
  return problems;
}
function files(path) {
  return readdirSync(path, { withFileTypes: true }).reduce((all, entry) => {
    const full = join(path, entry.name);
    return all.concat(entry.isDirectory() ? files(full) : /\.(js|css|html)$/.test(entry.name) ? [full] : []);
  }, []);
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const paths = process.argv.length > 2 ? process.argv.slice(2).map(path => resolve(path)) : files(join(base, 'js')).concat(files(join(base, 'css')), [join(base, 'index.html')]);
  let failed = false;
  paths.forEach(path => {
    const source = readFileSync(path, 'utf8');
    violations(source, path.slice(path.lastIndexOf('.'))).forEach(problem => {
      console.error(relative(base, path) + ':' + source.slice(0, problem.index).split('\n').length + ': ' + problem.reason);
      failed = true;
    });
    if (!path.endsWith('.js')) return;
    const checked = spawnSync(process.execPath, ['--check', path], { encoding: 'utf8' });
    if (checked.status !== 0) { console.error(checked.stderr); failed = true; }
  });
  if (failed) process.exitCode = 1;
  else console.log('TV compatibility and syntax: ' + paths.length + ' runtime files passed.');
}
