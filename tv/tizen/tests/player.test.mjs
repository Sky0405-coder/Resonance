import test from 'node:test';
import assert from 'node:assert/strict';
import { Player, playbackOrder } from '../js/player.js';
class AudioStub {
  constructor() { this.listeners = {}; this.currentTime = 0; this.paused = true; this.ended = false; this.src = ''; this.seekable = { length: 1, start: () => 0, end: () => 120 }; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  play() { this.paused = false; return Promise.resolve(); }
  pause() { this.paused = true; }
  load() { this.currentTime = 0; }
  removeAttribute(name) { if (name === 'src') this.src = ''; }
  getAttribute(name) { return name === 'src' ? this.src : null; }
  fire(name) { if (this.listeners[name]) this.listeners[name](); }
}
function setup() {
  globalThis.window = { addEventListener() {} }; globalThis.document = { addEventListener() {} };
  const calls = []; const errors = [];
  const api = { stream: track => '/stream/' + track.id, stationStream: id => '/station/' + id, request: async (path, opts) => { calls.push({ path, opts }); return null; } };
  const a = new AudioStub(); const b = new AudioStub();
  return { player: new Player(api, a, b, error => errors.push(error)), a, b, calls, errors };
}
const tracks = [{ id: 'a', duration: 100 }, { id: 'b', duration: 20 }, { id: 'c', duration: 80 }];
test('shuffle order preserves current item and contains every track once', () => {
  const order = playbackOrder(10, 4, true, () => 0.2);
  assert.equal(order[0], 4); assert.equal(new Set(order).size, 10);
  assert.deepEqual(playbackOrder(3, 1, false), [0, 1, 2]);
});
test('uses second audio for preload handoff; manual next skips repeat-one', () => {
  const { player, a, b } = setup(); player.setQueue(tracks, 0, 'album:test', false);
  assert.equal(a.src, '/stream/a'); assert.equal(b.src, '/stream/b'); assert.equal(player.preloaded, 1);
  player.next(); assert.equal(player.audio, b); assert.equal(player.track.id, 'b'); assert.equal(a.src, '/stream/c');
  player.repeat = 'one'; player.preload(); b.fire('ended'); assert.equal(player.track.id, 'b');
  player.next(); assert.equal(player.track.id, 'c'); player.stop();
});
test('previous respects shuffled history and repeat-all wraps at queue end', () => {
  const { player } = setup(); player.setQueue(tracks, 2, 'liked', true);
  const first = player.index; player.next(); player.previous(); assert.equal(player.index, first);
  player.shuffle = false; player.order = [0, 1, 2]; player.index = 2; player.repeat = 'all';
  player.next(); assert.equal(player.index, 0); player.stop();
});
test('play reports count listening, ignore seeks and follow Flutter threshold', async () => {
  const { player, a, calls } = setup(); player.setQueue(tracks, 0, 'album:test', false);
  for (let i = 1; i <= 31; i++) { a.currentTime = i; a.fire('timeupdate'); }
  a.currentTime = 90; a.fire('timeupdate');
  await player.flush();
  const reports = calls.filter(call => call.path === '/api/me/plays'); assert.equal(reports.length, 1);
  assert.deepEqual(reports[0].opts.body, { track_id: 'a', seconds_played: 31, context: 'album:test' });
  await player.flush(); assert.equal(calls.length, 1); player.stop();
});
test('short tracks report at half duration; unsupported seeks leave position unchanged', async () => {
  const { player, a, calls, errors } = setup(); player.setQueue(tracks, 1, 'playlist:test', false);
  for (let i = 1; i <= 10; i++) { a.currentTime = i; a.fire('timeupdate'); }
  await player.flush(); assert.equal(calls.length, 1);
  a.seekable = { length: 0 }; assert.equal(player.seekTo(25), false); assert.equal(a.currentTime, 10); assert.equal(errors.length, 1);
  player.stop(); assert.equal(a.src, ''); assert.equal(player.spare.src, ''); assert.equal(player.track, null);
});
