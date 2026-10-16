import 'dart:async';
import 'dart:math' as math;

import 'package:just_audio/just_audio.dart';

typedef SourceFactory = AudioSource Function();

(double, double) fadeVolumes({
  required Duration elapsed,
  required Duration crossfade,
  required double outgoingTarget,
  required double incomingTarget,
}) {
  final t = crossfade == Duration.zero ? 1.0 : (elapsed.inMicroseconds / crossfade.inMicroseconds).clamp(0.0, 1.0);
  return (outgoingTarget * (1 - t), incomingTarget * t);
}

bool shouldStartFade({
  required int crossfadeSeconds,
  required bool playing,
  required bool isBook,
  required LoopMode loopMode,
  required int? index,
  required int length,
  required Duration position,
  required Duration? duration,
}) =>
    crossfadeSeconds > 0 &&
    playing &&
    !isBook &&
    loopMode != LoopMode.one &&
    index != null &&
    length > 0 &&
    (index + 1 < length || loopMode == LoopMode.all) &&
    duration != null &&
    duration > Duration(seconds: 2 * crossfadeSeconds) &&
    position >= duration - Duration(seconds: crossfadeSeconds) &&
    position < duration;

List<T> shuffleQueue<T>(List<T> queue, int currentIndex, {math.Random? random}) {
  final rest = [...queue]..removeAt(currentIndex);
  rest.shuffle(random);
  return [queue[currentIndex], ...rest];
}

(List<T>, int) unshuffleQueue<T>(List<T> original, T current) => ([...original], original.indexOf(current));

(List<T>, List<T>) replaceUpcomingQueue<T>(
  T current,
  List<T> tracks, {
  required String Function(T) id,
  required bool shuffle,
  math.Random? random,
}) {
  final original = [current, ...tracks.where((track) => id(track) != id(current))];
  return (shuffle ? shuffleQueue(original, 0, random: random) : [...original], original);
}

class _Fade {
  _Fade(this.outgoing, this.incoming, this.index, this.duration)
    : outgoingIndex = outgoing.currentIndex,
      outgoingPosition = outgoing.position;
  final AudioPlayer outgoing;
  final AudioPlayer incoming;
  final int index;
  final Duration duration;
  final int? outgoingIndex;
  final Duration outgoingPosition;
  final clock = Stopwatch();
  late final Future<void> ready;
  Timer? timer;
}

/// Two independent playlists built from factories; only the active player drives the UI.
class PlaybackEngine {
  PlaybackEngine() {
    for (final player in _players) {
      _forward(player, player.playerStateStream, _states);
      _subs.add(
        player.errorStream.listen((error) {
          if (player == _active && !_editing) _errors.add(error);
        }),
      );
      _subs.add(
        player.currentIndexStream.listen((index) {
          if (player != _active || _editing) return;
          final fade = _fade;
          if (fade != null && index != fade.outgoingIndex) {
            finishFade().ignore();
          } else {
            _indices.add(index);
          }
        }),
      );
      _forward(player, player.durationStream, _durations);
      _forward(player, player.loopModeStream, _loops);
      _forward(player, player.playbackEventStream, _events);
      _subs.add(
        player.positionStream.listen((position) {
          if (player != _active || _editing) return;
          final fade = _fade;
          if (fade != null && (player.currentIndex != fade.outgoingIndex || position < fade.outgoingPosition)) {
            finishFade().ignore();
            return;
          }
          _positions.add(position);
          _checkFade();
        }),
      );
    }
  }

  final _players = [AudioPlayer(), AudioPlayer()];
  int _activeIndex = 0;
  AudioPlayer get _active => _players[_activeIndex];
  AudioPlayer get _inactive => _players[1 - _activeIndex];
  final List<StreamSubscription> _subs = [];
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final _indices = StreamController<int?>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _durations = StreamController<Duration?>.broadcast(sync: true);
  final _loops = StreamController<LoopMode>.broadcast(sync: true);
  final _events = StreamController<PlaybackEvent>.broadcast(sync: true);
  final _errors = StreamController<Object>.broadcast();
  Stream<Object> get errorStream => _errors.stream;
  List<SourceFactory> _sources = [];
  bool _editing = false;
  bool _disposed = false;
  double _targetVolume = 1;
  _Fade? _fade;
  Future<void>? _finishingFade;
  int? _failedFadeIndex;

  int crossfadeSeconds = 0;
  bool isBook = false;
  double Function(int index)? targetVolumeForIndex;

  void _forward<T>(AudioPlayer player, Stream<T> stream, StreamController<T> controller) {
    _subs.add(
      stream.listen(
        (value) {
          if (player == _active && !_editing && (_fade == null || player.currentIndex == _fade!.outgoingIndex)) {
            controller.add(value);
          }
        },
        onError: (Object error) {
          if (player == _active && !_editing && controller == _events) _errors.add(error);
        },
      ),
    );
  }

  Stream<T> _values<T>(StreamController<T> controller, T Function() current) => Stream<T>.multi((sink) {
    sink.add(current());
    final sub = controller.stream.listen(sink.add, onError: sink.addError, onDone: sink.close);
    sink.onCancel = sub.cancel;
  }, isBroadcast: true);

  late final playerStateStream = _values(_states, () => _active.playerState);
  late final currentIndexStream = _values(_indices, () => currentIndex);
  late final positionStream = _values(_positions, () => position);
  late final durationStream = _values(_durations, () => duration);
  late final loopModeStream = _values(_loops, () => loopMode);
  late final playbackEventStream = _values(_events, () => _active.playbackEvent);

  bool get playing => _active.playing;
  ProcessingState get processingState => _active.processingState;
  Duration get position => _active.position;
  Duration get bufferedPosition => _active.bufferedPosition;
  Duration? get duration => _active.duration;
  int? get currentIndex => _active.currentIndex;
  LoopMode get loopMode => _active.loopMode;
  double get speed => _active.speed;
  bool get hasPrevious => _active.hasPrevious;
  List<SourceFactory> get audioSources => List.unmodifiable(_sources);

  void _emitCurrent() {
    _indices.add(currentIndex);
    _states.add(_active.playerState);
    _positions.add(position);
    _durations.add(duration);
    _loops.add(loopMode);
    _events.add(_active.playbackEvent);
  }

  void _checkFade() {
    if (_disposed || _editing || _fade != null || _finishingFade != null) return;
    if (_failedFadeIndex != null && _failedFadeIndex != currentIndex) _failedFadeIndex = null;
    if (_failedFadeIndex == currentIndex) return;
    if (!shouldStartFade(
      crossfadeSeconds: crossfadeSeconds,
      playing: playing,
      isBook: isBook,
      loopMode: loopMode,
      index: currentIndex,
      length: _sources.length,
      position: position,
      duration: duration,
    )) {
      return;
    }
    final next = (currentIndex! + 1) % _sources.length;
    final fade = _Fade(_active, _inactive, next, Duration(seconds: crossfadeSeconds));
    _fade = fade;
    fade.ready = _prepareFade(fade);
  }

  Future<void> _prepareFade(_Fade fade) async {
    final index = currentIndex;
    try {
      await fade.incoming.setVolume(0);
      // Loading an idle playlist resets its initial index, so seek after loading.
      await fade.incoming.load();
      await fade.incoming.seek(Duration.zero, index: fade.index);
      // A slow load may have outlived the outgoing item.
      if (_disposed || currentIndex != index) {
        if (_fade == fade) _fade = null;
        if (!_disposed) _emitCurrent();
        return;
      }
      fade.incoming.play().ignore();
      fade.clock.start();
      fade.timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
        if (fade.clock.elapsed >= fade.duration) {
          finishFade().ignore();
        } else {
          _applyFadeVolumes(fade).ignore();
        }
      });
    } catch (_) {
      await fade.incoming.pause();
      _failedFadeIndex = index;
      if (_fade == fade) _fade = null;
    }
  }

  double _incomingTarget(_Fade fade) => targetVolumeForIndex?.call(fade.index) ?? _targetVolume;

  Future<void> _applyFadeVolumes(_Fade fade) async {
    final (outgoing, incoming) = fadeVolumes(
      elapsed: fade.clock.elapsed,
      crossfade: fade.duration,
      outgoingTarget: _targetVolume,
      incomingTarget: _incomingTarget(fade),
    );
    await Future.wait([fade.outgoing.setVolume(outgoing), fade.incoming.setVolume(incoming)]);
  }

  /// Settle the incoming track before applying an explicit user action.
  Future<void> finishFade() {
    if (_finishingFade != null) return _finishingFade!;
    final fade = _fade;
    if (fade == null) return Future.value();
    final result = _finishFade(fade);
    _finishingFade = result;
    return result.whenComplete(() => _finishingFade = null);
  }

  Future<void> _finishFade(_Fade fade) async {
    await fade.ready;
    if (_fade != fade || _disposed) return;
    fade.timer?.cancel();
    _editing = true;
    try {
      await fade.outgoing.pause();
      await fade.outgoing.setVolume(0);
      _targetVolume = _incomingTarget(fade);
      await fade.incoming.setVolume(_targetVolume);
      _activeIndex = 1 - _activeIndex;
      _fade = null;
    } finally {
      _editing = false;
      _emitCurrent();
    }
    // Release the old playlist's decoder; its factories remain ready for the next fade.
    await fade.outgoing.stop();
  }

  Future<void> play() async {
    await finishFade();
    return _active.play();
  }

  Future<void> pause() async {
    await finishFade();
    await _active.pause();
  }

  Future<void> stop() async {
    await finishFade();
    await Future.wait(_players.map((p) => p.stop()));
  }

  Future<void> seek(Duration position, {int? index}) async {
    await finishFade();
    await _active.seek(position, index: index);
  }

  Future<void> seekToNext() async {
    await finishFade();
    await _active.seekToNext();
  }

  Future<void> seekToPrevious() async {
    await finishFade();
    await _active.seekToPrevious();
  }

  Future<void> setLoopMode(LoopMode mode) async {
    await finishFade();
    await Future.wait(_players.map((p) => p.setLoopMode(mode)));
  }

  Future<void> setSpeed(double speed) => Future.wait(_players.map((p) => p.setSpeed(speed)));

  Future<void> setVolume(double volume) async {
    _targetVolume = volume;
    final fade = _fade;
    if (fade == null) {
      await _active.setVolume(volume);
    } else if (fade.clock.isRunning) {
      await _applyFadeVolumes(fade);
    }
  }

  Future<void> insert(int index, SourceFactory source) async {
    await finishFade();
    _sources.insert(index, source);
    await Future.wait(_players.map((p) => p.insertAudioSource(index, source())));
  }

  Future<void> removeAt(int index) async {
    await finishFade();
    _sources.removeAt(index);
    await Future.wait(_players.map((p) => p.removeAudioSourceAt(index)));
  }

  Future<void> setSources(
    List<SourceFactory> sources, {
    required int initialIndex,
    Duration initialPosition = Duration.zero,
    bool preserveCurrent = false,
  }) async {
    await finishFade();
    _editing = true;
    _failedFadeIndex = null;
    try {
      await _inactive.stop();
      for (final player in _players) {
        await player.setShuffleModeEnabled(false);
        if (player == _active && preserveCurrent && currentIndex != null) {
          final index = currentIndex!;
          await player.removeAudioSourceRange(index + 1, player.audioSources.length);
          await player.removeAudioSourceRange(0, index);
          await player.insertAudioSources(0, [for (final source in sources.take(initialIndex)) source()]);
          await player.addAudioSources([for (final source in sources.skip(initialIndex + 1)) source()]);
        } else {
          await player.setAudioSources(
            [for (final source in sources) source()],
            initialIndex: initialIndex,
            initialPosition: initialPosition,
            preload: player == _active,
          );
        }
      }
      _sources = [...sources];
    } finally {
      _editing = false;
      _emitCurrent();
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _fade?.timer?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    await Future.wait(_players.map((p) => p.dispose()));
    for (final stream in [_states, _indices, _positions, _durations, _loops, _events, _errors]) {
      await stream.close();
    }
  }
}
