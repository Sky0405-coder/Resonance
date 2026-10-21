import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:resonance/core/changelog.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/changelog_page.dart';
import 'package:resonance/ui/widgets/changelog.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _entries = [
  for (final version in ['1.6.10', '1.6.9', '1.6.8', '1.6.7', '1.6.6'])
    ChangelogEntry(
      version: version,
      date: DateTime(2026, 10, 21),
      de: ['Deutsche Neuigkeit $version', 'Weitere Neuigkeit $version'],
      en: ['English news $version', 'Another change $version'],
    ),
];

Future<SharedPreferences> _show(
  WidgetTester tester, {
  String locale = 'en',
  String? seen = '1.6.6',
  String? current = '1.6.10+40',
  bool? enabled,
  Widget child = const Scaffold(body: ChangelogTile()),
  bool notify = false,
  Future<List<ChangelogEntry>> Function()? load,
}) async {
  SharedPreferences.setMockInitialValues({changelogSeenVersionKey: ?seen});
  final prefs = await SharedPreferences.getInstance();
  final router = GoRouter(
    routes: [
      ShellRoute(
        builder: (_, _, content) => notify ? WhatsNewNotifier(child: content) : content,
        routes: [GoRoute(path: '/', builder: (_, _) => child)],
      ),
      GoRoute(path: '/changelog', builder: (_, _) => const ChangelogPage()),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        installedVersionProvider.overrideWith((ref) async => current),
        changelogProvider.overrideWith((ref) async => load == null ? _entries : load()),
        if (enabled != null) whatsNewEnabledProvider.overrideWithValue(enabled),
      ],
      child: MaterialApp.router(
        locale: Locale(locale),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return prefs;
}

void main() {
  for (final locale in ['de', 'en']) {
    testWidgets('settings tile opens $locale notes with dates and the installed version', (tester) async {
      await _show(tester, locale: locale);
      await tester.pumpAndSettle();
      final title = locale == 'de' ? 'Neuigkeiten' : "What's new";
      expect(find.byIcon(Icons.new_releases_outlined), findsOneWidget);
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      expect(find.byType(ChangelogPage), findsOneWidget);
      expect(find.text(title), findsOneWidget);
      expect(find.text(locale == 'de' ? 'Installiert' : 'Installed'), findsOneWidget);
      expect(find.text(locale == 'de' ? 'Deutsche Neuigkeit 1.6.10' : 'English news 1.6.10'), findsOneWidget);
      expect(find.text(locale == 'de' ? 'English news 1.6.10' : 'Deutsche Neuigkeit 1.6.10'), findsNothing);
      expect(find.text(locale == 'de' ? '21. Okt. 2026' : 'Oct 21, 2026'), findsWidgets);
      await tester.scrollUntilVisible(find.text('1.6.6'), 200);
      expect(find.text('1.6.6'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('automatic reminders are disabled by default in tests even when updates exist', (tester) async {
    final prefs = await _show(tester, notify: true, load: () => throw StateError('Must not load'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(prefs.getString(changelogSeenVersionKey), '1.6.6');
    expect(tester.takeException(), isNull);
  });

  for (final locale in ['de', 'en']) {
    testWidgets('opted-in $locale reminder shows at most three versions and acknowledges once', (tester) async {
      final prefs = await _show(tester, locale: locale, notify: true, enabled: true);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text(locale == 'de' ? 'Neu in Version 1.6.10+40' : 'New in version 1.6.10+40'), findsOneWidget);
      expect(find.byType(ChangelogSection), findsNWidgets(3));
      expect(find.text('1.6.10'), findsOneWidget);
      expect(find.text('1.6.9'), findsOneWidget);
      expect(find.text('1.6.8'), findsOneWidget);
      expect(find.text('1.6.7'), findsNothing);
      expect(prefs.getString(changelogSeenVersionKey), '1.6.6');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(prefs.getString(changelogSeenVersionKey), '1.6.10+40');
      final element = tester.element(find.byType(WhatsNewNotifier));
      final container = ProviderScope.containerOf(element);
      container.invalidate(whatsNewProvider);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('all news opens the full history and returns to the sheet for acknowledgment', (tester) async {
    final prefs = await _show(tester, notify: true, enabled: true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All updates'));
    await tester.pumpAndSettle();
    expect(find.byType(ChangelogPage), findsOneWidget);
    await tester.scrollUntilVisible(find.text('1.6.6'), 200);
    expect(find.text('1.6.6'), findsOneWidget);
    expect(prefs.getString(changelogSeenVersionKey), '1.6.6');
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(prefs.getString(changelogSeenVersionKey), '1.6.10+40');
    expect(find.byType(BottomSheet), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('first install silently records the running version', (tester) async {
    final prefs = await _show(tester, seen: null, notify: true, enabled: true);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(prefs.getString(changelogSeenVersionKey), '1.6.10+40');
  });

  testWidgets('an unknown web or platform version never opens a reminder', (tester) async {
    final prefs = await _show(tester, current: null, notify: true, enabled: true);
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(prefs.getString(changelogSeenVersionKey), '1.6.6');
  });

  testWidgets('loading and failed changelog assets can be retried', (tester) async {
    final pending = Completer<List<ChangelogEntry>>();
    var attempts = 0;
    await _show(
      tester,
      child: const ChangelogPage(),
      load: () {
        attempts++;
        return attempts == 1 ? pending.future : Future.value(_entries);
      },
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(StateError('Missing asset'));
    await tester.pumpAndSettle();
    expect(find.text('Try again'), findsOneWidget);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('1.6.10'), findsOneWidget);
    expect(attempts, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('small screens scroll release notes while keeping the actions accessible', (tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final prefs = await _show(
      tester,
      locale: 'de',
      notify: true,
      enabled: true,
      load: () async => [
        for (final entry in _entries)
          ChangelogEntry(
            version: entry.version,
            date: entry.date,
            de: List.filled(8, 'Eine längere Neuigkeit, die auf kleinen Bildschirmen mehrere Zeilen braucht.'),
            en: entry.en,
          ),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.text('Alle Neuigkeiten').hitTestable(), findsOneWidget);
    expect(find.text('OK').hitTestable(), findsOneWidget);
    expect(prefs.getString(changelogSeenVersionKey), '1.6.6');
    await tester.tapAt(const Offset(2, 2));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
  });
}
