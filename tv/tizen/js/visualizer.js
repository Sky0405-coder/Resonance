import { parseSpectrum, levelsAt } from './spectrum.js';
const cache = new Map();
async function loadSpectrum(api, id, signal) {
  const key = api.server + ':' + api.token + ':' + id;
  if (cache.has(key)) return cache.get(key);
  for (let attempt = 0; attempt < 3 && !signal.aborted; attempt++) {
    try {
      const bytes = await api.request('/api/tracks/' + encodeURIComponent(id) + '/spectrum', { binary: true, signal: signal });
      if (signal.aborted) return null;
      const data = bytes ? parseSpectrum(bytes) : null;
      cache.set(key, data);
      while (cache.size > 3) cache.delete(cache.keys().next().value);
      return data;
    } catch (_) {
      if (signal.aborted) return null;
      if (attempt < 2) await new Promise(resolve => setTimeout(resolve, (attempt + 1) * 2000));
    }
  }
  return null;
}
export function coverColor(url) {
  return new Promise(resolve => {
    const image = new Image();
    image.crossOrigin = 'anonymous';
    const timer = setTimeout(() => resolve('#1DB954'), 10000);
    image.onerror = () => { clearTimeout(timer); resolve('#1DB954'); };
    image.onload = () => {
      clearTimeout(timer);
      try {
        const canvas = document.createElement('canvas'); canvas.width = 32; canvas.height = 32;
        const context = canvas.getContext('2d'); context.drawImage(image, 0, 0, 32, 32);
        const pixels = context.getImageData(0, 0, 32, 32).data;
        let best = [255, 255, 255]; let score = -1;
        for (let i = 0; i < pixels.length; i += 4) {
          const max = Math.max(pixels[i], pixels[i + 1], pixels[i + 2]);
          const min = Math.min(pixels[i], pixels[i + 1], pixels[i + 2]);
          const saturation = max ? (max - min) / max : 0;
          const value = saturation * (0.3 + max / 255);
          if (pixels[i + 3] > 128 && value > score) {
            score = value;
            if (saturation < 0.15) best = [255, 255, 255];
            else {
              const sat = Math.min(saturation, 0.75);
              best = [pixels[i], pixels[i + 1], pixels[i + 2]].map(v => Math.round(242 * (1 - sat + sat * (v - min) / (max - min))));
            }
          }
        }
        resolve('rgb(' + best.join(',') + ')');
      } catch (_) { resolve('#1DB954'); }
    };
    image.src = url;
  });
}
export function attachVisualizer(canvas, player, api, track, cover, isVisible) {
  let disposed = false; let requested = false;
  let spectrum = null; let last = -Infinity; let frame = 0;
  const controller = new AbortController();
  const levels = new Array(24).fill(0);
  const ctx = canvas.getContext('2d');
  let gradient;
  // Canvas pixels equal its CSS dimensions. No device pixel ratio scaling on the TV.
  function setColor(color) {
    gradient = ctx.createLinearGradient(0, canvas.height, 0, 0);
    gradient.addColorStop(0, color); gradient.addColorStop(1, 'rgba(255,255,255,0.18)');
  }
  setColor('#1DB954');
  function visible() { return !disposed && !document.hidden && (!isVisible || isVisible()); }
  function paint() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (!spectrum) return;
    levelsAt(spectrum, player.audio.currentTime, levels);
    ctx.fillStyle = gradient;
    const slot = canvas.width / 48;
    // One path/fill per half; the mirrored half is deliberately lighter.
    for (let side = 0; side < 2; side++) {
      ctx.beginPath(); ctx.globalAlpha = side ? 0.65 : 1;
      for (let i = 0; i < 24; i++) {
        const band = side ? i : 23 - i;
        const height = Math.max(3, levels[band] * canvas.height);
        ctx.rect((side * 24 + i) * slot + slot * 0.15, canvas.height - height, slot * 0.7, height);
      }
      ctx.fill();
    }
    ctx.globalAlpha = 1;
  }
  function draw(timestamp) {
    frame = 0;
    if (!visible()) return;
    if (timestamp - last >= 1000 / 24) { last = timestamp; paint(); }
    if (player.playing) frame = requestAnimationFrame(draw);
    else paint();
  }
  function sync() {
    if (frame) cancelAnimationFrame(frame);
    frame = 0;
    if (!visible()) return;
    if (!requested && track) {
      requested = true;
      loadSpectrum(api, track.id, controller.signal).then(data => { if (!disposed) { spectrum = data; sync(); } });
      coverColor(cover).then(color => { if (!disposed) { setColor(color); sync(); } });
    }
    if (!player.playing) { paint(); return; }
    if (spectrum) frame = requestAnimationFrame(draw);
  }
  const unsubscribe = player.subscribe(kind => { if (kind !== 'time') sync(); });
  document.addEventListener('visibilitychange', sync);
  sync();
  return () => {
    disposed = true; controller.abort(); unsubscribe(); document.removeEventListener('visibilitychange', sync);
    if (frame) cancelAnimationFrame(frame);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
  };
}
