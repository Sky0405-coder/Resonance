import { t } from '../i18n.js';
import { el, button, row, image, time, artistName } from '../ui.js';
import { attachVisualizer } from '../visualizer.js';
export function nowPlayingView(ctx) {
  const player = ctx.player;
  const root = el('div', 'now-page');
  let disposeVisualizer = null; let disposed = false; let version = 0;
  let lyricsData = null; let lyricsOpen = !!ctx.route.lyrics; let activeLine = -1;
  let title; let artist; let art; let lyricsPane; let transport; let progress; let elapsed; let duration;
  const buttons = {};
  let coverUrl = '';
  function updateMetadata() {
    const track = player.track; const station = player.station; const now = player.now;
    title.textContent = station ? (now && (now.title || now.raw)) || station.name : track ? track.title : t('nothingPlaying');
    artist.textContent = station ? [now && now.artist, station.name].filter(Boolean).join(' · ') : track ? artistName(track) : '';
    const url = station ? (now && /^https?:\/\//i.test(now.cover_url || '') ? now.cover_url : ctx.api.artwork('station', station, 600)) : track ? ctx.api.artwork('track', track, 800) : 'icon.png';
    if (url !== coverUrl) { coverUrl = url; art.src = url; }
  }
  function render() {
    const focusId = document.activeElement && document.activeElement.dataset.focusId;
    const mounted = root.isConnected;
    version++; const current = version;
    if (disposeVisualizer) disposeVisualizer();
    disposeVisualizer = null; coverUrl = ''; activeLine = -1; lyricsData = null;
    root.textContent = '';
    const top = el('div', 'now-top'); top.appendChild(el('span', 'eyebrow', t('nowPlaying')));
    top.appendChild(button('‹ ' + t('back'), () => ctx.app.back(), 'now-back'));
    root.appendChild(top);
    const layout = el('div', 'now-layout'); const cover = el('div', 'now-cover-wrap');
    art = image('icon.png', 'now-cover'); cover.appendChild(art);
    const canvas = el('canvas', 'visualizer'); canvas.width = 660; canvas.height = 264;
    canvas.setAttribute('aria-hidden', 'true'); cover.appendChild(canvas); layout.appendChild(cover);
    const info = el('div', 'now-info');
    title = el('h1', 'now-title'); artist = el('p', 'now-artist muted'); info.appendChild(title); info.appendChild(artist);
    const line = el('div', 'timeline'); elapsed = el('span', '', '0:00'); duration = el('span', '', '0:00');
    progress = el('div', 'progress'); progress.appendChild(el('div', 'progress-fill'));
    progress.setAttribute('role', 'progressbar'); progress.setAttribute('aria-label', t('nowPlaying'));
    line.appendChild(elapsed); line.appendChild(progress); line.appendChild(duration); info.appendChild(line);
    transport = row('now-transport', 'transport');
    function control(key, action, label) {
      buttons[key] = button(label || t(key), action, 'now-' + key, 'button transport-button'); transport.appendChild(buttons[key]);
    }
    control('shuffle', () => player.toggleShuffle(), '⤨');
    control('previous', () => player.previous(), '❮❮');
    control('play', () => player.toggle(), '▶');
    control('next', () => player.next(), '❯❯');
    control('repeat', () => player.cycleRepeat(), '↻');
    info.appendChild(transport);
    const extras = row('now-extras');
    extras.appendChild(button(t('rewind'), () => player.seek(-10), 'now-rewind'));
    extras.appendChild(button(t('forward'), () => player.seek(10), 'now-forward'));
    buttons.lyrics = button('● ' + t('lyrics'), toggleLyrics, 'now-lyrics', 'button lyrics-button'); extras.appendChild(buttons.lyrics);
    buttons.stop = button(t('stop'), () => player.stop(), 'now-stop'); extras.appendChild(buttons.stop);
    info.appendChild(extras);
    lyricsPane = el('div', 'lyrics-pane'); lyricsPane.setAttribute('aria-label', t('lyrics'));
    lyricsPane.tabIndex = 0; lyricsPane.dataset.focusable = ''; lyricsPane.dataset.focusId = 'lyrics-pane';
    lyricsPane.textContent = t('loading'); info.appendChild(lyricsPane);
    info.appendChild(el('p', 'remote-hint muted', t('colorHint')));
    layout.appendChild(info); root.appendChild(layout);
    updateMetadata();
    if (player.track) {
      disposeVisualizer = attachVisualizer(canvas, player, ctx.api, player.track, coverUrl);
      ctx.api.request('/api/tracks/' + encodeURIComponent(player.track.id) + '/lyrics').then(data => {
        if (disposed || current !== version) return;
        lyricsData = data; lyricsPane.textContent = '';
        if (data.instrumental) lyricsPane.textContent = t('instrumental');
        else if (!data.lines.length) lyricsPane.textContent = t('noLyrics');
        else data.lines.forEach(line => lyricsPane.appendChild(el('p', 'lyric-line', line.text || '♪')));
        tick();
      }).catch(() => { if (!disposed && current === version) lyricsPane.textContent = t('noLyrics'); });
    } else lyricsPane.textContent = t('noLyrics');
    if (player.station) {
      let favorite = false; let busy = false;
      const station = player.station;
      const favoriteButton = button(t('addFavorite'), async () => {
        if (busy) return; busy = true;
        try {
          await ctx.api.request('/api/worldradio/favorites/' + encodeURIComponent(station.id), { method: favorite ? 'DELETE' : 'PUT' });
          if (disposed || current !== version) return;
          favorite = !favorite; favoriteButton.textContent = t(favorite ? 'removeFavorite' : 'addFavorite');
        } catch (error) { ctx.app.toast(error.message); }
        finally { busy = false; }
      }, 'station-favorite');
      favoriteButton.disabled = true;
      info.insertBefore(favoriteButton, lyricsPane);
      ctx.api.request('/api/worldradio/favorites').then(items => {
        if (disposed || current !== version) return;
        favorite = items.some(item => item.id === station.id);
        favoriteButton.textContent = t(favorite ? 'removeFavorite' : 'addFavorite'); favoriteButton.disabled = false;
      }).catch(error => { if (!disposed && current === version) ctx.app.toast(error.message); });
    }
    update(); applyLyrics(); tick();
    if (mounted) ctx.nav.restore(focusId || 'now-play', root);
  }
  function applyLyrics() {
    lyricsPane.hidden = !lyricsOpen;
    root.classList.toggle('with-lyrics', lyricsOpen);
    buttons.lyrics.classList.toggle('selected', lyricsOpen);
  }
  function toggleLyrics() {
    lyricsOpen = !lyricsOpen; ctx.route.lyrics = lyricsOpen; applyLyrics(); tick();
    ctx.nav.focus(lyricsOpen ? lyricsPane : buttons.lyrics);
  }
  function update() {
    if (!buttons.play) return;
    buttons.play.textContent = player.playing ? 'Ⅱ' : '▶';
    buttons.play.setAttribute('aria-label', t(player.playing ? 'pause' : 'play'));
    buttons.shuffle.classList.toggle('selected', player.shuffle); buttons.shuffle.setAttribute('aria-label', t('shuffle'));
    buttons.shuffle.setAttribute('aria-pressed', String(player.shuffle));
    buttons.repeat.textContent = player.repeat === 'one' ? '↻ 1' : '↻';
    buttons.repeat.classList.toggle('selected', player.repeat !== 'off');
    buttons.repeat.setAttribute('aria-label', t('repeat') + ': ' + t(player.repeat === 'off' ? 'off' : player.repeat));
    ['previous', 'next'].forEach(key => buttons[key].setAttribute('aria-label', t(key)));
    ['shuffle', 'previous', 'next', 'repeat'].forEach(key => { buttons[key].disabled = !!player.station || !player.track; });
    buttons.lyrics.disabled = !player.track;
  }
  function tick() {
    if (!progress) return;
    const position = player.audio.currentTime || 0; const length = player.duration;
    elapsed.textContent = player.station ? t('live') : time(position); duration.textContent = player.station ? '' : time(length);
    const percent = length ? Math.min(100, position / length * 100) : 0;
    progress.firstChild.style.width = percent + '%'; progress.setAttribute('aria-valuenow', String(Math.round(percent)));
    if (!lyricsOpen || !lyricsData || !lyricsData.synced) return;
    let index = -1;
    lyricsData.lines.forEach((line, i) => { if (line.time_ms !== null && line.time_ms <= position * 1000) index = i; });
    if (index === activeLine) return;
    if (activeLine >= 0 && lyricsPane.children[activeLine]) lyricsPane.children[activeLine].classList.remove('active');
    activeLine = index;
    if (index >= 0 && lyricsPane.children[index]) {
      const line = lyricsPane.children[index]; line.classList.add('active');
      lyricsPane.scrollTo({ top: Math.max(0, line.offsetTop - lyricsPane.offsetTop - lyricsPane.clientHeight / 2 + line.clientHeight / 2), behavior: 'smooth' });
    }
  }
  render();
  const unsubscribe = player.subscribe(kind => {
    if (kind === 'track') render(); else if (kind === 'metadata') updateMetadata(); else if (kind === 'time') tick(); else update();
  });
  return { node: root, initialFocus: 'now-play', toggleLyrics: toggleLyrics, dispose: () => {
    disposed = true; version++; unsubscribe(); if (disposeVisualizer) disposeVisualizer();
  } };
}
