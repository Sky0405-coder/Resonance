import test from 'node:test';
import assert from 'node:assert/strict';
import { Player, playbackOrder, reorderUpcoming } from '../js/player.js';
class AudioStub {
  constructor() { this.listeners = {}; this.readyState = 4; this.volume = 1; this.playCalls = 0; this.loads = 0; this.pauses = 0; this.currentTime = 0; this.paused = true; this.ended = false; this.src = ''; this.seekable = { length: 1, start: () => 0, end: () => 120 }; }
  addEventListener(name, fn) { this.listeners[name] = fn; }
  play() { this.playCalls++; this.paused = false; return Promise.resolve(); }
  pause() { this.pauses++; this.paused = true; }
  load() { this.loads++; this.currentTime = 0; }
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
  assert.equal(a.src, '/stream/a'); assert.equal(b.src, ''); assert.equal(player.preloaded, -1);
  a.currentTime = 76; a.fire('timeupdate');
  assert.equal(b.src, '/stream/b'); assert.equal(player.preloaded, 1);
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

test('manual next/previous and ended always start the selected track, even from pause', () => {
  const { player } = setup(); player.setQueue(tracks, 0);
  assert.equal(player.playing, true);
  player.pause(); player.next(); assert.equal(player.track.id, 'b'); assert.equal(player.playing, true);
  player.pause(); player.previous(); assert.equal(player.track.id, 'a'); assert.equal(player.playing, true);
  player.audio.ended = true; player.audio.fire('ended'); player.audio.ended = false;
  assert.equal(player.track.id, 'b'); assert.equal(player.playing, true);
  player.audio.currentTime = 5; player.pause(); player.previous(); assert.equal(player.audio.currentTime, 0); assert.equal(player.playing, true);
  player.stop();
});
test('plays immediately, retries a rejected play on canplay, and cancels stale play intentions', async () => {
  const { player, a, errors } = setup();
  a.play = function () { this.playCalls++; return Promise.reject(new Error('Not ready')); };
  a.readyState = 0; player.setQueue(tracks, 0); assert.equal(a.playCalls, 1);
  await Promise.resolve(); assert.equal(errors.length, 0);
  a.play = AudioStub.prototype.play; a.readyState = 3; a.fire('canplay'); assert.equal(a.playCalls, 2); assert.equal(player.playing, true);
  a.fire('canplay'); assert.equal(a.playCalls, 2);
  player.pause(); a.fire('canplay'); assert.equal(a.playCalls, 2);
});
test('a decode error on a raw stream falls back to MP3 for that codec', () => {
  const { player, a, errors } = setup();
  player.api.supportedCodecs = { flac: true };
  player.api.stream = track => '/stream/' + track.id + '?format=' + (player.api.supportedCodecs[track.codec] ? 'raw' : 'mp3');
  player.setQueue([{ id: 'x', codec: 'flac', duration: 100 }], 0); assert.equal(a.src, '/stream/x?format=raw');
  a.fire('error');
  assert.equal(player.api.supportedCodecs.flac, false); assert.equal(a.src, '/stream/x?format=mp3'); assert.equal(errors.length, 0);
  player.stop();
});
test('a second play rejection reports one error without an unbounded retry', async () => {
  const { player, a, errors } = setup();
  a.play = function () { this.playCalls++; return Promise.reject(new Error('Cannot play')); };
  player.setQueue(tracks, 0); await Promise.resolve(); await Promise.resolve();
  assert.equal(a.playCalls, 2); assert.equal(errors.length, 1);
  a.fire('canplay'); assert.equal(a.playCalls, 2); player.stop();
});
test('shuffle only reorders upcoming tracks and preserves current slot and played history', () => {
  const order = [4, 1, 2, 0, 3];
  assert.deepEqual(reorderUpcoming(order, 2, true, () => 0), [4, 1, 2, 3, 0]);
  assert.deepEqual(reorderUpcoming(order, 2, false), [4, 1, 2, 0, 3]);
  assert.deepEqual(order, [4, 1, 2, 0, 3]);
});
test('shuffle and repeat never pause, reload or seek the current audio, including after a handoff', () => {
  const { player, a } = setup(); player.setQueue(tracks, 0);
  a.currentTime = 76; a.fire('timeupdate'); player.next();
  const audio = player.audio; audio.currentTime = 7;
  const snapshot = { src: audio.src, loads: audio.loads, pauses: audio.pauses, plays: audio.playCalls };
  const position = player.order.indexOf(player.index);
  player.toggleShuffle(); player.toggleShuffle(); player.cycleRepeat(); player.cycleRepeat(); player.cycleRepeat();
  assert.equal(player.order.indexOf(player.index), position);
  assert.equal(player.playing, true); assert.equal(audio.currentTime, 7);
  assert.deepEqual({ src: audio.src, loads: audio.loads, pauses: audio.pauses, plays: audio.playCalls }, snapshot);
  player.stop();
});
test('preloading starts below 25 seconds remaining and is not restarted on every update', () => {
  const { player, a, b } = setup(); player.setQueue(tracks, 0);
  a.currentTime = 75; a.fire('timeupdate'); assert.equal(player.preloaded, -1);
  a.currentTime = 76; a.fire('timeupdate'); assert.equal(player.preloaded, 1);
  const loads = b.loads; a.currentTime = 77; a.fire('timeupdate'); assert.equal(b.loads, loads);
  a.currentTime = 20; a.fire('timeupdate'); assert.equal(b.src, '');
  player.stop();
});
