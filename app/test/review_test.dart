import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/review.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/wrapped_page.dart';
import 'package:resonance/ui/widgets/blends.dart';
import 'package:resonance/ui/widgets/credits_sheet.dart';

Map<String, dynamic> _trackJson(String id, String title) => {
  'id': id,
  'title': title,
  'artist': {'id': 'a-$id', 'name': 'Artist $id'},
  'artist_credit': 'Artist $id',
  'album': {'id': 'al-$id', 'title': 'Album $id'},
  'track_no': 1,
  'disc_no': 1,
  'duration': 200.0,
};

final _wrappedJson = {
  'year': 2026,
  'years': [2025, 2026],
  'minutes': 12345,
  'plays': 900,
  'songs': 321,
  'artists': 87,
  'new_artists': 12,
  'top_tracks': [
    {'track': _trackJson('t1', 'Best Song'), 'plays': 80, 'minutes': 240},
    {'track': _trackJson('t2', 'Second Song'), 'plays': 50, 'minutes': 150},
  ],
  'top_artists': [
    {'id': 'x', 'name': 'Top Artist', 'plays': 200, 'minutes': 700, 'songs': 9, 'has_image': false},
    {'id': 'y', 'name': 'Other Artist', 'plays': 90, 'minutes': 300, 'songs': 4, 'cover_album_id': 'al-t2'},
  ],
  'top_genres': [
    {'name': 'Pop', 'share': 0.5},
    {'name': 'Hip-Hop', 'share': 0.25},
  ],
  'months': [10, 20, 30, 40, 50, 60, 70, 80, 90, 500, 100, 110],
  'hours': [for (var h = 0; h < 24; h++) h == 23 ? 900 : 10],
  'top_day': '2026-10-03',
  'top_day_minutes': 333,
  'first_track': _trackJson('t3', 'First Song'),
  'playlist_id': null,
};

class _Api extends ApiClient {
  _Api() : super('https://example.test', 'token');
  final calls = <String>[];

  @override
  Future<Wrapped> wrapped([int? year]) async {
    calls.add('wrapped $year');
    return Wrapped.fromJson(_wrappedJson);
  }

  @override
  Future<String> saveWrappedPlaylist(int year, {required String name, String? description}) async {
    calls.add('save $year $name');
    return 'top';
  }

  @override
  Future<Credits> credits(String trackId) async {
    calls.add('credits $trackId');
    return Credits.fromJson({
      'performers': [
        {
          'name': 'Main Act',
          'roles': ['artist'],
        },
        {
          'name': 'Guitar Hero',
          'roles': ['guitar'],
        },
      ],
      'writers': [
        {
          'name': 'Pen Person',
          'roles': ['composer', 'lyricist'],
        },
      ],
      'producers': [
        {
          'name': 'Knob Turner',
          'roles': ['producer'],
        },
      ],
      'engineers': [],
      'label': 'Big Label',
      'copyright': '℗ 2026 Big Label',
      'sources': ['tags', 'musicbrainz'],
    });
  }

  @override
  Future<List<NamedRef>> otherUsers() async => const [NamedRef('u2', 'Anna')];

  @override
  Future<Blend> createBlend(String userId) async {
    calls.add('blend $userId');
    return Blend.fromJson({
      'id': 'b1',
      'partner': {'id': userId, 'name': 'Anna'},
      'playlist_id': 'blend-playlist',
      'match': 0.42,
    });
  }

  @override
  Future<(List<Playlist>, List<Playlist>, Playlist?, List<Playlist>, List<Playlist>)> mixes() async =>
      (const <Playlist>[], const <Playlist>[], null, const <Playlist>[], const <Playlist>[]);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(serverUrl: 'https://example.test');
}

void main() {
  late _Api api;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  Future<ProviderContainer> container() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    api = _Api();
    return ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
        downloadSummaryProvider.overrideWith((ref) async => const DownloadSummary()),
      ],
    );
  }

  Future<void> show(
    WidgetTester tester,
    ProviderContainer scope,
    Widget Function(BuildContext) home, {
    Size size = const Size(500, 1000),
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final router = GoRouter(
      routes: [
        GoRoute(path: '/', builder: (context, _) => home(context)),
        GoRoute(path: '/playlist/:id', builder: (_, state) => Text('playlist ${state.pathParameters['id']}')),
      ],
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp.router(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
  }

  Future<void> finish(WidgetTester tester, ProviderContainer scope) async {
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await tester.pump(const Duration(seconds: 11));
  }

  group('models', () {
    test('wrapped parses the year and finds the peak hour', () {
      final w = Wrapped.fromJson(_wrappedJson);
      expect(w.isEmpty, isFalse);
      expect(w.topTracks.first.track.title, 'Best Song');
      expect(w.topArtists[1].artist.coverAlbumId, 'al-t2');
      expect(w.topGenres.first, ('Pop', 0.5));
      expect(w.topDay, DateTime(2026, 10, 3));
      expect(w.peakHour, 23);
      expect(const Wrapped(year: 2026).peakHour, isNull);
      expect(Wrapped.fromJson({'year': 2020}).isEmpty, isTrue);
    });

    test('the review season is December and January (for the last year)', () {
      expect(wrappedSeason(DateTime(2026, 11, 30)), isFalse);
      expect(wrappedSeason(DateTime(2026, 12, 1)), isTrue);
      expect(wrappedSeasonYear(DateTime(2026, 12, 24)), 2026);
      expect(wrappedSeason(DateTime(2027, 1, 15)), isTrue);
      expect(wrappedSeasonYear(DateTime(2027, 1, 15)), 2026);
      expect(wrappedSeason(DateTime(2027, 2, 1)), isFalse);
    });

    test('listening times and credit roles are named', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(listeningTime(l10n, 7), 'in the morning');
      expect(listeningTime(l10n, 12), 'during the day');
      expect(listeningTime(l10n, 19), 'in the evening');
      expect(listeningTime(l10n, 23), 'at night');
      expect(listeningTime(l10n, 3), 'at night');
      expect(creditRole(l10n, 'composer'), 'Composer');
      expect(creditRole(l10n, 'mix'), 'Mixing');
      expect(creditRole(l10n, 'bass guitar'), 'Bass guitar');
      final sections = creditSections(
        l10n,
        Credits.fromJson({
          'writers': [
            {
              'name': 'W',
              'roles': ['writer'],
            },
          ],
        }),
      );
      expect(sections.map((s) => s.$1), ['Written by']);
    });

    test('blend playlists are recognized by their mix key', () {
      Playlist playlist(String kind, String? key) => Playlist(
        id: 'p',
        name: 'n',
        isPublic: false,
        owner: const NamedRef('o', 'O'),
        trackCount: 0,
        duration: 0,
        coverAlbumIds: const [],
        kind: kind,
        mixKey: key,
      );
      expect(playlist('mix', 'blend:u2').isBlend, isTrue);
      expect(playlist('mix', 'daily:1').isBlend, isFalse);
      expect(playlist('user', 'blend:u2').isBlend, isFalse);
    });
  });

  testWidgets('the review moves through its pages and saves the top songs playlist', (tester) async {
    final scope = (await tester.runAsync(container))!;
    await show(tester, scope, (_) => const WrappedPage(year: 2026), size: const Size(360, 640));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(seconds: 1));
    expect(api.calls, ['wrapped 2026']);
    expect(find.text('Your 2026 in music'), findsOneWidget);
    expect(find.text('2025'), findsOneWidget);

    Future<void> next() async {
      await tester.tapAt(const Offset(330, 300));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(seconds: 3));
    }

    await next();
    expect(find.text('minutes of music.'), findsOneWidget);
    expect(find.text('12,345'), findsOneWidget);
    // Left goes back.
    await tester.tapAt(const Offset(30, 300));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Your 2026 in music'), findsOneWidget);
    await next();
    await next();
    expect(find.text('Your top genres'), findsOneWidget);
    await next();
    expect(find.text('Top Artist'), findsOneWidget);
    expect(find.text('200 plays · 700 minutes'), findsOneWidget);
    await next();
    expect(find.text('Your top artists'), findsOneWidget);
    await next();
    expect(find.text('Best Song'), findsOneWidget);
    await next();
    expect(find.text('Your top songs'), findsOneWidget);
    await next();
    expect(find.text('at night'), findsOneWidget);
    expect(find.text('Your biggest month: October'), findsOneWidget);
    await next();
    expect(find.text('different songs'), findsOneWidget);
    // Pages move on by themselves too.
    await tester.pump(const Duration(seconds: 8));
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Your 2026'), findsOneWidget);
    // The last page stays.
    await tester.pump(const Duration(seconds: 9));
    expect(find.text('Your 2026'), findsOneWidget);

    await tester.tap(find.text('Top songs as a playlist'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'save 2026 Your Top Songs 2026');
    expect(find.text('playlist top'), findsOneWidget);
    await finish(tester, scope);
  });

  testWidgets('the credits card shows the first people and opens all credits', (tester) async {
    final scope = (await tester.runAsync(container))!;
    final track = Track.fromJson(_trackJson('t1', 'Best Song'));
    await show(
      tester,
      scope,
      (_) => Scaffold(
        body: ListView(children: [CreditsCard(track: track)]),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(find.text('Credits'), findsOneWidget);
    expect(find.text('Main Act'), findsOneWidget);
    expect(find.text('Pen Person'), findsOneWidget);
    expect(find.text('Knob Turner'), findsNothing);

    await tester.tap(find.text('Show all'));
    await tester.pumpAndSettle();
    expect(find.text('Performed by'), findsOneWidget);
    expect(find.text('Composer, Lyricist'), findsNWidgets(2));
    expect(find.text('Produced by'), findsOneWidget);
    expect(find.text('Knob Turner'), findsOneWidget);
    expect(find.text('Big Label'), findsOneWidget);
    expect(find.text('Source: File tags, MusicBrainz'), findsOneWidget);
    expect(api.calls, ['credits t1']);
    await finish(tester, scope);
  });

  testWidgets('a blend is made with the picked user and opened', (tester) async {
    final scope = (await tester.runAsync(container))!;
    await show(
      tester,
      scope,
      (_) => Scaffold(
        body: Consumer(
          builder: (context, ref, _) =>
              TextButton(onPressed: () => showCreateSheet(context, ref), child: const Text('create')),
        ),
      ),
    );
    await tester.tap(find.text('create'));
    await tester.pumpAndSettle();
    expect(find.text('New playlist'), findsOneWidget);
    await tester.tap(find.text('Blend'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(find.text('Blend with …'), findsOneWidget);
    await tester.tap(find.text('Anna'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(api.calls, ['blend u2']);
    expect(find.text('playlist blend-playlist'), findsOneWidget);
    await finish(tester, scope);
  });
}
