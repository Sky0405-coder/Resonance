import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/admin/admin_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _AdminApi extends ApiClient {
  _AdminApi(this.analysisStatus) : super('http://localhost', 'token');

  ({int total, int analyzed, int failed}) analysisStatus;
  ({int total, int synced, int plainOnly, int instrumental, int none, int missing}) lyricsState = (
    total: 20000,
    synced: 1250,
    plainOnly: 2000,
    instrumental: 500,
    none: 3000,
    missing: 13250,
  );
  int calls = 0;
  int lyricsCalls = 0;
  bool backgroundFetch = true;
  Map<String, dynamic>? lastPatch;

  @override
  Future<LibraryStats> libraryStats() async => const LibraryStats(1, 1, 2000, 0, 0);

  @override
  Future<List<Job>> jobs() async => [];

  @override
  Future<({int total, int analyzed, int failed})> mixAnalysisStatus() async {
    calls++;
    return analysisStatus;
  }

  @override
  Future<({int total, int synced, int plainOnly, int instrumental, int none, int missing})> lyricsStatus() async {
    lyricsCalls++;
    return lyricsState;
  }

  @override
  Future<Map<String, dynamic>> adminConfig() async => {
    'server_name': 'Resonance',
    'registration': {'mode': 'invite'},
    'radio': {'auto_download_enabled': true, 'temporary_tracks_enabled': true, 'temporary_retention_days': 14},
    'downloads': {
      'quality_upgrade_enabled': true,
      'auto_approve_requests': true,
      'daily_limit_enabled': true,
      'daily_limit_per_user': 50,
    },
    'lyrics': {'background_fetch': backgroundFetch},
  };

  @override
  Future<Map<String, dynamic>> patchAdminConfig(Map<String, dynamic> patch) async {
    lastPatch = patch;
    backgroundFetch = patch['lyrics']['background_fetch'] as bool;
    return adminConfig();
  }

  @override
  Future<Job?> genreFillStatus() async => null;
}

Future<void> _showAdmin(WidgetTester tester, _AdminApi api, String locale) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api), prefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        locale: Locale(locale),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AdminPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final locale in ['en', 'de']) {
    testWidgets('admin analysis progress formats $locale counts and refreshes', (tester) async {
      final api = _AdminApi((total: 2000, analyzed: 1250, failed: 250));
      await _showAdmin(tester, api, locale);
      expect(find.text(locale == 'en' ? 'AutoMix analysis' : 'AutoMix-Analyse'), findsOneWidget);
      expect(
        find.text(
          locale == 'en'
              ? '1,250 of 2,000 songs analyzed, 250 failed'
              : '1.250 von 2.000 Songs analysiert, 250 fehlgeschlagen',
        ),
        findsOneWidget,
      );
      // Failed songs count as done.
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).first).value, 0.75);
      api.analysisStatus = (total: 2000, analyzed: 1998, failed: 2);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(
        find.text(
          locale == 'en' ? 'All 2,000 songs analyzed, 2 failed' : 'Alle 2.000 Songs analysiert, 2 fehlgeschlagen',
        ),
        findsOneWidget,
      );
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).first).value, 1.0);
      api.analysisStatus = (total: 2000, analyzed: 1500, failed: 0);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(api.calls, 3);
      expect(
        find.text(locale == 'en' ? '1,500 of 2,000 songs analyzed' : '1.500 von 2.000 Songs analysiert'),
        findsOneWidget,
      );
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).first).value, 0.75);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('admin lyrics progress formats $locale counts and refreshes', (tester) async {
      final api = _AdminApi((total: 2000, analyzed: 1250, failed: 0));
      await _showAdmin(tester, api, locale);
      expect(find.text(locale == 'en' ? 'Lyrics' : 'Songtexte'), findsOneWidget);
      expect(
        find.text(
          locale == 'en'
              ? '1,250 synced, 2,000 plain only, 3,000 none · 13,250 pending'
              : '1.250 mit synchronisiertem Text, 2.000 nur Text, 3.000 ohne · 13.250 noch offen',
        ),
        findsOneWidget,
      );
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).last).value, 0.3375);
      api.lyricsState = (total: 20000, synced: 2000, plainOnly: 2000, instrumental: 500, none: 3000, missing: 12500);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(api.lyricsCalls, 2);
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator).last).value, 0.375);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('admin background lyrics switch saves $locale setting', (tester) async {
      final api = _AdminApi((total: 0, analyzed: 0, failed: 0));
      await _showAdmin(tester, api, locale);
      DefaultTabController.of(tester.element(find.byType(TabBar))).animateTo(5);
      await tester.pumpAndSettle();
      final title = locale == 'en' ? 'Fetch lyrics in the background' : 'Songtexte im Hintergrund laden';
      final toggle = find.widgetWithText(SwitchListTile, title);
      final settingsList = find
          .byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down)
          .last;
      await tester.scrollUntilVisible(toggle, 400, scrollable: settingsList);
      expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(api.lastPatch, {
        'lyrics': {'background_fetch': false},
      });
      expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('empty libraries show zero progress', (tester) async {
    final api = _AdminApi((total: 0, analyzed: 0, failed: 0));
    api.lyricsState = (total: 0, synced: 0, plainOnly: 0, instrumental: 0, none: 0, missing: 0);
    await _showAdmin(tester, api, 'en');
    expect(find.text('0 of 0 songs analyzed'), findsOneWidget);
    expect(find.text('0 synced, 0 plain only, 0 none · 0 pending'), findsOneWidget);
    for (final progress in tester.widgetList<LinearProgressIndicator>(find.byType(LinearProgressIndicator))) {
      expect(progress.value, 0);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
