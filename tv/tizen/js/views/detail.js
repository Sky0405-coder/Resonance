import { t } from '../i18n.js';
import { el, button, row, image, trackList, shelf, artistName, likedArtwork } from '../ui.js';
export async function detailView(ctx) {
  const kind = ctx.route.kind; const id = ctx.route.id;
  const path = kind === 'liked' ? '/api/me/likes/tracks' : '/api/' + kind + 's/' + encodeURIComponent(id);
  const data = await ctx.api.request(path);
  const tracks = kind === 'liked' ? data : kind === 'playlist' ? data.entries.map(entry => entry.track) : kind === 'artist' ? data.top_tracks : data.tracks;
  const item = kind === 'liked' ? { id: 'liked', title: t('liked') } : data;
  const root = el('div', 'detail-page'); const header = el('header', 'detail-header');
  header.appendChild(kind === 'liked' ? likedArtwork('detail-cover') : image(ctx.api.artwork(kind, item, 300), 'detail-cover'));
  const info = el('div', 'detail-info');
  info.appendChild(el('p', 'eyebrow', t(kind)));
  info.appendChild(el('h1', '', item.title || item.name));
  info.appendChild(el('p', 'muted', [artistName(item), item.year, tracks.length + ' ' + t('tracks')].filter(Boolean).join(' · ')));
  if (item.description) info.appendChild(el('p', 'description', item.description));
  const actions = row('detail-actions');
  function play(shuffle) {
    const index = shuffle ? Math.floor(Math.random() * tracks.length) : 0;
    ctx.player.setQueue(tracks, index, kind === 'liked' ? 'liked' : kind + ':' + id, shuffle);
    ctx.app.navigate({ name: 'now' });
  }
  const playButton = button('▶ ' + t('play'), () => play(false), 'detail-play', 'button primary'); playButton.disabled = !tracks.length;
  const shuffle = button('⤨ ' + t('shuffle'), () => play(true), 'detail-shuffle'); shuffle.disabled = !tracks.length;
  actions.appendChild(playButton); actions.appendChild(shuffle); info.appendChild(actions);
  header.appendChild(info); root.appendChild(header);
  root.appendChild(trackList(ctx, tracks, kind === 'liked' ? 'liked' : kind + ':' + id));
  if (kind === 'artist' && data.albums.length) root.appendChild(shelf(ctx, t('albums'), 'album', data.albums, 'artist-albums'));
  return { node: root, initialFocus: 'detail-play' };
}
