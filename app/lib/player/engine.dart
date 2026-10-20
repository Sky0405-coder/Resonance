import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import 'equalizer.dart';

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

/// AutoMix analysis of a song from the server (seconds).
class MixPoints {
  const MixPoints({required this.bpm, required this.mixIn, required this.mixOut, required this.end});
  final double? bpm;
  final double mixIn;
  final double mixOut;
  final double end;

  factory MixPoints.fromJson(Map<String, dynamic> j) => MixPoints(
    bpm: (j['bpm'] as num?)?.toDouble(),
    mixIn: (j['mix_in'] as num).toDouble(),
    mixOut: (j['mix_out'] as num).toDouble(),
    end: (j['end'] as num).toDouble(),
  );
}

/// How an AutoMix transition runs: the next song starts at [incomingStart] when the current one reaches [start],
/// both overlap for [duration], and the next song plays at [speed] meanwhile so the beats line up.
class AutomixPlan {
  const AutomixPlan({required this.start, required this.incomingStart, required this.duration, required this.speed});
  final Duration start;
  final Duration incomingStart;
  final Duration duration;
  final double speed;

  bool get beatMatched => speed != 1;
}

Duration _seconds(double s) => Duration(microseconds: (s * 1e6).round());

/// Tempos within 8 % (also at double or half time) are matched; otherwise the songs just blend at their mix points.
AutomixPlan? automixPlan(MixPoints outgoing, MixPoints incoming) {
  final overlap = outgoing.end - outgoing.mixOut;
  if (outgoing.mixOut <= 0 || overlap < 2) return null;
  var speed = 1.0;
  if (outgoing.bpm != null && incoming.bpm != null && outgoing.bpm! > 0 && incoming.bpm! > 0) {
    var ratio = outgoing.bpm! / incoming.bpm!;
    while (ratio > 1.5) {
      ratio /= 2;
    }
    while (ratio < 0.75) {
      ratio *= 2;
    }
    // A ratio of exactly 1 needs no tempo change but still starts on the beat.
    if ((ratio - 1).abs() <= 0.08) speed = ratio == 1 ? 1.0000001 : ratio;
  }
  return AutomixPlan(
    start: _seconds(outgoing.mixOut),
    incomingStart: _seconds(incoming.mixIn),
    duration: _seconds(overlap.clamp(3, 14).toDouble()),
    speed: speed,
  );
}

/// Equal-power curves keep the loudness steady while both songs play.
(double, double) automixVolumes({
  required Duration elapsed,
  required Duration duration,
  required double outgoingTarget,
  required double incomingTarget,
}) {
  final t = duration == Duration.zero ? 1.0 : (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  return (outgoingTarget * math.cos(t * math.pi / 2), incomingTarget * math.sin(t * math.pi / 2));
}

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
  _Fade(this.outgoing, this.incoming, this.index, this.duration, {this.plan})
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

  /// AutoMix: the next song is loaded ahead and only starts at the plan's mix point.
  final AutomixPlan? plan;
  bool prepared = false;
  Timer? startTimer;
  bool get started => clock.isRunning || clock.elapsed > Duration.zero;
  final corrected = <int>{};
}

/// Two independent playlists built from factories; only the active player drives the UI.
class PlaybackEngine {
  PlaybackEngine() {
    final android = !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
    _equalizers = android ? [AndroidEqualizer(), AndroidEqualizer()] : [];
    _players = [
      for (var i = 0; i < 2; i++)
        AudioPlayer(audioPipeline: android ? AudioPipeline(androidAudioEffects: [_equalizers[i]]) : null),
    ];
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
          // Position updates come every ~200 ms; a timer hits the mix point more precisely.
          if (fade != null && fade.plan != null && fade.prepared && !fade.started && fade.startTimer == null) {
            final wait = fade.plan!.start - position;
            if (wait <= const Duration(milliseconds: 400)) {
              fade.startTimer = Timer(wait.isNegative ? Duration.zero : wait, () {
                if (_fade == fade && !fade.started && !_disposed) _startAutomix(fade);
              });
            }
          }
          // media_kit reports ~20×/s; the UI, Discord and play counting need ~5×/s. Seeks pass right away.
          final last = _lastPosition;
          if (last == null ||
              _positionClock.elapsedMilliseconds >= 200 ||
              position < last ||
              position - last > const Duration(seconds: 1)) {
            _lastPosition = position;
            _positionClock.reset();
            _positions.add(position);
          }
          _checkFade();
        }),
      );
    }
  }

  late final List<AudioPlayer> _players;
  late final List<AndroidEqualizer> _equalizers;
  EqualizerSettings _equalizer = EqualizerSettings();
  Future<void> _equalizerUpdate = Future.value();
  int _activeIndex = 0;
  AudioPlayer get _active => _players[_activeIndex];
  AudioPlayer get _inactive => _players[1 - _activeIndex];
  final List<StreamSubscription> _subs = [];
  final _states = StreamController<PlayerState>.broadcast(sync: true);
  final _indices = StreamController<int?>.broadcast(sync: true);
  final _positions = StreamController<Duration>.broadcast(sync: true);
  final _positionClock = Stopwatch()..start();
  Duration? _lastPosition;
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

  /// AutoMix: beat-matched transitions at analyzed mix points; songs without analysis get a plain crossfade.
  bool automix = false;
  MixPoints? Function(int index)? mixPointsForIndex;
  double _speed = 1;
  Timer? _speedRamp;

  int get _crossfade => crossfadeSeconds > 0 ? crossfadeSeconds : (automix ? 6 : 0);

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

  Future<void> setEqualizer(EqualizerSettings settings) {
    _equalizer = settings;
    if (!kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows)) {
      JustAudioMediaKit.setAudioFilter(mpvEqualizerFilter(settings));
    }
    return _applyEqualizer();
  }

  Future<void> _applyEqualizer() {
    // Serialize writes so a slower parameter lookup cannot overwrite a newer slider change.
    _equalizerUpdate = _equalizerUpdate.then((_) async {
      if (_disposed) return;
      await Future.wait(
        _equalizers.map((eq) async {
          try {
            await eq.setEnabled(_equalizer.enabled);
            // Before the first source, just_audio's parameter future has not completed yet.
            final parameters = await eq.parameters.timeout(const Duration(milliseconds: 100));
            if (_disposed) return;
            final settings = _equalizer;
            final levels = androidBandLevels(
              settings.gains,
              [for (final band in parameters.bands) (band.centerFrequency * 1000).round()],
              (parameters.minDecibels * 100).round(),
              (parameters.maxDecibels * 100).round(),
            );
            for (var i = 0; i < parameters.bands.length; i++) {
              await parameters.bands[i].setGain(levels[i] / 100);
            }
            await eq.setEnabled(settings.enabled);
          } catch (_) {
            // Audio sessions can be absent or replaced; retry the remembered settings after loading.
          }
        }),
      );
    });
    return _equalizerUpdate;
  }

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
    if (_checkAutomix()) return;
    if (!shouldStartFade(
      crossfadeSeconds: _crossfade,
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
    final fade = _Fade(_active, _inactive, next, Duration(seconds: _crossfade));
    _fade = fade;
    fade.ready = _prepareFade(fade);
  }

  /// Load the next song a few seconds before the mix point; true while AutoMix handles this transition.
  bool _checkAutomix() {
    final index = currentIndex;
    final points = mixPointsForIndex;
    if (!automix || points == null || isBook || index == null || _sources.isEmpty) return false;
    if (loopMode == LoopMode.one || (index + 1 >= _sources.length && loopMode != LoopMode.all)) return false;
    final next = (index + 1) % _sources.length;
    // Looked up early in the song so the analysis can arrive in time.
    final outgoing = points(index);
    final incoming = points(next);
    if (outgoing == null || incoming == null || !playing) return false;
    final plan = automixPlan(outgoing, incoming);
    if (plan == null) return false;
    final ahead = plan.start - const Duration(seconds: 8);
    if (position < ahead) return true;
    if (position >= plan.start + const Duration(seconds: 1)) return false;
    final fade = _Fade(_active, _inactive, next, plan.duration, plan: plan);
    _fade = fade;
    fade.ready = _prepareAutomix(fade);
    return true;
  }

  Future<void> _prepareAutomix(_Fade fade) async {
    final index = currentIndex;
    try {
      _speedRamp?.cancel();
      await fade.incoming.setVolume(0);
      await fade.incoming.load();
      await _applyEqualizer();
      await fade.incoming.seek(fade.plan!.incomingStart, index: fade.index);
      await fade.incoming.setSpeed(_speed * fade.plan!.speed);
      if (_disposed || currentIndex != index || _fade != fade) {
        if (_fade == fade) _fade = null;
        return;
      }
      fade.prepared = true;
    } catch (_) {
      _failedFadeIndex = index;
      if (_fade == fade) _fade = null;
    }
  }

  void _startAutomix(_Fade fade) {
    final plan = fade.plan!;
    fade.incoming.play().ignore();
    fade.clock.start();
    fade.timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (fade.clock.elapsed >= fade.duration) {
        finishFade().ignore();
        return;
      }
      final (outgoing, incoming) = automixVolumes(
        elapsed: fade.clock.elapsed,
        duration: fade.duration,
        outgoingTarget: _targetVolume,
        incomingTarget: _incomingTarget(fade),
      );
      Future.wait([fade.outgoing.setVolume(outgoing), fade.incoming.setVolume(incoming)]).ignore();
      // Starting playback takes a moment; while the next song is still quiet, line its beats up once or twice.
      if (!plan.beatMatched) return;
      for (final at in const [400, 1200]) {
        if (fade.clock.elapsedMilliseconds >= at && fade.corrected.add(at)) {
          final expected = plan.incomingStart + (fade.outgoing.position - plan.start) * plan.speed;
          final error = fade.incoming.position - expected;
          if (error.abs() > const Duration(milliseconds: 20) && error.abs() < const Duration(seconds: 2)) {
            fade.incoming.seek(expected + const Duration(milliseconds: 10)).ignore();
          }
        }
      }
    });
  }

  /// After a beat-matched transition the new song drifts back to its own tempo.
  void _rampSpeed(AudioPlayer player, double from) {
    _speedRamp?.cancel();
    const steps = 32;
    var step = 0;
    _speedRamp = Timer.periodic(const Duration(milliseconds: 250), (timer) {
      step++;
      final done = step >= steps || player != _active || _disposed;
      player.setSpeed(done ? _speed : from + (_speed - from) * step / steps).ignore();
      if (done) timer.cancel();
    });
  }

  Future<void> _prepareFade(_Fade fade) async {
    final index = currentIndex;
    try {
      await fade.incoming.setVolume(0);
      // Loading an idle playlist resets its initial index, so seek after loading.
      await fade.incoming.load();
      await _applyEqualizer();
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
    fade.startTimer?.cancel();
    if (!fade.started) {
      // A user action (or the song ending early) came before the mix point: drop the preloaded next song.
      _fade = null;
      _emitCurrent();
      await fade.incoming.pause();
      await fade.incoming.setSpeed(_speed);
      return;
    }
    _editing = true;
    try {
      await fade.outgoing.pause();
      await fade.outgoing.setVolume(0);
      _targetVolume = _incomingTarget(fade);
      await fade.incoming.setVolume(_targetVolume);
      _activeIndex = 1 - _activeIndex;
      _fade = null;
      if (fade.plan?.beatMatched ?? false) _rampSpeed(fade.incoming, _speed * fade.plan!.speed);
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

  Future<void> setSpeed(double speed) {
    _speed = speed;
    _speedRamp?.cancel();
    return Future.wait(_players.map((p) => p.setSpeed(speed)));
  }

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
        await _applyEqualizer();
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
    _fade?.startTimer?.cancel();
    _speedRamp?.cancel();
    for (final sub in _subs) {
      await sub.cancel();
    }
    await Future.wait(_players.map((p) => p.dispose()));
    for (final stream in [_states, _indices, _positions, _durations, _loops, _events, _errors]) {
      await stream.close();
    }
  }
}
