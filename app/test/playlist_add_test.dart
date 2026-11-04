import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/playlist_add_page.dart';

Track _track(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: const NamedRef('a', 'Artist'),
  artistCredit: 'Artist',
  album: const NamedRef('b', 'Album'),
  duration: 210,
);

class _Api extends ApiClient {
  _Api() : super('https://example.test', 'token');
  final calls = <String>[];
  var round = 0;

  @override
  Future<List<Track>> recommendations({
    required List<String> trackIds,
    List<String> excludeIds = const [],
    int limit = 20,
  }) async {
    calls.add('recommend ${trackIds.join(',')} -${excludeIds.join(',')}');
    round++;
    return [_track('r${round}a'), _track('r${round}b')];
  }

  @override
  Future<SearchResult> search(String q) async {
    calls.add('search $q');
    return SearchResult(const [], const [], [_track('found')]);
  }

  @override
  Future<void> addToPlaylist(String id, List<String> trackIds) async => calls.add('add $id ${trackIds.join(',')}');
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

  Future<void> show(WidgetTester tester, ProviderContainer scope, Widget child) async {
    await tester.binding.setSurfaceSize(const Size(500, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
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

  testWidgets('suggestions under a playlist: add one, get new ones without repeating', (tester) async {
    final scope = (await tester.runAsync(container))!;
    await show(
      tester,
      scope,
      const Scaffold(
        body: SingleChildScrollView(
          child: PlaylistSuggestions(playlistId: 'p', trackIds: ['one', 'two']),
        ),
      ),
    );
    expect(find.text('Recommended songs'), findsOneWidget);
    expect(find.text('Based on the songs in this playlist'), findsOneWidget);
    expect(api.calls, ['recommend one,two -one,two']);
    expect(find.text('Song r1a'), findsOneWidget);

    await tester.tap(find.byTooltip('Add to playlist').first);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(api.calls.last, 'add p r1a');
    expect(find.text('Song r1a'), findsNothing);

    await tester.tap(find.text('New suggestions'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(api.calls.last, 'recommend one,two -one,two,r1a,r1b');
    expect(find.text('Song r2a'), findsOneWidget);
    expect(find.text('Search for songs'), findsOneWidget);
    await finish(tester, scope);
  });

  testWidgets('an empty playlist gets suggestions from the likes', (tester) async {
    final scope = (await tester.runAsync(container))!;
    await show(
      tester,
      scope,
      const Scaffold(
        body: SingleChildScrollView(
          child: PlaylistSuggestions(playlistId: 'p', trackIds: []),
        ),
      ),
    );
    expect(api.calls, ['recommend  -']);
    expect(find.text('Based on your liked songs'), findsOneWidget);
    await finish(tester, scope);
  });

  testWidgets('the search adds a song straight away and marks it', (tester) async {
    final scope = (await tester.runAsync(container))!;
    await show(tester, scope, const PlaylistAddSongsPage(playlistId: 'p'));
    expect(find.text('Search for songs to add them to the playlist straight away.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(api.calls, ['search abc']);
    expect(find.text('Song found'), findsOneWidget);
    await tester.tap(find.byTooltip('Add to playlist'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump();
    expect(api.calls.last, 'add p found');
    expect(find.byTooltip('Added'), findsOneWidget);
    await finish(tester, scope);
  });
}
