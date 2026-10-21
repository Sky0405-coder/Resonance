import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/admin/admin_page.dart';

class _AdminApi extends ApiClient {
  _AdminApi(this.analysisStatus) : super('http://localhost', 'token');

  ({int total, int analyzed, int failed}) analysisStatus;
  int calls = 0;

  @override
  Future<LibraryStats> libraryStats() async => const LibraryStats(1, 1, 2000, 0, 0);

  @override
  Future<List<Job>> jobs() async => [];

  @override
  Future<({int total, int analyzed, int failed})> mixAnalysisStatus() async {
    calls++;
    return analysisStatus;
  }
}

Future<void> _showAdmin(WidgetTester tester, _AdminApi api, String locale) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiProvider.overrideWithValue(api)],
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
      final api = _AdminApi((total: 2000, analyzed: 1250, failed: 1000));
      await _showAdmin(tester, api, locale);
      expect(find.text(locale == 'en' ? 'AutoMix analysis' : 'AutoMix-Analyse'), findsOneWidget);
      expect(
        find.text(
          locale == 'en'
              ? '1,250 of 2,000 songs analyzed, 1,000 failed'
              : '1.250 von 2.000 Songs analysiert, 1.000 fehlgeschlagen',
        ),
        findsOneWidget,
      );
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.625);
      api.analysisStatus = (total: 2000, analyzed: 1500, failed: 0);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      expect(api.calls, 2);
      expect(
        find.text(locale == 'en' ? '1,500 of 2,000 songs analyzed' : '1.500 von 2.000 Songs analysiert'),
        findsOneWidget,
      );
      expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0.75);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('empty libraries show zero progress', (tester) async {
    await _showAdmin(tester, _AdminApi((total: 0, analyzed: 0, failed: 0)), 'en');
    expect(find.text('0 of 0 songs analyzed'), findsOneWidget);
    expect(tester.widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator)).value, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
