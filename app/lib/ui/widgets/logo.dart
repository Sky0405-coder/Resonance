import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The Resonance mark (filled circle with a dot and sound waves, see branding/logo.svg). The circle is drawn
/// in [color] – by default the user's accent color – and the symbol in the dark background color.
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
    // Same geometry as the SVG: 108 units, circle r=54, dot r=8, arcs r=17/27/37 at ±42° around the horizontal.
    canvas.translate(size.width / 2, size.height / 2);
    canvas.scale(size.width / 108);
    canvas.drawCircle(Offset.zero, 54, Paint()..color = color);
    const symbol = Color(0xFF121212);
    canvas.drawCircle(Offset.zero, 8, Paint()..color = symbol);
    final paint = Paint()
      ..color = symbol
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.5
      ..strokeCap = StrokeCap.round;
    const sweep = 84 * math.pi / 180;
    for (final r in const [17.0, 27.0, 37.0]) {
      final rect = Rect.fromCircle(center: Offset.zero, radius: r);
      canvas.drawArc(rect, -sweep / 2, sweep, false, paint);
      canvas.drawArc(rect, math.pi - sweep / 2, sweep, false, paint);
    }
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.color != color;
}
