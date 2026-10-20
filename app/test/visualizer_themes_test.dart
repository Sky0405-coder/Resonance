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

  test('peaks hold for 0.4 seconds, then fall by 0.6 per second', () {
    expect(nextPeak(0.9, 0.2, 0, 0.1), 0.9);
    expect(nextPeak(0.9, 0.2, 0.3, 0.1), 0.9);
    expect(nextPeak(0.9, 0.2, 0.35, 0.1), closeTo(0.87, 1e-9));
    expect(nextPeak(0.9, 0.2, 0.4, 0.1), closeTo(0.84, 1e-9));
    expect(nextPeak(0.9, 0.2, 1, 0.5), closeTo(0.6, 1e-9));
  });

  test('peaks follow rising levels immediately and never fall below the current level', () {
    expect(nextPeak(0.5, 0.9, 0.2, 0.1), 0.9);
    expect(nextPeak(0.5, 0.9, 1, 0.1), 0.9);
    expect(nextPeak(0.5, 0.49, 1, 0.1), 0.49);
    expect(nextPeak(0.1, 0, 1, 1), 0);
    expect(nextPeak(0.8, 0.2, 1, 0), 0.8);
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
