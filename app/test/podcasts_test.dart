import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/audiobooks.dart';
import 'package:resonance/core/books.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/media_sections.dart';
import 'package:resonance/core/library.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/podcasts.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/core/tv_mode.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/offline/offline_store.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/equalizer.dart';
import 'package:resonance/player/connect.dart';
import 'package:resonance/player/player.dart';
import 'package:resonance/ui/pages/book_pages.dart';
import 'package:resonance/ui/pages/now_playing_page.dart';
import 'package:resonance/ui/pages/podcast_pages.dart';
import 'package:resonance/ui/shell.dart';
import 'package:resonance/ui/tv/tv_shell.dart';
import 'package:resonance/ui/tv/tv_media_pages.dart';
import 'package:resonance/ui/tv/tv_focusable.dart';
import 'package:resonance/ui/widgets/player_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _episode = PodcastEpisode(
  id: 'episode',
  podcastId: 'podcast',
  title: 'Episode title',
  podcastTitle: 'Podcast title',
  durationSeconds: 300,
  positionSeconds: 60,
);
const _audiobook = AbsItem(id: 'audio', title: 'Audiobook title', duration: 600, author: 'Author');
const _ebook = Book(
  id: 'ebook',
  title: 'Ebook title',
  authors: ['Author'],
  format: 'epub',
  size: 100,
  hasCover: false,
  filename: 'ebook.epub',
);
const _track = Track(
  id: 'track',
  title: 'Music',
  duration: 120,
  artist: NamedRef('artist', 'Artist'),
  artistCredit: 'Artist',
  album: NamedRef('album', 'Album'),
);

class _Api extends ApiClient {
  _Api() : super('https://resonance.example', 'secret-token');
  PodcastEpisode episode = _episode;
  PodcastEpisode latestEpisode = const PodcastEpisode(
    id: 'latest',
    podcastId: 'podcast',
    title: 'Latest episode',
    podcastTitle: 'Podcast title',
    durationSeconds: 180,
  );
  final saves = <(String, double, bool)>[];
  final queries = <String>[];
  final feeds = <String>[];
  final pages = <int>[];
  final orders = <bool>[];
  final markedAll = <bool>[];
  bool subscribed = true;
  bool manyEpisodes = false;
  int absCalls = 0;

  @override
  Future<PodcastEpisode> podcastEpisode(String id) async => episode;
  @override
  Future<void> saveEpisodeProgress(String id, double position, {required bool completed}) async {
    saves.add((id, position, completed));
  }

  @override
  Future<void> markPodcastPlayed(String id, {required bool completed}) async => markedAll.add(completed);

  @override
  Future<dynamic> absPost(String path, [Object? body]) async {
    absCalls++;
    throw StateError('Episodes must not use ABS sessions');
  }

  @override
  Future<List<PodcastEpisode>> podcastContinue() async => [episode];
  @override
  Future<List<PodcastEpisode>> podcastLatest() async => [latestEpisode];
  @override
  Future<PodcastDiscover> podcastDiscover() async => const PodcastDiscover(
    genres: [PodcastGenre(id: 1303, name: 'Comedy')],
    sections: [
      PodcastSection(
        id: 'top',
        title: 'Top podcasts',
        items: [
          PodcastSearchResult(feedUrl: 'https://top.example/feed', title: 'Discovered podcast', author: 'Author'),
        ],
      ),
    ],
  );
  @override
  Future<List<PodcastSearchResult>> podcastGenre(int id) async => const [
    PodcastSearchResult(feedUrl: 'https://top.example/feed', title: 'Discovered podcast', author: 'Author'),
  ];
  @override
  Future<List<Podcast>> podcastSubscriptions() async => subscribed ? [await podcast('podcast')] : [];
  @override
  Future<Podcast> podcast(String id, {int offset = 0, int limit = 50, bool oldestFirst = false}) async {
    pages.add(offset);
    orders.add(oldestFirst);
    return Podcast(
      id: id,
      feedUrl: 'https://pod.example/feed',
      title: 'Podcast title',
      author: 'Author',
      description: 'Plain description',
      subscribed: subscribed,
      unplayedCount: 3,
      episodeCount: 4,
      completedCount: 1,
      episodes: offset > 0
          ? []
          : manyEpisodes
          ? List.filled(50, episode)
          : [episode],
    );
  }

  @override
  Future<List<PodcastSearchResult>> podcastSearch(String query) async {
    queries.add(query);
    if (query == 'empty') return [];
    return const [PodcastSearchResult(feedUrl: 'https://pod.example/feed', title: 'Search result', author: 'Author')];
  }

  @override
  Future<Podcast> openPodcast(String feedUrl) async => podcast('podcast');
  @override
  Future<Podcast> subscribePodcast(String feedUrl) async {
    feeds.add(feedUrl);
    subscribed = true;
    return podcast('podcast');
  }

  @override
  Future<void> unsubscribePodcast(String id) async {
    subscribed = false;
  }

  @override
  Future<List<Track>> recommendations({
    required List<String> trackIds,
    List<String> excludeIds = const [],
    int limit = 20,
  }) async => [];
}

class _Engine implements PlaybackEngine {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Object> get errorStream => const Stream.empty();
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<LoopMode> get loopModeStream => const Stream.empty();
  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.ready;
  @override
  Duration position = Duration.zero;
  @override
  Duration? duration = const Duration(seconds: 300);
  @override
  int? currentIndex;
  @override
  List<SourceFactory> audioSources = [];
  @override
  bool isBook = false;
  @override
  int crossfadeSeconds = 0;
  @override
  bool automix = false;
  @override
  double speed = 1;
  @override
  double Function(int)? targetVolumeForIndex;
  @override
  MixPoints? Function(int)? mixPointsForIndex;
  @override
  String? Function(int)? sourceKeyForIndex;
  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {}
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> finishFade() async {}
  @override
  Future<void> setLoopMode(LoopMode mode) async {}
  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> setSources(
    List<SourceFactory> sources, {
    int initialIndex = 0,
    Duration initialPosition = Duration.zero,
    bool preserveCurrent = false,
  }) async {
    audioSources = sources;
    currentIndex = initialIndex;
    position = initialPosition;
  }

  @override
  Future<void> play() async {
    playing = true;
    states.add(PlayerState(true, processingState));
  }

  @override
  Future<void> pause() async {
    playing = false;
    states.add(PlayerState(false, processingState));
  }

  @override
  Future<void> stop() => pause();
  @override
  Future<void> seek(Duration value, {int? index}) async {
    position = value;
  }

  @override
  Future<void> dispose() => states.close();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Offline extends OfflineController {
  @override
  OfflineState build() => const OfflineState();
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    user: User(
      id: 'user',
      username: 'admin',
      displayName: 'Admin',
      role: 'admin',
      accentColor: '#1db954',
      isDisabled: false,
      createdAt: DateTime.utc(2026),
    ),
  );
}

class _Connect extends ConnectController {
  @override
  ConnectView build() {
    ref.onDispose(messages.close);
    return const ConnectView(deviceId: 'test', name: 'Test', kind: 'test');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async => initializeDateFormatting());
  late ProviderContainer container;
  late _Api api;
  late _Engine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    api = _Api();
    engine = _Engine();
    container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        playerProvider.overrideWith(() => PlayerController(engine: engine)),
        offlineProvider.overrideWith(_Offline.new),
        downloadSummaryProvider.overrideWith((ref) async => const DownloadSummary()),
        sessionProvider.overrideWith(_Session.new),
        connectProvider.overrideWith(_Connect.new),
        playlistsProvider.overrideWith((ref) async => []),
        booksStatusProvider.overrideWith(
          (ref) async => const BooksStatus(enabled: true, requestsEnabled: false, defaultLanguage: 'en'),
        ),
        absStatusProvider.overrideWith((ref) async => const AbsStatus(enabled: true, url: '', linked: true)),
        absLibrariesProvider.overrideWith(
          (ref) async => const [AbsLibrary(id: 'library', name: 'Library', mediaType: 'book')],
        ),
        absItemsProvider.overrideWith((ref, id) async => const [_audiobook]),
        absShelvesProvider.overrideWith((ref, id) async => const []),
        absProgressProvider.overrideWith(
          (ref) async => const {'audio': AbsProgress(progress: 0.5, currentTime: 60, isFinished: false)},
        ),
        bookLibraryProvider.overrideWith((ref, query) async => [_ebook]),
        bookRequestsProvider.overrideWith((ref, all) async => []),
      ],
    );
  });
  tearDown(() => container.dispose());

  Future<void> page(WidgetTester tester, Widget child, {String language = 'en'}) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: Locale(language),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: child,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> routed(WidgetTester tester, GoRouter router) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  test('podcast models preserve nullable duration, per-user progress, and cover fallback', () {
    final episode = PodcastEpisode.fromJson({
      'id': 'one',
      'podcast_id': 'pod',
      'title': 'Title',
      'podcast_title': 'Podcast',
      'position_seconds': 35.5,
      'completed': true,
      'podcast_image_url': 'https://cover.example/pod',
      'published_at': '2026-10-21T10:00:00Z',
    });
    expect(episode.durationSeconds, isNull);
    expect(episode.positionSeconds, 35.5);
    expect(episode.completed, true);
    expect(episode.coverUrl, 'https://cover.example/pod');
    expect(episode.publishedAt, DateTime.utc(2026, 10, 21, 10));
    final searchResult = PodcastSearchResult.fromJson({
      'itunes_id': null,
      'source': 'fyyd',
      'feed_url': 'https://pod.example/feed',
      'title': 'Fyyd result',
    });
    expect(searchResult.itunesId, isNull);
    expect(searchResult.source, 'fyyd');
    expect(
      api.episodeStreamUrl('episode'),
      'https://resonance.example/api/podcasts/episodes/episode/stream?token=secret-token',
    );
  });

  test('episode dates use localized month, weekday, and year formats', () {
    final date = DateTime(2024, 5, 19);
    expect(formatEpisodeDate(date, 'en'), 'Sun, May 19, 2024');
    expect(formatEpisodeDate(date, 'de'), 'So., 19. Mai 2024');
  });

  for (final language in ['en', 'de']) {
    testWidgets('mobile episode subtitle includes the year in $language', (tester) async {
      await page(
        tester,
        Scaffold(
          body: PodcastEpisodeTile(
            episode: PodcastEpisode(
              id: 'dated',
              podcastId: 'podcast',
              title: 'Dated episode',
              podcastTitle: 'Podcast title',
              publishedAt: DateTime(2024, 5, 19),
              durationSeconds: 300,
            ),
          ),
        ),
        language: language,
      );
      expect(find.textContaining('2024'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  test('podcasts default visible without any configured book service and can be hidden', () {
    expect(container.read(podcastsVisibleProvider), true);
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.podcasts, true);
    expect(container.read(podcastsVisibleProvider), false);
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.podcasts, false);
    expect(container.read(podcastsVisibleProvider), true);
  });

  testWidgets('episodes resume, use spoken-word mode, save every 15 seconds, pause, stop and replacement', (
    tester,
  ) async {
    final player = container.read(playerProvider.notifier);
    player.setCrossfade(8);
    player.setAutomix(true);
    await player.playEpisode(_episode);
    expect(engine.isBook, true);
    expect(engine.position, const Duration(seconds: 60));
    expect(container.read(playerProvider).queue, isEmpty);
    expect(container.read(playerProvider).book!.author, 'Podcast title');
    final source = engine.audioSources.single() as UriAudioSource;
    expect(source.uri.toString(), api.episodeStreamUrl('episode'));
    engine.position = const Duration(seconds: 80);
    await tester.pump(const Duration(seconds: 15));
    expect(api.saves.last, ('episode', 80.0, false));
    engine.position = const Duration(seconds: 90);
    await player.pause();
    expect(api.saves.last, ('episode', 90.0, false));
    engine.position = const Duration(seconds: 275);
    await player.stop();
    expect(api.saves.last, ('episode', 275.0, true));
    await player.playTracks([_track], index: 0);
    expect(api.saves.last, ('episode', 275.0, true));
    expect(engine.isBook, false);
    expect(engine.speed, 1);
    expect(api.absCalls, 0);
  });

  testWidgets('unknown feed durations use engine duration, skips clamp, completed episodes restart', (tester) async {
    final player = container.read(playerProvider.notifier);
    api.episode = const PodcastEpisode(
      id: 'episode',
      podcastId: 'podcast',
      title: 'Unknown',
      podcastTitle: 'Podcast',
      positionSeconds: 100,
    );
    await player.playEpisode(_episode);
    await player.skipBook(-15);
    expect(engine.position, const Duration(seconds: 85));
    await player.skipBook(30);
    expect(engine.position, const Duration(seconds: 115));
    await player.seekBook(-20);
    expect(engine.position, Duration.zero);
    engine.position = const Duration(seconds: 280);
    await player.pause();
    expect(api.saves.last.$3, true);
    api.episode = const PodcastEpisode(
      id: 'episode',
      podcastId: 'podcast',
      title: 'Finished',
      podcastTitle: 'Podcast',
      durationSeconds: 300,
      positionSeconds: 290,
      completed: true,
    );
    await player.playEpisode(_episode);
    expect(engine.position, Duration.zero);
    engine.position = const Duration(seconds: 300);
    engine.states.add(PlayerState(true, ProcessingState.completed));
    await tester.pump();
    expect(api.saves.last, ('episode', 300.0, true));
    container.dispose();
  });

  testWidgets('the spoken-word player shows what is left, speed, timer and show notes', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    api.episode = const PodcastEpisode(
      id: 'episode',
      podcastId: 'podcast',
      title: 'Episode title',
      podcastTitle: 'Podcast title',
      description: 'Notes of the episode',
      durationSeconds: 3900,
      positionSeconds: 60,
    );
    await container.read(playerProvider.notifier).playEpisode(_episode);
    await page(tester, const NowPlayingPage());
    expect(find.text('PODCASTS'), findsOneWidget);
    expect(find.text('Episode title'), findsOneWidget);
    expect(find.text('1×'), findsOneWidget);
    expect(find.text('Timer'), findsOneWidget);
    expect(find.text('1 hr 4 min left'), findsOneWidget);
    await tester.tap(find.text('Show notes'));
    await tester.pumpAndSettle();
    expect(find.text('Notes of the episode'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });

  for (final language in ['en', 'de']) {
    testWidgets('podcasts home renders localized shelves and discovery in $language', (tester) async {
      tester.view.physicalSize = const Size(900, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await page(tester, const PodcastsPage(), language: language);
      expect(find.byTooltip('Add by RSS link'), findsNothing);
      expect(find.text(language == 'de' ? 'Weiterhören' : 'Continue listening'), findsOneWidget);
      expect(find.text('Episode title'), findsOneWidget);
      expect(find.text('Latest episode'), findsOneWidget);
      expect(find.text(language == 'de' ? 'Deine Podcasts' : 'Your podcasts'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text(language == 'de' ? 'Kategorien' : 'Categories'), findsOneWidget);
      expect(find.text('Comedy'), findsOneWidget);
      expect(find.text('Top podcasts'), findsOneWidget);
      expect(find.text('Discovered podcast'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('podcast home search field opens search', (tester) async {
    final router = GoRouter(
      initialLocation: '/podcasts',
      routes: [
        GoRoute(path: '/podcasts', builder: (_, _) => const PodcastsPage()),
        GoRoute(path: '/podcasts/search', builder: (_, _) => const PodcastSearchPage()),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final searchField = tester.widget<TextField>(find.byType(TextField).first);
    expect(searchField.readOnly, true);
    expect(searchField.decoration!.hintText, 'Search podcasts');
    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();
    expect(find.byType(PodcastSearchPage), findsOneWidget);
  });

  testWidgets('TV podcast search accepts on-screen and physical keyboard input', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    container.read(tvModeProvider.notifier).set(true);
    await page(tester, const Scaffold(body: TvPodcastSearchPage()));

    for (final key in ['s', 'c', 'i', 'e', 'n', 'c', 'e']) {
      final focusable = tester.widget<TvFocusable>(find.byKey(ValueKey('tv-key-$key')));
      focusable.focusNode!.requestFocus();
      await tester.pump();
      Actions.invoke(FocusManager.instance.primaryFocus!.context!, const ActivateIntent());
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.queries, contains('science'));
    expect(find.text('Search result'), findsOneWidget);

    final submit = tester.widget<TvFocusable>(find.byKey(const ValueKey('tv-key-submit')));
    submit.focusNode!.requestFocus();
    await tester.pump();
    Actions.invoke(FocusManager.instance.primaryFocus!.context!, const ActivateIntent());
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus!.debugLabel, 'TV first search result');

    final clear = tester.widget<TvFocusable>(find.byKey(const ValueKey('tv-key-clear')));
    clear.focusNode!.requestFocus();
    await tester.pump();
    Actions.invoke(FocusManager.instance.primaryFocus!.context!, const ActivateIntent());
    await tester.pump(const Duration(milliseconds: 300));
    for (final (key, character) in [
      (LogicalKeyboardKey.keyR, 'r'),
      (LogicalKeyboardKey.keyA, 'a'),
      (LogicalKeyboardKey.keyD, 'd'),
      (LogicalKeyboardKey.keyI, 'i'),
      (LogicalKeyboardKey.keyO, 'o'),
    ]) {
      await tester.sendKeyEvent(key, character: character);
    }
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(api.queries, contains('radio'));
    expect(find.text('Search result'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('detail shows episode progress, completed state, and subscription toggle', (tester) async {
    await page(tester, const PodcastPage(id: 'podcast'));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('4 min left'), findsOneWidget);
    expect(find.text('4 episodes · 1 played'), findsOneWidget);
    expect(find.text('Subscribed'), findsOneWidget);
    await tester.tap(find.text('Subscribed'));
    await tester.pumpAndSettle();
    expect(api.subscribed, false);
    expect(find.text('Subscribe'), findsOneWidget);
    await tester.tap(find.text('Subscribe'));
    await tester.pumpAndSettle();
    expect(api.feeds, ['https://pod.example/feed']);
    await page(
      tester,
      const Scaffold(
        body: PodcastEpisodeTile(
          episode: PodcastEpisode(
            id: 'done',
            podcastId: 'podcast',
            title: 'Done',
            podcastTitle: 'Podcast',
            completed: true,
          ),
        ),
      ),
    );
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('Played'), findsOneWidget);
  });

  testWidgets('episodes can be marked played, all at once, and listed oldest first', (tester) async {
    await page(tester, const PodcastPage(id: 'podcast'));
    await tester.tap(find.byIcon(Icons.more_vert).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark as played'));
    await tester.pumpAndSettle();
    expect(api.saves.last, ('episode', 300.0, true));

    await tester.longPress(find.text('Episode title'));
    await tester.pumpAndSettle();
    expect(api.saves.last, ('episode', 300.0, true));

    await tester.tap(find.byIcon(Icons.more_vert).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark all as played'));
    await tester.pumpAndSettle();
    expect(api.markedAll, [true]);

    await tester.tap(find.text('Newest first'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Oldest first').last);
    await tester.pumpAndSettle();
    expect(api.orders.last, true);
    expect(container.read(podcastOldestFirstProvider('podcast')), true);
    expect(find.text('Oldest first'), findsOneWidget);
  });

  testWidgets('tapping an episode opens its show notes with play and mark actions', (tester) async {
    api.episode = const PodcastEpisode(
      id: 'episode',
      podcastId: 'podcast',
      title: 'Episode title',
      podcastTitle: 'Podcast title',
      description: 'What this episode is about',
      durationSeconds: 300,
    );
    await page(tester, const PodcastPage(id: 'podcast'));
    await tester.tap(find.text('Episode title'));
    await tester.pumpAndSettle();
    expect(find.text('Show notes'), findsOneWidget);
    expect(find.text('What this episode is about'), findsNWidgets(2));
    await tester.tap(find.text('Mark as played'));
    await tester.pumpAndSettle();
    expect(api.saves.last, ('episode', 300.0, true));
  });

  testWidgets('search debounces, opens without subscribing, and offers explicit subscribe and RSS add', (tester) async {
    api.subscribed = false;
    final router = GoRouter(
      initialLocation: '/podcasts/search',
      routes: [
        GoRoute(path: '/podcasts/search', builder: (_, _) => const PodcastSearchPage()),
        GoRoute(
          path: '/podcasts/:id',
          builder: (_, s) => PodcastPage(id: s.pathParameters['id']!),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'science');
    await tester.pump(const Duration(milliseconds: 349));
    expect(api.queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(api.queries, ['science']);
    await tester.tap(find.text('Search result'));
    await tester.pumpAndSettle();
    expect(find.text('Podcast title'), findsOneWidget);
    expect(api.subscribed, false);
    router.pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Subscribe'));
    await tester.pumpAndSettle();
    expect(api.subscribed, true);
    expect(find.byTooltip('Search podcasts'), findsNothing);
    expect(find.byTooltip('Add by RSS link'), findsOneWidget);
    await tester.tap(find.byTooltip('Add by RSS link'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'https://other.example/rss');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(api.feeds.last, 'https://other.example/rss');
    router.pop();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'https://new.example/feed.xml');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(api.queries, ['science']);
    expect(find.text('Add RSS feed'), findsOneWidget);
    expect(
      find.descendant(of: find.byType(ListTile), matching: find.text('https://new.example/feed.xml')),
      findsOneWidget,
    );
    await tester.tap(find.text('Add RSS feed'));
    await tester.pumpAndSettle();
    expect(api.feeds.last, 'https://new.example/feed.xml');
    router.pop();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'empty');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    const noResults =
        'Nothing found. Spotify-exclusive podcasts have no public feed '
        '– if you know the RSS address, add it at the top right.';
    expect(find.text(noResults), findsOneWidget);
  });

  testWidgets('media hub shows every enabled tab and ebook actions only on the ebook tab', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await page(tester, const BooksHubPage());
    expect(find.text('Media'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Ebooks'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Audiobooks'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Podcasts'), findsOneWidget);
    expect(find.byTooltip('Requests'), findsOneWidget);
    expect(find.byTooltip('Import'), findsOneWidget);
    expect(find.byTooltip('Add by RSS link'), findsNothing);
    await tester.tap(find.widgetWithText(Tab, 'Podcasts'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Requests'), findsNothing);
    expect(find.byTooltip('Import'), findsNothing);
    expect(find.byTooltip('Add by RSS link'), findsNothing);
    expect(find.text('New episodes'), findsOneWidget);
    await tester.tap(find.widgetWithText(Tab, 'Ebooks'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Requests'), findsOneWidget);
    expect(find.byTooltip('Import'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('wide media hub keeps audiobook and podcast tabs', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await page(tester, const BooksHubPage());
    expect(find.widgetWithText(Tab, 'Ebooks'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Audiobooks'), findsOneWidget);
    expect(find.widgetWithText(Tab, 'Podcasts'), findsOneWidget);
    expect(find.text('Media'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mobile navigation has one media entry for non-admin users and selects podcast routes', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    container
        .read(sessionProvider.notifier)
        .updateUser(
          User(
            id: 'user',
            username: 'listener',
            displayName: 'Listener',
            role: 'user',
            accentColor: '#1db954',
            isDisabled: false,
            createdAt: DateTime.utc(2026),
          ),
        );
    await page(tester, const AppShell(location: '/podcasts/example', child: SizedBox.shrink()));
    expect(find.text('Media'), findsOneWidget);
    expect(find.text('Books'), findsNothing);
    expect(find.text('Podcasts'), findsNothing);
    expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('media navigation shows a single section by its own name and disappears when all are hidden', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await page(tester, const AppShell(location: '/books', child: SizedBox.shrink()));
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.podcasts, true);
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.audiobooks, true);
    await tester.pumpAndSettle();
    expect(find.text('Books'), findsOneWidget);
    expect(find.text('Media'), findsNothing);
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.podcasts, false);
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.ebooks, true);
    await tester.pumpAndSettle();
    expect(find.text('Podcasts'), findsOneWidget);
    expect(find.text('Media'), findsNothing);
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.podcasts, true);
    await tester.pumpAndSettle();
    expect(find.text('Podcasts'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop and TV rails show one selected media entry across media routes', (tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await page(tester, const AppShell(location: '/audiobooks/item/book', child: SizedBox.shrink()));
    expect(find.text('Media'), findsOneWidget);
    expect(find.text('Books'), findsNothing);
    expect(find.text('Podcasts'), findsNothing);
    tester.takeException();
    await page(tester, const TvShell(location: '/podcasts/example', child: SizedBox.shrink()));
    expect(find.text('Media'), findsOneWidget);
    expect(find.text('Books'), findsNothing);
    expect(find.text('Podcasts'), findsNothing);
    expect(find.byIcon(Icons.video_library), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV media shelves follow the specified order and hide disabled sections', (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await page(tester, const TvMediaPage());
    final headings = ['Continue listening', 'Audiobooks', 'Your podcasts', 'New episodes', 'Top podcasts', 'Ebooks'];
    final positions = [for (final heading in headings) tester.getTopLeft(find.text(heading).first).dy];
    expect(positions, orderedEquals([...positions]..sort()));
    expect(find.text('Media'), findsOneWidget);

    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.ebooks, true);
    container.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.podcasts, true);
    await tester.pumpAndSettle();
    expect(find.text('Your podcasts'), findsNothing);
    expect(find.text('New episodes'), findsNothing);
    expect(find.text('Top podcasts'), findsNothing);
    expect(find.text('Ebooks'), findsNothing);
    expect(find.text('Audiobooks'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('TV audiobook activation opens its detail route', (tester) async {
    final router = GoRouter(
      initialLocation: '/books',
      routes: [
        GoRoute(path: '/books', builder: (_, _) => const TvMediaPage()),
        GoRoute(path: '/audiobooks/item/:id', builder: (_, state) => Text('audiobook:${state.pathParameters['id']}')),
      ],
    );
    addTearDown(router.dispose);
    await routed(tester, router);
    await tester.tap(find.text('Audiobook title').first);
    await tester.pumpAndSettle();
    expect(find.text('audiobook:audio'), findsOneWidget);
  });

  testWidgets('TV episode activation starts playback and opens now playing', (tester) async {
    final router = GoRouter(
      initialLocation: '/books',
      routes: [
        GoRoute(path: '/books', builder: (_, _) => const TvMediaPage()),
        GoRoute(path: '/now-playing', builder: (_, _) => const Text('now-playing-route')),
      ],
    );
    addTearDown(router.dispose);
    await routed(tester, router);
    await tester.tap(find.text('Episode title').first);
    await tester.pumpAndSettle();
    expect(find.text('now-playing-route'), findsOneWidget);
    expect(container.read(playerProvider).book?.itemId, 'episode');
    expect(engine.audioSources, isNotEmpty);
    await container.read(playerProvider.notifier).playTracks([_track]);
  });

  testWidgets('episode transport has a fifteen second back button and required speeds', (tester) async {
    final player = container.read(playerProvider.notifier);
    await player.playEpisode(_episode);
    await page(tester, const Scaffold(body: TransportControls(big: true)));
    await tester.tap(find.byTooltip('Back 15 seconds'));
    expect(engine.position, const Duration(seconds: 45));
    await tester.tap(find.text('1×'));
    await tester.pumpAndSettle();
    for (final speed in ['0.75×', '1×', '1.25×', '1.50×', '1.75×', '2×']) {
      expect(find.text(speed), findsWidgets);
    }
    expect(find.text('1.10×'), findsNothing);
    await tester.tap(find.text('1.50×'));
    await tester.pumpAndSettle();
    expect(engine.speed, 1.5);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
