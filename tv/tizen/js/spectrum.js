// RSP1: magic(4), bands(u8), fps(f32 LE), frames(u32 LE), frame-major u8 levels.
export function parseSpectrum(input) {
  const bytes = input instanceof Uint8Array ? input : new Uint8Array(input);
  if (bytes.byteLength < 13 || String.fromCharCode(bytes[0], bytes[1], bytes[2], bytes[3]) !== 'RSP1') return null;
  const header = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const bands = header.getUint8(4);
  const fps = header.getFloat32(5, true);
  const frames = header.getUint32(9, true);
  if (!bands || !Number.isFinite(fps) || fps <= 0 || bytes.byteLength < 13 + bands * frames) return null;
  return { bands: bands, fps: fps, frameCount: frames, data: bytes.subarray(13, 13 + bands * frames) };
}
export function levelsAt(spectrum, seconds, out) {
  out.fill(0);
  if (!spectrum || spectrum.frameCount === 0) return out;
  const position = Math.max(0, Math.min(spectrum.frameCount - 1, (Number.isFinite(seconds) ? seconds : 0) * spectrum.fps));
  const a = Math.floor(position);
  const b = Math.min(a + 1, spectrum.frameCount - 1);
  const fraction = position - a;
  // Resample to 24 bands if a future server uses a different band count.
  for (let i = 0; i < out.length; i++) {
    const band = Math.min(spectrum.bands - 1, Math.floor(i * spectrum.bands / out.length));
    out[i] = (spectrum.data[a * spectrum.bands + band] * (1 - fraction) + spectrum.data[b * spectrum.bands + band] * fraction) / 255;
  }
  return out;
}
