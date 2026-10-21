import test from 'node:test';
import assert from 'node:assert/strict';
import { violations } from '../check-syntax.mjs';
test('compatibility gate rejects each forbidden feature', () => {
  ['x?.a', 'x ?? y', 'class A { #secret; }', 'class A { value = 1; }', 'class A { value; }',
    'class A { static value = 1; }', 'class A { method() {} value = 1; }', 'x.flat()', 'x. flat (1)', 'Object.fromEntries(x)', 'globalThis', 'Promise.allSettled(x)',
    'x.replaceAll(a, b)', 'queueMicrotask(f)', 'x.replaceChildren(a)', 'x.at(-1)', 'loading="lazy"',
    'gap: 3px', 'inset: 0', 'aspect-ratio: 1', ':is(a, b)', 'backdrop-filter: blur(3px)'].forEach(source => {
    assert.ok(violations(source).length > 0, source);
  });
});
test('ES2017 class methods, constructors and getters pass', () => {
  assert.deepEqual(violations('class A { constructor() { this.x = 1; } get x() { return 1; } set x(v) {} static run() {} set(key, value) {} get() {} async load() {} }'), []);
});
