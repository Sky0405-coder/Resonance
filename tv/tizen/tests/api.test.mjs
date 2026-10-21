import test from 'node:test';
import assert from 'node:assert/strict';
import { Api, normalizeServer } from '../js/api.js';
test('media URLs mirror Flutter auth and include cover revision', () => {
  const api = new Api(); api.server = 'https://example.test'; api.token = 'a &/b';
  const stream = new URL(api.stream({ id: 'track', codec: 'mp3' }));
  assert.equal(stream.pathname, '/api/tracks/track/stream'); assert.equal(stream.searchParams.get('token'), 'a &/b');
  assert.equal(stream.searchParams.get('format'), 'raw');
  assert.equal(new URL(api.stream({ id: 'track', codec: 'flac' })).searchParams.get('format'), 'mp3');
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
