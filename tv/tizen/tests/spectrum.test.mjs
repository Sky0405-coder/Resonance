import test from 'node:test';
import assert from 'node:assert/strict';
import { parseSpectrum, levelsAt } from '../js/spectrum.js';
function rsp(bands, fps, frames, values) {
  const buffer = new ArrayBuffer(13 + values.length); const header = new DataView(buffer);
  new Uint8Array(buffer).set([82, 83, 80, 49]); header.setUint8(4, bands); header.setFloat32(5, fps, true); header.setUint32(9, frames, true);
  new Uint8Array(buffer, 13).set(values); return buffer;
}
test('RSP1 little-endian header and interpolated frame-major levels match Flutter', () => {
  const spectrum = parseSpectrum(rsp(2, 2, 2, [0, 255, 255, 0]));
  assert.equal(spectrum.fps, 2); assert.equal(spectrum.bands, 2); assert.equal(spectrum.frameCount, 2);
  assert.deepEqual(levelsAt(spectrum, 0.25, [0, 0]), [0.5, 0.5]);
  assert.deepEqual(levelsAt(spectrum, -1, [0, 0]), [0, 1]);
  assert.deepEqual(levelsAt(spectrum, 500, [0, 0]), [1, 0]);
});
test('rejects truncated, invalid magic, zero bands and invalid fps', () => {
  assert.equal(parseSpectrum(new ArrayBuffer(12)), null);
  const bad = new Uint8Array(rsp(1, 1, 1, [255])); bad[0] = 0;
  assert.equal(parseSpectrum(bad), null);
  assert.equal(parseSpectrum(rsp(0, 1, 1, [])), null);
  [0, -1, NaN, Infinity].forEach(fps => assert.equal(parseSpectrum(rsp(1, fps, 1, [1])), null));
  assert.equal(parseSpectrum(rsp(24, 30, 100, [])), null);
});
test('supports nonzero byte offsets, empty spectra and output resampling', () => {
  const raw = new Uint8Array(rsp(2, 30, 1, [0, 255]));
  const wrapper = new Uint8Array(raw.length + 7); wrapper.set(raw, 7);
  assert.deepEqual(levelsAt(parseSpectrum(wrapper.subarray(7)), 0, new Array(4)), [0, 0, 1, 1]);
  assert.deepEqual(levelsAt(parseSpectrum(rsp(2, 30, 0, [])), 0, [1, 1]), [0, 0]);
});
