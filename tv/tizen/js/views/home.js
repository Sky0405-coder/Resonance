import { t } from '../i18n.js';
import { el, heading, shelf, row, card } from '../ui.js';
export function userPlaylists(playlists) {
  // Same visible own/saved playlist filter as Flutter's library and audio_handler.
  return playlists.filter(playlist => playlist.kind !== 'mix' && playlist.kind !== 'radio');
}
export async function homeView(ctx) {
  const responses = await Promise.all([ctx.api.request('/api/home'), ctx.api.request('/api/playlists')]);
  const data = responses[0];
  const root = el('div', 'home-page');
  root.appendChild(el('div', 'eyebrow', 'RESONANCE · TV'));
  root.appendChild(heading(t('home'), t('welcome')));
  if (data.recently_played && data.recently_played.length) root.appendChild(shelf(ctx, t('recentlyPlayed'), 'album', data.recently_played, 'recently_played'));
  const playlists = el('section', 'shelf'); playlists.appendChild(el('h2', '', t('yourPlaylists')));
  const cards = row('your-playlists', 'shelf-row');
  cards.appendChild(card(ctx, 'liked', { id: 'liked', title: t('liked') }));
  userPlaylists(responses[1]).forEach(item => cards.appendChild(card(ctx, 'playlist', item)));
  playlists.appendChild(cards); root.appendChild(playlists);
  [['recentlyAdded', 'recently_added', 'album'], ['mostPlayed', 'most_played', 'track']].forEach(section => {
    if (data[section[1]] && data[section[1]].length) root.appendChild(shelf(ctx, t(section[0]), section[2], data[section[1]], section[1]));
  });
  return { node: root };
}
