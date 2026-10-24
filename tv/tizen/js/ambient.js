import { artistName } from './ui.js';

// active(): only on the full-screen player; the rest of the app never dims.
export function createAmbient({ player, preferences, root, api, timeoutMs = 10000, now = Date.now, timers = window, active = () => true }) {
  const documentRef = root.ownerDocument || document;
  function element(tag, className) { const node = documentRef.createElement(tag); if (className) node.className = className; return node; }
  const overlay = element('div', 'ambient');
  overlay.setAttribute('aria-hidden', 'true');
  const content = element('div', 'ambient-content');
  const cover = element('img', 'ambient-cover'); cover.alt = '';
  const details = element('div', 'ambient-details');
  const title = element('div', 'ambient-title'); const artist = element('div', 'ambient-artist');
  details.appendChild(title); details.appendChild(artist);
  content.appendChild(cover); content.appendChild(details); overlay.appendChild(content); root.appendChild(overlay);

  let timeout = null; let movement = null; let visible = false; let wasEligible = false; let lastActivity = now(); let disposed = false;
  function clearTimeoutId() { if (timeout !== null) timers.clearTimeout(timeout); timeout = null; }
  function clearMovement() { if (movement !== null) timers.clearInterval(movement); movement = null; }
  function eligible() { return preferences.value.ambient && active() && player.playing && !!(player.track || player.station); }
  function updateContent() {
    const track = player.track; const station = player.station; const metadata = player.now;
    title.textContent = station ? (metadata && (metadata.title || metadata.raw)) || station.name : track ? track.title : '';
    artist.textContent = station ? [metadata && metadata.artist, station.name].filter(Boolean).join(' · ') : track ? artistName(track) : '';
    let url = 'icon.png';
    if (station) url = api ? api.artwork('station', station, 700) : (/^https?:\/\//i.test(station.favicon || '') ? station.favicon : 'icon.png');
    else if (track) url = api ? api.artwork('track', track, 700) : track.cover_url || (track.album && track.album.cover_url) || 'icon.png';
    if (cover.getAttribute('src') !== url) cover.src = url;
  }
  function moveContent() {
    const x = Math.floor(Math.random() * 81) - 40; const y = Math.floor(Math.random() * 61) - 30;
    content.style.transform = 'translate(' + x + 'px, ' + y + 'px)';
  }
  function show() {
    if (disposed || !eligible()) return;
    updateContent(); visible = true; overlay.classList.add('visible'); overlay.setAttribute('aria-hidden', 'false');
    clearMovement(); movement = timers.setInterval(moveContent, 60000);
  }
  function hide() {
    visible = false; overlay.classList.remove('visible'); overlay.setAttribute('aria-hidden', 'true');
    clearMovement(); content.style.transform = 'translate(0, 0)';
  }
  function schedule() {
    clearTimeoutId();
    if (!eligible() || visible || disposed) return;
    const remaining = Math.max(0, timeoutMs - (now() - lastActivity));
    timeout = timers.setTimeout(() => {
      timeout = null;
      if (!eligible() || disposed) return;
      const delay = timeoutMs - (now() - lastActivity);
      if (delay > 0) { schedule(); return; }
      show();
    }, remaining);
  }
  function refresh(kind) {
    if (kind === 'track' || kind === 'metadata' || kind === undefined) updateContent();
    // Once dimmed it stays until the remote is used (or it is switched off / the player is left): a song change
    // briefly is not "playing" and must not wake it.
    if (visible && preferences.value.ambient && active()) { updateContent(); return; }
    if (!eligible()) { wasEligible = false; clearTimeoutId(); hide(); return; }
    if (!wasEligible) { wasEligible = true; lastActivity = now(); }
    if (visible) updateContent();
    else if (timeout === null) schedule();
  }
  function keydown(event) {
    if (visible) {
      hide(); lastActivity = now(); schedule();
      event.preventDefault(); event.stopImmediatePropagation();
      return;
    }
    if (eligible()) { lastActivity = now(); schedule(); }
  }
  documentRef.addEventListener('keydown', keydown, true);
  const unsubscribePlayer = player.subscribe(refresh);
  const unsubscribePreferences = preferences.subscribe(() => refresh());
  refresh();

  // Shown right away, e.g. when it is switched on in the player, so it is clear what it does.
  function showNow() { clearTimeoutId(); lastActivity = now() - timeoutMs; wasEligible = eligible(); show(); }
  return { node: overlay, refresh: () => refresh(), showNow: showNow, dispose: () => {
    if (disposed) return;
    disposed = true; clearTimeoutId(); clearMovement(); hide();
    unsubscribePlayer(); unsubscribePreferences(); documentRef.removeEventListener('keydown', keydown, true);
    overlay.remove();
  } };
}
