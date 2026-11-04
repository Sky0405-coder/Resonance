import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/player/transitions.dart';

void main() {
  testWidgets('the slider button switches only its own playlist to mixing, and that is remembered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final scope = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: MixModeButton(playlistId: 'p')),
        ),
      ),
    );
    expect(scope.read(mixModeProvider), isEmpty);
    expect(find.byTooltip('Mix'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    expect(scope.read(mixModeProvider), {'p'});
    expect(find.byTooltip('Stop mixing'), findsOneWidget);
    expect(prefs.getStringList(MixModePlaylists.key), ['p']);

    scope.read(mixModeProvider.notifier).toggle('other');
    final restarted = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    addTearDown(restarted.dispose);
    expect(restarted.read(mixModeProvider), {'p', 'other'});

    await tester.tap(find.byIcon(Icons.tune));
    await tester.pump();
    expect(scope.read(mixModeProvider), {'other'});
  });
}
