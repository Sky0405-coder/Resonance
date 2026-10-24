import { userPlaylists } from './home.js';
import { t } from '../i18n.js';
import { el, button, heading, row, card, errorBox, releaseImages } from '../ui.js';
export async function libraryView(ctx) {
  const root = el('div', 'library-page'); root.appendChild(heading(t('library')));
  const tabs = row('library-tabs'); const content = el('div', 'library-grid'); content.dataset.row = 'library-content';
  let selected = ctx.route.tab || 'playlists'; let version = 0; let disposed = false; let offset = 0;
  const more = button(t('more'), () => load(true), 'library-more'); more.hidden = true;
  // Liked Songs is the first playlist, like on the home page and in the Flutter app.
  ['playlists', 'albums', 'artists'].forEach(kind => {
    const tab = button(t(kind), () => { selected = kind; ctx.route.tab = kind; load(false); }, 'library-tab-' + kind);
    tab.dataset.tab = kind; tabs.appendChild(tab);
  });
  root.appendChild(tabs); root.appendChild(content); root.appendChild(more);
  async function load(append) {
    const current = ++version;
    const kind = selected;
    if (!append) { releaseImages(content); offset = 0; content.textContent = t('loading'); }
    more.hidden = true;
    Array.from(tabs.children).forEach(tab => { tab.classList.toggle('selected', tab.dataset.tab === kind); });
    try {
      const data = await ctx.api.request('/api/' + kind, { query: kind === 'playlists' ? {} : { offset: offset, limit: 60 } });
      if (disposed || current !== version) return;
      const items = kind === 'playlists' ? userPlaylists(data) : Array.isArray(data) ? data : data.items;
      if (!append) content.textContent = '';
      if (kind === 'playlists') content.appendChild(card(ctx, 'liked', { id: 'liked', title: t('liked') }));
      items.forEach(item => content.appendChild(card(ctx, { playlists: 'playlist', albums: 'album', artists: 'artist' }[kind], item)));
      offset += items.length;
      more.hidden = kind === 'playlists' || items.length < 60 || (data.total !== undefined && offset >= data.total);
      if (!content.childElementCount) content.textContent = t('empty');
      if (append) ctx.nav.focus(content.querySelectorAll('[data-focusable]')[offset - items.length]);
    } catch (error) { if (!disposed && current === version) { releaseImages(content); content.textContent = ''; content.appendChild(errorBox(error.message, () => load(false))); } }
  }
  await load(false);
  return { node: root, dispose: () => { disposed = true; version++; } };
}
