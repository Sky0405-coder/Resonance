import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/ui/widgets/cover_crop.dart';

void main() {
  test('the crop is the centred square at first and follows pan and zoom', () {
    const image = Size(2000, 1000);
    // Laid out to cover a 400 viewport: 800 × 400, centred by moving 200 to the left.
    final centred = Matrix4.translationValues(-200, 0, 0);
    expect(coverCropRect(image, 400, centred), const Rect.fromLTWH(500, 0, 1000, 1000));
    final zoomed = Matrix4.translationValues(-400, -100, 0)..scaleByDouble(2, 2, 1, 1);
    expect(coverCropRect(image, 400, zoomed), const Rect.fromLTWH(500, 125, 500, 500));
    expect(coverCropRect(image, 400, Matrix4.translationValues(300, 0, 0)).left, 0, reason: 'never outside the image');
  });
}
