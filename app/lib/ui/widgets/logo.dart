import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Resonance mark (dot with sound waves, see branding/logo.svg), drawn in [color] – by default the
/// user's accent color.
class ResonanceLogo extends StatelessWidget {
  const ResonanceLogo({super.key, this.size = 56, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      CustomPaint(size: Size.square(size), painter: _LogoPainter(color ?? Theme.of(context).colorScheme.primary));
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Same geometry as the SVG (108 units, artwork spans 22..86 around the centre 54).
    final scale = size.width / 64;
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(scale);
    canvas.drawCircle(Offset.zero, 7, Paint()..color = color);
    // Arcs of ±45° around the horizontal axis on both sides (SVG endpoints at 14/23/32 units diagonally).
    for (final (offset, opacity) in const [(14.0, 1.0), (23.0, 0.7), (32.0, 0.4)]) {
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round;
      final rect = Rect.fromCircle(center: Offset.zero, radius: offset * math.sqrt2);
      canvas.drawArc(rect, math.pi * 3 / 4, math.pi / 2, false, paint);
      canvas.drawArc(rect, -math.pi / 4, math.pi / 2, false, paint);
    }
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.color != color;
}
