import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/audiobooks.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/audiobook_stats_page.dart';

final _now = DateTime(2026, 10, 28, 15);

AbsStats _stats() => AbsStats.fromJson(
  {
    'totalTime': 657478.0,
    'days': {
      '2026-10-28': 1800.0,
      '2026-10-27': 3600.0,
      '2026-10-26': 60.0,
      '2026-10-20': 7200.0,
      '2026-10-01': 600.0,
      '2026-09-01': 100.0,
      '2026-09-02': 100.0,
      '2026-09-03': 100.0,
      '2026-09-04': 100.0,
    },
    'items': {
      'a': {
        'timeListening': 100.0,
        'mediaMetadata': {'title': 'Small', 'authors': []},
      },
      'b': {
        'timeListening': 9000.0,
        'mediaMetadata': {
          'title': 'Big',
          'authors': [
            {'name': 'Writer'},
          ],
        },
      },
    },
  },
  {
    'mediaProgress': [
      {'libraryItemId': 'a', 'isFinished': true, 'finishedAt': DateTime(2026, 3, 1).millisecondsSinceEpoch},
      {'libraryItemId': 'b', 'isFinished': true, 'finishedAt': DateTime(2025, 3, 1).millisecondsSinceEpoch},
      {'libraryItemId': 'c', 'isFinished': false},
      {'libraryItemId': 'p', 'episodeId': 'e', 'isFinished': true},
    ],
  },
  now: _now,
);

void main() {
  test('totals, streaks, finished books and top items', () {
    final stats = _stats();
    final today = DateTime(2026, 10, 28);
    expect(stats.on(today), 1800);
    expect(stats.between(DateTime(2026, 10, 26), today), 5460);
    expect(stats.between(DateTime(2026, 10, 1), today), 13260);
    expect(stats.currentStreak(today), 3);
    // Without listening yet today, yesterday's streak still counts.
    expect(stats.currentStreak(DateTime(2026, 10, 29)), 3);
    expect(stats.currentStreak(DateTime(2026, 10, 30)), 0);
    expect(stats.bestStreak, 4);
    expect(stats.daysActive, 9);
    expect((stats.finished, stats.finishedThisYear), (2, 1));
    expect(stats.items.map((i) => i.title), ['Big', 'Small']);
    expect(stats.items.first.author, 'Writer');
  });

  testWidgets('the stats page shows the total, the week and the activity', (tester) async {
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          absStatsProvider.overrideWith((ref) async => _stats()),
          apiProvider.overrideWithValue(ApiClient('http://localhost', 'token')),
        ],
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: AudiobookStatsPage(now: _now),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('TOTAL LISTENING TIME'), findsOneWidget);
    expect(find.textContaining('182'), findsWidgets);
    expect(find.text("That's 7.6 days of audio"), findsOneWidget);
    expect(find.text('30m'), findsWidgets);
    expect(find.text('3 days'), findsOneWidget);
    expect(find.text('4 days'), findsOneWidget);
    expect(find.text('Big'), findsOneWidget);
    expect(find.text('Wed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
