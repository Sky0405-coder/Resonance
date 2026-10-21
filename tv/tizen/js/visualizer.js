import { parseSpectrum, levelsAt } from './spectrum.js';
const cache = new Map();
async function loadSpectrum(api, id) {
  const key = api.server + ':' + api.token + ':' + id;
  if (cache.has(key)) return cache.get(key);
  const pending = (async function () {
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const bytes = await api.request('/api/tracks/' + encodeURIComponent(id) + '/spectrum', { binary: true });
        return bytes ? parseSpectrum(bytes) : null;
      } catch (_) { if (attempt < 2) await new Promise(resolve => setTimeout(resolve, (attempt + 1) * 2000)); }
    }
    return null;
  })();
  cache.set(key, pending);
  while (cache.size > 3) cache.delete(cache.keys().next().value);
  return pending;
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
export function attachVisualizer(canvas, player, api, track, cover) {
  let disposed = false;
  let spectrum = null;
  let color = '#1DB954';
  let last = -Infinity;
  let frame = 0;
  const levels = new Array(24).fill(0);
  const ctx = canvas.getContext('2d');
  if (track) loadSpectrum(api, track.id).then(data => { if (!disposed) spectrum = data; });
  coverColor(cover).then(value => { if (!disposed) color = value; });
  function draw(now) {
    if (disposed) return;
    frame = requestAnimationFrame(draw);
    if (document.hidden || now - last < 1000 / 30) return;
    last = now;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (!spectrum) return;
    levelsAt(spectrum, player.audio.currentTime, levels);
    const gradient = ctx.createLinearGradient(0, canvas.height, 0, 0);
    gradient.addColorStop(0, color); gradient.addColorStop(1, 'rgba(255,255,255,0.18)');
    ctx.fillStyle = gradient;
    const slot = canvas.width / 48;
    for (let i = 0; i < 48; i++) {
      const band = i < 24 ? 23 - i : i - 24;
      const height = Math.max(3, levels[band] * canvas.height);
      ctx.fillRect(i * slot + slot * 0.15, canvas.height - height, slot * 0.7, height);
    }
  }
  frame = requestAnimationFrame(draw);
  return () => { disposed = true; cancelAnimationFrame(frame); ctx.clearRect(0, 0, canvas.width, canvas.height); };
}
