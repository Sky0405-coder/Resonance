import '../l10n/locale.dart';
import '../l10n/l10n.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'engine.dart';
import 'equalizer_controller.dart';
import 'radio_follow.dart';

import '../core/api.dart';
import '../core/downloads.dart';
import '../offline/offline_store.dart';
import '../core/audiobooks.dart';
import '../core/models.dart';
import '../core/session.dart';

/// One file of an audiobook; [start] is its offset within the whole book in seconds.
class BookPart {
  const BookPart({required this.url, required this.start, required this.duration});
  final String url;
  final double start;
  final double duration;
}

/// An Audiobookshelf playback session that is currently loaded into the engine.
class BookPlayback {
  const BookPlayback({
    required this.itemId,
    required this.sessionId,
    required this.title,
    required this.coverUrl,
    required this.duration,
    required this.parts,
    required this.chapters,
    this.author,
  });
  final String itemId;
  final String sessionId;
  final String title;
  final String? author;
  final String coverUrl;
  final double duration;
  final List<BookPart> parts;
  final List<AbsChapter> chapters;

  AbsChapter? chapterAt(double seconds) => chapters.where((c) => seconds >= c.start && seconds < c.end).firstOrNull;
}

/// Receives the player's actions while a Jam is active (the server owns the queue then).
abstract class JamRouter {
  Future<void> playTracks(List<Track> tracks, int index);
  Future<void> add(Track track, {required bool next});
  Future<void> removeAt(int index);
  Future<void> jumpTo(int index);
  Future<void> play();
  Future<void> pause();
  Future<void> next();
  Future<void> previous();
  Future<void> seek(Duration position);
  bool get playing;
}

/// Snapshot of what the UI needs to render the engine.
class PlayerView {
  const PlayerView({
    this.queue = const [],
    this.index,
    this.playing = false,
    this.buffering = false,
    this.shuffle = false,
    this.smartShuffle = false,
    this.autoplayIds = const {},
    this.smartIds = const {},
    this.isRadio = false,
    this.loop = LoopMode.off,
    this.context,
    this.book,
    this.station,
    this.stationNow,
    this.speed = 1,
    this.sleepAt,
    this.jamRemote = false,
  });

  final List<Track> queue;
  final int? index;
  final bool playing;
  final bool buffering;
  final bool shuffle;
  final bool smartShuffle;
  final Set<String> autoplayIds;
  final Set<String> smartIds;
  final bool isRadio;
  final LoopMode loop;
  // Where playback was started from, e.g. "album:<id>".
  final String? context;
  // Set while an audiobook is playing instead of music (queue is empty then).
  final BookPlayback? book;
  final Station? station;
  final StationNowPlaying? stationNow;
  final double speed;
  // Sleep timer: pause at this time (null = off).
  final DateTime? sleepAt;
  // In a Jam without listening on this device: the view mirrors the Jam, the engine is idle.
  final bool jamRemote;

  bool get inJam => context?.startsWith('jam:') ?? false;

  Track? get current => index != null && index! < queue.length ? queue[index!] : null;
}

/// Owns the [PlaybackEngine]; one instance for the whole app.
class PlayerController extends Notifier<PlayerView> {
  PlayerController({PlaybackEngine? engine}) : engine = engine ?? PlaybackEngine();

  final PlaybackEngine engine;
  final errors = StreamController<Object>.broadcast();
  Timer? _stationRetry;
  Timer? _equalizerDebounce;
  Timer? _stationPoll;
  int _stationPollGeneration = 0;
  int _stationPollRequest = 0;
  bool _stationRetried = false;
  bool _stationFailed = false;
  int _stationGeneration = 0;
  List<Track> _unshuffled = [];
  List<Track> _contextTracks = [];
  final _autoplayIds = <String>{};
  final _smartIds = <String>{};
  final _autoplayAttempted = <String>{};
  Object? _autoplayRequest;
  Object? _smartRequest;
  int _contextGeneration = 0;
  bool autoplay = true;
  final List<StreamSubscription> _subs = [];

  // Play reporting: count listened time for the current track.
  String? _reportTrackId;
  double _listened = 0;
  Duration _lastPos = Duration.zero;

  bool normalize = true;
  // Volume chosen by the user; multiplied with the ReplayGain factor.
  final ValueNotifier<double> userVolume = ValueNotifier(1);
  double _gainFactor = 1;

  bool _switching = false;
  Future<void> _pendingSwitch = Future.value();

  /// Set by the Jam controller while in a Jam: user actions go to the server instead of the engine.
  JamRouter? jam;
  Duration Function()? _jamPosition;
  int? _crossfadeBeforeJam;
  bool? _automixBeforeJam;

  // AutoMix analyses by track id; null once the server could not provide one.
  final _mixPoints = <String, MixPoints?>{};
  final _mixPointsLoading = <String>{};

  /// Expected position of the Jam's current song (used while not listening on this device).
  Duration get jamPosition => _jamPosition?.call() ?? Duration.zero;

  // Serialize replacements so a late load cannot overwrite another request.
  Future<void> _switch(Future<void> Function() action) {
    final result = _pendingSwitch.then((_) => action());
    _pendingSwitch = result.catchError((Object _) {});
    return result;
  }

  AppLocalizations get _l10n => lookupAppLocalizations(ref.read(appLocaleProvider));

  ApiClient get _api => ref.read(apiProvider);

  String get _autoplayKey {
    final session = ref.read(sessionProvider);
    return session.user == null ? 'autoplay' : 'autoplay:${session.serverUrl}:${session.user!.id}';
  }

  @override
  PlayerView build() {
    final prefs = ref.read(prefsProvider);
    normalize = prefs.getBool('normalize_volume') ?? true;
    userVolume.value = (prefs.getDouble('user_volume') ?? 1).clamp(0, 1);
    engine.crossfadeSeconds = (prefs.getInt('crossfade_seconds') ?? 0).clamp(0, 12);
    engine.targetVolumeForIndex = (index) => userVolume.value * _gainForTrack(state.queue[index]);
    engine.automix = prefs.getBool('automix') ?? false;
    engine.setEqualizer(ref.read(equalizerProvider)).ignore();
    ref.listen(equalizerProvider, (_, settings) {
      _equalizerDebounce?.cancel();
      _equalizerDebounce = Timer(const Duration(milliseconds: 80), () => engine.setEqualizer(settings).ignore());
    });
    engine.mixPointsForIndex = _mixPointsFor;
    // Stream URLs and offline files both contain the song id.
    engine.sourceKeyForIndex = (index) => index < state.queue.length ? state.queue[index].id : null;
    autoplay = prefs.getBool(_autoplayKey) ?? true;
    ref.listen(sessionProvider.select((s) => (s.serverUrl, s.user?.id)), (_, next) {
      autoplay = prefs.getBool(_autoplayKey) ?? true;
      _contextGeneration++;
      _autoplayRequest = _smartRequest = null;
    });
    _subs.addAll([
      engine.playerStateStream.listen((s) {
        if (_switching || state.jamRemote) return;
        // Save the audiobook position right away when pausing.
        if (state.playing && !s.playing && state.book != null) _syncBook().ignore();
        state = _copy(
          playing: s.playing,
          buffering: s.processingState == ProcessingState.loading || s.processingState == ProcessingState.buffering,
        );
        _maybeAutoplay();
      }),
      // just_audio repeats the index (and loop mode) with every playback event – ~16×/s with media_kit. Only real
      // changes may rebuild the UI and close the play report of the previous song.
      engine.currentIndexStream.listen((i) {
        if (_switching || state.jamRemote || i == state.index) return;
        if (state.book != null) {
          state = _copy(index: i);
          return;
        }
        _flushPlayReport();
        state = _copy(index: i);
        _applyGain();
        _reportTrackId = state.current?.id;
        _maybeAutoplay();
      }),
      engine.loopModeStream.listen((v) {
        if (!_switching && v != state.loop) {
          state = _copy(loop: v);
          _maybeAutoplay();
        }
      }),
      engine.positionStream.listen(_trackListening),
      engine.errorStream.listen(_stationError),
    ]);
    final radioFollow = RadioFollow(
      loadPlaylist: (id) async {
        final detail = await _api.playlist(id);
        return (
          isRadio: detail.playlist.isRadio,
          tracks: [for (final entry in detail.entries) entry.track],
          pendingDownloads: null,
        );
      },
      currentContext: () => state.context,
      queuedTrackIds: () => {for (final track in state.queue) track.id},
      append: (track, context) => _switch(() async {
        if (state.context != context || state.queue.any((t) => t.id == track.id)) return;
        await addToQueue(track);
      }),
    );
    listenSelf((previous, next) {
      if (previous?.context != next.context) radioFollow.contextChanged(next.context);
      if (previous?.station != next.station || previous?.playing != next.playing) _updateStationPolling();
    });
    ref.listen(downloadSummaryProvider, (_, next) {
      final summary = next.asData?.value;
      if (summary != null) radioFollow.downloadRunningChanged(summary.running);
    });
    ref.onDispose(() {
      radioFollow.dispose();
      for (final s in _subs) {
        s.cancel();
      }
      _bookSync?.cancel();
      _stationGeneration++;
      _stationRetry?.cancel();
      _equalizerDebounce?.cancel();
      _stopStationPolling();
      errors.close();
      _sleepTimer?.cancel();
      engine.dispose();
      _saveVolume?.cancel();
      userVolume.dispose();
    });
    return const PlayerView();
  }

  PlayerView _copy({
    List<Track>? queue,
    int? index,
    bool? playing,
    bool? buffering,
    bool? shuffle,
    bool? smartShuffle,
    bool? isRadio,
    String? context,
    LoopMode? loop,
    double? speed,
    DateTime? Function()? sleepAt,
    StationNowPlaying? Function()? stationNow,
  }) => PlayerView(
    queue: queue ?? state.queue,
    index: index ?? state.index,
    playing: playing ?? state.playing,
    buffering: buffering ?? state.buffering,
    shuffle: shuffle ?? state.shuffle,
    smartShuffle: smartShuffle ?? state.smartShuffle,
    autoplayIds: Set.unmodifiable(_autoplayIds),
    smartIds: Set.unmodifiable(_smartIds),
    isRadio: isRadio ?? state.isRadio,
    loop: loop ?? state.loop,
    context: context ?? state.context,
    book: state.book,
    station: state.station,
    stationNow: stationNow == null ? state.stationNow : stationNow(),
    speed: speed ?? state.speed,
    sleepAt: sleepAt == null ? state.sleepAt : sleepAt(),
    jamRemote: state.jamRemote,
  );

  SourceFactory _source(Track t) => () {
    final offline = kIsWeb ? null : ref.read(offlineProvider);
    final file = offline?.filePath(t.id);
    return file == null ? AudioSource.uri(Uri.parse(_api.streamUrl(t.id))) : AudioSource.file(file);
  };

  /// Replace the queue and start playing at [index]. Shuffle is a global toggle (like Spotify): when it is on,
  /// the queue is shuffled around the start track, which is random if no [index] is given.
  Future<void> playTracks(List<Track> tracks, {int? index, String? context, bool isRadio = false}) {
    final jam = this.jam;
    if (jam != null) return jam.playTracks(tracks, index ?? 0);
    return _playTracks(tracks, index: index, context: context, isRadio: isRadio);
  }

  Future<void> _playTracks(List<Track> tracks, {int? index, String? context, bool isRadio = false}) =>
      _switch(() async {
        if (tracks.isEmpty) return;
        final shuffle = state.shuffle;
        final chosen = index ?? (shuffle ? math.Random().nextInt(tracks.length) : 0);
        final queue = shuffle ? shuffleQueue(tracks, chosen) : tracks;
        await _replacePlayback(
          PlayerView(
            queue: List.unmodifiable(queue),
            shuffle: shuffle,
            smartShuffle: state.smartShuffle && supportsSmartShuffle(context, isRadio: isRadio),
            isRadio: isRadio,
            loop: state.book == null ? state.loop : LoopMode.off,
            context: context,
            sleepAt: state.sleepAt,
          ),
          [for (final t in queue) _source(t)],
          index: shuffle ? 0 : chosen,
        );
        _unshuffled = [...tracks];
        _contextTracks = [...tracks];
        if (state.smartShuffle) _loadSmart().ignore();
        _maybeAutoplay();
      });

  Future<void> replaceUpcoming(List<Track> tracks, {required String context, bool isRadio = false}) {
    final previousContext = state.context;
    final current = state.current;
    return _switch(() async {
      await engine.finishFade();
      if (current == null || state.context != previousContext || state.current?.id != current.id) return;
      final (queue, original) = replaceUpcomingQueue(current, tracks, id: (track) => track.id, shuffle: state.shuffle);
      _switching = true;
      try {
        await engine.setSources([for (final track in queue) _source(track)], initialIndex: 0, preserveCurrent: true);
        _unshuffled = original;
        _resetRecommendations();
        _contextTracks = [...tracks];
        state = _copy(
          queue: List.unmodifiable(queue),
          index: 0,
          context: context,
          isRadio: isRadio,
          smartShuffle: state.smartShuffle && supportsSmartShuffle(context, isRadio: isRadio),
        );
      } finally {
        _switching = false;
      }
      if (state.smartShuffle) _loadSmart().ignore();
      _maybeAutoplay();
    });
  }

  /// Commit metadata only after loading, and reload the previous sources on failure.
  Future<void> _replacePlayback(
    PlayerView next,
    List<SourceFactory> sources, {
    required int index,
    Duration position = Duration.zero,
  }) async {
    await engine.finishFade();
    final previous = state;
    final previousSources = List<SourceFactory>.of(engine.audioSources);
    final previousIndex = engine.currentIndex ?? 0;
    final previousPosition = engine.position;
    final previousBookPosition = bookPosition;
    _stopStationPolling();
    _switching = true;
    try {
      await engine.pause();
      // just_audio_web caches the root playlist by ID. setAudioSources reuses
      // that ID; stopping releases the cached platform playlist before loading.
      // Web only: on Android stop() ends the media session, and the playback
      // notification / lock screen controls would not come back.
      if (kIsWeb) await engine.stop();
      engine.isBook = next.book != null || next.station != null;
      await engine.setLoopMode(next.loop);
      await engine.setSpeed(next.speed);
      await engine.setSources(sources, initialIndex: index, initialPosition: position);
    } catch (e, st) {
      debugPrint('Playback replacement failed: $e\n$st');
      try {
        await engine.stop();
        engine.isBook = previous.book != null || previous.station != null;
        await engine.setLoopMode(previous.loop);
        await engine.setSpeed(previous.speed);
        if (previousSources.isNotEmpty) {
          await engine.setSources(previousSources, initialIndex: previousIndex, initialPosition: previousPosition);
        }
      } catch (restoreError) {
        debugPrint('Playback restore failed: $restoreError');
        await engine.stop();
      }
      _switching = false;
      state = _copy(playing: false, buffering: false);
      _lastPos = engine.position;
      if (previous.playing && engine.processingState == ProcessingState.ready) engine.play();
      throw ApiException(
        next.station != null
            ? _l10n.worldRadioUnavailable
            : next.book == null
            ? _l10n.playerMusicLoadError
            : _l10n.playerAudiobookLoadError,
      );
    }
    // Use the old position: the player's sources now belong to the new item.
    await _closeBook(position: previousBookPosition);
    _flushPlayReport();
    _stationGeneration++;
    _stationRetry?.cancel();
    _stationRetry = null;
    _resetRecommendations();
    state = PlayerView(
      queue: next.queue,
      index: engine.currentIndex,
      playing: engine.playing,
      shuffle: next.shuffle,
      smartShuffle: next.smartShuffle,
      isRadio: next.isRadio,
      loop: next.loop,
      context: next.context,
      book: next.book,
      station: next.station,
      speed: next.speed,
      sleepAt: state.sleepAt,
    );
    _bookListened = 0;
    _lastPos = engine.position;
    _reportTrackId = state.current?.id;
    _switching = false;
    _applyGain();
    if (state.book != null) {
      _bookSync = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!_switching && engine.playing) _syncBook().ignore();
      });
    }
    engine.play().catchError((Object error) {
      if (state.station != null) _stationError(error);
    });
  }

  Future<void> playNext(Track t) async {
    if (jam != null) return jam!.add(t, next: true);
    await engine.finishFade();
    final at = (state.index ?? -1) + 1;
    await _insert(at, t);
  }

  Future<void> addToQueue(Track t) => jam != null ? jam!.add(t, next: false) : _insert(state.queue.length, t);

  Future<void> _insert(int at, Track t) async {
    if (state.queue.isEmpty || state.book != null) return playTracks([t]);
    await engine.finishFade();
    state = _copy(queue: List.unmodifiable([...state.queue]..insert(at, t)));
    _unshuffled.insert(state.shuffle ? _unshuffled.length : at, t);
    await engine.insert(at, _source(t));
  }

  Future<void> removeAt(int i) async {
    if (jam != null) return jam!.removeAt(i);
    await engine.finishFade();
    _unshuffled.remove(state.queue[i]);
    state = _copy(queue: List.unmodifiable([...state.queue]..removeAt(i)));
    await engine.removeAt(i);
  }

  void togglePlay() => (jam != null ? jam!.playing : engine.playing) ? pause() : play();

  Future<void> play() => jam != null ? jam!.play() : engine.play();

  Future<void> pause() async {
    if (jam != null) return jam!.pause();
    _stationGeneration++;
    _stationRetry?.cancel();
    _stationRetry = null;
    _stopStationPolling();
    await engine.pause();
  }

  Future<void> stop() async {
    if (state.book != null) await _syncBook();
    _flushPlayReport();
    _stationGeneration++;
    _stationRetry?.cancel();
    _stationRetry = null;
    _stopStationPolling();
    await engine.stop();
  }

  Future<void> next() async {
    if (jam != null) return jam!.next();
    if (state.station == null) await engine.seekToNext();
  }

  /// Like Spotify: restart the track unless we're in its first 3 seconds.
  Future<void> previous() async {
    if (jam != null) return jam!.previous();
    if (state.station != null) return;
    await engine.finishFade();
    if (engine.position > const Duration(seconds: 3) || !engine.hasPrevious) {
      await engine.seek(Duration.zero);
    } else {
      await engine.seekToPrevious();
    }
  }

  Future<void> jumpTo(int index) async {
    if (jam != null) return jam!.jumpTo(index);
    if (state.station == null) await engine.seek(Duration.zero, index: index);
  }

  Future<void> seek(Duration d) async {
    if (jam != null) return jam!.seek(d);
    if (state.station == null) await engine.seek(d);
  }

  Future<void> toggleShuffle() => _switch(() {
    final (shuffle, smart) = nextShuffleMode(
      shuffle: state.shuffle,
      smartShuffle: state.smartShuffle,
      allowSmart: supportsSmartShuffle(state.context, isRadio: state.isRadio),
    );
    return _setShuffle(shuffle, smart: smart);
  });

  Future<void> setShuffle(bool enabled) => _switch(() => _setShuffle(enabled));

  Future<void> _setShuffle(bool enabled, {bool smart = false}) async {
    if (state.station != null || state.book != null || state.inJam || jam != null) return;
    await engine.finishFade();
    if (enabled == state.shuffle && smart == state.smartShuffle) return;
    _smartRequest = null;
    if (state.smartShuffle && !smart) {
      state = _copy(smartShuffle: false);
      for (var i = state.queue.length - 1; i > (state.index ?? -1); i--) {
        if (_smartIds.contains(state.queue[i].id)) {
          _smartIds.remove(state.queue[i].id);
          await removeAt(i);
        }
      }
    }
    if (enabled == state.shuffle) {
      state = _copy(smartShuffle: smart);
      if (smart) _loadSmart().ignore();
      return;
    }
    final current = state.current;
    if (current == null) {
      state = _copy(shuffle: enabled, smartShuffle: smart);
      return;
    }
    if (enabled) _unshuffled = [...state.queue];
    final (queue, index) = enabled
        ? (shuffleQueue(state.queue, state.index!), 0)
        : unshuffleQueue(_unshuffled, current);
    _switching = true;
    try {
      await engine.setSources([for (final t in queue) _source(t)], initialIndex: index, preserveCurrent: true);
      state = _copy(queue: List.unmodifiable(queue), index: index, shuffle: enabled, smartShuffle: smart);
    } finally {
      _switching = false;
    }
    if (smart) _loadSmart().ignore();
    _maybeAutoplay();
  }

  void _resetRecommendations() {
    _contextGeneration++;
    _autoplayRequest = _smartRequest = null;
    _autoplayAttempted.clear();
    _autoplayIds.clear();
    _smartIds.clear();
    _contextTracks = [];
  }

  void setAutoplay(bool enabled) {
    autoplay = enabled;
    ref.read(prefsProvider).setBool(_autoplayKey, enabled);
    if (enabled) _maybeAutoplay();
  }

  bool get _canAutoplay => shouldAutoplay(
    enabled: autoplay,
    length: state.queue.length,
    index: state.index,
    loopMode: state.loop,
    playing: state.playing && !state.buffering && engine.processingState == ProcessingState.ready,
    isBook: state.book != null,
    isStation: state.station != null,
    inJam: state.inJam || jam != null,
  );

  void _maybeAutoplay() {
    if (_switching || !_canAutoplay || _autoplayRequest != null || _smartRequest != null) return;
    final id = state.current!.id;
    if (!_autoplayAttempted.add(id)) return;
    _loadAutoplay(id).ignore();
  }

  Future<void> _loadAutoplay(String id) async {
    final request = Object();
    _autoplayRequest = request;
    final generation = _contextGeneration;
    try {
      final tracks = await _api.recommendations(
        trackIds: [for (final t in state.queue.skip(math.max(0, state.queue.length - 20))) t.id],
        excludeIds: [for (final t in state.queue) t.id],
      );
      if (!ref.mounted) return;
      await _switch(() async {
        if (generation != _contextGeneration || !_canAutoplay || state.current?.id != id) return;
        final seen = {for (final t in state.queue) t.id};
        for (final track in tracks) {
          if (!seen.add(track.id)) continue;
          _autoplayIds.add(track.id);
          await addToQueue(track);
        }
      });
    } catch (_) {
      // Offline or an older server: leave the queue as it is.
    } finally {
      if (_autoplayRequest == request) _autoplayRequest = null;
    }
  }

  Future<void> _loadSmart() async {
    final seeds = [..._contextTracks];
    if (seeds.isEmpty || !state.smartShuffle || state.inJam || jam != null) return;
    final request = Object();
    _smartRequest = request;
    seeds.shuffle();
    try {
      final tracks = await _api.recommendations(
        trackIds: [for (final t in seeds.take(100)) t.id],
        excludeIds: {
          for (final t in [..._contextTracks, ...state.queue]) t.id,
        }.toList(),
        limit: math.min(50, (seeds.length + 2) ~/ 3),
      );
      if (!ref.mounted) return;
      await _switch(() async {
        if (_smartRequest != request || !state.smartShuffle || state.inJam || jam != null) return;
        await engine.finishFade();
        final index = state.index;
        if (index == null) return;
        final seen = {for (final t in state.queue) t.id};
        final extra = tracks.where((t) => seen.add(t.id)).toList();
        final ids = {for (final t in extra) t.id};
        final upcoming = interleaveEvery(state.queue.skip(index + 1).toList(), extra, 3);
        for (var i = 0; i < upcoming.length; i++) {
          final track = upcoming[i];
          if (!ids.contains(track.id)) continue;
          _smartIds.add(track.id);
          await _insert(index + 1 + i, track);
        }
      });
    } catch (_) {
      // Recommendations are optional; the shuffled context keeps playing.
    } finally {
      if (_smartRequest == request) {
        _smartRequest = null;
        if (ref.mounted) _maybeAutoplay();
      }
    }
  }

  Future<void> setLoop(LoopMode mode) async {
    if (state.station == null && jam == null) await engine.setLoopMode(mode);
  }

  Future<void> cycleLoop() => setLoop(switch (engine.loopMode) {
    LoopMode.off => LoopMode.all,
    LoopMode.all => LoopMode.one,
    LoopMode.one => LoopMode.off,
  });

  void setLikedLocally(String trackId, bool liked) {
    final replacements = <Track, Track>{for (final t in state.queue) t: t.id == trackId ? t.copyWith(liked: liked) : t};
    _unshuffled = [for (final t in _unshuffled) replacements[t] ?? t];
    state = _copy(queue: List.unmodifiable([for (final t in state.queue) replacements[t]!]));
  }

  Future<void> playStation(Station station) => _switch(() async {
    await _replacePlayback(PlayerView(station: station, context: 'station:${station.id}', sleepAt: state.sleepAt), [
      () => AudioSource.uri(Uri.parse(_api.stationStreamUrl(station.id))),
    ], index: 0);
    _unshuffled = [];
    _stationRetried = false;
    _stationFailed = false;
  });

  void _stopStationPolling() {
    _stationPollGeneration++;
    _stationPoll?.cancel();
    _stationPoll = null;
  }

  void _updateStationPolling() {
    _stopStationPolling();
    final station = state.station;
    if (station == null || !state.playing) return;
    final generation = _stationPollGeneration;
    Future<void> poll() async {
      final request = ++_stationPollRequest;
      try {
        final now = await _api.stationNowPlaying(station.id);
        if (generation != _stationPollGeneration || request != _stationPollRequest) return;
        if (now != state.stationNow) state = _copy(stationNow: () => now);
      } catch (_) {
        // A metadata lookup failure must not interrupt the stream.
      }
    }

    poll();
    _stationPoll = Timer(const Duration(seconds: 3), () {
      poll();
      _stationPoll = Timer.periodic(const Duration(seconds: 15), (_) => poll());
    });
  }

  void _stationError(Object error) {
    final station = state.station;
    if (_switching || station == null || _stationRetry != null || _stationFailed) return;
    if (_stationRetried) {
      _stationFailed = true;
      stop().ignore();
      errors.add(ApiException(_l10n.worldRadioUnavailable));
      return;
    }
    _stationRetried = true;
    final generation = _stationGeneration;
    _stationRetry = Timer(const Duration(seconds: 3), () {
      _stationRetry = null;
      _switch(() async {
        if (state.station?.id != station.id || generation != _stationGeneration) return;
        try {
          await engine.pause();
          if (kIsWeb) await engine.stop();
          await engine.setSources([
            () => AudioSource.uri(Uri.parse(_api.stationStreamUrl(station.id))),
          ], initialIndex: 0);
          if (generation == _stationGeneration) engine.play().catchError(_stationError);
        } catch (error) {
          _stationError(error);
        }
      }).ignore();
    });
  }

  // --- jam -------------------------------------------------------------------

  /// Make local playback follow the Jam's state. [expected] gives the position the current song should be at.
  Future<void> applyJam(
    List<Track> tracks,
    int index,
    Duration Function() expected,
    bool playing, {
    required bool listen,
    required String context,
  }) => _switch(() async {
    _jamPosition = expected;
    _crossfadeBeforeJam ??= engine.crossfadeSeconds;
    engine.crossfadeSeconds = 0;
    _automixBeforeJam ??= engine.automix;
    engine.automix = false;
    final queue = List<Track>.unmodifiable(tracks);
    final current = index >= 0 && index < queue.length ? index : null;
    if (!listen || current == null) {
      if (!state.jamRemote || state.playing) {
        await engine.finishFade();
        await engine.pause();
      }
      _flushPlayReport();
      if (state.context != context) _resetRecommendations();
      state = PlayerView(
        queue: queue,
        index: current,
        playing: listen ? false : playing && current != null,
        context: context,
        speed: state.speed,
        sleepAt: state.sleepAt,
        jamRemote: true,
      );
      return;
    }
    final sameQueue =
        state.context == context &&
        !state.jamRemote &&
        state.queue.length == queue.length &&
        Iterable.generate(queue.length).every((i) => state.queue[i].id == queue[i].id);
    if (!sameQueue) {
      final keepCurrent =
          state.context == context &&
          !state.jamRemote &&
          state.current != null &&
          state.current!.id == queue[current].id &&
          engine.audioSources.isNotEmpty;
      if (keepCurrent) {
        // Someone changed the queue around the playing song: keep it playing without a gap.
        _switching = true;
        try {
          await engine.setSources([for (final t in queue) _source(t)], initialIndex: current, preserveCurrent: true);
          _unshuffled = [...queue];
          state = _copy(queue: queue, index: current);
        } finally {
          _switching = false;
        }
      } else {
        await _replacePlayback(
          PlayerView(queue: queue, context: context, speed: 1, sleepAt: state.sleepAt),
          [for (final t in queue) _source(t)],
          index: current,
          position: expected(),
        );
        _unshuffled = [...queue];
        if (!playing) await engine.pause();
        return;
      }
    }
    if (engine.currentIndex != current) {
      await engine.seek(expected(), index: current);
    } else if (needsJamSeek(engine.position, expected())) {
      await engine.seek(expected());
    }
    if (playing && !engine.playing) {
      engine.play().ignore();
    } else if (!playing && engine.playing) {
      await engine.pause();
    }
  });

  /// Back to normal playback after leaving a Jam (the Jam's songs stay loaded, paused).
  Future<void> leaveJam() => _switch(() async {
    jam = null;
    _jamPosition = null;
    if (_crossfadeBeforeJam != null) engine.crossfadeSeconds = _crossfadeBeforeJam!;
    _crossfadeBeforeJam = null;
    if (_automixBeforeJam != null) engine.automix = _automixBeforeJam!;
    _automixBeforeJam = null;
    await engine.pause();
    state = PlayerView(
      queue: state.jamRemote ? const [] : state.queue,
      index: state.jamRemote ? null : engine.currentIndex,
      speed: state.speed,
      sleepAt: state.sleepAt,
    );
    _unshuffled = [...state.queue];
  });

  // --- audiobooks ------------------------------------------------------------

  Timer? _bookSync;
  double _bookListened = 0;

  /// Position within the whole book in seconds.
  double get bookPosition {
    final book = state.book;
    final i = engine.currentIndex;
    if (book == null || i == null || i >= book.parts.length) return 0;
    return book.parts[i].start + engine.position.inMilliseconds / 1000;
  }

  /// Starts an Audiobookshelf playback session and plays it from the saved position
  /// (or from [startAt] seconds, e.g. a chapter).
  Future<void> playBook(AbsItem item, {double? startAt}) => _switch(() async {
    final s = await _api.absPost('items/${item.id}/play', {
      'deviceInfo': {'clientName': 'Resonance', 'deviceName': 'Resonance'},
      'forceDirectPlay': true,
      'forceTranscode': false,
      'mediaPlayer': 'resonance',
      'supportedMimeTypes': ['audio/flac', 'audio/mpeg', 'audio/mp4', 'audio/ogg', 'audio/aac', 'audio/x-m4b'],
    });
    final coverUrl = _api.absUrl('items/${item.id}/cover', {'width': '600'});
    final book = BookPlayback(
      itemId: item.id,
      sessionId: s['id'],
      title: s['displayTitle'] ?? item.title,
      author: s['displayAuthor'] ?? item.author,
      coverUrl: coverUrl,
      duration: (s['duration'] as num?)?.toDouble() ?? item.duration,
      parts: [
        for (final t in s['audioTracks'])
          BookPart(
            url: _api.absUrl((t['contentUrl'] as String).replaceFirst(RegExp(r'^/api/'), '')),
            start: (t['startOffset'] as num).toDouble(),
            duration: (t['duration'] as num).toDouble(),
          ),
      ],
      chapters: [for (final c in (s['chapters'] as List? ?? const [])) AbsChapter.fromJson(c)],
    );
    final position = startAt ?? (s['currentTime'] as num?)?.toDouble() ?? 0;
    var index = book.parts.lastIndexWhere((p) => p.start <= position);
    if (index < 0) index = 0;
    await _replacePlayback(
      PlayerView(
        loop: LoopMode.off,
        context: 'book:${item.id}',
        book: book,
        speed: state.speed,
        sleepAt: state.sleepAt,
      ),
      [for (final p in book.parts) () => AudioSource.uri(Uri.parse(p.url))],
      index: index,
      position: Duration(milliseconds: ((position - book.parts[index].start) * 1000).round()),
    );
  });

  /// Seek within the whole book (across files).
  Future<void> seekBook(double seconds) async {
    final book = state.book;
    if (book == null) return;
    final target = seconds.clamp(0, book.duration - 1).toDouble();
    var index = book.parts.lastIndexWhere((p) => p.start <= target);
    if (index < 0) index = 0;
    await engine.seek(Duration(milliseconds: ((target - book.parts[index].start) * 1000).round()), index: index);
  }

  Future<void> skipBook(double seconds) => seekBook(bookPosition + seconds);

  Future<void> _syncBook({bool close = false, double? position}) async {
    final book = state.book;
    if (book == null) return;
    final listened = _bookListened;
    _bookListened = 0;
    final body = {'currentTime': position ?? bookPosition, 'timeListened': listened, 'duration': book.duration};
    try {
      await _api.absPost('session/${book.sessionId}/${close ? 'close' : 'sync'}', body);
    } catch (_) {
      // Offline or session expired: keep the time for the next attempt.
      _bookListened += listened;
    }
  }

  Future<void> _closeBook({required double position}) async {
    if (state.book == null) return;
    _bookSync?.cancel();
    _bookSync = null;
    await _syncBook(close: true, position: position);
  }

  Future<void> setSpeed(double speed) async {
    state = _copy(speed: speed);
    await engine.setSpeed(speed);
  }

  // --- sleep timer -------------------------------------------------------------

  Timer? _sleepTimer;

  /// Pause after [duration]; null switches the timer off.
  void setSleepTimer(Duration? duration) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    if (duration == null) {
      state = _copy(sleepAt: () => null);
      return;
    }
    state = _copy(sleepAt: () => DateTime.now().add(duration));
    _sleepTimer = Timer(duration, () {
      pause();
      state = _copy(sleepAt: () => null);
    });
  }

  /// ReplayGain: attenuate loud tracks towards a common level. We can only
  /// lower volume (max 1.0), so gains are offset by a fixed headroom.
  double _gainForTrack(Track? track) {
    if (!normalize || track == null) return 1;
    const headroomDb = -6.0;
    final gainDb = (track.replayGainTrack ?? 0) + headroomDb;
    return math.min(1.0, math.pow(10, gainDb / 20).toDouble());
  }

  void _applyGain() {
    _gainFactor = state.book == null ? _gainForTrack(state.current) : 1;
    engine.setVolume(_gainFactor * userVolume.value);
  }

  int get crossfadeSeconds => engine.crossfadeSeconds;

  void setCrossfade(int seconds) {
    engine.crossfadeSeconds = seconds.clamp(0, 12);
    if (engine.crossfadeSeconds == 0) engine.finishFade().ignore();
    ref.read(prefsProvider).setInt('crossfade_seconds', engine.crossfadeSeconds);
  }

  bool get automix => _automixBeforeJam ?? engine.automix;

  void setAutomix(bool enabled) {
    ref.read(prefsProvider).setBool('automix', enabled);
    if (_automixBeforeJam != null) {
      _automixBeforeJam = enabled;
      return;
    }
    engine.automix = enabled;
    if (!enabled) engine.finishFade().ignore();
  }

  MixPoints? _mixPointsFor(int index) {
    if (index >= state.queue.length) return null;
    final id = state.queue[index].id;
    if (_mixPoints.containsKey(id)) return _mixPoints[id];
    _loadMixPoints(index);
    return null;
  }

  /// Fetch the analyses of this and the next two songs (the server analyzes new ones in about a second each).
  Future<void> _loadMixPoints(int index) async {
    final ids = [
      for (var i = index; i < math.min(index + 3, state.queue.length); i++)
        if (!_mixPoints.containsKey(state.queue[i].id) && !_mixPointsLoading.contains(state.queue[i].id))
          state.queue[i].id,
    ];
    if (ids.isEmpty) return;
    _mixPointsLoading.addAll(ids);
    try {
      final result = await _api.mixPoints(ids);
      for (final id in ids) {
        _mixPoints[id] = result[id];
      }
    } catch (_) {
      // Offline or an older server: these songs get a plain crossfade.
      for (final id in ids) {
        _mixPoints[id] = null;
      }
    } finally {
      _mixPointsLoading.removeAll(ids);
    }
  }

  void setUserVolume(double v) {
    userVolume.value = v.clamp(0, 1);
    engine.setVolume(_gainFactor * userVolume.value);
    _saveVolume?.cancel();
    _saveVolume = Timer(
      const Duration(milliseconds: 500),
      () => ref.read(prefsProvider).setDouble('user_volume', userVolume.value),
    );
  }

  Timer? _saveVolume;

  void setNormalize(bool enabled) {
    normalize = enabled;
    _applyGain();
  }

  void _trackListening(Duration pos) {
    if (_switching || state.station != null) return;
    final delta = (pos - _lastPos).inMilliseconds / 1000;
    // Ignore seeks (big jumps or backwards); faster playback still counts as real time listened.
    if (delta > 0 && delta < 2 * state.speed && engine.playing) {
      if (state.book != null) {
        _bookListened += delta / state.speed;
      } else {
        _listened += delta;
      }
    }
    _lastPos = pos;
  }

  /// Report a play once at least 30 s or half of the track was listened to.
  void _flushPlayReport() {
    final id = _reportTrackId;
    final track = state.queue.where((t) => t.id == id).firstOrNull;
    if (id != null && track != null && (_listened >= 30 || _listened >= track.duration / 2)) {
      _api.reportPlay(id, _listened, context: state.context).ignore();
    }
    _reportTrackId = null;
    _listened = 0;
    _lastPos = Duration.zero;
  }
}

final playerProvider = NotifierProvider<PlayerController, PlayerView>(PlayerController.new);

/// Only correct audible drift in a Jam; small differences come from buffering and network jitter.
bool needsJamSeek(Duration local, Duration expected) => (local - expected).abs() > const Duration(seconds: 1);

final positionProvider = StreamProvider<Duration>((ref) {
  final controller = ref.read(playerProvider.notifier);
  if (ref.watch(playerProvider.select((p) => p.jamRemote))) {
    return Stream.periodic(const Duration(milliseconds: 500), (_) => controller.jamPosition);
  }
  return controller.engine.positionStream;
});

final durationProvider = StreamProvider<Duration?>((ref) {
  if (ref.watch(playerProvider.select((p) => p.jamRemote))) {
    final current = ref.watch(playerProvider.select((p) => p.current));
    return Stream.value(current == null ? null : Duration(milliseconds: (current.duration * 1000).round()));
  }
  return ref.read(playerProvider.notifier).engine.durationStream;
});

/// Position within the whole audiobook in seconds (updates with the player position).
final bookPositionProvider = Provider<double>((ref) {
  ref.watch(positionProvider);
  ref.watch(playerProvider.select((p) => p.index));
  return ref.read(playerProvider.notifier).bookPosition;
});

final playerErrorsProvider = StreamProvider<Object>((ref) => ref.watch(playerProvider.notifier).errors.stream);
