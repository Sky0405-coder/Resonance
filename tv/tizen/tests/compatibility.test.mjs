import test from 'node:test';
import assert from 'node:assert/strict';
import { violations } from '../check-syntax.mjs';
test('compatibility gate rejects each forbidden feature', () => {
  ['x?.a', 'x ?? y', 'class A { #secret; }', 'class A { value = 1; }', 'class A { value; }',
    'class A { static value = 1; }', 'class A { method() {} value = 1; }', 'x.flat()', 'x. flat (1)'].forEach(source => {
    assert.ok(violations(source).length > 0, source);
  });
});
test('ES2017 class methods, constructors and getters pass', () => {
  assert.deepEqual(violations('class A { constructor() { this.x = 1; } get x() { return 1; } set x(v) {} static run() {} async load() {} }'), []);
});
