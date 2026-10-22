import test from 'node:test';
import assert from 'node:assert/strict';
import { Preferences, normalizePreferences } from '../js/preferences.js';
import { userPlaylists } from '../js/views/home.js';
test('display preferences default to visualizer on and a dark background', () => {
  assert.deepEqual(normalizePreferences(), { visualizer: true, background: 'dark', autoplay: true });
  assert.deepEqual(normalizePreferences({ visualizer: false, background: 'dynamic', autoplay: false }), { visualizer: false, background: 'dynamic', autoplay: false });
  assert.deepEqual(normalizePreferences({ visualizer: 'false', background: 'invalid' }), { visualizer: true, background: 'dark', autoplay: true });
});
test('preferences persist, notify immediately and tolerate blocked or corrupt storage', () => {
  let saved = 'invalid JSON';
  const storage = { getItem() { return saved; }, setItem(key, value) { assert.equal(key, 'resonance.preferences'); saved = value; } };
  const preferences = new Preferences(storage); let changes = 0;
  const unsubscribe = preferences.subscribe(() => changes++);
  preferences.set('visualizer', false); preferences.set('background', 'dynamic');
  assert.equal(changes, 2); unsubscribe(); preferences.set('background', 'dark'); assert.equal(changes, 2);
  assert.deepEqual(new Preferences(storage).value, { visualizer: false, background: 'dark', autoplay: true });
  const blocked = new Preferences({ getItem() { throw new Error(); }, setItem() { throw new Error(); } });
  blocked.set('visualizer', false); assert.equal(blocked.value.visualizer, false);
});
test('home playlists mirror Flutter: exclude generated mixes and radios, keep own/saved user playlists', () => {
  const items = [{ id: 'old' }, { id: 'own', kind: 'user' }, { id: 'saved', kind: 'user' }, { id: 'mix', kind: 'mix' }, { id: 'radio', kind: 'radio' }];
  assert.deepEqual(userPlaylists(items).map(item => item.id), ['old', 'own', 'saved']);
  assert.equal(items.length, 5);
});
