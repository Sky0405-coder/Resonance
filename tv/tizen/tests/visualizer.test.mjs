import test from 'node:test';
import assert from 'node:assert/strict';
import { attachVisualizer } from '../js/visualizer.js';
function spectrumBytes() {
  const buffer = new ArrayBuffer(37); const bytes = new Uint8Array(buffer); const view = new DataView(buffer);
  bytes.set([82, 83, 80, 49, 24]); view.setFloat32(5, 1, true); view.setUint32(9, 1, true); bytes.fill(128, 13);
  return buffer;
}
test('visualizer uses two batched paths, caps frames at 24fps, and sleeps when paused, hidden or unmounted', async () => {
  const originals = { document: globalThis.document, Image: globalThis.Image, raf: globalThis.requestAnimationFrame, cancel: globalThis.cancelAnimationFrame };
  const events = new Map(); const frames = new Map(); let serial = 0; let visible = true;
  const doc = { hidden: false, addEventListener(name, fn) { events.set(name, fn); }, removeEventListener(name) { events.delete(name); } };
  globalThis.document = doc; globalThis.Image = class { set src(value) { this.onerror(); } };
  globalThis.requestAnimationFrame = fn => { frames.set(++serial, fn); return serial; };
  globalThis.cancelAnimationFrame = id => frames.delete(id);
  let fills = 0; let paths = 0; let rectangles = 0; let clears = 0; let requests = 0; let signal;
  const context = { createLinearGradient: () => ({ addColorStop() {} }), clearRect() { clears++; }, beginPath() { paths++; }, rect() { rectangles++; }, fill() { fills++; } };
  const canvas = { width: 660, height: 264, getContext: () => context };
  const listeners = new Set();
  const player = { playing: true, audio: { currentTime: 0 }, subscribe(fn) { listeners.add(fn); return () => listeners.delete(fn); } };
  const api = { server: 'visualizer-test', token: '', async request(path, options) { requests++; signal = options.signal; return spectrumBytes(); } };
  const emit = () => listeners.forEach(fn => fn('state'));
  const frame = timestamp => { const entry = frames.entries().next().value; assert.ok(entry); frames.delete(entry[0]); entry[1](timestamp); };
  let dispose;
  try {
    dispose = attachVisualizer(canvas, player, api, { id: 'a' }, 'cover', () => visible);
    await Promise.resolve(); await Promise.resolve(); await Promise.resolve();
    assert.equal(requests, 1); assert.equal(frames.size, 1);
    fills = 0; paths = 0; rectangles = 0; frame(0);
    assert.equal(fills, 2); assert.equal(paths, 2); assert.equal(rectangles, 48);
    frame(20); assert.equal(fills, 2); frame(42); assert.equal(fills, 4);
    player.playing = false; emit(); assert.equal(frames.size, 0); assert.equal(fills, 6);
    player.playing = true; emit(); assert.equal(frames.size, 1);
    doc.hidden = true; events.get('visibilitychange')(); assert.equal(frames.size, 0);
    doc.hidden = false; events.get('visibilitychange')(); assert.equal(frames.size, 1);
    visible = false; emit(); assert.equal(frames.size, 0);
    dispose(); dispose = null; assert.equal(listeners.size, 0); assert.equal(events.size, 0); assert.equal(signal.aborted, true);
    assert.ok(clears > 0); assert.equal(canvas.width, 660); assert.equal(canvas.height, 264);
  } finally {
    if (dispose) dispose(); globalThis.document = originals.document; globalThis.Image = originals.Image;
    globalThis.requestAnimationFrame = originals.raf; globalThis.cancelAnimationFrame = originals.cancel;
  }
});
