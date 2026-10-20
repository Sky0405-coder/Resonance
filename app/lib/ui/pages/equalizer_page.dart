import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../player/equalizer.dart';
import '../../player/equalizer_controller.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import '../widgets/collection.dart';

String equalizerPresetName(AppLocalizations l10n, String preset) => switch (preset) {
  'bass' => l10n.equalizerPresetBass,
  'treble' => l10n.equalizerPresetTreble,
  'vocal' => l10n.equalizerPresetVocal,
  'rock' => l10n.equalizerPresetRock,
  'pop' => l10n.equalizerPresetPop,
  'hiphop' => l10n.equalizerPresetHiphop,
  'electronic' => l10n.equalizerPresetElectronic,
  'acoustic' => l10n.equalizerPresetAcoustic,
  'loudness' => l10n.equalizerPresetLoudness,
  'custom' => l10n.equalizerPresetCustom,
  _ => l10n.equalizerPresetFlat,
};

String _gainLabel(double gain) {
  final value = gain.abs() == gain.abs().roundToDouble() ? gain.abs().toInt().toString() : gain.abs().toString();
  return '${gain > 0 ? '+' : (gain < 0 ? '−' : '')}$value';
}

class EqualizerPage extends ConsumerWidget {
  const EqualizerPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(equalizerProvider);
    final controller = ref.read(equalizerProvider.notifier);
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final color = settings.enabled ? accent : theme.disabledColor;
    // Only when the player already runs (the page alone should not start it).
    final track = ref.exists(playerProvider) ? ref.watch(playerProvider.select((p) => p.current)) : null;
    final presets = [...equalizerPresets.keys, if (settings.preset == 'custom') 'custom'];
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.equalizerTitle, style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [
          Semantics(
            label: l10n.equalizerTitle,
            child: Switch(
              value: settings.enabled,
              onChanged: (enabled) => controller.set(settings.copyWith(enabled: enabled)),
            ),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
            children: [
              // The curve with its ten bands, all on screen at once.
              AnimatedOpacity(
                duration: const Duration(milliseconds: 200),
                opacity: settings.enabled ? 1 : 0.55,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8, 16, 8, 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        color.withValues(alpha: 0.22),
                        theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                      ],
                    ),
                    border: Border.all(color: color.withValues(alpha: 0.25)),
                  ),
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                equalizerPresetName(l10n, settings.preset),
                                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                              ),
                            ),
                            TextButton.icon(
                              onPressed: () => controller.set(settings.withPreset('flat')),
                              icon: const Icon(Icons.restart_alt, size: 18),
                              label: Text(l10n.equalizerReset),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          for (final gain in settings.gains)
                            Expanded(
                              child: Text(
                                _gainLabel(gain),
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  fontFeatures: const [FontFeature.tabularFigures()],
                                  color: gain == 0 ? theme.hintColor : color,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      SizedBox(
                        height: 260,
                        child: Stack(
                          children: [
                            // The playing song's spectrum, shaped by the current settings.
                            if (track != null && ref.watch(visualizerEnabledProvider))
                              Positioned.fill(
                                child: IgnorePointer(
                                  child: SpectrumVisualizer(
                                    trackId: track.id,
                                    color: accent.withValues(alpha: 0.18),
                                    gap: 0.35,
                                    minHeight: 0,
                                    boost: settings.enabled ? (hz) => equalizerGainAt(settings.gains, hz) : null,
                                  ),
                                ),
                              ),
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: _EqualizerCurve(settings.gains, color, grid: theme.dividerColor),
                                ),
                              ),
                            ),
                            SliderTheme(
                              data: SliderTheme.of(context).copyWith(
                                trackHeight: 2,
                                activeTrackColor: Colors.transparent,
                                inactiveTrackColor: theme.dividerColor.withValues(alpha: 0.35),
                                disabledActiveTrackColor: Colors.transparent,
                                disabledInactiveTrackColor: theme.dividerColor.withValues(alpha: 0.2),
                                thumbColor: Colors.white,
                                disabledThumbColor: theme.disabledColor,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 9, elevation: 3),
                                overlayShape: const RoundSliderOverlayShape(overlayRadius: 18),
                                overlayColor: accent.withValues(alpha: 0.2),
                                tickMarkShape: SliderTickMarkShape.noTickMark,
                                showValueIndicator: ShowValueIndicator.never,
                              ),
                              child: Row(
                                children: [
                                  for (var i = 0; i < equalizerFrequencies.length; i++)
                                    Expanded(
                                      child: RotatedBox(
                                        quarterTurns: 3,
                                        child: Slider(
                                          value: settings.gains[i],
                                          min: -12,
                                          max: 12,
                                          divisions: 48,
                                          padding: const EdgeInsets.symmetric(horizontal: 14),
                                          semanticFormatterCallback: (value) =>
                                              '${l10n.equalizerBandLabel(equalizerFrequencies[i])}: '
                                              '${l10n.equalizerDecibels(_gainLabel(value))}',
                                          onChanged: settings.enabled
                                              ? (gain) => controller.set(settings.withGain(i, gain))
                                              : null,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          for (final frequency in equalizerFrequencies)
                            Expanded(
                              child: Text(
                                frequency < 1000 ? frequency.toString() : l10n.equalizerFrequencyK(frequency ~/ 1000),
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 11, color: theme.hintColor),
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 12),
                child: Text(
                  l10n.equalizerPresets,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns = math.max(3, (constraints.maxWidth / 170).floor());
                  final width = (constraints.maxWidth - (columns - 1) * 10) / columns;
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      for (final preset in presets)
                        SizedBox(
                          width: width,
                          child: EqualizerPresetCard(
                            name: equalizerPresetName(l10n, preset),
                            gains: equalizerPresets[preset] ?? settings.gains,
                            selected: settings.preset == preset,
                            onTap: preset == 'custom' ? null : () => controller.set(settings.withPreset(preset)),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A preset with a small preview of its curve.
class EqualizerPresetCard extends StatelessWidget {
  const EqualizerPresetCard({
    super.key,
    required this.name,
    required this.gains,
    required this.selected,
    required this.onTap,
  });
  final String name;
  final List<double> gains;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Material(
      color: selected
          ? accent.withValues(alpha: 0.2)
          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: selected ? accent : Colors.transparent, width: 1.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 30,
                width: double.infinity,
                child: CustomPaint(painter: _EqualizerCurve(gains, selected ? accent : theme.hintColor, preview: true)),
              ),
              const SizedBox(height: 8),
              Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: FontWeight.w700, color: selected ? accent : null),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EqualizerCurve extends CustomPainter {
  const _EqualizerCurve(this.gains, this.color, {this.grid, this.preview = false});
  final List<double> gains;
  final Color color;
  final Color? grid;
  final bool preview;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = preview ? 3.0 : 14.0; // Matches the sliders' padding, so the thumbs sit on the curve.
    double y(double gain) => inset + (12 - gain) / 24 * (size.height - 2 * inset);
    final bandWidth = size.width / gains.length;
    final grid = this.grid;
    if (grid != null) {
      // 0 dB stronger, ±6 and ±12 dB faint.
      for (final gain in const [12.0, 6.0, 0.0, -6.0, -12.0]) {
        canvas.drawLine(
          Offset(0, y(gain)),
          Offset(size.width, y(gain)),
          Paint()
            ..color = grid.withValues(alpha: gain == 0 ? 0.5 : 0.18)
            ..strokeWidth = 1,
        );
      }
    }
    final points = [for (var i = 0; i < gains.length; i++) Offset(bandWidth * (i + 0.5), y(gains[i]))];
    final curve = Path()
      ..moveTo(0, points.first.dy)
      ..lineTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final previous = points[i - 1];
      final point = points[i];
      final middle = (previous.dx + point.dx) / 2;
      curve.cubicTo(middle, previous.dy, middle, point.dy, point.dx, point.dy);
    }
    curve.lineTo(size.width, points.last.dy);
    final fill = Path.from(curve)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: preview ? 0.25 : 0.3),
            color.withValues(alpha: 0),
          ],
        ).createShader(Offset.zero & size),
    );
    if (!preview) {
      // A soft glow under the line.
      canvas.drawPath(
        curve,
        Paint()
          ..color = color.withValues(alpha: 0.35)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 8
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    canvas.drawPath(
      curve,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = preview ? 2 : 3,
    );
  }

  @override
  bool shouldRepaint(_EqualizerCurve oldDelegate) =>
      color != oldDelegate.color || grid != oldDelegate.grid || !listEquals(gains, oldDelegate.gains);
}
