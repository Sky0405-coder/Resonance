import { t } from '../i18n.js';
import { el, heading, shelf, row, card } from '../ui.js';
export function userPlaylists(playlists) {
  // Same visible own/saved playlist filter as Flutter's library and audio_handler.
  return playlists.filter(playlist => playlist.kind !== 'mix' && playlist.kind !== 'radio');
}
export async function homeView(ctx) {
  // Generated playlists are optional: the home page still shows when /api/mixes fails.
  const mixes = ctx.api.request('/api/mixes').catch(() => null);
  const responses = await Promise.all([ctx.api.request('/api/home'), ctx.api.request('/api/playlists'), mixes]);
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
  const generated = responses[2];
  if (generated) {
    // Same shelves as the Android TV home page.
    [['madeForYou', (generated.discover ? [generated.discover] : []).concat(generated.made_for_you || []), 'made_for_you'],
      ['charts', generated.charts, 'charts'], ['genreMixes', generated.genres, 'genres'], ['decadeMixes', generated.decades, 'decades']].forEach(section => {
      if (section[1] && section[1].length) root.appendChild(shelf(ctx, t(section[0]), 'playlist', section[1], 'mixes-' + section[2]));
    });
  }
  [['recentlyAdded', 'recently_added', 'album'], ['mostPlayed', 'most_played', 'track']].forEach(section => {
    if (data[section[1]] && data[section[1]].length) root.appendChild(shelf(ctx, t(section[0]), section[2], data[section[1]], section[1]));
  });
  return { node: root };
}
