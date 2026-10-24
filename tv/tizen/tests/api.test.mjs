import test from 'node:test';
import assert from 'node:assert/strict';
import { Api, normalizeServer, streamFormat, detectCodecs, codecMimes } from '../js/api.js';
test('media URLs mirror Flutter auth and include cover revision', () => {
  const api = new Api({ mp3: true, aac: true }); api.server = 'https://example.test'; api.token = 'a &/b';
  const stream = new URL(api.stream({ id: 'track', codec: 'mp3' }));
  assert.equal(stream.pathname, '/api/tracks/track/stream'); assert.equal(stream.searchParams.get('token'), 'a &/b');
  assert.equal(stream.searchParams.get('format'), 'raw');
  assert.equal(new URL(api.stream({ id: 'track', codec: 'flac' })).searchParams.get('format'), 'mp3');
  // Streamed, not complete=true: that waits for the whole transcode before the first note.
  assert.equal(new URL(api.stream({ id: 'track', codec: 'opus' })).searchParams.get('complete'), null);
  const cover = new URL(api.cover({ id: 'album', cover_key: 'revision' }, 600));
  assert.equal(cover.searchParams.get('v'), 'revision'); assert.equal(cover.searchParams.get('size'), '600');
  assert.equal(new URL(api.stationStream('station')).pathname, '/api/worldradio/stations/station/stream');
});
test('server URL validation keeps prefixes and rejects ambiguous addresses', () => {
  assert.equal(normalizeServer(' https://example.test/music/ '), 'https://example.test/music');
  ['file:///etc/passwd', 'hello', 'https://user:password@example.test', 'https://example.test?q=1'].forEach(value => assert.throws(() => normalizeServer(value)));
});
test('fetch uses bearer auth, JSON login contract and treats 404 spectrum as unavailable', async () => {
  const original = globalThis.fetch; const api = new Api(); api.server = 'https://example.test'; api.token = 'token';
  globalThis.fetch = async (url, options) => {
    assert.equal(options.headers.Authorization, 'Bearer token'); assert.equal(options.credentials, 'omit');
    return { status: 404, ok: false };
  };
  try { assert.equal(await api.request('/api/tracks/a/spectrum', { binary: true }), null); }
  finally { globalThis.fetch = original; }
});

test('native formats follow the TV capabilities; unknown/unsupported codecs use MP3 320', () => {
  const supported = {};
  Object.keys(codecMimes).forEach(codec => {
    supported[codec] = true;
    assert.equal(streamFormat(codec, supported), 'raw');
    assert.equal(streamFormat(codec, {}), 'mp3');
  });
  [undefined, null, 'alac', 'flac', 'opus', 'wav', 'toString', ''].forEach(codec => assert.equal(streamFormat(codec, supported), 'mp3'));
  const api = new Api(supported); api.server = 'https://example.test';
  assert.equal(new URL(api.stream({ id: 'x', codec: 'aac' })).searchParams.get('format'), 'raw');
  const fallback = new URL(api.stream({ id: 'x', codec: 'alac' }));
  assert.equal(fallback.searchParams.get('format'), 'mp3'); assert.equal(fallback.searchParams.get('bitrate'), '320');
});
test('capability detection probes each backend codec once with its explicit MIME', () => {
  const calls = [];
  const supported = detectCodecs({ canPlayType(mime) { calls.push(mime); return mime === 'audio/mpeg' ? '' : 'maybe'; } });
  assert.deepEqual(calls, Object.keys(codecMimes).map(codec => codecMimes[codec]));
  assert.equal(supported.mp3, false); assert.equal(supported.aac, true);
});
