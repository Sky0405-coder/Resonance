import '../l10n/locale.dart';
import '../l10n/l10n.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'engine.dart';
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

/// Snapshot of what the UI needs to render the engine.
class PlayerView {
  const PlayerView({
    this.queue = const [],
    this.index,
    this.playing = false,
    this.buffering = false,
    this.shuffle = false,
    this.loop = LoopMode.off,
    this.context,
    this.book,
    this.station,
    this.speed = 1,
    this.sleepAt,
  });

  final List<Track> queue;
  final int? index;
  final bool playing;
  final bool buffering;
  final bool shuffle;
  final LoopMode loop;
  // Where playback was started from, e.g. "album:<id>".
  final String? context;
  // Set while an audiobook is playing instead of music (queue is empty then).
  final BookPlayback? book;
  final Station? station;
  final double speed;
  // Sleep timer: pause at this time (null = off).
  final DateTime? sleepAt;

  Track? get current => index != null && index! < queue.length ? queue[index!] : null;
}

/// Owns the [PlaybackEngine]; one instance for the whole app.
class PlayerController extends Notifier<PlayerView> {
  PlayerController({PlaybackEngine? engine}) : engine = engine ?? PlaybackEngine();

  final PlaybackEngine engine;
  final errors = StreamController<Object>.broadcast();
  Timer? _stationRetry;
  bool _stationRetried = false;
  bool _stationFailed = false;
  int _stationGeneration = 0;
  List<Track> _unshuffled = [];
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

  // Serialize replacements so a late load cannot overwrite another request.
  Future<void> _switch(Future<void> Function() action) {
    final result = _pendingSwitch.then((_) => action());
    _pendingSwitch = result.catchError((Object _) {});
    return result;
  }

  AppLocalizations get _l10n => lookupAppLocalizations(ref.read(appLocaleProvider));

  ApiClient get _api => ref.read(apiProvider);

  @override
  PlayerView build() {
    final prefs = ref.read(prefsProvider);
    normalize = prefs.getBool('normalize_volume') ?? true;
    engine.crossfadeSeconds = (prefs.getInt('crossfade_seconds') ?? 0).clamp(0, 12);
    engine.targetVolumeForIndex = (index) => userVolume.value * _gainForTrack(state.queue[index]);
    _subs.addAll([
      engine.playerStateStream.listen((s) {
        if (_switching) return;
        // Save the audiobook position right away when pausing.
        if (state.playing && !s.playing && state.book != null) _syncBook().ignore();
        state = _copy(
          playing: s.playing,
          buffering: s.processingState == ProcessingState.loading || s.processingState == ProcessingState.buffering,
        );
      }),
      engine.currentIndexStream.listen((i) {
        if (_switching) return;
        if (state.book != null) {
          state = _copy(index: i);
          return;
        }
        _flushPlayReport();
        state = _copy(index: i);
        _applyGain();
        _reportTrackId = state.current?.id;
      }),
      engine.loopModeStream.listen((v) {
        if (!_switching) state = _copy(loop: v);
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
      errors.close();
      _sleepTimer?.cancel();
      engine.dispose();
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
    String? context,
    LoopMode? loop,
    double? speed,
    DateTime? Function()? sleepAt,
  }) => PlayerView(
    queue: queue ?? state.queue,
    index: index ?? state.index,
    playing: playing ?? state.playing,
    buffering: buffering ?? state.buffering,
    shuffle: shuffle ?? state.shuffle,
    loop: loop ?? state.loop,
    context: context ?? state.context,
    book: state.book,
    station: state.station,
    speed: speed ?? state.speed,
    sleepAt: sleepAt == null ? state.sleepAt : sleepAt(),
  );

  SourceFactory _source(Track t) => () {
    final offline = kIsWeb ? null : ref.read(offlineProvider);
    final file = offline?.filePath(t.id);
    return file == null ? AudioSource.uri(Uri.parse(_api.streamUrl(t.id))) : AudioSource.file(file);
  };

  /// Replace the queue and start playing at [index]. Shuffle is a global toggle (like Spotify): when it is on,
  /// the queue is shuffled around the start track, which is random if no [index] is given.
  Future<void> playTracks(List<Track> tracks, {int? index, String? context}) => _switch(() async {
    if (tracks.isEmpty) return;
    final shuffle = state.shuffle;
    final chosen = index ?? (shuffle ? math.Random().nextInt(tracks.length) : 0);
    final queue = shuffle ? shuffleQueue(tracks, chosen) : tracks;
    await _replacePlayback(
      PlayerView(
        queue: List.unmodifiable(queue),
        shuffle: shuffle,
        loop: state.book == null ? state.loop : LoopMode.off,
        context: context,
        sleepAt: state.sleepAt,
      ),
      [for (final t in queue) _source(t)],
      index: shuffle ? 0 : chosen,
    );
    _unshuffled = [...tracks];
  });

  Future<void> replaceUpcoming(List<Track> tracks, {required String context}) {
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
        state = _copy(queue: List.unmodifiable(queue), index: 0, context: context);
      } finally {
        _switching = false;
      }
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
    state = PlayerView(
      queue: next.queue,
      index: engine.currentIndex,
      playing: engine.playing,
      shuffle: next.shuffle,
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
    await engine.finishFade();
    final at = (state.index ?? -1) + 1;
    await _insert(at, t);
  }

  Future<void> addToQueue(Track t) => _insert(state.queue.length, t);

  Future<void> _insert(int at, Track t) async {
    if (state.queue.isEmpty || state.book != null) return playTracks([t]);
    await engine.finishFade();
    state = _copy(queue: List.unmodifiable([...state.queue]..insert(at, t)));
    _unshuffled.insert(state.shuffle ? _unshuffled.length : at, t);
    await engine.insert(at, _source(t));
  }

  Future<void> removeAt(int i) async {
    await engine.finishFade();
    _unshuffled.remove(state.queue[i]);
    state = _copy(queue: List.unmodifiable([...state.queue]..removeAt(i)));
    await engine.removeAt(i);
  }

  void togglePlay() => engine.playing ? pause() : play();

  Future<void> play() => engine.play();

  Future<void> pause() async {
    _stationGeneration++;
    _stationRetry?.cancel();
    _stationRetry = null;
    await engine.pause();
  }

  Future<void> stop() async {
    _stationGeneration++;
    _stationRetry?.cancel();
    _stationRetry = null;
    await engine.stop();
  }

  Future<void> next() async {
    if (state.station == null) await engine.seekToNext();
  }

  /// Like Spotify: restart the track unless we're in its first 3 seconds.
  Future<void> previous() async {
    if (state.station != null) return;
    await engine.finishFade();
    if (engine.position > const Duration(seconds: 3) || !engine.hasPrevious) {
      await engine.seek(Duration.zero);
    } else {
      await engine.seekToPrevious();
    }
  }

  Future<void> jumpTo(int index) async {
    if (state.station == null) await engine.seek(Duration.zero, index: index);
  }

  Future<void> seek(Duration d) async {
    if (state.station == null) await engine.seek(d);
  }

  Future<void> toggleShuffle() => _switch(() => _setShuffle(!state.shuffle));

  Future<void> setShuffle(bool enabled) => _switch(() => _setShuffle(enabled));

  Future<void> _setShuffle(bool enabled) async {
    if (state.station != null) return;
    await engine.finishFade();
    if (enabled == state.shuffle) return;
    final current = state.current;
    if (current == null) {
      state = _copy(shuffle: enabled);
      return;
    }
    if (enabled) _unshuffled = [...state.queue];
    final (queue, index) = enabled
        ? (shuffleQueue(state.queue, state.index!), 0)
        : unshuffleQueue(_unshuffled, current);
    _switching = true;
    try {
      await engine.setSources([for (final t in queue) _source(t)], initialIndex: index, preserveCurrent: true);
      state = _copy(queue: List.unmodifiable(queue), index: index, shuffle: enabled);
    } finally {
      _switching = false;
    }
  }

  Future<void> setLoop(LoopMode mode) async {
    if (state.station == null) await engine.setLoopMode(mode);
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

  void setUserVolume(double v) {
    userVolume.value = v.clamp(0, 1);
    engine.setVolume(_gainFactor * userVolume.value);
  }

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

final positionProvider = StreamProvider<Duration>((ref) => ref.read(playerProvider.notifier).engine.positionStream);
final durationProvider = StreamProvider<Duration?>((ref) => ref.read(playerProvider.notifier).engine.durationStream);

/// Position within the whole audiobook in seconds (updates with the player position).
final bookPositionProvider = Provider<double>((ref) {
  ref.watch(positionProvider);
  ref.watch(playerProvider.select((p) => p.index));
  return ref.read(playerProvider.notifier).bookPosition;
});

final playerErrorsProvider = StreamProvider<Object>((ref) => ref.watch(playerProvider.notifier).errors.stream);
