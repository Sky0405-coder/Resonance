import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/integrations/discord_presence.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/offline/offline_store.dart';
import 'package:resonance/player/audio_handler.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/equalizer.dart';
import 'package:resonance/player/equalizer_controller.dart';
import 'package:resonance/player/player.dart';
import 'package:resonance/ui/pages/world_radio_page.dart';

const _station = Station(
  id: 'one',
  name: 'Radio One',
  country: 'Germany',
  countryCode: 'DE',
  tags: ['rock'],
  codec: 'MP3',
);
const _track = Track(
  id: 'track',
  title: 'Song',
  duration: 120,
  artist: NamedRef('artist', 'Artist'),
  artistCredit: 'Artist',
  album: NamedRef('album', 'Album'),
);
const _now = StationNowPlaying(
  raw: 'Artist - Title',
  artist: 'Artist',
  title: 'Title',
  album: 'Album',
  year: 1987,
  coverUrl: 'https://cover.example/album.jpg',
);

class _Api extends ApiClient {
  _Api() : super('https://resonance.example', 'test-token');
  int reports = 0;
  final nowRequests = <String>[];
  StationNowPlaying? now;
  Future<StationNowPlaying?> Function()? lookup;

  @override
  Future<StationNowPlaying?> stationNowPlaying(String id) async {
    nowRequests.add(id);
    return lookup == null ? now : await lookup!();
  }

  @override
  Future<void> reportPlay(String id, double seconds, {String? context}) async {
    reports++;
  }
}

class _Engine implements PlaybackEngine {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final errors = StreamController<Object>.broadcast(sync: true);
  final positions = StreamController<Duration>.broadcast(sync: true);
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Object> get errorStream => errors.stream;
  @override
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<LoopMode> get loopModeStream => const Stream.empty();
  @override
  Stream<PlaybackEvent> get playbackEventStream => const Stream.empty();
  @override
  Duration get bufferedPosition => Duration.zero;
  @override
  int crossfadeSeconds = 0;
  @override
  bool automix = false;
  @override
  MixPoints? Function(int index)? mixPointsForIndex;
  @override
  String? Function(int index)? sourceKeyForIndex;
  @override
  bool isBook = false;
  @override
  double Function(int)? targetVolumeForIndex;
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
  int loads = 0;
  int seeks = 0;
  int stops = 0;
  final equalizers = <EqualizerSettings>[];
  Completer<void>? nextLoad;

  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {
    equalizers.add(settings);
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
    loads++;
    final pending = nextLoad;
    nextLoad = null;
    if (pending != null) await pending.future;
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
  Future<void> stop() async {
    stops++;
    await pause();
  }

  @override
  Future<void> finishFade() async {}
  @override
  Future<void> setLoopMode(LoopMode mode) async {
    loopMode = mode;
  }

  @override
  Future<void> setSpeed(double value) async {
    speed = value;
  }

  @override
  Future<void> setVolume(double value) async {}
  @override
  Future<void> seek(Duration value, {int? index}) async {
    seeks++;
  }

  @override
  Future<void> seekToNext() async {
    seeks++;
  }

  @override
  Future<void> seekToPrevious() async {
    seeks++;
  }

  @override
  Future<void> dispose() async {
    await states.close();
    await errors.close();
    await positions.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Offline extends OfflineController {
  @override
  OfflineState build() => const OfflineState();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late _Engine engine;
  late _Api api;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    engine = _Engine();
    api = _Api();
    container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        downloadSummaryProvider.overrideWith((ref) async => const DownloadSummary()),
        offlineProvider.overrideWith(_Offline.new),
        playerProvider.overrideWith(() => PlayerController(engine: engine)),
      ],
    );
  });
  tearDown(() => container.dispose());

  testWidgets('player applies saved equalizer settings at startup and debounces live changes', (tester) async {
    final saved = EqualizerSettings(enabled: true).withPreset('bass');
    container.read(equalizerProvider.notifier).set(saved);
    container.read(playerProvider);
    expect(engine.equalizers.single.toJson(), saved.toJson());
    container.read(equalizerProvider.notifier).set(saved.withGain(0, 2));
    await tester.pump(const Duration(milliseconds: 40));
    container.read(equalizerProvider.notifier).set(saved.withGain(0, -4.5));
    await tester.pump(const Duration(milliseconds: 79));
    expect(engine.equalizers, hasLength(1));
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.equalizers, hasLength(2));
    expect(engine.equalizers.last.preset, 'custom');
    expect(engine.equalizers.last.gains.first, -4.5);
  });

  test('Station.fromJson keeps directory metadata and nullable fields', () {
    final station = Station.fromJson({
      'id': 'one',
      'name': 'Radio One',
      'country': 'Germany',
      'country_code': 'DE',
      'tags': ['rock', 'pop'],
      'favicon': 'https://radio.example/icon.png',
      'codec': 'MP3',
      'bitrate': 128,
      'homepage': 'https://radio.example',
    });
    expect(station.id, 'one');
    expect(station.name, 'Radio One');
    expect(station.country, 'Germany');
    expect(station.countryCode, 'DE');
    expect(station.tags, ['rock', 'pop']);
    expect(station.favicon, 'https://radio.example/icon.png');
    expect(station.codec, 'MP3');
    expect(station.bitrate, 128);
    expect(station.homepage, 'https://radio.example');
    final unknown = Station.fromJson({
      'id': 'two',
      'name': 'Two',
      'country': '',
      'country_code': '',
      'tags': [],
      'codec': '',
    });
    expect(unknown.bitrate, isNull);
    expect(unknown.favicon, isNull);
    expect(unknown.homepage, isNull);
  });

  test('country flags handle upper/lower case and invalid codes', () {
    expect(countryFlag('DE'), '🇩🇪');
    expect(countryFlag('us'), '🇺🇸');
    for (final code in ['', 'D', 'DEU', '12', 'éé']) {
      expect(countryFlag(code), '');
    }
  });

  test('now-playing JSON, equality and subtitles include only known parts', () {
    final now = StationNowPlaying.fromJson({
      'raw': 'Artist - Title',
      'artist': 'Artist',
      'title': 'Title',
      'album': 'Album',
      'year': 1987,
      'cover_url': 'https://cover.example/album.jpg',
    });
    expect(now, _now);
    expect(now.hashCode, _now.hashCode);
    expect(now.artistYear, 'Artist · 1987');
    expect(now.subtitle('Radio One'), 'Artist · 1987 · Radio One');
    const titleOnly = StationNowPlaying(raw: 'Title', title: 'Title');
    expect(titleOnly.artistYear, '');
    expect(titleOnly.subtitle('Radio One'), 'Radio One');
    const artistOnly = StationNowPlaying(raw: 'Artist - Title', artist: 'Artist');
    expect(artistOnly.subtitle('Radio One'), 'Artist · Radio One');
    const yearOnly = StationNowPlaying(raw: 'Title', artist: '', year: 1987);
    expect(yearOnly.subtitle('Radio One'), '1987 · Radio One');
    expect(StationNowPlaying.fromJson({'raw': 'Title'}).coverUrl, isNull);
    expect(titleOnly, isNot(_now));
  });

  testWidgets('polls immediately, after three seconds, then every fifteen; pauses and stops cancel', (tester) async {
    api.now = _now;
    final player = container.read(playerProvider.notifier);
    await player.playStation(_station);
    await tester.pump();
    expect(api.nowRequests, ['one']);
    expect(container.read(playerProvider).stationNow, _now);
    await tester.pump(const Duration(seconds: 2));
    expect(api.nowRequests, hasLength(1));
    await tester.pump(const Duration(seconds: 1));
    expect(api.nowRequests, hasLength(2));
    api.now = const StationNowPlaying(raw: 'New title', title: 'New title');
    await tester.pump(const Duration(seconds: 14));
    expect(api.nowRequests, hasLength(2));
    await tester.pump(const Duration(seconds: 1));
    expect(api.nowRequests, hasLength(3));
    expect(container.read(playerProvider).stationNow?.title, 'New title');
    await player.pause();
    await tester.pump(const Duration(seconds: 30));
    expect(api.nowRequests, hasLength(3));
    await player.play();
    await tester.pump();
    expect(api.nowRequests, hasLength(4));
    await player.stop();
    await tester.pump(const Duration(seconds: 30));
    expect(api.nowRequests, hasLength(4));
  });

  testWidgets('metadata failures retain the song, while null clears it', (tester) async {
    api.now = _now;
    final player = container.read(playerProvider.notifier);
    await player.playStation(_station);
    await tester.pump();
    api.lookup = () async => throw ApiException('offline');
    await tester.pump(const Duration(seconds: 3));
    expect(container.read(playerProvider).stationNow, _now);
    expect(engine.playing, true);
    api.lookup = null;
    api.now = null;
    await tester.pump(const Duration(seconds: 15));
    expect(container.read(playerProvider).stationNow, isNull);
    await player.stop();
  });

  testWidgets('station changes and track playback ignore old in-flight metadata', (tester) async {
    final pending = Completer<StationNowPlaying?>();
    api.lookup = () => pending.future;
    final player = container.read(playerProvider.notifier);
    await player.playStation(_station);
    const other = Station(id: 'two', name: 'Two', country: '', countryCode: '', tags: [], codec: '');
    api.lookup = null;
    await player.playStation(other);
    await tester.pump();
    expect(api.nowRequests, ['one', 'two']);
    pending.complete(_now);
    await tester.pump();
    expect(container.read(playerProvider).stationNow, isNull);
    final late = Completer<StationNowPlaying?>();
    api.lookup = () => late.future;
    await tester.pump(const Duration(seconds: 3));
    await player.playTracks([_track]);
    late.complete(_now);
    await tester.pump(const Duration(seconds: 30));
    expect(api.nowRequests, ['one', 'two', 'two']);
    expect(container.read(playerProvider).station, isNull);
    expect(container.read(playerProvider).stationNow, isNull);
  });

  testWidgets('station media items refresh song, album and cover then fall back', (tester) async {
    final handler = ResonanceAudioHandler(container);
    try {
      api.now = _now;
      final player = container.read(playerProvider.notifier);
      await player.playStation(_station);
      await tester.pump();
      expect(handler.mediaItem.value?.title, 'Title');
      expect(handler.mediaItem.value?.artist, 'Artist · Radio One');
      expect(handler.mediaItem.value?.album, 'Album');
      expect(handler.mediaItem.value?.artUri.toString(), _now.coverUrl);
      api.now = null;
      await tester.pump(const Duration(seconds: 3));
      expect(handler.mediaItem.value?.title, 'Radio One');
      expect(handler.mediaItem.value?.artist, 'World radio');
      expect(handler.mediaItem.value?.album, isNull);
      expect(handler.mediaItem.value?.artUri, isNull);
      await player.stop();
    } finally {
      handler.dispose();
    }
  });

  test('known station songs use track-style Discord details and the station without a fake duration', () {
    final activity = buildDiscordActivity(
      player: const PlayerView(station: _station, stationNow: _now, playing: true),
      position: const Duration(seconds: 30),
      serverUrl: api.baseUrl,
      l10n: lookupAppLocalizations(const Locale('en')),
      now: DateTime.utc(2026),
    )!;
    expect(activity['details'], 'Title');
    expect(activity['state'], 'by Artist · Radio One');
    expect(activity['assets']['large_text'], 'Album');
    expect(activity.containsKey('timestamps'), false);
  });

  test('station playback uses proxy, clears music queue and cannot seek or repeat', () async {
    final player = container.read(playerProvider.notifier);
    await player.playTracks([_track]);
    await player.playStation(_station);
    final state = container.read(playerProvider);
    expect(state.station, same(_station));
    expect(state.queue, isEmpty);
    expect(state.book, isNull);
    expect(state.context, 'station:one');
    expect((engine.audioSources.single() as UriAudioSource).uri.toString(), api.stationStreamUrl('one'));
    await player.next();
    await player.previous();
    await player.seek(const Duration(seconds: 10));
    await player.jumpTo(1);
    await player.setShuffle(true);
    await player.setLoop(LoopMode.all);
    expect(engine.seeks, 0);
    expect(container.read(playerProvider).shuffle, false);
    expect(engine.loopMode, LoopMode.off);
    expect(
      buildDiscordActivity(
        player: state,
        position: Duration.zero,
        serverUrl: api.baseUrl,
        l10n: lookupAppLocalizations(const Locale('en')),
        now: DateTime.utc(2026),
      ),
      isNull,
    );
  });

  test('switching station to track clears station and preserves sleep timer', () async {
    final player = container.read(playerProvider.notifier);
    player.setSleepTimer(const Duration(minutes: 5));
    final sleepAt = container.read(playerProvider).sleepAt;
    await player.playStation(_station);
    engine.positions.add(const Duration(seconds: 90));
    await player.playTracks([_track]);
    final state = container.read(playerProvider);
    expect(state.station, isNull);
    expect(state.current, same(_track));
    expect(state.sleepAt, sleepAt);
    expect(engine.speed, 1);
    expect(api.reports, 0);
  });

  test('live errors retry once after three seconds, then stop and surface an error', () async {
    final player = container.read(playerProvider.notifier);
    final errors = <Object>[];
    final sub = player.errors.stream.listen(errors.add);
    await player.playStation(_station);
    engine.errors.add(StateError('stream dropped'));
    await Future<void>.delayed(const Duration(seconds: 2));
    expect(engine.loads, 1);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(engine.loads, 2);
    engine.errors.add(StateError('stream dropped again'));
    await Future<void>.delayed(Duration.zero);
    expect(engine.stops, 1);
    expect(errors.single.toString(), contains('Station unavailable'));
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(engine.loads, 2);
    await sub.cancel();
  });

  test('pausing while a live retry loads keeps the station paused', () async {
    final player = container.read(playerProvider.notifier);
    await player.playStation(_station);
    final loading = Completer<void>();
    engine.nextLoad = loading;
    engine.errors.add(StateError('drop'));
    await Future<void>.delayed(const Duration(milliseconds: 3100));
    expect(engine.loads, 2);
    await player.pause();
    loading.complete();
    await Future<void>.delayed(Duration.zero);
    expect(engine.playing, false);
  });

  test('sleep timer pauses a live station and cancels a pending retry', () async {
    final player = container.read(playerProvider.notifier);
    await player.playStation(_station);
    player.setSleepTimer(const Duration(seconds: 1));
    engine.errors.add(StateError('drop'));
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(engine.playing, false);
    expect(engine.loads, 1);
    expect(container.read(playerProvider).sleepAt, isNull);
  });
}
