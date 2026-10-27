import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/app_localizations.dart';
import 'package:resonance/ui/pages/download_pages.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('title and artist of a failed download can be copied', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
    final request = DownloadRequest.fromJson({
      'id': 'r1',
      'kind': 'song',
      'title': 'Al-Naafyish (The Soul)',
      'artist': 'Hashim',
      'status': 'failed',
      'user': {'id': 'u1', 'username': 'Marco'},
      'progress': 0,
      'item_count': 1,
      'done_count': 0,
      'failed_count': 1,
      'created_at': '2026-10-27T10:00:00Z',
      'items': [
        {
          'id': 'i1',
          'position': 0,
          'title': 'AL-Naafyish (The Soul)',
          'artist': 'Hashim',
          'status': 'failed',
          'progress': 0,
          'error': 'No matching source found',
        },
      ],
    });
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefsProvider.overrideWithValue(prefs),
          requestDetailProvider('r1').overrideWith((ref) async => request),
        ],
        child: const MaterialApp(
          locale: Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: RequestDetailPage(id: 'r1'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Copy title and artist'), findsNWidgets(3)); // header text, header button, item button
    await tester.tap(find.byIcon(Icons.content_copy).first);
    await tester.pump();
    expect(copied.last, 'Hashim - Al-Naafyish (The Soul)');
    expect(find.text('Copied “Hashim - Al-Naafyish (The Soul)”'), findsOneWidget);

    await tester.tap(find.text('AL-Naafyish (The Soul)'));
    await tester.pump();
    expect(copied.last, 'Hashim - AL-Naafyish (The Soul)');
  });
}
