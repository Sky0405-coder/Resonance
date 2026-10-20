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
    // Only when the player already runs (the page alone should not start it).
    final track = ref.exists(playerProvider) ? ref.watch(playerProvider.select((p) => p.current)) : null;
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
      body: ListView(
        padding: const EdgeInsets.only(top: 16, bottom: kBottomInset),
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              spacing: 8,
              children: [
                for (final preset in [...equalizerPresets.keys, if (settings.preset == 'custom') 'custom'])
                  ChoiceChip(
                    label: Text(equalizerPresetName(l10n, preset)),
                    selected: settings.preset == preset,
                    onSelected: (_) => controller.set(settings.withPreset(preset)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 32),
          LayoutBuilder(
            builder: (context, constraints) {
              final width = math.max(640.0, math.min(720.0, constraints.maxWidth));
              return SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  width: math.max(width, constraints.maxWidth),
                  child: Center(
                    child: SizedBox(
                      width: width,
                      child: Column(
                        children: [
                          Row(
                            children: [
                              for (final gain in settings.gains)
                                Expanded(
                                  child: Text(
                                    _gainLabel(gain),
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: settings.enabled ? null : theme.disabledColor),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            height: 240,
                            child: Stack(
                              children: [
                                // The playing song's spectrum, shaped by the current settings.
                                if (track != null && ref.watch(visualizerEnabledProvider))
                                  Positioned.fill(
                                    left: 8,
                                    right: 8,
                                    child: IgnorePointer(
                                      child: SpectrumVisualizer(
                                        trackId: track.id,
                                        color: theme.colorScheme.primary.withValues(alpha: 0.22),
                                        gap: 0.4,
                                        minHeight: 0,
                                        boost: settings.enabled ? (hz) => equalizerGainAt(settings.gains, hz) : null,
                                      ),
                                    ),
                                  ),
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: CustomPaint(
                                      painter: _EqualizerCurve(
                                        settings.gains,
                                        settings.enabled ? theme.colorScheme.primary : theme.disabledColor,
                                      ),
                                    ),
                                  ),
                                ),
                                Row(
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
                                            padding: const EdgeInsets.symmetric(horizontal: 16),
                                            label: l10n.equalizerDecibels(_gainLabel(settings.gains[i])),
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
                              ],
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              for (final frequency in equalizerFrequencies)
                                Expanded(
                                  child: Text(
                                    frequency < 1000
                                        ? frequency.toString()
                                        : l10n.equalizerFrequencyK(frequency ~/ 1000),
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
          const SizedBox(height: 24),
          Center(
            child: TextButton(
              onPressed: () => controller.set(settings.withPreset('flat')),
              child: Text(l10n.equalizerReset),
            ),
          ),
        ],
      ),
    );
  }
}

class _EqualizerCurve extends CustomPainter {
  const _EqualizerCurve(this.gains, this.color);
  final List<double> gains;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final bandWidth = size.width / gains.length;
    final points = [
      for (var i = 0; i < gains.length; i++)
        Offset(bandWidth * (i + 0.5), 16 + (12 - gains[i]) / 24 * (size.height - 32)),
    ];
    final curve = Path()..moveTo(points.first.dx, points.first.dy);
    for (var i = 1; i < points.length; i++) {
      final previous = points[i - 1];
      final point = points[i];
      final middle = (previous.dx + point.dx) / 2;
      curve.cubicTo(middle, previous.dy, middle, point.dy, point.dx, point.dy);
    }
    final fill = Path.from(curve)
      ..lineTo(points.last.dx, size.height)
      ..lineTo(points.first.dx, size.height)
      ..close();
    canvas.drawPath(fill, Paint()..color = color.withValues(alpha: 0.08));
    canvas.drawPath(
      curve,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_EqualizerCurve oldDelegate) =>
      color != oldDelegate.color || !listEquals(gains, oldDelegate.gains);
}
