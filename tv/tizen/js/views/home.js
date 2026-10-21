import { t } from '../i18n.js';
import { el, heading, shelf } from '../ui.js';
export async function homeView(ctx) {
  const data = await ctx.api.request('/api/home');
  const root = el('div', 'home-page');
  root.appendChild(el('div', 'eyebrow', 'RESONANCE · TV'));
  root.appendChild(heading(t('home'), t('welcome')));
  [['recentlyPlayed', 'recently_played', 'album'], ['recentlyAdded', 'recently_added', 'album'],
    ['playlists', 'playlists', 'playlist'], ['mostPlayed', 'most_played', 'track']].forEach(section => {
    if (data[section[1]] && data[section[1]].length) root.appendChild(shelf(ctx, t(section[0]), section[2], data[section[1]], section[1]));
  });
  if (!root.querySelector('.shelf')) root.appendChild(el('p', 'empty', t('empty')));
  return { node: root };
}
