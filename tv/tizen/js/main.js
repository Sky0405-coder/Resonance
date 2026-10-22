import { Api, normalizeServer } from './api.js';
import { language, t } from './i18n.js';
import { Navigation } from './nav.js';
import { bindKeys } from './keys.js';
import { Player } from './player.js';
import { Preferences } from './preferences.js';
import { coverColor } from './visualizer.js';
import { setIcon } from './icons.js';
import { el, button, row, image, time, artistName, errorBox, releaseImages } from './ui.js';
import { keyboard, editText } from './views/keyboard.js';
import { loginView } from './views/login.js';
import { homeView } from './views/home.js';
import { searchView } from './views/search.js';
import { libraryView } from './views/library.js';
import { detailView } from './views/detail.js';
import { radioView } from './views/radio.js';
import { settingsView } from './views/settings.js';
import { nowPlayingView } from './views/now-playing.js';

const root = document.getElementById('app');
const view = document.getElementById('view');
const rail = document.getElementById('rail');
const mini = document.getElementById('mini');
const modal = document.getElementById('modal');
const nav = new Navigation(root);
const api = new Api();
const preferences = new Preferences();
const backgroundLayer = el('div', 'app-background'); backgroundLayer.setAttribute('aria-hidden', 'true');
root.insertBefore(backgroundLayer, root.firstChild);
const app = {
  stack: [], current: null, controller: null, epoch: 0, closeModal: null, toastTimer: null,
  toast(message) {
    const node = document.getElementById('toast'); node.textContent = message; node.classList.add('visible');
    clearTimeout(this.toastTimer); this.toastTimer = setTimeout(() => node.classList.remove('visible'), 5000);
  },
  capture() {
    if (!this.current) return;
    this.current.focus = document.activeElement && document.activeElement.dataset.focusId;
    this.current.scroll = view.scrollTop;
    this.current.rows = Array.from(view.querySelectorAll('[data-row]')).map(node => ({ id: node.dataset.row, left: node.scrollLeft, top: node.scrollTop }));
  },
  async navigate(route, replace) {
    if (this.closeModal) this.closeModal();
    this.capture();
    if (this.current && !replace) this.stack.push(this.current);
    this.current = route;
    await this.render();
  },
  async render() {
    const epoch = ++this.epoch;
    const route = this.current;
    if (this.controller && this.controller.dispose) this.controller.dispose();
    this.controller = null;
    root.classList.toggle('login-mode', route.name === 'login'); root.classList.toggle('now-mode', route.name === 'now');
    Array.from(rail.querySelectorAll('[data-route]')).forEach(node => node.classList.toggle('selected', node.dataset.route === route.name));
    releaseImages(view);
    view.textContent = ''; view.scrollTop = 0; view.appendChild(el('p', 'loading', t('loading')));
    const ctx = { api: api, preferences: preferences, nav: nav, player: player, app: this, route: route, active: () => epoch === this.epoch };
    const loaders = { login: loginView, home: homeView, search: searchView, library: libraryView, detail: detailView, radio: radioView, settings: settingsView, now: nowPlayingView };
    try {
      const controller = await loaders[route.name](ctx);
      if (epoch !== this.epoch) { if (controller.dispose) controller.dispose(); releaseImages(controller.node); return; }
      this.controller = controller;
      view.textContent = ''; view.appendChild(controller.node);
      if (controller.mounted) controller.mounted();
      nav.restore(route.focus || controller.initialFocus, view);
      // Restore shelves as well as the vertical page position after returning from a detail view.
      (route.rows || []).forEach(saved => {
        Array.from(view.querySelectorAll('[data-row]')).filter(node => node.dataset.row === saved.id).forEach(node => {
          node.scrollLeft = saved.left; node.scrollTop = saved.top;
        });
      });
      if (route.scroll) view.scrollTop = route.scroll;
    } catch (error) {
      if (epoch !== this.epoch) return;
      view.textContent = ''; view.appendChild(errorBox(error.message, () => this.render())); nav.first(view);
    }
  },
  back() {
    if (this.closeModal) { this.closeModal(); return; }
    if (this.current.name === 'home') { this.confirmExit(); return; }
    if (this.stack.length) { this.capture(); this.current = this.stack.pop(); this.render(); return; }
    if (this.current.name !== 'home' && this.current.name !== 'login') { this.navigate({ name: 'home' }, true); return; }
    this.confirmExit();
  },
  authenticated() { this.stack = []; this.navigate({ name: 'home' }, true); },
  async logout() {
    player.stop();
    try { await api.request('/api/auth/logout', { method: 'POST' }); } catch (_) { /* Always clear the local session. */ }
    api.save(api.server, ''); this.stack = []; this.navigate({ name: 'login' }, true);
  },
  async changeServer(value) {
    const server = normalizeServer(value);
    if (server === api.server) { this.toast(t('saved')); return; }
    await this.logout(); api.save(server, ''); this.navigate({ name: 'login' }, true);
  },
  showModal(content, onClose) {
    if (this.closeModal) this.closeModal();
    const previous = document.activeElement;
    modal.textContent = ''; modal.appendChild(content); modal.hidden = false;
    modal.setAttribute('role', 'dialog'); modal.setAttribute('aria-modal', 'true');
    nav.scope = modal;
    this.closeModal = () => {
      modal.hidden = true; modal.textContent = ''; nav.scope = root; this.closeModal = null;
      if (onClose) onClose();
      if (previous && previous.isConnected) nav.focus(previous);
    };
    nav.first(modal);
  },
  textKeyboard(source, extended) {
    const panel = el('div', 'keyboard-dialog'); panel.appendChild(el('h2', '', t('loginKeyboard')));
    const input = el('input', 'keyboard-value'); input.type = source.type || 'text'; input.value = source.value;
    input.setAttribute('aria-label', source.getAttribute('aria-label') || source.name || t('loginKeyboard'));
    input.readOnly = typeof tizen !== 'undefined'; input.dataset.focusable = ''; input.dataset.focusId = 'keyboard-value';
    panel.appendChild(input);
    panel.appendChild(keyboard((action, text) => { input.value = editText(input.value, action, text); }, extended));
    const actions = row('keyboard-dialog-actions');
    actions.appendChild(button(t('keyboardDone'), () => {
      source.value = input.value; source.dispatchEvent(new Event('input', { bubbles: true })); this.closeModal();
    }, 'keyboard-done', 'button primary'));
    actions.appendChild(button(t('cancel'), () => this.closeModal(), 'keyboard-cancel')); panel.appendChild(actions);
    this.showModal(panel);
    nav.focus(panel.querySelector('[data-focus-id="key-q"]'));
  },
  confirmExit() {
    const panel = el('div', 'exit-dialog'); panel.appendChild(el('h1', '', t('exit')));
    const actions = row('exit-actions');
    actions.appendChild(button(t('cancel'), () => this.closeModal(), 'exit-cancel', 'button primary'));
    actions.appendChild(button(t('yes'), () => {
      player.stop();
      if (typeof tizen !== 'undefined' && tizen.application) tizen.application.getCurrentApplication().exit();
      else { this.closeModal(); this.toast(t('exit')); }
    }, 'exit-confirm'));
    panel.appendChild(actions); this.showModal(panel);
  }
};
const player = new Player(api, document.getElementById('audio-a'), document.getElementById('audio-b'), message => app.toast(message));
api.onUnauthorized = () => {
  api.save(api.server, ''); player.listened = 0; player.stop();
  app.toast(t('expired')); app.stack = []; app.navigate({ name: 'login' }, true);
};

const brand = el('div', 'rail-brand'); brand.appendChild(image('icon.png', 'rail-logo')); brand.appendChild(el('strong', '', 'Resonance')); rail.appendChild(brand);
const navigation = row('rail', 'rail-links');
[['home', '⌂'], ['search', '⌕'], ['library', '▤'], ['radio', '◉'], ['settings', '⚙']].forEach(pair => {
  const link = button('', () => { if (app.current.name !== pair[0]) app.navigate({ name: pair[0] }); }, 'nav-' + pair[0], 'nav-link');
  link.dataset.route = pair[0]; link.appendChild(el('span', 'nav-icon', pair[1])); link.appendChild(el('span', '', t(pair[0])));
  navigation.appendChild(link);
});
rail.appendChild(navigation); rail.appendChild(el('p', 'rail-foot muted', t('welcome')));

const miniArt = image('icon.png', 'mini-art');
const miniOpen = button('', () => app.navigate({ name: 'now' }), 'mini-open', 'mini-open');
miniOpen.appendChild(miniArt); const miniInfo = el('span', 'mini-info');
const miniTitle = el('strong', '', t('nothingPlaying')); const miniArtist = el('span', 'muted'); miniInfo.appendChild(miniTitle); miniInfo.appendChild(miniArtist); miniOpen.appendChild(miniInfo);
mini.appendChild(miniOpen);
const miniControls = row('mini-controls', 'mini-controls');
const miniPrevious = button('', () => player.previous(), 'mini-previous', 'button icon-button'); setIcon(miniPrevious, 'skip_previous'); miniControls.appendChild(miniPrevious);
const miniToggle = button('', () => player.toggle(), 'mini-toggle', 'button primary icon-button'); miniControls.appendChild(miniToggle);
const miniNext = button('', () => player.next(), 'mini-next', 'button icon-button'); setIcon(miniNext, 'skip_next'); miniControls.appendChild(miniNext); mini.appendChild(miniControls);
const miniTime = el('div', 'mini-time muted', '0:00 / 0:00'); mini.appendChild(miniTime);
miniControls.children[0].setAttribute('aria-label', t('previous')); miniControls.children[2].setAttribute('aria-label', t('next'));
function updateMini(kind) {
  if (kind !== 'time') {
    const track = player.track; const station = player.station; const now = player.now;
    miniTitle.textContent = station ? (now && (now.title || now.raw)) || station.name : track ? track.title : t('nothingPlaying');
    miniArtist.textContent = station ? station.name : track ? artistName(track) : '';
    const url = track ? api.artwork('track', track, 96) : station ? api.artwork('station', station, 96) : 'icon.png';
    if (miniArt.getAttribute('src') !== url) miniArt.src = url;
    setIcon(miniToggle, player.playing ? 'pause' : 'play_arrow'); miniToggle.setAttribute('aria-label', t(player.playing ? 'pause' : 'play'));
    miniControls.children[0].disabled = !!station || !track; miniControls.children[2].disabled = !!station || !track;
  }
  miniTime.textContent = player.station ? t('live') : time(player.audio.currentTime) + ' / ' + time(player.duration);
}
player.subscribe(updateMini); updateMini('track');
let backgroundVersion = 0;
function updateBackground() {
  const version = ++backgroundVersion;
  backgroundLayer.style.backgroundImage = '';
  if (preferences.value.background !== 'dynamic') return;
  const item = player.track || player.station;
  if (!item) return;
  const cover = api.artwork(player.station ? 'station' : 'track', item, 96);
  coverColor(cover).then(color => {
    if (version !== backgroundVersion) return;
    backgroundLayer.style.backgroundImage = 'linear-gradient(rgba(18,18,18,0.55), rgba(18,18,18,0.9)), radial-gradient(ellipse at 23% 30%, ' + color + ' 0, #121212 75%)';
  });
}
player.autoplay = preferences.value.autoplay;
let backgroundMode = preferences.value.background;
preferences.subscribe(value => {
  player.autoplay = value.autoplay;
  if (value.background === backgroundMode) return;
  backgroundMode = value.background; updateBackground();
});
player.subscribe(kind => { if (kind === 'track') updateBackground(); });
updateBackground();
function direction(value) {
  const focused = document.activeElement;
  if (focused && focused.classList.contains('lyrics-pane') && (value === 'up' || value === 'down')) {
    const delta = value === 'up' ? -140 : 140;
    if ((delta < 0 && focused.scrollTop > 0) || (delta > 0 && focused.scrollTop + focused.clientHeight < focused.scrollHeight - 2)) {
      focused.scrollBy({ top: delta, behavior: 'smooth' }); return;
    }
  }
  nav.move(value, focused && focused.closest('.keyboard'));
}
bindKeys({
  left: () => direction('left'), right: () => direction('right'), up: () => direction('up'), down: () => direction('down'),
  enter: () => { const current = document.activeElement; if (current && current.matches('[data-focusable]')) current.click(); },
  back: () => app.back(), toggle: () => player.toggle(), play: () => player.play(), pause: () => player.pause(), stop: () => player.stop(),
  previous: () => player.previous(), next: () => player.next(), forward: () => player.seek(10), rewind: () => player.seek(-10),
  now: () => { if (api.token && !app.closeModal && app.current.name !== 'now') app.navigate({ name: 'now' }); },
  lyrics: () => {
    if (!api.token || app.closeModal) return;
    if (app.controller && app.controller.toggleLyrics) app.controller.toggleLyrics();
    else app.navigate({ name: 'now', lyrics: true });
  }
});
function resize() {
  const scale = Math.min(window.innerWidth / 1920, window.innerHeight / 1080);
  root.style.transform = 'scale(' + scale + ')'; root.style.left = (window.innerWidth - 1920 * scale) / 2 + 'px'; root.style.top = (window.innerHeight - 1080 * scale) / 2 + 'px';
}
window.addEventListener('resize', resize); resize(); document.documentElement.lang = language;
app.navigate({ name: api.token ? 'home' : 'login' }, true);
