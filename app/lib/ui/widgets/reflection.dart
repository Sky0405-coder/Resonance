import 'package:flutter/material.dart';

/// A faded mirror of static cover artwork. Animated overlays paint their own reflection.
class CoverReflection extends StatelessWidget {
  const CoverReflection({super.key, required this.child, this.fraction = 0.22, this.radius = 8});

  final Widget child;
  final double fraction;
  final double radius;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: LayoutBuilder(
      builder: (context, constraints) => SizedBox(
        height: constraints.maxWidth * fraction,
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color.from(alpha: 0.35, red: 1, green: 1, blue: 1), Color(0x00FFFFFF)],
          ).createShader(bounds),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: OverflowBox(
              alignment: Alignment.topCenter,
              minHeight: constraints.maxWidth,
              maxHeight: constraints.maxWidth,
              child: Transform.flip(flipY: true, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}
