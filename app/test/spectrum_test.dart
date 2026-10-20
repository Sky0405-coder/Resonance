import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/player/spectrum.dart';

Uint8List encode(int bands, double fps, List<List<int>> frames) {
  final header = ByteData(13)
    ..setUint8(0, 0x52)
    ..setUint8(1, 0x53)
    ..setUint8(2, 0x50)
    ..setUint8(3, 0x31)
    ..setUint8(4, bands)
    ..setFloat32(5, fps, Endian.little)
    ..setUint32(9, frames.length, Endian.little);
  return Uint8List.fromList([...header.buffer.asUint8List(), for (final f in frames) ...f]);
}

void main() {
  test('parses the server format and interpolates between frames', () {
    final spectrum = Spectrum.parse(encode(2, 20, [
      [0, 255],
      [255, 0],
    ]))!;
    expect((spectrum.bands, spectrum.fps, spectrum.frameCount), (2, 20.0, 2));
    final out = [0.0, 0.0];
    spectrum.levelsAt(Duration.zero, out);
    expect(out, [0.0, 1.0]);
    spectrum.levelsAt(const Duration(milliseconds: 25), out);
    expect(out[0], closeTo(0.5, 0.01));
    expect(out[1], closeTo(0.5, 0.01));
    spectrum.levelsAt(const Duration(seconds: 10), out);
    expect(out, [1.0, 0.0]);
  });

  test('rejects broken data', () {
    expect(Spectrum.parse(Uint8List.fromList([1, 2, 3])), isNull);
    final truncated = encode(4, 20, [
      [1, 2, 3, 4],
    ]);
    expect(Spectrum.parse(Uint8List.sublistView(truncated, 0, truncated.length - 1)), isNull);
  });
}
