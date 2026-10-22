export function normalizePreferences(value) {
  const saved = value || {};
  return {
    visualizer: saved.visualizer !== false, background: saved.background === 'dynamic' ? 'dynamic' : 'dark',
    autoplay: saved.autoplay !== false
  };
}
export class Preferences {
  constructor(storage) {
    this.storage = storage || (typeof localStorage !== 'undefined' ? localStorage : null);
    this.listeners = new Set();
    let saved;
    try { saved = JSON.parse(this.storage.getItem('resonance.preferences')); } catch (_) { saved = null; }
    this.value = normalizePreferences(saved);
  }
  set(key, value) {
    const next = Object.assign({}, this.value); next[key] = value;
    this.value = normalizePreferences(next);
    try { this.storage.setItem('resonance.preferences', JSON.stringify(this.value)); } catch (_) { /* Keep session preferences when storage is unavailable. */ }
    this.listeners.forEach(listener => listener(this.value));
  }
  subscribe(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
}
