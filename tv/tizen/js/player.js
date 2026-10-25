import { t } from './i18n.js';
export function playbackOrder(length, start, shuffle, random) {
  const indices = Array.from({ length: length }, (_, i) => i).filter(i => i !== start);
  if (shuffle) {
    for (let i = indices.length - 1; i > 0; i--) {
      const j = Math.floor((random || Math.random)() * (i + 1));
      const value = indices[i]; indices[i] = indices[j]; indices[j] = value;
    }
    return [start].concat(indices);
  }
  return Array.from({ length: length }, (_, i) => i);
}
// Preserve the played prefix and current slot; only the unplayed suffix changes.
export function reorderUpcoming(order, current, shuffle, random) {
  const position = order.indexOf(current);
  if (position < 0) return order.slice();
  const upcoming = order.slice(position + 1);
  if (shuffle) {
    for (let i = upcoming.length - 1; i > 0; i--) {
      const j = Math.floor((random || Math.random)() * (i + 1));
      const value = upcoming[i]; upcoming[i] = upcoming[j]; upcoming[j] = value;
    }
  } else upcoming.sort((a, b) => a - b);
  return order.slice(0, position + 1).concat(upcoming);
}
export class Player {
  constructor(api, audioA, audioB, onError) {
    this.api = api;
    this.audio = audioA;
    this.spare = audioB;
    this.onError = onError;
    this.queue = [];
    this.index = -1;
    this.order = [];
    this.shuffle = false;
    this.repeat = 'off';
    this.station = null;
    this.now = null;
    this.listeners = new Set();
    this.listened = 0;
    this.lastPosition = 0;
    this.context = null;
    this.preloaded = -1;
    this.radioTimer = null;
    this.generation = 0;
    this.playIntent = null;
    this.autoplay = true;
    this.autoplayTried = new Set();
    this.autoplayRequest = null;
    this.diagnostics = [];
    this.preloadNext = false;
    [audioA, audioB].forEach(audio => {
      // Diagnostics: the TV gives no logs, so the player's own view of a stop is sent to the server.
      ['error', 'stalled', 'waiting', 'ended', 'pause', 'playing', 'abort', 'emptied'].forEach(name =>
        audio.addEventListener(name, () => this.diagnose(name, audio)));
      ['play', 'pause', 'waiting', 'playing', 'loadedmetadata', 'durationchange'].forEach(name => audio.addEventListener(name, () => {
        if (audio === this.audio) this.emit('state');
      }));
      audio.volume = Math.min(1, audio.volume === undefined ? 1 : audio.volume);
      audio.addEventListener('canplay', () => {
        const intent = this.playIntent;
        if (intent && intent.audio === audio && intent.waiting) this.attemptPlay(intent);
      });
      audio.addEventListener('timeupdate', () => {
        if (audio !== this.audio) return;
        const delta = audio.currentTime - this.lastPosition;
        if (!audio.paused && delta > 0 && delta < 2 && !this.station) this.listened += delta;
        this.lastPosition = audio.currentTime;
        if (this.recoveries && audio.currentTime - this.recoveredAt > 30) this.recoveries = 0;
        this.preload();
        this.maybeAutoplay();
        this.emit('time');
      });
      audio.addEventListener('ended', () => { if (audio === this.audio && !this.station) this.next(false); });
      audio.addEventListener('error', () => {
        if (audio !== this.audio || !audio.getAttribute('src')) return;
        const track = this.track;
        // The TV's player gives up when the connection drops mid-song (seen at 1:23, 2:28, 3:04) instead of asking
        // again: reload the song and continue where it stopped.
        if (track && !this.station && this.lastPosition > 1 && this.recover(this.lastPosition)) return;
        // The TV can claim support for a codec it then fails to decode; fall back to MP3 for that codec.
        if (track && !this.station && audio.getAttribute('src').indexOf('format=raw') >= 0) {
          this.api.supportedCodecs[track.codec] = false;
          this.load(this.index, false);
          return;
        }
        this.onError(t('playbackError')); this.emit('state');
      });
    });
    window.addEventListener('pagehide', () => this.flush());
    document.addEventListener('visibilitychange', () => { if (document.hidden) this.flush(); });
  }
  diagnose(name, audio, extra) {
    if (!this.api.request || !audio) return;
    let buffered = null;
    try { if (audio.buffered && audio.buffered.length) buffered = audio.buffered.end(audio.buffered.length - 1); } catch (_) { /* ignore */ }
    const track = this.track;
    this.diagnostics.push(Object.assign({
      e: name, ms: Date.now(), current: audio === this.audio, pos: audio.currentTime, dur: audio.duration, buffered: buffered,
      ns: audio.networkState, rs: audio.readyState, err: audio.error ? audio.error.code : null, paused: audio.paused,
      track: track ? track.id : null, src: String(audio.getAttribute('src') || '').split('?')[1] || ''
    }, extra || {}));
    if (this.diagnostics.length > 150) this.diagnostics.shift();
    if (name === 'error' || name === 'ended' || name === 'emptied' || name === 'recover') this.sendDiagnostics();
    else if (!this.diagnosticsTimer) this.diagnosticsTimer = setTimeout(() => this.sendDiagnostics(), 15000);
  }
  sendDiagnostics() {
    clearTimeout(this.diagnosticsTimer); this.diagnosticsTimer = null;
    if (!this.diagnostics.length) return;
    if (!this.api.token) { this.diagnostics = []; return; }
    const events = this.diagnostics.splice(0).map(event => Object.assign({}, event, { src: event.src.replace(/token=[^&]*/, '') }));
    Promise.resolve(this.api.request('/api/diagnostics/events', { method: 'POST', body: { events: events } })).catch(() => {});
  }
  get track() { return this.queue[this.index] || null; }
  get playing() { return !this.audio.paused && !this.audio.ended; }
  get duration() { return this.track ? this.track.duration : 0; }
  subscribe(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  emit(kind) { this.listeners.forEach(listener => listener(kind)); }
  async flush() {
    const track = this.track;
    const seconds = this.listened;
    this.listened = 0;
    if (track && !this.station && seconds > 0 && (seconds >= 30 || (track.duration > 0 && seconds >= track.duration / 2))) {
      try {
        await this.api.request('/api/me/plays', { method: 'POST', body: { track_id: track.id, seconds_played: seconds, context: this.context }, });
      } catch (_) { /* Playback must continue even if reporting is unavailable. */ }
    }
  }
  release(audio) { audio.pause(); audio.removeAttribute('src'); audio.load(); }
  clearRadio() { clearInterval(this.radioTimer); this.radioTimer = null; this.now = null; }
  // title: shown in the player as what is playing (playlist, album, artist or Liked Songs name).
  setQueue(tracks, index, context, shuffle, title) {
    if (!tracks.length) return;
    this.flush();
    this.clearRadio();
    this.station = null;
    this.queueGeneration = (this.queueGeneration || 0) + 1; this.autoplayTried.clear(); this.autoplayRequest = null;
    this.queue = tracks.slice();
    this.index = Math.max(0, Math.min(index || 0, tracks.length - 1));
    this.shuffle = !!shuffle;
    this.order = playbackOrder(tracks.length, this.index, this.shuffle);
    this.context = context || null;
    this.contextTitle = title || null;
    this.preloaded = -1;
    this.load(this.index, false);
  }
  recover(position) {
    if (this.recoveries >= 5) return false;
    this.recoveries++; this.recoveredAt = position;
    this.diagnose('recover', this.audio, { at: position, attempt: this.recoveries });
    const audio = this.audio; const generation = this.generation;
    const seek = () => {
      audio.removeEventListener('loadedmetadata', seek);
      if (generation !== this.generation || audio !== this.audio) return;
      try { audio.currentTime = position; } catch (_) { /* the element seeks once it can */ }
    };
    audio.addEventListener('loadedmetadata', seek);
    audio.src = this.api.stream(this.track);
    audio.load();
    this.play();
    return true;
  }
  load(index, usePreload) {
    this.generation++;
    this.recoveries = 0;
    this.playIntent = null;
    this.index = index;
    this.listened = 0;
    this.lastPosition = 0;
    if (usePreload && this.preloaded === index) {
      const old = this.audio;
      this.audio = this.spare;
      this.spare = old;
      this.release(this.spare);
    } else {
      this.release(this.spare);
      this.release(this.audio);
      this.audio.src = this.api.stream(this.queue[index]);
      this.audio.load();
    }
    this.preloaded = -1;
    this.play();
    this.preload();
    this.prepareUpcoming();
    this.emit('track');
  }
  // The next two songs get transcoded on the server while this one plays.
  prepareUpcoming() {
    if (this.station || !this.api.prepare) return;
    this.upcoming().slice(0, 2).forEach(index => this.api.prepare(this.queue[index]));
  }
  nextIndex(manual) {
    if (this.index < 0) return -1;
    if (!manual && this.repeat === 'one') return this.index;
    const position = this.order.indexOf(this.index);
    if (position + 1 < this.order.length) return this.order[position + 1];
    return this.repeat === 'all' ? this.order[0] : -1;
  }
  preload() {
    const remaining = this.duration - this.audio.currentTime;
    // Off on the TV: it has one audio decoder, loading the second element paused the playing song 25 s before its
    // end (diagnostics, 2026-10-24). The server prepares the next songs instead, so they still start quickly.
    const index = this.preloadNext && !this.station && this.track && this.duration > 0 && remaining < 25 ? this.nextIndex(false) : -1;
    if (index === this.preloaded) return;
    this.release(this.spare);
    this.preloaded = index;
    if (index >= 0) {
      this.spare.src = this.api.stream(this.queue[index]);
      this.spare.load();
    }
  }
  // Like the app: on the last track of the queue, append recommendations based on the recent queue.
  maybeAutoplay() {
    if (!this.autoplay || this.station || !this.track || this.repeat !== 'off' || this.audio.paused) return;
    if (this.order.indexOf(this.index) !== this.order.length - 1 || this.autoplayRequest) return;
    const id = this.track.id;
    if (this.autoplayTried.has(id)) return;
    this.autoplayTried.add(id);
    const generation = this.queueGeneration;
    const request = this.api.request('/api/recommendations', { method: 'POST', body: {
      track_ids: this.queue.slice(-20).map(track => track.id), exclude_ids: this.queue.map(track => track.id), limit: 20 } });
    this.autoplayRequest = request;
    Promise.resolve(request).then(tracks => {
      if (generation !== this.queueGeneration || !this.track || this.track.id !== id) return;
      const seen = new Set(this.queue.map(track => track.id));
      (tracks || []).filter(track => track && !seen.has(track.id) && seen.add(track.id)).forEach(track => {
        this.order.push(this.queue.length); this.queue.push(track);
      });
      this.emit('state');
    }, () => { /* Offline or an older server: leave the queue as it is. */ }).then(() => {
      if (this.autoplayRequest === request) this.autoplayRequest = null;
    });
  }
  // Queue indexes after the current one, in playback order (respects shuffle).
  upcoming() {
    const position = this.order.indexOf(this.index);
    return position < 0 ? [] : this.order.slice(position + 1);
  }
  jumpTo(index) {
    if (this.station || !this.queue[index] || index === this.index) return;
    this.flush();
    this.load(index, true);
  }
  play() {
    if (!this.track && !this.station) return;
    // Tizen only buffers after play() is called, so never wait for canplay before the first attempt.
    const intent = { audio: this.audio, generation: this.generation, retried: false, waiting: false };
    this.playIntent = intent;
    this.attemptPlay(intent);
  }
  attemptPlay(intent) {
    if (intent !== this.playIntent || intent.generation !== this.generation || intent.audio !== this.audio) return;
    intent.waiting = false;
    const failed = () => {
      if (intent !== this.playIntent || intent.generation !== this.generation) return;
      if (!intent.retried) {
        intent.retried = true;
        intent.waiting = true;
        // A preloaded element may already have fired canplay. Its ready state is equivalent.
        if (intent.audio.readyState >= 3) this.attemptPlay(intent);
      } else {
        this.playIntent = null;
        this.onError(t('playbackError')); this.emit('state');
      }
    };
    try {
      const result = intent.audio.play();
      if (result && result.catch) result.catch(failed);
    } catch (_) { failed(); }
  }
  pause() { this.playIntent = null; this.audio.pause(); }
  toggle() { if (this.playing) this.pause(); else this.play(); }
  stop() {
    this.flush();
    this.generation++;
    this.playIntent = null;
    this.clearRadio();
    this.station = null;
    this.queueGeneration = (this.queueGeneration || 0) + 1; this.autoplayRequest = null;
    this.queue = []; this.order = []; this.index = -1; this.preloaded = -1;
    this.release(this.audio); this.release(this.spare);
    this.emit('track');
  }
  next(manual) {
    if (this.station || !this.track) return;
    const index = this.nextIndex(manual !== false);
    this.flush();
    if (index < 0) { this.pause(); this.emit('state'); return; }
    this.load(index, true);
  }
  previous() {
    if (this.station || !this.track) return;
    if (this.audio.currentTime > 3 && this.seekTo(0)) { this.play(); return; }
    const position = this.order.indexOf(this.index);
    const index = position > 0 ? this.order[position - 1] : (this.repeat === 'all' ? this.order[this.order.length - 1] : this.order[0]);
    this.flush();
    this.load(index, false);
  }
  seekTo(position) {
    if (this.station || !this.track) return false;
    const ranges = this.audio.seekable;
    const target = Math.max(0, Math.min(this.duration, position));
    for (let i = 0; i < ranges.length; i++) {
      if (target >= ranges.start(i) && target <= ranges.end(i)) {
        this.lastPosition = target;
        this.audio.currentTime = target;
        this.emit('time');
        return true;
      }
    }
    this.onError(t('seekUnavailable'));
    return false;
  }
  seek(delta) { this.seekTo(this.audio.currentTime + delta); }
  toggleShuffle() {
    this.shuffle = !this.shuffle;
    this.order = reorderUpcoming(this.order, this.index, this.shuffle);
    if (!this.station) this.preload();
    this.emit('state');
  }
  cycleRepeat() {
    this.repeat = this.repeat === 'off' ? 'one' : 'off';
    if (!this.station) this.preload();
    this.emit('state');
  }
  playStation(station) {
    this.stop();
    this.station = station;
    this.generation++;
    this.audio.src = this.api.stationStream(station.id);
    this.audio.load();
    this.play();
    const generation = this.generation;
    const update = async () => {
      try {
        const now = await this.api.request('/api/worldradio/stations/' + encodeURIComponent(station.id) + '/now');
        if (generation === this.generation) { this.now = now; this.emit('metadata'); }
      } catch (_) { /* Stations are playable without ICY metadata. */ }
    };
    update();
    this.radioTimer = setInterval(update, 12000);
    this.emit('track');
  }
}
