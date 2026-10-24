import { t } from '../i18n.js';
import { el, button, row, image, time, artistName } from '../ui.js';
import { setIcon } from '../icons.js';
import { attachVisualizer } from '../visualizer.js';

export function coverflowTracks(player) {
  if (player.station || player.queue.length <= 1) return null;
  const position = player.order.indexOf(player.index);
  if (position < 0) return [];
  return [-2, -1, 0, 1, 2].map(offset => {
    const index = player.order[position + offset];
    return index === undefined ? null : player.queue[index];
  });
}

function coverTransform(offset) {
  if (offset === 0) return 'translateX(0) scale(1)';
  const side = offset < 0 ? -1 : 1;
  return 'translateX(' + offset * 297 + 'px) perspective(1000px) rotateY(' + (side < 0 ? 45 : -45) + 'deg) scale(.6)';
}

export function nowPlayingView(ctx) {
  const player = ctx.player;
  const root = el('div', 'now-page');
  let disposeVisualizer = null; let disposed = false; let version = 0;
  let lyricsData = null; let lyricsOpen = !!ctx.route.lyrics; let activeLine = -1;
  let title; let artist; let art; let coverWrap; let coverStage = null; let canvas; let lyricsPane; let progress; let elapsed; let duration; let bubble;
  let seekInterval = null; let seekDirection = 0; let bubbleTimer = null;
  let progressTimer = null; let flowTimer = null; let transitionStage = null; let lastTrackIndex = null; let lastOrder = [];
  let lastProgress = -Infinity; let likedBusy = false;
  const buttons = {};
  let coverUrl = '';
  function stopSeek() {
    clearInterval(seekInterval); seekInterval = null; seekDirection = 0;
    clearTimeout(bubbleTimer); bubbleTimer = setTimeout(() => { if (bubble) bubble.hidden = true; }, 700);
  }
  function syncVisualizer() {
    const enabled = ctx.preferences.value.visualizer && !!player.track && root.isConnected && ctx.active();
    if (enabled && disposeVisualizer) return;
    if (disposeVisualizer) { disposeVisualizer(); disposeVisualizer = null; }
    if (canvas) { canvas.remove(); canvas = null; }
    if (!enabled) return;
    canvas = el('canvas', 'visualizer'); canvas.width = 660; canvas.height = 264;
    canvas.setAttribute('aria-hidden', 'true'); (art.parentNode === coverStage ? coverStage : coverWrap).appendChild(canvas);
    disposeVisualizer = attachVisualizer(canvas, player, ctx.api, player.track, coverUrl, () => root.isConnected && ctx.active());
  }
  function updateMetadata() {
    const track = player.track; const station = player.station; const now = player.now;
    title.textContent = station ? (now && (now.title || now.raw)) || station.name : track ? track.title : t('nothingPlaying');
    artist.textContent = station ? [now && now.artist, station.name].filter(Boolean).join(' · ') : track ? artistName(track) : '';
    const url = station ? (now && /^https?:\/\//i.test(now.cover_url || '') ? now.cover_url : ctx.api.artwork('station', station, 700)) : track ? ctx.api.artwork('track', track, 700) : 'icon.png';
    if (url !== coverUrl) { coverUrl = url; art.src = url; }
  }
  async function toggleLike() {
    const track = player.track;
    if (!track || likedBusy) return;
    const current = version; const liked = !track.liked;
    likedBusy = true; update();
    try {
      await ctx.api.request('/api/me/likes/tracks/' + encodeURIComponent(track.id), { method: liked ? 'PUT' : 'DELETE' });
      track.liked = liked;
    } catch (error) { if (!disposed && current === version) ctx.app.toast(error.message); }
    finally { if (!disposed && current === version) { likedBusy = false; update(); } }
  }
  function render() {
    const focusId = document.activeElement && document.activeElement.dataset.focusId;
    const mounted = root.isConnected;
    const previousStage = coverStage; const flowItems = coverflowTracks(player);
    let flowDirection = 0;
    if (previousStage && flowItems && player.index !== lastTrackIndex) {
      const before = lastOrder.indexOf(lastTrackIndex); const after = player.order.indexOf(player.index);
      flowDirection = after >= before ? 1 : -1;
    }
    if (flowTimer) clearTimeout(flowTimer); flowTimer = null;
    if (transitionStage) transitionStage.remove(); transitionStage = null;
    if (previousStage) { previousStage.style.transition = 'none'; previousStage.style.transform = 'translateX(0)'; previousStage.style.opacity = '1'; previousStage.style.zIndex = '2'; }
    version++; const current = version;
    stopSeek(); clearTimeout(bubbleTimer); clearTimeout(progressTimer); progressTimer = null; lastProgress = -Infinity;
    if (disposeVisualizer) disposeVisualizer();
    if (canvas) canvas.remove();
    disposeVisualizer = null; canvas = null; coverUrl = ''; activeLine = -1; lyricsData = null; likedBusy = false;
    root.textContent = '';
    const top = el('div', 'now-top'); top.appendChild(el('span', 'eyebrow', t('nowPlaying')));
    top.appendChild(button('‹ ' + t('back'), () => ctx.app.back(), 'now-back')); root.appendChild(top);
    const layout = el('div', 'now-layout'); coverWrap = el('div', 'now-cover-wrap');
    if (flowItems && flowItems.length) {
      coverStage = el('div', 'coverflow-stage');
      flowItems.forEach((track, slot) => {
        const offset = slot - 2; const card = image(track ? ctx.api.artwork('track', track, 700) : 'icon.png', 'now-cover coverflow-card');
        card.classList.add(offset === 0 ? 'coverflow-current' : Math.abs(offset) === 1 ? 'coverflow-neighbor' : 'coverflow-outer');
        card.style.transform = coverTransform(offset);
        card.style.opacity = !track || Math.abs(offset) === 2 ? '0' : offset === 0 ? '1' : '0.6';
        card.dataset.offset = String(offset); card.dataset.trackId = track ? track.id : ''; coverStage.appendChild(card);
        if (offset === 0) art = card;
      });
      if (previousStage && flowDirection) {
        previousStage.style.transition = 'none'; previousStage.style.transform = 'translateX(0)'; previousStage.style.opacity = '1';
        coverStage.style.transition = 'none'; coverStage.style.transform = 'translateX(' + flowDirection * 297 + 'px)'; coverStage.style.opacity = '0.45';
        coverWrap.appendChild(previousStage); coverWrap.appendChild(coverStage); void coverWrap.offsetWidth;
        previousStage.style.transition = 'transform 300ms ease, opacity 300ms ease';
        coverStage.style.transition = 'transform 300ms ease, opacity 300ms ease';
        previousStage.style.transform = 'translateX(' + -flowDirection * 297 + 'px)'; previousStage.style.opacity = '0';
        coverStage.style.transform = 'translateX(0)'; coverStage.style.opacity = '1';
        transitionStage = previousStage;
        flowTimer = setTimeout(() => {
          if (transitionStage) transitionStage.remove();
          transitionStage = null; flowTimer = null;
          if (coverStage) { coverStage.style.transition = 'none'; coverStage.style.transform = 'translateX(0)'; coverStage.style.opacity = '1'; }
        }, 330);
      } else coverWrap.appendChild(coverStage);
      coverWrap.classList.add('coverflow-wrap');
      lastTrackIndex = player.index; lastOrder = player.order.slice();
    } else {
      coverStage = null; art = image('icon.png', 'now-cover'); coverWrap.appendChild(art);
      lastTrackIndex = player.index; lastOrder = player.order.slice();
    }
    layout.appendChild(coverWrap);
    const info = el('div', 'now-info');
    title = el('h1', 'now-title'); artist = el('p', 'now-artist muted'); info.appendChild(title); info.appendChild(artist);
    const line = el('div', 'timeline'); elapsed = el('span', '', '0:00'); duration = el('span', '', '0:00');
    progress = el('div', 'progress');
    const trackBar = el('div', 'progress-track'); trackBar.appendChild(el('div', 'progress-fill')); progress.appendChild(trackBar);
    bubble = el('span', 'seek-bubble'); bubble.hidden = true; progress.appendChild(bubble);
    progress.setAttribute('role', 'slider'); progress.setAttribute('aria-label', t('seek')); progress.setAttribute('aria-valuemin', '0');
    if (player.track) { progress.tabIndex = 0; progress.dataset.focusable = ''; progress.dataset.focusId = 'now-progress'; }
    progress.addEventListener('keydown', event => {
      const direction = event.keyCode === 37 ? -1 : event.keyCode === 39 ? 1 : 0;
      if (!direction || !player.track) return;
      event.preventDefault(); event.stopPropagation();
      if (seekDirection === direction) return;
      stopSeek(); clearTimeout(bubbleTimer); seekDirection = direction;
      const seek = () => {
        if (document.hidden || !root.isConnected || document.activeElement !== progress) { stopSeek(); return; }
        player.seek(direction * 10); bubble.textContent = time(player.audio.currentTime); bubble.hidden = false;
      };
      seek(); seekInterval = setInterval(seek, 300);
    });
    progress.addEventListener('keyup', event => {
      if (event.keyCode === 37 || event.keyCode === 39) { event.preventDefault(); event.stopPropagation(); stopSeek(); }
    });
    progress.addEventListener('blur', stopSeek);
    line.appendChild(elapsed); line.appendChild(progress); line.appendChild(duration); info.appendChild(line);
    const transport = row('now-transport', 'transport');
    function control(key, action, icon) {
      const node = button('', action, 'now-' + key, 'button transport-button');
      node.setAttribute('aria-label', t(key)); setIcon(node, icon); buttons[key] = node; transport.appendChild(node);
    }
    control('shuffle', () => player.toggleShuffle(), 'shuffle'); buttons.shuffle.classList.add('mode-button');
    control('previous', () => player.previous(), 'skip_previous');
    control('play', () => player.toggle(), 'play_arrow');
    control('next', () => player.next(), 'skip_next');
    control('repeat', () => player.cycleRepeat(), 'repeat'); buttons.repeat.classList.add('mode-button');
    control('lyrics', toggleLyrics, 'lyrics');
    control('like', toggleLike, 'favorite_border');
    if (!player.station) control('queue', () => ctx.app.navigate({ name: 'queue' }), 'queue_music');
    control('ambient', () => {
      const on = !ctx.preferences.value.ambient;
      ctx.preferences.set('ambient', on);
      if (on && ctx.app.ambient) ctx.app.ambient.showNow();
    }, 'dark_mode');
    info.appendChild(transport);
    lyricsPane = el('div', 'lyrics-pane'); lyricsPane.setAttribute('aria-label', t('lyrics'));
    lyricsPane.tabIndex = 0; lyricsPane.dataset.focusable = ''; lyricsPane.dataset.focusId = 'lyrics-pane';
    lyricsPane.textContent = t('loading'); info.appendChild(lyricsPane);
    info.appendChild(el('p', 'remote-hint muted', t('lyricsHint')));
    layout.appendChild(info); root.appendChild(layout); updateMetadata();
    if (player.track) {
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
      favoriteButton.disabled = true; info.insertBefore(favoriteButton, lyricsPane);
      ctx.api.request('/api/worldradio/favorites').then(items => {
        if (disposed || current !== version) return;
        favorite = items.some(item => item.id === station.id);
        favoriteButton.textContent = t(favorite ? 'removeFavorite' : 'addFavorite'); favoriteButton.disabled = false;
      }).catch(error => { if (!disposed && current === version) ctx.app.toast(error.message); });
    }
    update(); applyLyrics(); tick();
    if (mounted) { syncVisualizer(); ctx.nav.restore(focusId || 'now-play', root); }
  }
  function applyLyrics() {
    lyricsPane.hidden = !lyricsOpen; root.classList.toggle('with-lyrics', lyricsOpen);
    buttons.lyrics.classList.toggle('selected', lyricsOpen); buttons.lyrics.setAttribute('aria-pressed', String(lyricsOpen));
  }
  function toggleLyrics() {
    lyricsOpen = !lyricsOpen; ctx.route.lyrics = lyricsOpen; applyLyrics(); tick();
    ctx.nav.focus(lyricsOpen ? lyricsPane : buttons.lyrics);
  }
  function update() {
    if (!buttons.play) return;
    setIcon(buttons.play, player.playing ? 'pause' : 'play_arrow');
    buttons.play.setAttribute('aria-label', t(player.playing ? 'pause' : 'play'));
    buttons.shuffle.classList.toggle('selected', player.shuffle); buttons.shuffle.setAttribute('aria-pressed', String(player.shuffle));
    setIcon(buttons.repeat, player.repeat === 'one' ? 'repeat_one' : 'repeat');
    buttons.repeat.classList.toggle('selected', player.repeat !== 'off'); buttons.repeat.setAttribute('aria-pressed', String(player.repeat !== 'off'));
    buttons.repeat.setAttribute('aria-label', t('repeat') + ': ' + t(player.repeat === 'off' ? 'off' : player.repeat));
    ['shuffle', 'previous', 'next', 'repeat'].forEach(key => { buttons[key].disabled = !!player.station || !player.track; });
    buttons.play.disabled = !player.track && !player.station; buttons.lyrics.disabled = !player.track;
    const liked = !!(player.track && player.track.liked);
    setIcon(buttons.like, liked ? 'favorite' : 'favorite_border'); buttons.like.classList.toggle('selected', liked);
    buttons.like.setAttribute('aria-pressed', String(liked)); buttons.like.setAttribute('aria-label', t(liked ? 'unlike' : 'like'));
    buttons.like.disabled = !player.track || likedBusy;
    buttons.ambient.classList.toggle('selected', ctx.preferences.value.ambient);
    buttons.ambient.setAttribute('aria-pressed', String(ctx.preferences.value.ambient));
    buttons.ambient.setAttribute('aria-label', t(ctx.preferences.value.ambient ? 'ambientOn' : 'ambientOff'));
  }
  function tick() {
    if (disposed || !progress) return;
    const wait = 250 - (Date.now() - lastProgress);
    if (wait > 0) { if (!progressTimer) progressTimer = setTimeout(() => { progressTimer = null; tick(); }, wait); return; }
    lastProgress = Date.now();
    const position = player.audio.currentTime || 0; const length = player.duration;
    elapsed.textContent = player.station ? t('live') : time(position); duration.textContent = player.station ? '' : time(length);
    const fraction = length ? Math.max(0, Math.min(1, position / length)) : 0;
    progress.firstChild.firstChild.style.transform = 'scaleX(' + fraction + ')';
    progress.setAttribute('aria-valuenow', String(Math.round(position))); progress.setAttribute('aria-valuemax', String(length || 0));
    progress.setAttribute('aria-valuetext', time(position) + ' / ' + time(length));
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
  const unwatchPreferences = ctx.preferences.subscribe(() => { syncVisualizer(); update(); });
  const visibility = () => { if (document.hidden) stopSeek(); };
  document.addEventListener('visibilitychange', visibility);
  return { node: root, initialFocus: 'now-play', mounted: syncVisualizer, toggleLyrics: toggleLyrics, dispose: () => {
    disposed = true; version++; unsubscribe(); unwatchPreferences(); stopSeek(); clearTimeout(bubbleTimer); clearTimeout(progressTimer); clearTimeout(flowTimer);
    if (transitionStage) transitionStage.remove();
    document.removeEventListener('visibilitychange', visibility); if (disposeVisualizer) disposeVisualizer();
  } };
}
