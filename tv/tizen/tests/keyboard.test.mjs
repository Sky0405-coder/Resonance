import test from 'node:test';
import assert from 'node:assert/strict';
import { keyboardMove, keyboardLetters, keyboardSymbols, activateShift, editText } from '../js/views/keyboard.js';
const move = (row, column, direction, symbols) => keyboardMove({ row, column }, direction, symbols);
test('QWERTZ rows have eleven columns, arrows preserve columns, horizontal arrows leave at the edges', () => {
  assert.deepEqual(keyboardLetters, ['1234567890ß', 'qwertzuiopü', 'asdfghjklöä', 'yxcvbnm.-_@']);
  assert.deepEqual(move(1, 7, 'up'), { row: 0, column: 7 });
  assert.deepEqual(move(1, 7, 'down'), { row: 2, column: 7 });
  assert.equal(move(2, 0, 'left'), null); assert.deepEqual(move(2, 1, 'left'), { row: 2, column: 0 });
  assert.equal(move(3, 10, 'right'), null);
  assert.equal(move(0, 4, 'up'), null); assert.equal(move(4, 4, 'down'), null);
});
test('bottom-row wide keys select their covered column and use their first column going up', () => {
  [0, 0, 2, 2, 4, 4, 4, 4, 8, 8, 10].forEach((start, col) => {
    assert.deepEqual(move(3, col, 'down'), { row: 4, column: start });
    assert.deepEqual(move(4, col, 'up'), { row: 3, column: start });
  });
  assert.deepEqual(move(4, 4, 'right'), { row: 4, column: 8 });
  assert.equal(move(4, 0, 'left'), null); assert.equal(move(4, 10, 'right'), null);
});
test('symbols skip empty rows and disabled cells without trapping focus', () => {
  assert.equal(keyboardSymbols.length, 28);
  assert.deepEqual(move(1, 10, 'down', true), { row: 2, column: 5 });
  assert.equal(move(2, 5, 'right', true), null);
  assert.deepEqual(move(2, 4, 'down', true), { row: 4, column: 4 });
  assert.deepEqual(move(4, 8, 'up', true), { row: 2, column: 5 });
});
test('shift supports one-shot, double activation/hold within 400ms, and caps unlock', () => {
  assert.equal(activateShift('off', -Infinity, 10), 'once');
  assert.equal(activateShift('once', 10, 410), 'caps');
  assert.equal(activateShift('once', 10, 411), 'off');
  assert.equal(activateShift('caps', 10, 20), 'off');
  assert.equal(editText('abc', 'delete'), 'ab'); assert.equal(editText('abc', 'clear'), '');
});
