import '../l10n/locale.dart';
import '../l10n/l10n.dart';

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../core/api.dart';
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

/// An Audiobookshelf playback session that is currently loaded into the player.
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

/// Snapshot of what the UI needs to render the player.
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
  final double speed;
  // Sleep timer: pause at this time (null = off).
  final DateTime? sleepAt;

  Track? get current => index != null && index! < queue.length ? queue[index!] : null;
}

/// Owns the [AudioPlayer]; one instance for the whole app.
class PlayerController extends Notifier<PlayerView> {
  final AudioPlayer player = AudioPlayer();
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
    _subs.addAll([
      player.playerStateStream.listen((s) {
        if (_switching) return;
        // Save the audiobook position right away when pausing.
        if (state.playing && !s.playing && state.book != null) _syncBook().ignore();
        state = _copy(
          playing: s.playing,
          buffering: s.processingState == ProcessingState.loading || s.processingState == ProcessingState.buffering,
        );
      }),
      player.currentIndexStream.listen((i) {
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
      player.shuffleModeEnabledStream.listen((v) {
        if (!_switching) state = _copy(shuffle: v);
      }),
      player.loopModeStream.listen((v) {
        if (!_switching) state = _copy(loop: v);
      }),
      player.positionStream.listen(_trackListening),
    ]);
    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
      _bookSync?.cancel();
      _sleepTimer?.cancel();
      player.dispose();
    });
    return const PlayerView();
  }

  PlayerView _copy({
    List<Track>? queue,
    int? index,
    bool? playing,
    bool? buffering,
    bool? shuffle,
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
    context: state.context,
    book: state.book,
    speed: speed ?? state.speed,
    sleepAt: sleepAt == null ? state.sleepAt : sleepAt(),
  );

  AudioSource _source(Track t) => AudioSource.uri(
    Uri.parse(_api.streamUrl(t.id)),
    tag: MediaItem(
      id: t.id,
      title: t.title,
      artist: t.artistCredit,
      album: t.album.name,
      duration: t.length,
      artUri: Uri.parse(_api.coverUrl(t.album.id, size: 600)),
    ),
  );

  /// Replace the queue and start playing at [index].
  Future<void> playTracks(List<Track> tracks, {int index = 0, String? context, bool shuffle = false}) =>
      _switch(() async {
        if (tracks.isEmpty) return;
        await _replacePlayback(
          PlayerView(
            queue: List.unmodifiable(tracks),
            shuffle: shuffle,
            loop: state.book == null ? state.loop : LoopMode.off,
            context: context,
            sleepAt: state.sleepAt,
          ),
          [for (final t in tracks) _source(t)],
          index: shuffle ? math.Random().nextInt(tracks.length) : index,
        );
      });

  /// Commit metadata only after loading, and reload the previous sources on failure.
  Future<void> _replacePlayback(
    PlayerView next,
    List<AudioSource> sources, {
    required int index,
    Duration position = Duration.zero,
  }) async {
    final previous = state;
    final previousSources = List<AudioSource>.of(player.audioSources);
    final previousIndex = player.currentIndex ?? 0;
    final previousPosition = player.position;
    final previousBookPosition = bookPosition;
    _switching = true;
    try {
      await player.pause();
      // just_audio_web caches the root playlist by ID. setAudioSources reuses
      // that ID; stopping releases the cached platform playlist before loading.
      await player.stop();
      await player.setShuffleModeEnabled(next.shuffle);
      await player.setLoopMode(next.loop);
      await player.setSpeed(next.speed);
      await player.setAudioSources(sources, initialIndex: index, initialPosition: position, preload: true);
      if (next.shuffle) await player.shuffle();
    } catch (e, st) {
      debugPrint('Playback replacement failed: $e\n$st');
      try {
        await player.stop();
        await player.setShuffleModeEnabled(previous.shuffle);
        await player.setLoopMode(previous.loop);
        await player.setSpeed(previous.speed);
        if (previousSources.isNotEmpty) {
          await player.setAudioSources(
            previousSources,
            initialIndex: previousIndex,
            initialPosition: previousPosition,
            preload: true,
          );
        }
      } catch (restoreError) {
        debugPrint('Playback restore failed: $restoreError');
        await player.stop();
      }
      _switching = false;
      state = _copy(playing: false, buffering: false);
      _lastPos = player.position;
      if (previous.playing && player.processingState == ProcessingState.ready) player.play();
      throw ApiException(next.book == null ? _l10n.playerMusicLoadError : _l10n.playerAudiobookLoadError);
    }
    // Use the old position: the player's sources now belong to the new item.
    await _closeBook(position: previousBookPosition);
    _flushPlayReport();
    state = PlayerView(
      queue: next.queue,
      index: player.currentIndex,
      playing: player.playing,
      shuffle: next.shuffle,
      loop: next.loop,
      context: next.context,
      book: next.book,
      speed: next.speed,
      sleepAt: state.sleepAt,
    );
    _bookListened = 0;
    _lastPos = player.position;
    _reportTrackId = state.current?.id;
    _switching = false;
    _applyGain();
    if (state.book != null) {
      _bookSync = Timer.periodic(const Duration(seconds: 15), (_) {
        if (!_switching && player.playing) _syncBook().ignore();
      });
    }
    player.play();
  }

  Future<void> playNext(Track t) async {
    final at = (state.index ?? -1) + 1;
    await _insert(at, t);
  }

  Future<void> addToQueue(Track t) => _insert(state.queue.length, t);

  Future<void> _insert(int at, Track t) async {
    if (state.queue.isEmpty || state.book != null) return playTracks([t]);
    state = _copy(queue: List.unmodifiable([...state.queue]..insert(at, t)));
    await player.insertAudioSource(at, _source(t));
  }

  Future<void> removeAt(int i) async {
    state = _copy(queue: List.unmodifiable([...state.queue]..removeAt(i)));
    await player.removeAudioSourceAt(i);
  }

  void togglePlay() => player.playing ? player.pause() : player.play();

  Future<void> next() => player.seekToNext();

  /// Like Spotify: restart the track unless we're in its first 3 seconds.
  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  Future<void> jumpTo(int index) => player.seek(Duration.zero, index: index);

  Future<void> seek(Duration d) => player.seek(d);

  Future<void> toggleShuffle() async {
    final enable = !player.shuffleModeEnabled;
    if (enable) await player.shuffle();
    await player.setShuffleModeEnabled(enable);
  }

  Future<void> cycleLoop() => player.setLoopMode(switch (player.loopMode) {
    LoopMode.off => LoopMode.all,
    LoopMode.all => LoopMode.one,
    LoopMode.one => LoopMode.off,
  });

  void setLikedLocally(String trackId, bool liked) {
    state = _copy(
      queue: List.unmodifiable([for (final t in state.queue) t.id == trackId ? t.copyWith(liked: liked) : t]),
    );
  }

  // --- audiobooks ------------------------------------------------------------

  Timer? _bookSync;
  double _bookListened = 0;

  /// Position within the whole book in seconds.
  double get bookPosition {
    final book = state.book;
    final i = player.currentIndex;
    if (book == null || i == null || i >= book.parts.length) return 0;
    return book.parts[i].start + player.position.inMilliseconds / 1000;
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
      [
        for (final (i, p) in book.parts.indexed)
          AudioSource.uri(
            Uri.parse(p.url),
            tag: MediaItem(
              id: '${item.id}:$i',
              title: book.title,
              artist: book.author,
              album: book.parts.length > 1 ? _l10n.playerBookPart(i + 1, book.parts.length) : null,
              duration: Duration(milliseconds: (p.duration * 1000).round()),
              artUri: Uri.parse(coverUrl),
            ),
          ),
      ],
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
    await player.seek(Duration(milliseconds: ((target - book.parts[index].start) * 1000).round()), index: index);
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
    await player.setSpeed(speed);
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
      player.pause();
      state = _copy(sleepAt: () => null);
    });
  }

  /// ReplayGain: attenuate loud tracks towards a common level. We can only
  /// lower volume (max 1.0), so gains are offset by a fixed headroom.
  void _applyGain() {
    final t = state.current;
    if (state.book != null) {
      _gainFactor = 1;
      player.setVolume(userVolume.value);
      return;
    }
    if (!normalize || t == null) {
      _gainFactor = 1;
    } else {
      const headroomDb = -6.0;
      final gainDb = (t.replayGainTrack ?? 0) + headroomDb;
      _gainFactor = math.min(1.0, math.pow(10, gainDb / 20).toDouble());
    }
    player.setVolume(_gainFactor * userVolume.value);
  }

  void setUserVolume(double v) {
    userVolume.value = v.clamp(0, 1);
    player.setVolume(_gainFactor * userVolume.value);
  }

  void setNormalize(bool enabled) {
    normalize = enabled;
    _applyGain();
  }

  void _trackListening(Duration pos) {
    if (_switching) return;
    final delta = (pos - _lastPos).inMilliseconds / 1000;
    // Ignore seeks (big jumps or backwards); faster playback still counts as real time listened.
    if (delta > 0 && delta < 2 * state.speed && player.playing) {
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

final positionProvider = StreamProvider<Duration>((ref) => ref.read(playerProvider.notifier).player.positionStream);
final durationProvider = StreamProvider<Duration?>((ref) => ref.read(playerProvider.notifier).player.durationStream);

/// Position within the whole audiobook in seconds (updates with the player position).
final bookPositionProvider = Provider<double>((ref) {
  ref.watch(positionProvider);
  ref.watch(playerProvider.select((p) => p.index));
  return ref.read(playerProvider.notifier).bookPosition;
});
