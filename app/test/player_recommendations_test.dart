import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/equalizer.dart';
import 'package:resonance/player/player.dart';

Track track(String id) => Track(
  id: id,
  title: id,
  duration: 180,
  artist: const NamedRef('artist', 'Artist'),
  artistCredit: 'Artist',
  album: const NamedRef('album', 'Album'),
);

class _Api extends ApiClient {
  _Api() : super('https://resonance.example', 'test');
  final recommendationCalls =
      <({List<String> seeds, List<String> excluded, int limit, Completer<List<Track>> response})>[];

  @override
  Future<List<Track>> recommendations({
    required List<String> trackIds,
    List<String> excludeIds = const [],
    int limit = 20,
  }) {
    final response = Completer<List<Track>>();
    recommendationCalls.add((seeds: trackIds, excluded: excludeIds, limit: limit, response: response));
    return response.future;
  }

  @override
  Future<PlaylistDetail> playlist(String id) async => throw ApiException('offline');
  @override
  Future<void> reportPlay(String id, double seconds, {String? context}) async {}
}

class _Engine implements PlaybackEngine {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final indices = StreamController<int?>.broadcast(sync: true);
  final loops = StreamController<LoopMode>.broadcast(sync: true);
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<int?> get currentIndexStream => indices.stream;
  @override
  Stream<LoopMode> get loopModeStream => loops.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Object> get errorStream => const Stream.empty();
  @override
  int crossfadeSeconds = 0;
  @override
  bool automix = false;
  @override
  MixPoints? Function(int)? mixPointsForIndex;
  @override
  String? Function(int index)? sourceKeyForIndex;
  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {}
  @override
  double Function(int)? targetVolumeForIndex;
  @override
  bool isBook = false;
  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.ready;
  @override
  int? currentIndex;
  @override
  Duration position = Duration.zero;
  @override
  LoopMode loopMode = LoopMode.off;
  @override
  double speed = 1;
  @override
  List<SourceFactory> audioSources = [];
  final removed = <int>[];

  @override
  Future<void> setSources(
    List<SourceFactory> sources, {
    required int initialIndex,
    Duration initialPosition = Duration.zero,
    bool preserveCurrent = false,
  }) async {
    audioSources = [...sources];
    currentIndex = initialIndex;
    if (!preserveCurrent) position = initialPosition;
  }

  @override
  Future<void> insert(int index, SourceFactory source) async => audioSources.insert(index, source);
  @override
  Future<void> removeAt(int index) async {
    removed.add(index);
    audioSources.removeAt(index);
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
  Future<void> finishFade() async {}
  @override
  Future<void> setLoopMode(LoopMode mode) async {
    loopMode = mode;
    loops.add(mode);
  }

  @override
  Future<void> setSpeed(double value) async => speed = value;
  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> seek(Duration value, {int? index}) async {
    position = value;
    currentIndex = index ?? currentIndex;
    indices.add(currentIndex);
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await indices.close();
    await loops.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> settle() async {
  for (var i = 0; i < 30; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Api api;
  late _Engine engine;
  late SharedPreferences prefs;
  late PlayerController player;
  PlayerView view() => container.read(playerProvider);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    api = _Api();
    engine = _Engine();
    container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        downloadSummaryProvider.overrideWith((ref) async => const DownloadSummary()),
        playerProvider.overrideWith(() => PlayerController(engine: engine)),
      ],
    );
    player = container.read(playerProvider.notifier);
  });
  tearDown(() => container.dispose());

  test('autoplay requests once when the last song starts and appends through the engine', () async {
    final context = List.generate(25, (i) => track('$i'));
    await player.playTracks(context, index: 24, context: 'album:first');
    expect(api.recommendationCalls, hasLength(1));
    expect(api.recommendationCalls.single.seeds, context.skip(5).map((t) => t.id));
    expect(api.recommendationCalls.single.excluded, context.map((t) => t.id));
    expect(api.recommendationCalls.single.limit, 20);
    await engine.play();
    await engine.play();
    expect(api.recommendationCalls, hasLength(1));
    api.recommendationCalls.single.response.complete([context.last, track('extra'), track('extra'), track('another')]);
    await settle();
    expect(view().queue.map((t) => t.id), [...context.map((t) => t.id), 'extra', 'another']);
    expect(view().autoplayIds, {'extra', 'another'});
    expect(engine.audioSources, hasLength(27));
    await player.setShuffle(true);
    await player.setShuffle(false);
    expect(view().queue.last.id, 'another');
    await player.playTracks(context.take(2).toList(), context: 'album:second');
    expect(view().autoplayIds, isEmpty);
  });

  for (final fail in [false, true]) {
    test('autoplay does not retry after ${fail ? 'failure' : 'an empty result'}', () async {
      await player.playTracks([track('only')]);
      if (fail) {
        api.recommendationCalls.single.response.completeError(ApiException('offline'));
      } else {
        api.recommendationCalls.single.response.complete([]);
      }
      await settle();
      await engine.play();
      await player.pause();
      await player.play();
      expect(api.recommendationCalls, hasLength(1));
      expect(view().queue, hasLength(1));
    });
  }

  test('late autoplay results do not enter a replacement context', () async {
    await player.playTracks([track('old')], context: 'album:same');
    await player.playTracks([track('new'), track('next')], context: 'album:same');
    api.recommendationCalls.single.response.complete([track('stale')]);
    await settle();
    expect(view().queue.map((t) => t.id), ['new', 'next']);
    expect(view().autoplayIds, isEmpty);
  });

  test('autoplay defaults on and persists the setting', () async {
    expect(player.autoplay, isTrue);
    player.setAutoplay(false);
    expect(prefs.getBool('autoplay'), isFalse);
    await player.playTracks([track('only')]);
    expect(api.recommendationCalls, isEmpty);
    player.setAutoplay(true);
    expect(api.recommendationCalls, hasLength(1));
  });

  test('autoplay waits until the last song is ready', () async {
    engine.processingState = ProcessingState.buffering;
    await player.playTracks([track('only')]);
    expect(api.recommendationCalls, isEmpty);
    engine.processingState = ProcessingState.ready;
    await engine.play();
    expect(api.recommendationCalls, hasLength(1));
  });

  test('autoplay preferences belong to each signed-in user', () async {
    User user(String id) => User(
      id: id,
      username: id,
      displayName: id,
      role: 'user',
      accentColor: '#ffffff',
      isDisabled: false,
      createdAt: DateTime.utc(2026),
    );
    final session = container.read(sessionProvider.notifier);
    await session.signedIn('first-token', user('first'));
    player.setAutoplay(false);
    await session.signedIn('second-token', user('second'));
    expect(player.autoplay, isTrue);
    await session.signedIn('first-token', user('first'));
    expect(player.autoplay, isFalse);
  });

  Future<List<Track>> enableSmart() async {
    player.setAutoplay(false);
    final context = List.generate(7, (i) => track('$i'));
    await player.playTracks(context, context: 'album:first');
    await player.toggleShuffle();
    expect(view().shuffle, isTrue);
    expect(view().smartShuffle, isFalse);
    await player.toggleShuffle();
    expect(view().smartShuffle, isTrue);
    expect(api.recommendationCalls.single.limit, 3);
    expect(api.recommendationCalls.single.seeds, unorderedEquals(context.map((t) => t.id)));
    api.recommendationCalls.single.response.complete([track('smart-a'), track('smart-b')]);
    await settle();
    return context;
  }

  test('smart shuffle interleaves, marks and removes upcoming extras when switched off', () async {
    final original = await enableSmart();
    expect(view().queue[4].id, 'smart-a');
    expect(view().queue[8].id, 'smart-b');
    expect(view().smartIds, {'smart-a', 'smart-b'});
    expect(engine.audioSources, hasLength(9));
    engine.position = const Duration(seconds: 42);
    await player.toggleShuffle();
    expect(view().shuffle, isFalse);
    expect(view().smartShuffle, isFalse);
    expect(view().queue.map((t) => t.id), original.map((t) => t.id));
    expect(view().current!.id, original.first.id);
    expect(engine.removed, [8, 4]);
    expect(engine.playing, isTrue);
    expect(engine.position, const Duration(seconds: 42));
  });

  test('disabling smart shuffle keeps a currently playing recommendation', () async {
    await enableSmart();
    await player.jumpTo(4);
    engine.position = const Duration(seconds: 25);
    await player.toggleShuffle();
    expect(view().current!.id, 'smart-a');
    expect(view().smartIds, {'smart-a'});
    expect(view().queue.any((t) => t.id == 'smart-b'), isFalse);
    expect(engine.playing, isTrue);
    expect(engine.position, const Duration(seconds: 25));
  });

  test('media shuffle all selects normal shuffle even from smart shuffle', () async {
    await enableSmart();
    await player.setShuffle(true);
    expect(view().shuffle, isTrue);
    expect(view().smartShuffle, isFalse);
    expect(view().smartIds, isEmpty);
    expect(engine.audioSources, hasLength(7));
  });

  test('smart shuffle carries to new eligible contexts and skips radio playlists', () async {
    await enableSmart();
    final next = List.generate(10, (i) => track('new-$i'));
    await player.playTracks(next, context: 'album:second');
    expect(view().smartShuffle, isTrue);
    expect(view().smartIds, isEmpty);
    expect(api.recommendationCalls, hasLength(2));
    expect(api.recommendationCalls.last.seeds, unorderedEquals(next.map((t) => t.id)));
    api.recommendationCalls.last.response.complete([track('new-smart')]);
    await settle();
    expect(view().smartIds, {'new-smart'});
    await player.playTracks(next, context: 'playlist:radio', isRadio: true);
    expect(view().smartShuffle, isFalse);
    expect(view().smartIds, isEmpty);
    await player.toggleShuffle();
    expect(view().shuffle, isFalse);
    await player.toggleShuffle();
    expect(view().shuffle, isTrue);
    expect(view().smartShuffle, isFalse);
    expect(api.recommendationCalls, hasLength(2));
  });

  test('late smart shuffle responses are discarded after switching off', () async {
    player.setAutoplay(false);
    await player.playTracks(List.generate(7, (i) => track('$i')), context: 'liked');
    await player.toggleShuffle();
    await player.toggleShuffle();
    await player.toggleShuffle();
    api.recommendationCalls.single.response.complete([track('late')]);
    await settle();
    expect(view().queue, hasLength(7));
    expect(view().smartIds, isEmpty);
  });

  test('smart shuffle samples at most 100 context tracks and requests at most 50', () async {
    player.setAutoplay(false);
    await player.playTracks(List.generate(180, (i) => track('$i')), context: 'liked');
    await player.toggleShuffle();
    await player.toggleShuffle();
    expect(api.recommendationCalls.single.seeds, hasLength(100));
    expect(api.recommendationCalls.single.excluded, hasLength(180));
    expect(api.recommendationCalls.single.limit, 50);
  });
}
