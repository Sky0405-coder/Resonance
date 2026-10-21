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
    [audioA, audioB].forEach(audio => {
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
        this.preload();
        this.emit('time');
      });
      audio.addEventListener('ended', () => { if (audio === this.audio && !this.station) this.next(false); });
      audio.addEventListener('error', () => {
        if (audio === this.audio && audio.getAttribute('src')) { this.onError(t('playbackError')); this.emit('state'); }
      });
    });
    window.addEventListener('pagehide', () => this.flush());
    document.addEventListener('visibilitychange', () => { if (document.hidden) this.flush(); });
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
  setQueue(tracks, index, context, shuffle) {
    if (!tracks.length) return;
    this.flush();
    this.clearRadio();
    this.station = null;
    this.queue = tracks.slice();
    this.index = Math.max(0, Math.min(index || 0, tracks.length - 1));
    this.shuffle = !!shuffle;
    this.order = playbackOrder(tracks.length, this.index, this.shuffle);
    this.context = context || null;
    this.preloaded = -1;
    this.load(this.index, false);
  }
  load(index, usePreload) {
    this.generation++;
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
    this.emit('track');
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
    const index = !this.station && this.track && this.duration > 0 && remaining < 25 ? this.nextIndex(false) : -1;
    if (index === this.preloaded) return;
    this.release(this.spare);
    this.preloaded = index;
    if (index >= 0) {
      this.spare.src = this.api.stream(this.queue[index]);
      this.spare.load();
    }
  }
  play() {
    if (!this.track && !this.station) return;
    const intent = { audio: this.audio, generation: this.generation, retried: false, waiting: this.audio.readyState < 3 };
    this.playIntent = intent;
    if (!intent.waiting) this.attemptPlay(intent);
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
    this.repeat = { off: 'all', all: 'one', one: 'off' }[this.repeat];
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
