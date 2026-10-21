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
    this.reflect = false,
  });

  final String id;
  final VisualizerStyle style;
  final List<Color> colors;
  final bool glow;
  final bool peaks;
  final bool rainbow;
  final bool reflect;
}

/// Colors run from the bottom to the top. Automatic uses the cover's color instead.
const visualizerThemes = <VisualizerTheme>[
  VisualizerTheme(id: 'auto', style: VisualizerStyle.bars, colors: []),
  VisualizerTheme(
    id: 'retro',
    style: VisualizerStyle.segments,
    colors: [Color(0xFF3DDC84), Color(0xFFFFD60A), Color(0xFFFF453A)],
    peaks: true,
    reflect: true,
  ),
  VisualizerTheme(
    id: 'synthwave',
    style: VisualizerStyle.bars,
    colors: [Color(0xFFFF2BD6), Color(0xFF00E5FF)],
    glow: true,
    reflect: true,
  ),
  VisualizerTheme(id: 'neon', style: VisualizerStyle.bars, colors: [Color(0xFF39FF14)], glow: true, reflect: true),
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
    reflect: true,
  ),
  VisualizerTheme(
    id: 'matrix',
    style: VisualizerStyle.segments,
    colors: [Color(0xFF00FF41)],
    peaks: true,
    reflect: true,
  ),
  VisualizerTheme(
    id: 'aurora',
    style: VisualizerStyle.area,
    colors: [Color(0xFF00C9A7), Color(0xFF4FFFB0), Color(0xFFA06CFF)],
    glow: true,
    reflect: true,
  ),
  VisualizerTheme(id: 'mono', style: VisualizerStyle.bars, colors: [Color.from(alpha: 0.9, red: 1, green: 1, blue: 1)]),
  VisualizerTheme(id: 'rainbow', style: VisualizerStyle.bars, colors: [], rainbow: true, reflect: true),
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

final visualizerPeaksProvider = NotifierProvider<VisualizerPeaksController, bool>(VisualizerPeaksController.new);

class VisualizerPeaksController extends Notifier<bool> {
  @override
  bool build() => ref.read(prefsProvider).getBool('visualizer_peaks') ?? true;

  void set(bool enabled) {
    ref.read(prefsProvider).setBool('visualizer_peaks', enabled);
    state = enabled;
  }
}

final coverflowProvider = NotifierProvider<CoverflowController, bool>(CoverflowController.new);

class CoverflowController extends Notifier<bool> {
  @override
  bool build() => ref.read(prefsProvider).getBool('coverflow') ?? false;

  void set(bool enabled) {
    ref.read(prefsProvider).setBool('coverflow', enabled);
    state = enabled;
  }
}

class PeakBubble {
  const PeakBubble(this.height, {this.age = 0});

  final double height;
  final double age;

  double get opacity => (1 - age / 0.8).clamp(0.0, 1.0);
}

class PeakDots {
  const PeakDots({this.level = 0, this.bubbles = const []});

  final double level;
  final List<PeakBubble> bubbles;

  PeakDots advance(double level, double dt) {
    final elapsed = math.max(0.0, dt);
    final next = [
      for (final bubble in bubbles)
        if (bubble.age + elapsed < 0.8) PeakBubble(bubble.height + 0.5 * elapsed, age: bubble.age + elapsed),
      if (level < this.level) PeakBubble(this.level),
    ];
    return PeakDots(level: level, bubbles: List.unmodifiable(next.skip(math.max(0, next.length - 3))));
  }
}

Color rainbowColor(int barIndex, int barCount) => HSVColor.fromAHSV(1, 360 * barIndex / barCount, 0.8, 1).toColor();
