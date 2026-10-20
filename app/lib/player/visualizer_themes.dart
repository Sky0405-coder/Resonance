import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import '../l10n/l10n.dart';

enum VisualizerStyle { bars, segments, area }

class VisualizerTheme {
  const VisualizerTheme({
    required this.id,
    required this.style,
    required this.colors,
    this.glow = false,
    this.peaks = false,
    this.rainbow = false,
  });

  final String id;
  final VisualizerStyle style;
  final List<Color> colors;
  final bool glow;
  final bool peaks;
  final bool rainbow;
}

/// Colors run from the bottom to the top. Automatic uses the cover's color instead.
const visualizerThemes = <VisualizerTheme>[
  VisualizerTheme(id: 'auto', style: VisualizerStyle.bars, colors: []),
  VisualizerTheme(
    id: 'retro',
    style: VisualizerStyle.segments,
    colors: [Color(0xFF3DDC84), Color(0xFFFFD60A), Color(0xFFFF453A)],
    peaks: true,
  ),
  VisualizerTheme(
    id: 'synthwave',
    style: VisualizerStyle.bars,
    colors: [Color(0xFFFF2BD6), Color(0xFF00E5FF)],
    glow: true,
  ),
  VisualizerTheme(id: 'neon', style: VisualizerStyle.bars, colors: [Color(0xFF39FF14)], glow: true),
  VisualizerTheme(id: 'ocean', style: VisualizerStyle.area, colors: [Color(0xFF0A3D91), Color(0xFF2EE6D6)]),
  VisualizerTheme(
    id: 'sunset',
    style: VisualizerStyle.bars,
    colors: [Color(0xFFFF7A00), Color(0xFFFF2E63), Color(0xFF7A2BFF)],
  ),
  VisualizerTheme(
    id: 'fire',
    style: VisualizerStyle.bars,
    colors: [Color(0xFFB00000), Color(0xFFFF4500), Color(0xFFFFD000)],
    glow: true,
  ),
  VisualizerTheme(id: 'matrix', style: VisualizerStyle.segments, colors: [Color(0xFF00FF41)], peaks: true),
  VisualizerTheme(
    id: 'aurora',
    style: VisualizerStyle.area,
    colors: [Color(0xFF00C9A7), Color(0xFF4FFFB0), Color(0xFFA06CFF)],
    glow: true,
  ),
  VisualizerTheme(id: 'mono', style: VisualizerStyle.bars, colors: [Color.from(alpha: 0.9, red: 1, green: 1, blue: 1)]),
  VisualizerTheme(id: 'rainbow', style: VisualizerStyle.bars, colors: [], rainbow: true),
];

String visualizerThemeName(AppLocalizations l10n, String id) => switch (id) {
  'retro' => l10n.visualizerThemeRetro,
  'synthwave' => l10n.visualizerThemeSynthwave,
  'neon' => l10n.visualizerThemeNeon,
  'ocean' => l10n.visualizerThemeOcean,
  'sunset' => l10n.visualizerThemeSunset,
  'fire' => l10n.visualizerThemeFire,
  'matrix' => l10n.visualizerThemeMatrix,
  'aurora' => l10n.visualizerThemeAurora,
  'mono' => l10n.visualizerThemeMono,
  'rainbow' => l10n.visualizerThemeRainbow,
  _ => l10n.visualizerThemeAuto,
};

final visualizerThemeProvider = NotifierProvider<VisualizerThemeController, VisualizerTheme>(
  VisualizerThemeController.new,
);

class VisualizerThemeController extends Notifier<VisualizerTheme> {
  @override
  VisualizerTheme build() {
    final id = ref.read(prefsProvider).getString('visualizer_theme') ?? 'auto';
    return visualizerThemes.firstWhere((theme) => theme.id == id, orElse: () => visualizerThemes.first);
  }

  void set(VisualizerTheme theme) {
    ref.read(prefsProvider).setString('visualizer_theme', theme.id);
    state = theme;
  }
}

/// [heldFor] is the time since this peak was last reached, before the current tick.
double nextPeak(double peak, double level, double heldFor, double dt) {
  final fallingFor = math.max(0.0, heldFor + dt - 0.4) - math.max(0.0, heldFor - 0.4);
  return math.max(level, peak - 0.6 * fallingFor);
}

Color rainbowColor(int barIndex, int barCount) => HSVColor.fromAHSV(1, 360 * barIndex / barCount, 0.8, 1).toColor();
