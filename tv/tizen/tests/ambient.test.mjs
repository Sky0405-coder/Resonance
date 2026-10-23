import test from 'node:test';
import assert from 'node:assert/strict';
import { createAmbient } from '../js/ambient.js';

class FakeElement {
  constructor(tag) {
    this.tagName = tag.toUpperCase(); this.children = []; this.attributes = {}; this.style = {};
    this.className = ''; this.textContent = ''; this.parentNode = null; this.classList = {
      add: name => { if (!this.classList.contains(name)) this.className = (this.className + ' ' + name).trim(); },
      remove: name => { this.className = this.className.split(/\s+/).filter(value => value && value !== name).join(' '); },
      contains: name => this.className.split(/\s+/).indexOf(name) >= 0
    };
  }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  remove() { if (!this.parentNode) return; this.parentNode.children = this.parentNode.children.filter(child => child !== this); this.parentNode = null; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  getAttribute(name) { return this.attributes[name] === undefined ? null : this.attributes[name]; }
  get ownerDocument() { return this.documentRef || null; }
}

function setup({ playing = true, ambient = true } = {}) {
  let time = 0; let serial = 0; const tasks = new Map(); const listeners = new Map();
  const documentRef = {
    createElement(tag) { const node = new FakeElement(tag); node.documentRef = documentRef; return node; },
    addEventListener(name, listener, capture) { listeners.set(name, { listener, capture }); },
    removeEventListener(name) { listeners.delete(name); }
  };
  const root = new FakeElement('main'); root.documentRef = documentRef;
  const timers = {
    setTimeout(fn, delay) { const id = ++serial; tasks.set(id, { fn, at: time + delay, interval: 0 }); return id; },
    clearTimeout(id) { tasks.delete(id); },
    setInterval(fn, delay) { const id = ++serial; tasks.set(id, { fn, at: time + delay, interval: delay }); return id; },
    clearInterval(id) { tasks.delete(id); }
  };
  function advance(ms) {
    const target = time + ms;
    while (true) {
      const due = Array.from(tasks.entries()).filter(([, task]) => task.at <= target).sort((a, b) => a[1].at - b[1].at)[0];
      if (!due) break;
      const [id, task] = due; time = task.at;
      if (task.interval) task.at += task.interval; else tasks.delete(id);
      task.fn();
    }
    time = target;
  }
  const playerListeners = new Set();
  const player = { playing, track: { title: 'Test title', artist_credit: 'Test artist', album: { cover_url: '/cover.png' } }, station: null, now: null,
    subscribe(listener) { playerListeners.add(listener); return () => playerListeners.delete(listener); },
    emit(kind) { playerListeners.forEach(listener => listener(kind)); } };
  const preferenceListeners = new Set();
  const preferences = { value: { ambient }, subscribe(listener) { preferenceListeners.add(listener); return () => preferenceListeners.delete(listener); },
    set(value) { this.value.ambient = value; preferenceListeners.forEach(listener => listener(this.value)); } };
  const ambientView = createAmbient({ player, preferences, root, timeoutMs: 30000, now: () => time, timers });
  function keydown() {
    const event = { prevented: false, stopped: false, preventDefault() { this.prevented = true; }, stopImmediatePropagation() { this.stopped = true; } };
    listeners.get('keydown').listener(event); return event;
  }
  return { root, player, preferences, ambientView, advance, keydown, tasks, listeners, time: () => time };
}

test('ambient mode appears after 30 seconds of playback and displays current metadata', () => {
  const state = setup(); const overlay = state.ambientView.node;
  assert.equal(overlay.classList.contains('visible'), false);
  state.advance(29999); assert.equal(overlay.classList.contains('visible'), false);
  state.advance(1); assert.equal(overlay.classList.contains('visible'), true);
  assert.equal(overlay.children[0].children[1].children[0].textContent, 'Test title');
  assert.equal(overlay.children[0].children[1].children[1].textContent, 'Test artist');
  state.player.track = { title: 'Changed title', artist_credit: 'Changed artist', album: { cover_url: '/next.png' } };
  state.player.emit('track');
  assert.equal(overlay.children[0].children[1].children[0].textContent, 'Changed title');
  assert.equal(overlay.children[0].children[0].src, '/next.png');
  state.ambientView.dispose();
});

test('a key wakes and swallows its event, then playback returns to ambient after inactivity', () => {
  const state = setup(); state.advance(30000);
  assert.equal(state.ambientView.node.classList.contains('visible'), true);
  const event = state.keydown();
  assert.equal(event.prevented, true); assert.equal(event.stopped, true);
  assert.equal(state.ambientView.node.classList.contains('visible'), false);
  state.advance(29999); assert.equal(state.ambientView.node.classList.contains('visible'), false);
  state.advance(1); assert.equal(state.ambientView.node.classList.contains('visible'), true);
  state.ambientView.dispose(); assert.equal(state.listeners.size, 0); assert.equal(state.tasks.size, 0);
});

test('paused playback and a disabled preference never show ambient mode', () => {
  const paused = setup({ playing: false }); paused.advance(60000);
  assert.equal(paused.ambientView.node.classList.contains('visible'), false);
  paused.player.playing = true; paused.player.emit('state'); paused.advance(29999);
  assert.equal(paused.ambientView.node.classList.contains('visible'), false);
  paused.advance(1);
  assert.equal(paused.ambientView.node.classList.contains('visible'), true); paused.ambientView.dispose();

  const disabled = setup({ ambient: false }); disabled.advance(60000);
  assert.equal(disabled.ambientView.node.classList.contains('visible'), false);
  disabled.preferences.set(true); disabled.advance(30000);
  assert.equal(disabled.ambientView.node.classList.contains('visible'), true);
  disabled.preferences.set(false); assert.equal(disabled.ambientView.node.classList.contains('visible'), false);
  assert.equal(disabled.tasks.size, 0); disabled.ambientView.dispose();
});
