#!/usr/bin/env node
// No npm dependencies. CHROMIUM=/absolute/path/to/chrome node tests/browser-smoke.mjs
import { createServer } from 'node:http';
import { readFile, mkdtemp, rm, writeFile, access } from 'node:fs/promises';
import { spawn } from 'node:child_process';
import { tmpdir, homedir } from 'node:os';
import { join, resolve, extname, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
const app = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const candidates = [process.env.CHROMIUM, '/usr/bin/chromium', '/usr/bin/chromium-browser', '/usr/bin/google-chrome',
  join(homedir(), '.cache/ms-playwright/chromium-1243/chrome-linux64/chrome')].filter(Boolean);
let chromium;
for (const path of candidates) { try { await access(path); chromium = path; break; } catch (_) {} }
if (!chromium) { console.error('Set CHROMIUM to an installed Chromium executable.'); process.exit(1); }
const profile = await mkdtemp(join(tmpdir(), 'resonance-tv-browser-'));
const server = createServer(async (request, response) => {
  try {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    if (pathname === '/__test__') {
      const html = (await readFile(join(app, 'index.html'), 'utf8')).replace('href="css/', 'href="/css/').replace('href="icon.png"', 'href="/icon.png"')
        .replace('<script type="module" src="js/main.js"></script>', `<script>Object.defineProperty(navigator, 'language', { get: () => 'de-DE' });</script><script type="module">
          import { installMocks, runSmoke } from '/tests/browser-fixture.js';
          installMocks(); window.__screenshotScene = ${JSON.stringify(process.env.TV_SCREENSHOT_SCENE || '')};
          await import('/js/main.js');
          runSmoke().then(result => { window.__smoke = { ok: true, result }; }, error => { window.__smoke = { ok: false, error: error.stack }; });
        </script>`);
      response.writeHead(200, { 'Content-Type': 'text/html' }); response.end(html); return;
    }
    const path = resolve(app, '.' + decodeURIComponent(pathname));
    if (!path.startsWith(app + '/')) throw new Error('Invalid path');
    const data = await readFile(path);
    const types = { '.js': 'text/javascript', '.css': 'text/css', '.png': 'image/png', '.html': 'text/html' };
    response.writeHead(200, { 'Content-Type': types[extname(path)] || 'application/octet-stream' }); response.end(data);
  } catch (_) { response.writeHead(404); response.end('Not found'); }
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const port = server.address().port;
if (process.argv.indexOf('--serve') >= 0) {
  console.log('Browser fixture: http://127.0.0.1:' + port + '/__test__');
  await new Promise(() => {});
}
const child = spawn(chromium, ['--headless', '--no-sandbox', '--disable-gpu', '--disable-dev-shm-usage', '--window-size=1920,1080',
  '--autoplay-policy=no-user-gesture-required', '--remote-debugging-port=0', '--user-data-dir=' + profile, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
let stderr = ''; child.stderr.on('data', data => { stderr += data.toString(); });
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
let socket;
try {
  const startup = Date.now() + 15000;
  while (!/DevTools listening on ws:\/\//.test(stderr)) {
    if (Date.now() > startup || child.exitCode !== null) throw new Error('Chromium startup failed: ' + stderr.slice(-2000));
    await sleep(100);
  }
  const debuggingPort = /DevTools listening on ws:\/\/127.0.0.1:(\d+)/.exec(stderr)[1];
  const targets = await (await fetch('http://127.0.0.1:' + debuggingPort + '/json/list')).json();
  socket = new WebSocket(targets.find(target => target.type === 'page').webSocketDebuggerUrl);
  await new Promise((resolve, reject) => { socket.onopen = resolve; socket.onerror = reject; });
  let serial = 0; const pending = new Map(); const exceptions = [];
  socket.onmessage = event => {
    const message = JSON.parse(event.data);
    if (message.method === 'Runtime.exceptionThrown') exceptions.push(message.params.exceptionDetails);
    if (!message.id) return;
    const task = pending.get(message.id); if (!task) return; pending.delete(message.id);
    if (message.error) task.reject(new Error(message.error.message)); else task.resolve(message.result);
  };
  const call = (method, params) => new Promise((resolve, reject) => {
    const id = ++serial; pending.set(id, { resolve, reject }); socket.send(JSON.stringify({ id, method, params: params || {} }));
  });
  await call('Runtime.enable'); await call('Page.enable');
  await call('Emulation.setDeviceMetricsOverride', { width: 1920, height: 1080, deviceScaleFactor: 1, mobile: false });
  await call('Page.navigate', { url: 'http://127.0.0.1:' + port + '/__test__' });
  let result; const deadline = Date.now() + 35000;
  while (Date.now() < deadline) {
    const evaluated = await call('Runtime.evaluate', { expression: 'window.__smoke', returnByValue: true });
    result = evaluated.result.value; if (result) break; await sleep(150);
  }
  const screenshot = await call('Page.captureScreenshot', { format: 'png' });
  const screenshotPath = process.env.TV_SCREENSHOT || join(tmpdir(), 'resonance-tv-smoke.png');
  await writeFile(screenshotPath, Buffer.from(screenshot.data, 'base64'));
  if (!result || !result.ok || exceptions.length) throw new Error(JSON.stringify({ result, exceptions }, null, 2));
  console.log(JSON.stringify({ ...result.result, screenshot: screenshotPath }, null, 2));
} finally {
  if (socket) socket.close();
  child.kill('SIGTERM'); await new Promise(resolve => { if (child.exitCode !== null) resolve(); else child.once('exit', resolve); });
  await new Promise(resolve => server.close(resolve)); await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}
