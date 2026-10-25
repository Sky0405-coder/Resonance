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
const node = (x, y, row, extra) => Object.assign({ getBoundingClientRect: () => rect(x, y), closest: selector => selector === '[data-row]' ? row : null }, extra);
function moveFrom(current, others, direction) {
  const nav = new Navigation({ addEventListener() {} });
  nav.elements = () => [current].concat(others);
  let focused; nav.focus = el => { focused = el; };
  globalThis.document = { activeElement: current };
  nav.move(direction); delete globalThis.document;
  return focused;
}
test('vertical navigation goes straight down to the card below in the next row', () => {
  const first = { dataset: { row: 'first' } }; const second = { dataset: { row: 'second' } };
  const current = node(500, 100, first);
  const left = node(330, 250, second); const below = node(510, 250, second); const right = node(690, 250, second);
  assert.equal(moveFrom(current, [left, right, below], 'down'), below);
});
test('the next shelf in the page wins over the nearer mini player below it', () => {
  const page = { contains: el => el !== mini }; const shelf = { dataset: { row: 'shelf' } }; const bar = { dataset: { row: 'mini' } };
  const current = node(500, 700, { dataset: { row: 'first' } }, { closest: selector => selector === '[data-scroll-root]' ? page : { dataset: { row: 'first' } } });
  const mini = node(500, 950, bar); const next = node(500, 1100, shelf);
  assert.equal(moveFrom(current, [mini, next], 'down'), next);
});
