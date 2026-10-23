// Local browser test data only; build.sh excludes tests from the WGT.
import { Api } from '../js/api.js';
const artist = { id: 'artist', name: 'Test Artist', has_image: false, album_count: 1 };
const album = { id: 'album', title: 'Test Album', artist: artist, cover_key: 'test-v1', year: 2026, track_count: 3 };
const tracks = ['First Song', 'Second Song', 'Third Song'].map((title, i) => ({ id: 'track' + i, title: title, artist: artist, artist_credit: artist.name, album: album, duration: 120, codec: 'mp3', liked: false }));
const playlist = { id: 'playlist', name: 'Test Playlist', track_count: 3, entries: tracks.map(track => ({ track: track, entry_id: track.id })) };
const station = { id: 'station', name: 'Test FM', country: 'Deutschland', tags: [], codec: 'MP3' };
export const requests = [];
function testAudio() {
  const bytes = new Uint8Array(44 + 8000 * 120);
  const view = new DataView(bytes.buffer);
  function text(offset, value) { for (let i = 0; i < value.length; i++) bytes[offset + i] = value.charCodeAt(i); }
  text(0, 'RIFF'); view.setUint32(4, bytes.length - 8, true); text(8, 'WAVE'); text(12, 'fmt ');
  view.setUint32(16, 16, true); view.setUint16(20, 1, true); view.setUint16(22, 1, true);
  view.setUint32(24, 8000, true); view.setUint32(28, 8000, true); view.setUint16(32, 1, true); view.setUint16(34, 8, true);
  text(36, 'data'); view.setUint32(40, bytes.length - 44, true); bytes.fill(128, 44);
  return URL.createObjectURL(new Blob([bytes], { type: 'audio/wav' }));
}
export function installMocks() {
  window.tizen = { tvinputdevice: { registerKeyBatch(keys, success) { window.registeredRemoteKeys = keys; success(); } }, application: { getCurrentApplication() { return { exit() { window.exitCalled = true; } }; } } };
  localStorage.removeItem('resonance.preferences'); localStorage.removeItem('resonance.token'); localStorage.setItem('resonance.server', location.origin);
  const audio = testAudio(); let favorites = [];
  Api.prototype.stream = () => audio; Api.prototype.stationStream = () => audio; Api.prototype.artwork = () => 'icon.png';
  const nativeFetch = window.fetch;
  window.fetch = async (url, options) => {
    const path = new URL(url).pathname; const method = options.method || 'GET';
    if (path.indexOf('/api/') !== 0) return nativeFetch(url, options);
    requests.push({ path: path, query: new URL(url).search, method: method, authorization: options.headers.Authorization, body: options.body });
    let data;
    if (path === '/api/auth/login') data = { token: 'fixture-token', user: { username: 'test' } };
    else if (path === '/api/auth/logout') return new Response(null, { status: 204 });
    else if (path === '/api/home') data = { recently_played: [album], recently_added: [album], playlists: [playlist], most_played: tracks };
    else if (path === '/api/albums') data = { items: [album], total: 1 };
    else if (path === '/api/artists') data = { items: [artist], total: 1 };
    else if (path === '/api/playlists') data = [playlist, { id: 'mix', name: 'Generated mix', kind: 'mix' }, { id: 'radio', name: 'Generated radio', kind: 'radio' }];
    else if (path === '/api/albums/album') data = Object.assign({}, album, { tracks: tracks });
    else if (path === '/api/artists/artist') data = Object.assign({}, artist, { albums: [album], top_tracks: tracks });
    else if (path === '/api/playlists/playlist') data = playlist;
    else if (path === '/api/me/likes/tracks') data = tracks;
    else if (/^\/api\/me\/likes\/tracks\//.test(path)) return new Response(null, { status: 204 });
    else if (path === '/api/search') data = { albums: [album], artists: [artist], playlists: [playlist], tracks: tracks };
    else if (/\/lyrics$/.test(path)) data = { synced: true, instrumental: false, lines: [{ time_ms: 0, text: 'A first line' }, { time_ms: 1000, text: 'A second line' }, { time_ms: 30000, text: 'A third line' }] };
    else if (/\/spectrum$/.test(path)) {
      const buffer = new ArrayBuffer(13 + 24 * 120); const bytes = new Uint8Array(buffer); const header = new DataView(buffer);
      bytes.set([82, 83, 80, 49]); bytes[4] = 24; header.setFloat32(5, 1, true); header.setUint32(9, 120, true);
      for (let i = 13; i < bytes.length; i++) bytes[i] = 40 + i % 180;
      return new Response(buffer);
    }
    else if (path === '/api/worldradio/stations') data = [station];
    else if (path === '/api/worldradio/favorites') data = favorites;
    else if (path === '/api/worldradio/favorites/station') {
      favorites = method === 'PUT' ? [station] : []; return new Response(null, { status: 204 });
    }
    else if (path === '/api/worldradio/stations/station/now') data = { title: 'Live Track', artist: 'Live Artist', raw: 'Live Artist - Live Track' };
    else if (path === '/api/me/plays') return new Response(null, { status: 204 });
    else throw new Error('Unexpected API request: ' + path);
    return new Response(JSON.stringify(data), { status: 200, headers: { 'Content-Type': 'application/json' } });
  };
}
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
async function wait(predicate, message) {
  const deadline = Date.now() + 6000;
  while (!predicate()) { if (Date.now() > deadline) throw new Error('Timed out: ' + message); await sleep(40); }
}
function assert(value, message) { if (!value) throw new Error(message); }
function focusId() { return document.activeElement.dataset.focusId; }
function click(id) {
  const node = document.querySelector('[data-focus-id="' + id + '"]'); assert(node, 'Missing control ' + id); node.click();
}
function key(code, value, type) {
  const event = new KeyboardEvent(type || 'keydown', { key: value || '', keyCode: code, which: code, bubbles: true, cancelable: true });
  document.activeElement.dispatchEvent(event);
}
export async function runSmoke() {
  const passed = [];
  await wait(() => document.querySelector('.login-form'), 'login');
  assert(document.documentElement.lang === 'de', 'German locale selected');
  assert(window.registeredRemoteKeys.length === 12, 'Samsung remote keys registered');
  click('login-keyboard');
  const q = document.querySelector('[data-focus-id="key-q"]'); q.focus(); key(39, 'ArrowRight');
  assert(focusId() === 'key-w', 'Keyboard owns horizontal navigation'); key(40, 'ArrowDown');
  assert(focusId() === 'key-s', 'Keyboard keeps column'); key(38, 'ArrowUp'); key(38, 'ArrowUp');
  assert(focusId() === 'key-2', 'Keyboard reaches number row'); key(38, 'ArrowUp');
  assert(focusId() === 'keyboard-value', 'Top edge leaves keyboard');
  if (window.__screenshotScene === 'keyboard') return { passed: ['keyboard scene'] };
  click('key-case'); click('key-1');
  assert(document.querySelector('[data-focus-id="key-case"]').classList.contains('shift-once'), 'Digits preserve one-shot shift');
  click('key-clear'); click('key-a');
  assert(document.querySelector('[data-focus-id="key-q"]').textContent === 'q', 'Shift resets after next letter');
  click('key-ä'); click('key-delete');
  click('key-case'); click('key-case');
  assert(document.querySelector('[data-focus-id="key-case"]').classList.contains('shift-caps'), 'Double Shift locks capitals');
  click('key-case');
  const shiftKey = document.querySelector('[data-focus-id="key-case"]'); shiftKey.focus(); key(13, 'Enter'); await sleep(450); key(13, 'Enter', 'keyup');
  assert(shiftKey.classList.contains('shift-caps'), 'Holding Shift locks capitals'); click('key-case');
  click('key-symbols'); assert(document.querySelector('[data-focus-id="key-1"]').textContent === '!', 'Symbol page');
  assert(document.querySelector('[data-focus-id="key-y"]').disabled, 'Unused symbol cells disabled');
  click('key-symbols'); click('keyboard-done');
  assert(document.querySelector('[name="username"]').value === 'A', 'Remote keyboard edit');
  document.querySelector('[name="username"]').value = 'test'; document.querySelector('[name="password"]').value = 'fixture';
  click('login-submit'); await wait(() => document.querySelector('.home-page .card'), 'home shelves');
  assert(localStorage.getItem('resonance.token') === 'fixture-token', 'Persist login token'); passed.push('login, keyboard and home shelves');
  if (window.__screenshotScene === 'home') return { passed: passed };
  key(10009); assert(!document.getElementById('modal').hidden, 'Home Back opens exit confirmation');
  key(10009); assert(document.getElementById('modal').hidden, 'Back dismisses exit confirmation');
  assert(!document.querySelector('[data-focus-id="playlist-mix"]') && !document.querySelector('[data-focus-id="playlist-radio"]'), 'Generated playlists excluded');
  assert(document.querySelector('[data-row="your-playlists"]').firstChild.dataset.focusId === 'liked-liked', 'Liked songs first');
  const first = document.querySelector('.home-page .card'); first.focus(); key(40, 'ArrowDown');
  assert(document.activeElement.closest('[data-row]').dataset.row === 'your-playlists', 'D-pad moves to next shelf');
  key(13, 'Enter'); await wait(() => document.querySelector('.detail-page .liked-cover'), 'home liked songs detail');
  assert(document.querySelectorAll('.track-row').length === 3, 'Home liked songs opens track list');
  key(10009); await wait(() => document.querySelector('.home-page'), 'home after liked');
  const playlistCard = document.querySelector('.home-page [data-focus-id="playlist-playlist"]'); playlistCard.focus(); key(13, 'Enter'); await wait(() => document.querySelector('.detail-page'), 'album detail');
  assert(focusId() === 'detail-play', 'Detail Play focused first');
  key(10009); await wait(() => document.querySelector('.home-page'), 'back home');
  assert(focusId() === 'playlist-playlist', 'Back restores card focus'); passed.push('D-pad, detail focus and view stack');
  click('nav-library'); await wait(() => document.querySelector('.library-grid .card'), 'playlists');
  click('playlist-playlist'); await wait(() => document.querySelector('.detail-page'), 'playlist detail');
  assert(document.querySelectorAll('.track-row').length === 3, 'Playlist entries decoded');
  key(10009); await wait(() => document.querySelector('.library-grid'), 'back library');
  click('library-tab-artists'); await wait(() => document.querySelector('.library-grid .artist'), 'artists');
  click('artist-artist'); await wait(() => document.querySelector('.detail-page'), 'artist detail');
  assert(document.querySelectorAll('.track-row').length === 3, 'Artist top tracks decoded');
  key(10009); await wait(() => document.querySelector('.library-grid'), 'back artists');
  click('library-tab-liked'); await wait(() => document.querySelector('.detail-page'), 'liked detail');
  assert(document.querySelectorAll('.track-row').length === 3, 'Liked array decoded'); passed.push('library, playlist, artist and liked songs');
  click('nav-search'); await wait(() => document.querySelector('.search-page'), 'search');
  const before = requests.filter(request => request.path === '/api/search').length;
  click('key-a'); click('key-b'); click('key-ä');
  await sleep(200); assert(requests.filter(request => request.path === '/api/search').length === before, '400 ms debounce');
  await wait(() => document.querySelector('.search-results .track'), 'search results');
  assert(requests.filter(request => request.path === '/api/search').length === before + 1, 'Single debounced request');
  click('track-track0'); await wait(() => document.querySelector('.now-page'), 'now playing');
  await wait(() => !document.getElementById('audio-a').paused || !document.getElementById('audio-b').paused, 'HTML audio playing');
  assert(focusId() === 'now-play', 'Transport focused');
  assert(document.querySelectorAll('.coverflow-stage .coverflow-card').length === 5, 'Coverflow renders five queue covers');
  assert(document.querySelector('.coverflow-current').dataset.trackId === 'track0', 'Coverflow centers the current cover');
  assert(document.querySelectorAll('.coverflow-neighbor').length === 2, 'Coverflow shows previous and next slots');
  const nextCoverTransform = document.querySelector('[data-offset="1"]').style.transform;
  assert(nextCoverTransform.indexOf('perspective(1000px)') >= 0 && nextCoverTransform.indexOf('rotateY(-45deg)') >= 0 && nextCoverTransform.indexOf('scale(') >= 0, 'Coverflow rotates and scales the next cover');
  assert(getComputedStyle(document.querySelector('[data-offset="2"]')).opacity === '0', 'Coverflow hides the outer covers');
  assert(getComputedStyle(document.querySelector('[data-offset="1"]')).opacity === '0.6', 'Coverflow dims neighboring covers');
  assert(getComputedStyle(document.querySelector('.coverflow-current')).transitionDuration.indexOf('0.3s') >= 0, 'Coverflow uses a 300ms slide');
  key(10252); await sleep(100); assert(document.querySelector('[data-focus-id="mini-toggle"]').getAttribute('aria-label') === 'Abspielen', 'Media pause');
  key(415); await sleep(100); assert(document.querySelector('[data-focus-id="mini-toggle"]').getAttribute('aria-label') === 'Pause', 'Media play');
  assert(document.querySelectorAll('.transport button svg').length === 9, 'All nine transport icons are SVG');
  assert(document.querySelector('[data-focus-id="now-ambient"]').getAttribute('aria-label') === 'Ruhemodus an', 'Ambient mode is enabled by default');
  click('now-ambient'); assert(document.querySelector('[data-focus-id="now-ambient"]').getAttribute('aria-label') === 'Ruhemodus aus', 'Now-playing ambient toggle updates');
  click('now-ambient');
  assert(!document.querySelector('[data-focus-id="now-rewind"]') && !document.querySelector('[data-focus-id="now-stop"]'), 'Pill controls removed');
  assert(getComputedStyle(document.querySelector('[data-focus-id="now-play"]')).width === '72px', '72px transport buttons');
  assert(getComputedStyle(document.querySelector('[data-focus-id="mini-toggle"]')).width === '56px', '56px mini buttons');
  click('now-like'); await wait(() => document.querySelector('[data-focus-id="now-like"]').getAttribute('aria-pressed') === 'true', 'like PUT');
  click('now-like'); await wait(() => document.querySelector('[data-focus-id="now-like"]').getAttribute('aria-pressed') === 'false', 'like DELETE');
  assert(requests.some(request => request.method === 'PUT' && request.path === '/api/me/likes/tracks/track0'), 'Like endpoint');
  const currentAudio = [document.getElementById('audio-a'), document.getElementById('audio-b')].find(audio => !audio.paused);
  key(19); currentAudio.currentTime = 30;
  document.querySelector('[data-focus-id="now-progress"]').focus(); key(39, 'ArrowRight'); await sleep(650); key(39, 'ArrowRight', 'keyup');
  assert(Math.abs(currentAudio.currentTime - 60) < 1, 'Held seek repeats every 300ms');
  assert(!document.querySelector('.seek-bubble').hidden, 'Seeking shows time bubble');
  await sleep(350); assert(Math.abs(currentAudio.currentTime - 60) < 1, 'Seek stops on release');
  key(37, 'ArrowLeft'); key(37, 'ArrowLeft', 'keyup'); assert(Math.abs(currentAudio.currentTime - 50) < 1, 'Left seeks ten seconds');
  key(415); key(405); await wait(() => document.querySelector('.lyric-line.active'), 'synced lyrics');
  key(10233); await wait(() => document.querySelector('.now-title').textContent === 'Second Song', 'next');
  await wait(() => !document.getElementById('audio-a').paused || !document.getElementById('audio-b').paused, 'next starts playback');
  await sleep(350);
  assert(document.querySelectorAll('.coverflow-stage').length === 1, 'Coverflow slide settles to one stage');
  assert(document.querySelector('.coverflow-current').dataset.trackId === 'track1', 'Coverflow centers the new track');
  key(10232); await wait(() => document.querySelector('.now-title').textContent === 'First Song', 'previous');
  await wait(() => !document.getElementById('audio-a').paused || !document.getElementById('audio-b').paused, 'previous starts playback');
  const continuingAudio = [document.getElementById('audio-a'), document.getElementById('audio-b')].find(audio => !audio.paused);
  const continuingSource = continuingAudio.currentSrc;
  click('now-shuffle'); assert(document.querySelector('[data-focus-id="now-shuffle"]').getAttribute('aria-pressed') === 'true', 'Shuffle enabled');
  click('now-repeat'); assert(document.querySelector('[data-focus-id="now-repeat"]').getAttribute('aria-label').indexOf('Ein Titel') >= 0, 'Repeat-one');
  assert(!continuingAudio.paused && continuingAudio.currentSrc === continuingSource, 'Shuffle/repeat preserve active audio');
  passed.push('SVG controls, likes, held seeking, search debounce, audio, preload handoff, media keys, shuffle, repeat and lyrics');
  click('now-queue'); await wait(() => document.querySelector('.queue-page'), 'queue');
  assert(document.querySelectorAll('.queue-page .track-row').length >= 1, 'Queue shows the current track');
  key(10009); await wait(() => document.querySelector('.now-page'), 'back to player from queue');
  click('now-back'); await wait(() => document.querySelector('.search-page'), 'back search');
  assert(document.querySelector('.search-input').value === 'abä', 'Search retained across back');
  click('nav-settings'); await wait(() => document.querySelector('.settings-page'), 'display settings');
  if (window.__screenshotScene === 'settings') return { passed: passed };
  assert(document.querySelector('[data-focus-id="settings-background"]').textContent.indexOf('Dunkel') >= 0, 'Dark background default');
  click('settings-background'); await wait(() => document.querySelector('.app-background').style.backgroundImage, 'dynamic background');
  click('settings-background'); assert(!document.querySelector('.app-background').style.backgroundImage, 'Dark applies immediately');
  assert(document.querySelector('[data-focus-id="settings-ambient"]').textContent.indexOf('An') >= 0, 'Ambient mode setting is enabled');
  assert(document.querySelector('.settings-ambient-description').textContent === 'Bei Inaktivität nur Cover und Titel zeigen', 'Ambient mode description');
  click('settings-ambient'); assert(JSON.parse(localStorage.getItem('resonance.preferences')).ambient === false, 'Ambient preference persists');
  click('settings-ambient');
  click('settings-visualizer');
  const spectraBefore = requests.filter(request => /\/spectrum$/.test(request.path)).length;
  click('mini-open'); await wait(() => document.querySelector('.now-page'), 'player with visualizer disabled');
  key(10233); await sleep(200);
  assert(!document.querySelector('canvas.visualizer'), 'Disabled visualizer creates no canvas');
  assert(requests.filter(request => /\/spectrum$/.test(request.path)).length === spectraBefore, 'Disabled visualizer does not download spectrum');
  assert(JSON.parse(localStorage.getItem('resonance.preferences')).visualizer === false, 'Display settings persisted');
  click('now-back'); await wait(() => document.querySelector('.settings-page'), 'back settings');
  click('settings-visualizer'); passed.push('persistent visualizer and immediate background preferences');
  click('nav-radio'); await wait(() => document.querySelector('.radio-page .station'), 'radio');
  click('station-station'); await wait(() => document.querySelector('[data-focus-id="station-favorite"]:not(:disabled)'), 'radio favorite');
  assert(!document.querySelector('.coverflow-stage'), 'Radio stations keep a single cover');
  click('station-favorite'); await wait(() => requests.some(request => request.method === 'PUT' && request.path.indexOf('/favorites/station') > 0), 'favorite PUT');
  await wait(() => document.querySelector('.now-title').textContent === 'Live Track', 'radio metadata');
  click('now-back'); await wait(() => document.querySelector('[data-row="radio-favorites"]'), 'radio favorites shelf'); passed.push('radio playback, metadata and favorite persistence');
  click('nav-settings'); await wait(() => document.querySelector('.settings-page'), 'settings');
  click('settings-logout'); await wait(() => document.querySelector('.login-form'), 'logout');
  assert(!localStorage.getItem('resonance.token'), 'Logout clears token'); passed.push('settings logout');
  // Leave a representative full-screen player for the test screenshot.
  document.querySelector('[name="username"]').value = 'test'; document.querySelector('[name="password"]').value = 'fixture';
  click('login-submit'); await wait(() => document.querySelector('.home-page .card'), 'home again');
  click('album-album'); await wait(() => document.querySelector('.detail-page'), 'detail again');
  click('detail-play'); await wait(() => document.querySelector('.now-page'), 'player again'); key(405);
  await wait(() => document.querySelector('.lyric-line.active'), 'final lyrics'); await sleep(150);
  assert(requests.filter(request => request.path !== '/api/auth/login').every(request => request.authorization === 'Bearer fixture-token'), 'All API requests have bearer auth');
  assert(document.querySelector('.now-page').scrollWidth <= document.querySelector('.now-page').clientWidth + 1, 'Now-playing layout fits');
  return { passed: passed, apiRequests: requests.length, focus: focusId() };
}
