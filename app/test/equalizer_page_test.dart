import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/player/equalizer.dart';
import 'package:resonance/player/equalizer_controller.dart';
import 'package:resonance/ui/pages/equalizer_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> showEqualizer(WidgetTester tester, {String? saved, String locale = 'en'}) async {
  SharedPreferences.setMockInitialValues({'equalizer': ?saved});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [prefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const EqualizerPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return prefs;
}

List<Slider> sliders(WidgetTester tester) => tester.widgetList<Slider>(find.byType(Slider)).toList();

void main() {
  testWidgets('renders ten disabled vertical sliders and selecting Bass updates and persists their gains', (
    tester,
  ) async {
    final prefs = await showEqualizer(tester);
    expect(sliders(tester), hasLength(10));
    expect(sliders(tester).every((slider) => slider.onChanged == null && slider.value == 0), isTrue);
    expect(sliders(tester).every((slider) => slider.min == -12 && slider.max == 12 && slider.divisions == 48), isTrue);
    expect(tester.widgetList<RotatedBox>(find.byType(RotatedBox)).every((box) => box.quarterTurns == 3), isTrue);
    expect(find.text('Custom'), findsNothing);

    await tester.tap(find.widgetWithText(ChoiceChip, 'Bass boost'));
    await tester.pump();
    expect(sliders(tester).map((slider) => slider.value), equalizerPresets['bass']);
    expect(prefs.getString('equalizer'), isNull);
    await tester.pump(const Duration(milliseconds: 80));
    final saved = EqualizerSettings.fromJson(jsonDecode(prefs.getString('equalizer')!));
    expect(saved.preset, 'bass');
    expect(saved.gains, equalizerPresets['bass']);
    expect(saved.enabled, isFalse);
  });

  testWidgets('loads saved settings, enables sliders, selects custom on edits, and resets to flat', (tester) async {
    await showEqualizer(tester, saved: jsonEncode(EqualizerSettings().withPreset('rock').toJson()));
    expect(sliders(tester).map((slider) => slider.value), equalizerPresets['rock']);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(sliders(tester).every((slider) => slider.onChanged != null), isTrue);
    sliders(tester).first.onChanged!(3.5);
    await tester.pump();
    expect(sliders(tester).first.value, 3.5);
    expect(find.text('+3.5'), findsOneWidget);
    final custom = tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Custom'));
    expect(custom.selected, isTrue);

    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(sliders(tester).every((slider) => slider.value == 0 && slider.onChanged != null), isTrue);
    expect(find.text('Custom'), findsNothing);
  });

  testWidgets('narrow screens scroll the band row and display German preset names', (tester) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await showEqualizer(tester, locale: 'de');
    expect(find.widgetWithText(ChoiceChip, 'Bass-Boost'), findsOneWidget);
    expect(find.text('Zurücksetzen'), findsOneWidget);
    final lastSlider = find.byType(Slider).last;
    expect(tester.getCenter(lastSlider).dx, greaterThan(360));
    await tester.drag(find.byType(Slider).at(4), const Offset(-360, 0));
    await tester.pumpAndSettle();
    expect(tester.getCenter(lastSlider).dx, lessThan(360));
    expect(tester.takeException(), isNull);
  });

  testWidgets('broken saved JSON falls back to disabled flat settings', (tester) async {
    await showEqualizer(tester, saved: 'broken');
    expect(sliders(tester).every((slider) => slider.value == 0 && slider.onChanged == null), isTrue);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Flat')).selected, isTrue);
  });

  testWidgets('rapid changes persist only the latest settings after 80 ms', (tester) async {
    final prefs = await showEqualizer(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(EqualizerPage)));
    final controller = container.read(equalizerProvider.notifier);
    controller.set(EqualizerSettings(enabled: true).withGain(0, 2));
    await tester.pump(const Duration(milliseconds: 40));
    controller.set(container.read(equalizerProvider).withGain(0, -4.5));
    await tester.pump(const Duration(milliseconds: 79));
    expect(prefs.getString('equalizer'), isNull);
    await tester.pump(const Duration(milliseconds: 1));
    final saved = EqualizerSettings.fromJson(jsonDecode(prefs.getString('equalizer')!));
    expect(saved.enabled, isTrue);
    expect(saved.preset, 'custom');
    expect(saved.gains.first, -4.5);
  });
}
