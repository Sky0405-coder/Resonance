import test from 'node:test';
import assert from 'node:assert/strict';
import { image, releaseImages } from '../js/ui.js';
test('shelf images have no src until IntersectionObserver sees them within a screen width', () => {
  let callback; let margin; const observed = new Set();
  globalThis.window = { innerWidth: 1920 };
  globalThis.document = { createElement: () => ({ dataset: {}, addEventListener() {} }) };
  globalThis.IntersectionObserver = class {
    constructor(fn, options) { callback = fn; margin = options.rootMargin; }
    observe(node) { observed.add(node); }
    unobserve(node) { observed.delete(node); }
  };
  const img = image('/cover?size=300', 'card-cover', '', true);
  assert.equal(img.src, undefined); assert.equal(margin, '1920px'); assert.equal(observed.size, 1);
  callback([{ target: img, isIntersecting: false }]); assert.equal(img.src, undefined);
  callback([{ target: img, isIntersecting: true }]); assert.equal(img.src, '/cover?size=300'); assert.equal(observed.size, 0);
  const detached = image('/other', '', '', true);
  releaseImages({ querySelectorAll: () => [detached] }); assert.equal(observed.size, 0);
  callback([{ target: detached, isIntersecting: true }]); assert.equal(detached.src, undefined);
});
