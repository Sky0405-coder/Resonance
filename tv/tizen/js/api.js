import { language, t } from './i18n.js';
export const DEFAULT_SERVER = 'https://resonance.k-node.de';
export function normalizeServer(value) {
  let url;
  try { url = new URL(value.trim()); } catch (_) { throw new Error(t('invalidServer')); }
  if (!/^https?:$/.test(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error(t('invalidServer'));
  }
  return url.href.replace(/\/+$/, '');
}
function stored(key, fallback) {
  try { return localStorage.getItem(key) || fallback; } catch (_) { return fallback; }
}
export class Api {
  constructor() {
    this.server = stored('resonance.server', DEFAULT_SERVER);
    this.token = stored('resonance.token', '');
    this.onUnauthorized = null;
  }
  save(server, token) {
    this.server = normalizeServer(server);
    this.token = token || '';
    try {
      localStorage.setItem('resonance.server', this.server);
      if (this.token) localStorage.setItem('resonance.token', this.token);
      else localStorage.removeItem('resonance.token');
    } catch (_) { /* Session still works if TV storage is full. */ }
  }
  url(path, query, media) {
    const url = new URL(this.server + path);
    Object.keys(query || {}).forEach(key => {
      if (query[key] !== undefined && query[key] !== null) url.searchParams.set(key, query[key]);
    });
    if (media && this.token) url.searchParams.set('token', this.token);
    return url.href;
  }
  async request(path, options) {
    const opts = options || {};
    const headers = { 'Accept-Language': language };
    const requestToken = this.token;
    if (requestToken) headers.Authorization = 'Bearer ' + requestToken;
    if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), opts.binary ? 60000 : 20000);
    try {
      const response = await fetch(this.url(path, opts.query), {
        method: opts.method || 'GET', headers: headers,
        body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
        signal: controller.signal, credentials: 'omit'
      });
      if (response.status === 404 && opts.binary) return null;
      if (!response.ok) {
        let detail = '';
        try { const data = await response.json(); detail = typeof data.detail === 'string' ? data.detail : ''; } catch (_) { /* HTTP fallback. */ }
        const error = new Error(detail || ('HTTP ' + response.status));
        error.status = response.status;
        if (response.status === 401 && requestToken && requestToken === this.token && this.onUnauthorized) this.onUnauthorized();
        throw error;
      }
      if (response.status === 204) return null;
      return opts.binary ? await response.arrayBuffer() : await response.json();
    } catch (error) {
      if (error.status) throw error;
      throw new Error(t('networkError'));
    } finally { clearTimeout(timer); }
  }
  async login(server, username, password) {
    this.save(server, '');
    const data = await this.request('/api/auth/login', {
      method: 'POST', body: { username: username, password: password, device_name: 'Resonance Samsung TV' }
    });
    this.save(this.server, data.token);
    return data.user;
  }
  cover(album, size) {
    return this.url('/api/albums/' + encodeURIComponent(album.id) + '/cover', { size: size || 300, v: album.cover_key }, true);
  }
  artwork(kind, item, size) {
    if (kind === 'track') return item.album ? this.cover(item.album, size) : 'icon.png';
    if (kind === 'album') return this.cover(item, size);
    if (kind === 'playlist') return this.url('/api/playlists/' + encodeURIComponent(item.id) + '/cover', { size: size || 300, v: item.cover_key }, true);
    if (kind === 'liked') return this.url('/api/me/likes/cover', { size: size || 300 }, true);
    if (kind === 'artist') {
      if (item.has_image) return this.url('/api/artists/' + encodeURIComponent(item.id) + '/image', { size: size || 300 }, true);
      if (item.cover_album_id) return this.cover({ id: item.cover_album_id }, size);
    }
    if (kind === 'station' && /^https?:\/\//i.test(item.favicon || '')) return item.favicon;
    return 'icon.png';
  }
  stream(track) {
    // Raw MP3/AAC supports Range; other formats use the TV-compatible MP3 transcoder.
    const format = /^(mp3|aac)$/.test(track.codec || '') ? 'raw' : 'mp3';
    return this.url('/api/tracks/' + encodeURIComponent(track.id) + '/stream', { format: format, bitrate: 192 }, true);
  }
  stationStream(id) { return this.url('/api/worldradio/stations/' + encodeURIComponent(id) + '/stream', {}, true); }
}
