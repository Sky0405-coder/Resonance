import test from 'node:test';
import assert from 'node:assert/strict';
import { coverflowTracks } from '../js/views/now-playing.js';

test('coverflow follows shuffled playback order and keeps five neighbor slots', () => {
  const queue = ['zero', 'one', 'two', 'three'].map(id => ({ id: id }));
  const player = { station: null, queue: queue, order: [2, 0, 3, 1], index: 0 };
  assert.deepEqual(coverflowTracks(player).map(track => track && track.id), [null, 'two', 'zero', 'three', 'one']);
});

test('coverflow leaves missing edge tracks empty and skips stations and single track queues', () => {
  const queue = [{ id: 'only' }, { id: 'next' }];
  const player = { station: null, queue: queue, order: [0, 1], index: 0 };
  assert.deepEqual(coverflowTracks(player).map(track => track && track.id), [null, null, 'only', 'next', null]);
  player.station = { id: 'radio' };
  assert.equal(coverflowTracks(player), null);
  player.station = null; player.queue = [queue[0]]; player.order = [0];
  assert.equal(coverflowTracks(player), null);
});
