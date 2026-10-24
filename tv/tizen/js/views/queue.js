import { t } from '../i18n.js';
import { el, button, heading, image, time, artistName, releaseImages } from '../ui.js';
function trackRow(ctx, track, index, label, action) {
  const node = button('', action, 'queue-' + index, 'track-row');
  node.dataset.row = 'queue-row-' + index;
  node.appendChild(el('span', 'track-number', label));
  node.appendChild(image(ctx.api.artwork('track', track, 96), 'track-cover', '', true));
  const info = el('span', 'track-info');
  info.appendChild(el('strong', '', track.title)); info.appendChild(el('span', 'muted', artistName(track)));
  node.appendChild(info); node.appendChild(el('span', 'track-album muted', track.album && track.album.title));
  node.appendChild(el('span', 'muted', time(track.duration)));
  return node;
}
export function queueView(ctx) {
  const player = ctx.player;
  const root = el('div', 'queue-page');
  let signature = '';
  function render() {
    const upcoming = player.upcoming();
    const next = [player.index].concat(upcoming).join(',') + '|' + player.queue.length;
    if (next === signature) return;
    signature = next;
    const focused = root.isConnected && document.activeElement && document.activeElement.dataset.focusId;
    releaseImages(root); root.textContent = '';
    root.appendChild(heading(t('queue')));
    if (player.track) {
      root.appendChild(el('h2', 'queue-section', t('nowPlaying')));
      root.appendChild(trackRow(ctx, player.track, player.index, '♪', () => ctx.app.navigate({ name: 'now' })));
    }
    root.appendChild(el('h2', 'queue-section', t('upNext')));
    const list = el('div', 'track-list');
    upcoming.forEach((index, position) => {
      list.appendChild(trackRow(ctx, player.queue[index], index, position + 1, () => player.jumpTo(index)));
    });
    if (!upcoming.length) list.appendChild(el('p', 'empty', t('queueEmpty')));
    root.appendChild(list);
    // Keep the remote's place when the list changes underneath (autoplay, skipping).
    if (focused) ctx.nav.restore(focused, root);
  }
  render();
  const unsubscribe = player.subscribe(kind => { if (kind === 'track' || kind === 'state') render(); });
  return { node: root, initialFocus: 'queue-' + player.index, dispose: () => { unsubscribe(); releaseImages(root); } };
}
