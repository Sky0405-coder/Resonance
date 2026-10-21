import { t } from './i18n.js';
export function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
export function button(label, action, id, className) {
  const node = el('button', className || 'button', label);
  node.type = 'button'; node.dataset.focusable = ''; node.dataset.focusId = id || label;
  node.addEventListener('click', action);
  return node;
}
export function row(id, className) { const node = el('div', className || 'actions'); node.dataset.row = id; return node; }
export function image(url, className, alt) {
  const node = el('img', className); node.alt = alt || ''; node.src = url;
  node.addEventListener('error', () => { if (node.getAttribute('src') !== 'icon.png') node.src = 'icon.png'; });
  return node;
}
export function time(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return '0:00';
  return Math.floor(seconds / 60) + ':' + String(Math.floor(seconds % 60)).padStart(2, '0');
}
export function artistName(item) { return item.artist_credit || (item.artist && item.artist.name) || ''; }
export function heading(title, subtitle) {
  const node = el('header', 'page-heading');
  node.appendChild(el('h1', '', title));
  if (subtitle) node.appendChild(el('p', 'muted', subtitle));
  return node;
}
export function card(ctx, kind, item, index, tracks) {
  const label = item.title || item.name || t('liked');
  const node = button('', () => {
    if (kind === 'track') { ctx.player.setQueue(tracks || [item], index || 0, 'search', false); ctx.app.navigate({ name: 'now' }); }
    else if (kind === 'station') { ctx.player.playStation(item); ctx.app.navigate({ name: 'now' }); }
    else ctx.app.navigate({ name: 'detail', kind: kind, id: item.id });
  }, kind + '-' + item.id, 'card ' + kind);
  node.appendChild(image(ctx.api.artwork(kind, item), 'card-cover', ''));
  node.appendChild(el('strong', '', label));
  const subtitle = kind === 'station' ? item.country : artistName(item);
  node.appendChild(el('span', 'muted', subtitle || (item.track_count !== undefined ? item.track_count + ' ' + t('tracks') : t(kind))));
  return node;
}
export function shelf(ctx, title, kind, items, id) {
  const section = el('section', 'shelf');
  section.appendChild(el('h2', '', title));
  const itemsRow = row(id || title, 'shelf-row');
  (items || []).forEach((item, i) => itemsRow.appendChild(card(ctx, kind, item, i, kind === 'track' ? items : null)));
  section.appendChild(itemsRow);
  return section;
}
export function trackList(ctx, tracks, context) {
  const list = el('div', 'track-list');
  tracks.forEach((track, index) => {
    const node = button('', () => { ctx.player.setQueue(tracks, index, context, false); ctx.app.navigate({ name: 'now' }); }, 'track-' + track.id + '-' + index, 'track-row');
    node.dataset.row = 'track-row-' + index;
    node.appendChild(el('span', 'track-number', index + 1));
    node.appendChild(image(ctx.api.artwork('track', track, 96), 'track-cover'));
    const info = el('span', 'track-info');
    info.appendChild(el('strong', '', track.title)); info.appendChild(el('span', 'muted', artistName(track)));
    node.appendChild(info); node.appendChild(el('span', 'track-album muted', track.album && track.album.title));
    node.appendChild(el('span', 'muted', time(track.duration)));
    list.appendChild(node);
  });
  if (!tracks.length) list.appendChild(el('p', 'empty', t('empty')));
  return list;
}
export function errorBox(message, retry) {
  const node = el('div', 'error-box'); node.setAttribute('role', 'alert');
  node.appendChild(el('p', '', message));
  if (retry) node.appendChild(button(t('retry'), retry, 'retry'));
  return node;
}
