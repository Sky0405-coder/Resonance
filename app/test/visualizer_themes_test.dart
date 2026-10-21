import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/player/spectrum.dart';
import 'package:resonance/player/visualizer_themes.dart';
import 'package:resonance/ui/pages/settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the eleven themes have unique ids and names in both ARB locales', () {
    const ids = [
      'auto',
      'retro',
      'synthwave',
      'neon',
      'ocean',
      'sunset',
      'fire',
      'matrix',
      'aurora',
      'mono',
      'rainbow',
    ];
    const names = {
      'de': [
        'Automatisch',
        'Retro-Stereo',
        'Synthwave',
        'Neon',
        'Ozean',
        'Sonnenuntergang',
        'Feuer',
        'Matrix',
        'Polarlicht',
        'Monochrom',
        'Regenbogen',
      ],
      'en': [
        'Automatic',
        'Retro hi-fi',
        'Synthwave',
        'Neon',
        'Ocean',
        'Sunset',
        'Fire',
        'Matrix',
        'Aurora',
        'Monochrome',
        'Rainbow',
      ],
    };
    expect(visualizerThemes.map((theme) => theme.id), ids);
    expect(visualizerThemes.map((theme) => theme.id).toSet(), hasLength(11));
    for (final locale in names.keys) {
      final arb = jsonDecode(File('lib/l10n/app_$locale.arb').readAsStringSync()) as Map<String, dynamic>;
      final l10n = lookupAppLocalizations(Locale(locale));
      for (var i = 0; i < ids.length; i++) {
        final id = ids[i];
        final key = 'visualizerTheme${id[0].toUpperCase()}${id.substring(1)}';
        expect(arb[key], names[locale]![i]);
        expect(visualizerThemeName(l10n, id), names[locale]![i]);
      }
    }
    expect(visualizerThemes.first.colors, isEmpty);
    expect(visualizerThemes.first.style, VisualizerStyle.bars);
  });

  test('only the specified themes reflect their visualizers', () {
    expect(visualizerThemes.where((theme) => theme.reflect).map((theme) => theme.id).toSet(), {
      'synthwave',
      'neon',
      'fire',
      'aurora',
      'rainbow',
      'retro',
      'matrix',
    });
  });

  test('peak dots follow rising and held bars without releasing bubbles', () {
    const initial = PeakDots(level: 0.4);
    final rising = initial.advance(0.9, 0.1);
    final held = rising.advance(0.9, 0.1);
    expect(rising.level, 0.9);
    expect(held.level, 0.9);
    expect(rising.bubbles, isEmpty);
    expect(held.bubbles, isEmpty);
    expect(initial.level, 0.4);
  });

  test('falling bars release a bubble and immediately create a dot at the current level', () {
    final dots = const PeakDots(level: 0.9).advance(0.3, 0.1);
    expect(dots.level, 0.3);
    expect(dots.bubbles, hasLength(1));
    expect(dots.bubbles.single.height, 0.9);
    expect(dots.bubbles.single.opacity, 1);
    final next = dots.advance(0.3, 0.4);
    expect(next.bubbles.single.height, closeTo(1.1, 1e-9));
    expect(next.bubbles.single.opacity, closeTo(0.5, 1e-9));
    expect(next.advance(0.3, 0.4).bubbles, isEmpty);
    expect(dots.bubbles.single.age, 0);
  });

  test('each bar keeps at most three live bubbles and drops the oldest', () {
    var dots = const PeakDots(level: 1);
    for (final level in [0.9, 0.8, 0.7, 0.6]) {
      dots = dots.advance(level, 0.1);
    }
    expect(dots.bubbles, hasLength(3));
    expect(dots.bubbles.map((bubble) => bubble.age), [closeTo(0.2, 1e-9), closeTo(0.1, 1e-9), 0]);
    expect(dots.bubbles.map((bubble) => bubble.height), [closeTo(1, 1e-9), closeTo(0.85, 1e-9), 0.7]);
  });

  test('bubble updates handle silence, zero and negative time, and a long elapsed frame', () {
    const initial = PeakDots(level: 0.6, bubbles: [PeakBubble(0.8, age: 0.2)]);
    for (final dt in [0.0, -1.0]) {
      final dots = initial.advance(0.6, dt);
      expect(dots.bubbles.single.height, 0.8);
      expect(dots.bubbles.single.age, 0.2);
    }
    final silent = initial.advance(0, 1);
    expect(silent.level, 0);
    expect(silent.bubbles.single.height, 0.6);
    expect(silent.advance(0, 0.8).bubbles, isEmpty);
    expect(const PeakDots().advance(0, 0.1).bubbles, isEmpty);
  });

  test('peak and coverflow preferences default, persist and restore', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    expect(container.read(visualizerPeaksProvider), isTrue);
    expect(container.read(coverflowProvider), isFalse);
    container.read(visualizerPeaksProvider.notifier).set(false);
    container.read(coverflowProvider.notifier).set(true);
    expect(container.read(visualizerPeaksProvider), isFalse);
    expect(container.read(coverflowProvider), isTrue);
    expect(prefs.getBool('visualizer_peaks'), isFalse);
    expect(prefs.getBool('coverflow'), isTrue);
    container.dispose();
    final restored = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    expect(restored.read(visualizerPeaksProvider), isFalse);
    expect(restored.read(coverflowProvider), isTrue);
    restored.dispose();
  });

  test('rainbow colors evenly span the hue wheel at saturation 0.8 and value 1', () {
    for (final count in [1, 12, 24, 48]) {
      for (var i = 0; i < count; i++) {
        final color = HSVColor.fromColor(rainbowColor(i, count));
        // HSVColor.toColor quantizes the RGB channels to eight bits.
        expect(color.hue, closeTo(360 * i / count, 0.2));
        expect(color.saturation, closeTo(0.8, 0.005));
        expect(color.value, 1);
        expect(color.alpha, 1);
      }
    }
  });

  test('the theme preference defaults to automatic and restores a saved selection', () async {
    for (final id in [null, 'unknown', 'synthwave']) {
      SharedPreferences.setMockInitialValues({'visualizer_theme': ?id});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
      expect(container.read(visualizerThemeProvider).id, id == 'synthwave' ? id : 'auto');
      container.dispose();
    }
  });

  for (final theme in visualizerThemes) {
    testWidgets('${theme.id} preview paints in mirrored and ordinary layouts', (tester) async {
      for (final mirrored in [true, false]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Center(
                child: SizedBox(
                  width: 240,
                  child: SpectrumPreview(theme: theme, color: Colors.purple, mirrored: mirrored),
                ),
              ),
            ),
          ),
        );
        expect(tester.getSize(find.byType(SpectrumPreview)).height, 72);
        expect(tester.takeException(), isNull);
      }
    });
  }

  testWidgets('the settings sheet shows eleven previews and selecting Synthwave persists and closes it', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => const FractionallySizedBox(
                    heightFactor: 0.85,
                    child: VisualizerThemeSheet(accent: Colors.purple),
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Visualizer style'), findsOneWidget);
    expect(find.byType(SpectrumPreview), findsNWidgets(11));
    final autoTile = tester.widget<Material>(
      find.ancestor(of: find.text('Automatic'), matching: find.byType(Material)).first,
    );
    final border = (autoTile.shape! as RoundedRectangleBorder).side;
    expect(border.color, Colors.purple);
    expect(border.width, 2);
    await tester.tap(find.text('Synthwave'));
    await tester.pumpAndSettle();
    expect(find.byType(VisualizerThemeSheet), findsNothing);
    expect(prefs.getString('visualizer_theme'), 'synthwave');
    final restored = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    expect(restored.read(visualizerThemeProvider).id, 'synthwave');
    restored.dispose();
  });

  testWidgets('the settings grid uses two columns up to 600 pixels and three above it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [360.0, 600.0, 601.0, 900.0]) {
      tester.view.physicalSize = Size(width, 800);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [prefsProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            locale: const Locale('de'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: VisualizerThemeSheet(accent: Colors.purple)),
          ),
        ),
      );
      final grid = tester.widget<GridView>(find.byType(GridView));
      final delegate = grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
      expect(delegate.crossAxisCount, width > 600 ? 3 : 2);
      expect(find.text('Visualizer-Stil'), findsOneWidget);
      expect(find.text('Sonnenuntergang'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
