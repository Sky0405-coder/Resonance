import test from 'node:test';
import assert from 'node:assert/strict';
import { nearestInDirection, Navigation } from '../js/nav.js';
const rect = (x, y, w = 100, h = 100) => ({ left: x, top: y, right: x + w, bottom: y + h });
const origin = rect(200, 200);
const candidate = (id, x, y, w, h) => ({ id, rect: rect(x, y, w, h) });
test('picks a directional neighbor for all four D-pad directions', () => {
  const candidates = [candidate('left', 60, 200), candidate('right', 340, 200), candidate('up', 200, 60), candidate('down', 200, 340)];
  ['left', 'right', 'up', 'down'].forEach(direction => assert.equal(nearestInDirection(origin, candidates, direction).id, direction));
});
test('prioritizes aligned shelves over diagonals and rejects wrong directions', () => {
  const candidates = [candidate('diagonal', 305, 320), candidate('aligned', 450, 200), candidate('behind', 10, 200)];
  assert.equal(nearestInDirection(origin, candidates, 'right').id, 'aligned');
  assert.equal(nearestInDirection(origin, [candidate('behind', 10, 200)], 'right'), null);
  assert.equal(nearestInDirection(origin, [], 'up'), null);
});
test('geometry allows offscreen cards to be focused and scrolled into view', () => {
  assert.equal(nearestInDirection(rect(1700, 100), [candidate('next', 2010, 100)], 'right').id, 'next');
});
test('vertical navigation restores the remembered index of a target row', () => {
  const currentRow = { dataset: { row: 'first' } };
  const targetRow = { dataset: { row: 'second' } };
  const current = { getBoundingClientRect: () => rect(100, 100), closest: () => currentRow };
  const a = { getBoundingClientRect: () => rect(100, 250), closest: () => targetRow };
  const b = { getBoundingClientRect: () => rect(230, 250), closest: () => targetRow };
  const nav = new Navigation({ addEventListener() {} }); nav.rows.set('second', 1);
  nav.elements = scope => scope === targetRow ? [a, b] : [current, a, b];
  let focused; nav.focus = node => { focused = node; };
  globalThis.document = { activeElement: current };
  nav.move('down'); assert.equal(focused, b); delete globalThis.document;
});
