import { t } from '../i18n.js';
import { el, heading, shelf, errorBox, releaseImages } from '../ui.js';
import { keyboard, editText } from './keyboard.js';
export function searchView(ctx) {
  const root = el('div', 'search-page'); root.appendChild(heading(t('search'), t('searchHint')));
  const split = el('div', 'search-split');
  const entry = el('div', 'search-entry');
  const input = el('input', 'search-input'); input.placeholder = t('searchHint'); input.setAttribute('aria-label', t('search'));
  input.dataset.focusable = ''; input.dataset.focusId = 'search-input'; input.readOnly = typeof tizen !== 'undefined';
  input.value = ctx.route.query || ''; entry.appendChild(input);
  const results = el('div', 'search-results');
  let timer = null; let version = 0; let disposed = false;
  function schedule() {
    ctx.route.query = input.value;
    clearTimeout(timer); version++;
    timer = setTimeout(search, 400);
  }
  async function search() {
    const current = ++version;
    const query = input.value.trim();
    releaseImages(results); results.textContent = t('loading');
    if (!query) { results.textContent = t('searchHint'); return; }
    try {
      const data = await ctx.api.request('/api/search', { query: { q: query } });
      if (disposed || current !== version) return;
      results.textContent = '';
      [['tracks', 'track'], ['albums', 'album'], ['artists', 'artist'], ['playlists', 'playlist']].forEach(pair => {
        if (data[pair[0]] && data[pair[0]].length) results.appendChild(shelf(ctx, t(pair[0]), pair[1], data[pair[0]], 'search-' + pair[0]));
      });
      if (!results.childElementCount) results.textContent = t('noResults');
    } catch (error) { if (!disposed && current === version) { results.textContent = ''; results.appendChild(errorBox(error.message, search)); } }
  }
  input.addEventListener('input', schedule);
  entry.appendChild(keyboard((action, text) => { input.value = editText(input.value, action, text); schedule(); }));
  split.appendChild(entry); split.appendChild(results); root.appendChild(split);
  if (input.value) schedule(); else results.textContent = t('searchHint');
  return { node: root, dispose: () => { disposed = true; version++; clearTimeout(timer); } };
}
