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
  const MixPoints({
    required this.bpm,
    required this.mixIn,
    required this.mixOut,
    required this.end,
    this.key,
    this.keyConfidence,
    this.vocalsIn,
    this.vocalsOut,
  });
  final double? bpm;
  final double mixIn;
  final double mixOut;
  final double end;

  /// Musical key as a Camelot code ("8A" = A minor, "8B" = C major), when the server could tell.
  final String? key;
  final double? keyConfidence;
  final double? vocalsIn;
  final double? vocalsOut;

  /// The key only when the analysis was reasonably sure (a wrong key would cause needless filter-outs).
  String? get reliableKey => (keyConfidence ?? 0) >= 0.1 ? key : null;

  factory MixPoints.fromJson(Map<String, dynamic> j) => MixPoints(
    bpm: (j['bpm'] as num?)?.toDouble(),
    mixIn: (j['mix_in'] as num).toDouble(),
    mixOut: (j['mix_out'] as num).toDouble(),
    end: (j['end'] as num).toDouble(),
    key: j['key'] as String?,
    keyConfidence: (j['key_confidence'] as num?)?.toDouble(),
    vocalsIn: (j['vocals_in'] as num?)?.toDouble(),
    vocalsOut: (j['vocals_out'] as num?)?.toDouble(),
  );
}

/// How an AutoMix transition runs: the next song starts at [incomingStart] when the current one reaches [start],
/// both overlap for [duration], and the next song plays at [speed] meanwhile so the beats line up. Like a DJ, larger
/// tempo differences meet in the middle: the current song drifts to [outgoingSpeed] in the seconds before.
class AutomixPlan {
  const AutomixPlan({
    required this.start,
    required this.incomingStart,
    required this.duration,
    required this.speed,
    required this.bassSwap,
    this.outgoingSpeed = 1,
    this.filterOut = false,
  });
  final Duration start;
  final Duration incomingStart;
  final Duration duration;
  final double speed;
  final double outgoingSpeed;

  /// Song time of the incoming song per song time of the outgoing one while both play.
  double get ratio => speed / outgoingSpeed;

  /// When the bass moves from the outgoing to the incoming song (on a beat near the middle of the overlap).
  final Duration bassSwap;

  /// Songs that do not go together (tempo too far apart or clashing keys) do not blend: the current song is
  /// filtered away from the bass up, with an echo on the beat on the desktop, while the next one comes in quickly.
  final bool filterOut;

  bool get beatMatched => speed != 1;
}

Duration _seconds(double s) => Duration(microseconds: (s * 1e6).round());

/// Tempo differences up to this are matched (time-stretched without changing the pitch); above
/// [automixShareTempoChange] both songs move halfway, so neither changes by more than about 8 %.
const automixMaxTempoChange = 0.16;
const automixShareTempoChange = 0.04;

/// The song without the bass also loses some of its vocal range, so two voices clash less: bands up to
/// [automixBassCutoff] Hz drop by [automixBassCutDb], bands from 500 Hz to 4 kHz by [automixVocalCutDb].
const automixBassCutoff = 250.0;
const automixBassCutDb = -15.0;
const automixVocalCutDb = -7.0;
const automixBassFilter = 'lavfi=[bass=g=-15:f=180:w=0.6,equalizer=f=1500:t=o:w=2.5:g=-7]';

/// Camelot codes that mix well: the same key, a neighbour on the wheel (±1, 12 wraps to 1), or the relative
/// major/minor (same number, other letter).
bool camelotCompatible(String a, String b) {
  final ma = RegExp(r'^(1[0-2]|[1-9])([AB])$').firstMatch(a);
  final mb = RegExp(r'^(1[0-2]|[1-9])([AB])$').firstMatch(b);
  if (ma == null || mb == null) return false;
  final na = int.parse(ma[1]!), nb = int.parse(mb[1]!);
  if (ma[2] != mb[2]) return na == nb;
  final distance = (na - nb).abs() % 12;
  return distance <= 1 || distance == 11;
}

/// The filter-out transition (tempos too far apart): about eight beats, between 4 and 8 seconds.
Duration _filterOutDuration(double? bpm) =>
    _seconds((bpm != null && bpm > 0 ? 8 * 60 / bpm : 6.0).clamp(4.0, 8.0).toDouble());

/// A blend runs for about [automixBlendBeats] beats (16 s at 120 BPM), between [automixMinSeconds] and
/// [automixMaxSeconds]; with clashing keys only half as long, so the harmonies rub briefly.
const automixBlendBeats = 32;
const automixMinSeconds = 6.0;
const automixMaxSeconds = 20.0;

/// Tempos within 16 % (also at double or half time) are matched and blended; tempos further apart filter the current
/// song out. The blend starts at the analyzed mix-out point, earlier by whole bars when the outro is shorter than
/// the blend (never in the first half of the song). [minSeconds] (the crossfade setting) asks for up to 30 seconds.
///
/// Vocals (from the server's song analysis or synced lyrics) are handed over: the next song's voice comes in only
/// after the current one has stopped singing, and the bass swaps at that moment.
AutomixPlan? automixPlan(MixPoints outgoing, MixPoints incoming, {int minSeconds = 0}) {
  final overlap = outgoing.end - outgoing.mixOut;
  if (outgoing.mixOut <= 0 || overlap < 2) return null;
  final (keyOut, keyIn) = (outgoing.reliableKey, incoming.reliableKey);
  final keysClash = keyOut != null && keyIn != null && !camelotCompatible(keyOut, keyIn);
  var tempoMismatch = false;
  var speed = 1.0;
  var outgoingSpeed = 1.0;
  if (outgoing.bpm != null && incoming.bpm != null && outgoing.bpm! > 0 && incoming.bpm! > 0) {
    var ratio = outgoing.bpm! / incoming.bpm!;
    while (ratio > 1.5) {
      ratio /= 2;
    }
    while (ratio < 0.75) {
      ratio *= 2;
    }
    // A ratio of exactly 1 needs no tempo change but still starts on the beat.
    if ((ratio - 1).abs() <= automixMaxTempoChange) speed = ratio == 1 ? 1.0000001 : ratio;
    tempoMismatch = speed == 1;
    if ((ratio - 1).abs() > automixShareTempoChange && speed != 1) {
      outgoingSpeed = 1 / math.sqrt(ratio);
      speed = math.sqrt(ratio);
    }
  }
  final bpm = outgoing.bpm != null && outgoing.bpm! > 0 ? outgoing.bpm : null;
  final beat = bpm == null ? null : 60 / bpm;
  final bar = beat == null ? null : 4 * beat;
  double toBars(double seconds) => bar == null ? seconds : (seconds / bar - 1e-4).ceil() * bar;
  if (tempoMismatch) {
    final short = _filterOutDuration(bpm);
    final lead = math.min(overlap, short.inMicroseconds / 1e6 + 2);
    return AutomixPlan(
      start: _seconds(math.max(outgoing.mixOut, outgoing.end - lead)),
      incomingStart: _seconds(incoming.mixIn),
      duration: short,
      speed: speed,
      outgoingSpeed: outgoingSpeed,
      bassSwap: Duration.zero,
      filterOut: true,
    );
  }
  var target = (beat == null ? 12.0 : automixBlendBeats * beat).clamp(automixMinSeconds, automixMaxSeconds).toDouble();
  if (keysClash) target = math.max(automixMinSeconds, target / 2);
  target = math.max(target, math.min(minSeconds, 30).toDouble());
  final latest = outgoing.end - math.min(automixMinSeconds, overlap);
  var start = outgoing.mixOut;
  var duration = math.min(overlap, target);
  if (target > overlap) {
    // Start earlier by whole bars, but not before the middle of the song.
    var earlier = toBars(target - overlap);
    final room = start - outgoing.end / 2;
    if (earlier > room) earlier = bar == null ? math.max(0.0, room) : math.max(0.0, (room / bar).floor() * bar);
    start -= earlier;
    duration = math.min(target, overlap + earlier);
  }
  // Seconds into the blend at which the current song stops singing and the next one starts.
  final voiceEnds = outgoing.vocalsOut == null ? null : outgoing.vocalsOut! - start;
  final voiceStarts = incoming.vocalsIn == null ? null : (incoming.vocalsIn! - incoming.mixIn) / speed;
  // Both voices known: the next voice must not start before the current one ends. Otherwise the unknown side is
  // assumed to be in the middle of the blend.
  final ends = voiceEnds ?? (voiceStarts == null ? null : 0.0);
  final starts = voiceStarts ?? (voiceEnds == null ? null : duration / 2);
  // Between these, neither song sings: the bass swaps there.
  (double, double)? quiet;
  if (ends != null && starts != null) {
    var later = 0.0;
    if (ends > starts + 0.01) {
      // Start later by whole bars, as far as the end of the song allows; the blend keeps its length while it can.
      final room = math.max(0.0, latest - start);
      later = toBars(ends - starts);
      if (later > room) later = bar == null ? room : (room / bar).floor() * bar;
      start += later;
      duration = math.min(duration, outgoing.end - start);
    }
    if (ends - later <= starts + 0.01) quiet = (math.max(0.0, ends - later), math.min(starts, duration));
  }
  var swap = quiet == null ? duration / 2 : (duration / 2).clamp(quiet.$1, math.max(quiet.$1, quiet.$2)).toDouble();
  if (beat != null) {
    swap = ((swap / beat).round() * beat).clamp(beat, math.max(beat, duration - beat)).toDouble();
  }
  return AutomixPlan(
    start: _seconds(start),
    incomingStart: _seconds(incoming.mixIn),
    duration: _seconds(duration),
    speed: speed,
    outgoingSpeed: outgoingSpeed,
    bassSwap: _seconds(swap),
  );
}

/// Filter-out volumes: the next song is up within the first 40 %, the current one fades over the whole time.
(double, double) filterOutVolumes({
  required Duration elapsed,
  required Duration duration,
  required double outgoingTarget,
  required double incomingTarget,
}) {
  final t = duration == Duration.zero ? 1.0 : (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  return (
    outgoingTarget * math.pow(1 - t, 1.5).toDouble(),
    incomingTarget * math.sin(math.min(1, t / 0.4) * math.pi / 2),
  );
}

/// A step of the filter-out: the low end disappears in four steps (sweeping from 250 Hz up to 2 kHz).
AutomixCut filterOutCut(int step, {double? bpm}) => AutomixCut(
  lowDb: -6.0 * step,
  lowUpTo: 250.0 * math.pow(2, step - 1),
  echoMs: bpm != null && bpm > 0 ? (60000 / bpm / 2).round() : 250,
);

/// How one player's sound is cut during an AutoMix transition.
class AutomixCut {
  const AutomixCut({this.lowDb = 0, this.lowUpTo = automixBassCutoff, this.vocalDb = 0, this.echoMs});

  /// The blend's bass swap: no bass, less of the vocal range.
  static const bassSwap = AutomixCut(lowDb: automixBassCutDb, vocalDb: automixVocalCutDb);

  final double lowDb;
  final double lowUpTo;
  final double vocalDb;

  /// Desktop only: an echo of this delay (half a beat) as the song leaves.
  final int? echoMs;

  /// The reduction (dB) of an equalizer band at [frequency] Hz.
  double reductionAt(double frequency) => frequency <= lowUpTo
      ? lowDb
      : frequency >= 500 && frequency <= 4000
      ? vocalDb
      : 0;

  /// The same as an mpv filter (desktop).
  String get mpvFilter {
    if (echoMs == null) return automixBassFilter;
    return 'lavfi=[highpass=f=${lowUpTo.round()}:p=2,aecho=0.8:0.6:$echoMs:0.35]';
  }
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

List<T> interleaveEvery<T>(List<T> upcoming, List<T> extra, int every) {
  if (every < 1) throw ArgumentError.value(every, 'every');
  final result = <T>[];
  var next = 0;
  for (var i = 0; i < upcoming.length; i++) {
    result.add(upcoming[i]);
    if ((i + 1) % every == 0 && next < extra.length) result.add(extra[next++]);
  }
  return result;
}

(bool, bool) nextShuffleMode({required bool shuffle, required bool smartShuffle, required bool allowSmart}) => !shuffle
    ? (true, false)
    : !smartShuffle && allowSmart
    ? (true, true)
    : (false, false);

bool supportsSmartShuffle(String? context, {bool isRadio = false}) =>
    !isRadio &&
    (context == 'liked' ||
        (context?.startsWith('playlist:') ?? false) ||
        (context?.startsWith('album:') ?? false) ||
        (context?.startsWith('mix:') ?? false));

bool shouldAutoplay({
  required bool enabled,
  required int length,
  required int? index,
  required LoopMode loopMode,
  required bool playing,
  required bool isBook,
  required bool isStation,
  required bool inJam,
}) =>
    enabled &&
    playing &&
    length > 0 &&
    index == length - 1 &&
    loopMode == LoopMode.off &&
    !isBook &&
    !isStation &&
    !inJam;

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
            // Song time to real time at the current (possibly ramped) speed.
            final wait = (fade.plan!.start - position) * (1 / player.speed);
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

  /// AutoMix bass swap: which player's low end is cut, and (desktop) the source keys with a cut filter.
  final _bassCut = <AutomixCut?>[null, null];
  final _bassCutKeys = <String>{};
  static final _desktop =
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows);
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

  /// Identifies a queue item's media (a part of its URI, e.g. the song id) for per-song desktop filters.
  String? Function(int index)? sourceKeyForIndex;

  /// True while an AutoMix transition plays, for the "AutoMix" badge in the player.
  final automixing = ValueNotifier<bool>(false);
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
        _equalizers.indexed.map((entry) async {
          final (slot, eq) = entry;
          try {
            final cut = _bassCut[slot];
            // With AutoMix the effect stays on (flat when unused): switching it on and off mid-song stutters.
            final enabled = _equalizer.enabled || cut != null || automix;
            await eq.setEnabled(enabled);
            // Before the first source, just_audio's parameter future has not completed yet.
            final parameters = await eq.parameters.timeout(const Duration(milliseconds: 100));
            if (_disposed) return;
            final settings = _equalizer;
            final minMb = (parameters.minDecibels * 100).round();
            final maxMb = (parameters.maxDecibels * 100).round();
            final levels = androidBandLevels(
              settings.enabled ? settings.gains : List.filled(equalizerFrequencies.length, 0),
              [for (final band in parameters.bands) (band.centerFrequency * 1000).round()],
              minMb,
              maxMb,
            );
            for (var i = 0; i < parameters.bands.length; i++) {
              final reduction = cut?.reductionAt(parameters.bands[i].centerFrequency) ?? 0.0;
              final level = (levels[i] + reduction * 100).round().clamp(minMb, maxMb);
              await parameters.bands[i].setGain(level / 100);
            }
            await eq.setEnabled(enabled);
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
    final plan = automixPlan(outgoing, incoming, minSeconds: crossfadeSeconds);
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
      // The next song comes in without its bass; the bass swaps over halfway (see [_startAutomix]).
      if (!fade.plan!.filterOut) await _setCut(fade.incoming, fade.index, AutomixCut.bassSwap);
      if (_disposed || currentIndex != index || _fade != fade) {
        if (_fade == fade) _fade = null;
        return;
      }
      fade.prepared = true;
      // The current song drifts toward the shared tempo until the mix point.
      final outgoingSpeed = fade.plan!.outgoingSpeed;
      if (outgoingSpeed != 1) {
        final left = fade.plan!.start - fade.outgoing.position;
        _rampSpeed(fade.outgoing, _speed, _speed * outgoingSpeed, left * 0.8);
      }
    } catch (_) {
      _failedFadeIndex = index;
      if (_fade == fade) _fade = null;
    }
  }

  void _startAutomix(_Fade fade) {
    final plan = fade.plan!;
    fade.incoming.play().ignore();
    fade.clock.start();
    automixing.value = true;
    var swapped = false;
    var filterStep = 0;
    final outgoingIndex = fade.outgoingIndex;
    final bpm = outgoingIndex == null ? null : mixPointsForIndex?.call(outgoingIndex)?.bpm;
    fade.timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (fade.clock.elapsed >= fade.duration) {
        finishFade().ignore();
        return;
      }
      if (plan.filterOut) {
        // Four steps over the first 80 %: the sweep moves up while the song fades.
        final step = (fade.clock.elapsed.inMicroseconds / fade.duration.inMicroseconds / 0.2).floor() + 1;
        if (step > filterStep && step <= 4) {
          filterStep = step;
          _setCut(fade.outgoing, fade.outgoingIndex, filterOutCut(step, bpm: bpm)).ignore();
        }
      } else if (!swapped && fade.clock.elapsed >= plan.bassSwap) {
        swapped = true;
        _setCut(fade.outgoing, fade.outgoingIndex, AutomixCut.bassSwap).ignore();
        _setCut(fade.incoming, fade.index, null).ignore();
      }
      final (outgoing, incoming) = (plan.filterOut ? filterOutVolumes : automixVolumes)(
        elapsed: fade.clock.elapsed,
        duration: fade.duration,
        outgoingTarget: _targetVolume,
        incomingTarget: _incomingTarget(fade),
      );
      Future.wait([fade.outgoing.setVolume(outgoing), fade.incoming.setVolume(incoming)]).ignore();
      // Starting playback takes a moment; while the next song is still quiet, line its beats up once (a later
      // seek would be audible as a hiccup).
      if (!plan.beatMatched) return;
      if (fade.clock.elapsedMilliseconds >= 300 && fade.corrected.add(300)) {
        final expected = plan.incomingStart + (fade.outgoing.position - plan.start) * plan.ratio;
        final error = fade.incoming.position - expected;
        if (error.abs() > const Duration(milliseconds: 30) && error.abs() < const Duration(seconds: 2)) {
          fade.incoming.seek(expected + const Duration(milliseconds: 10)).ignore();
        }
      }
    });
  }

  /// After a beat-matched transition the new song drifts back to its own tempo.
  /// Moves [player] from [from] to [to] in half-second steps (each speed change costs the decoder a moment, so
  /// few and even steps sound smoother than many tiny ones).
  void _rampSpeed(AudioPlayer player, double from, double to, Duration duration) {
    _speedRamp?.cancel();
    final steps = (duration.inMilliseconds / 500).round().clamp(1, 24);
    var step = 0;
    _speedRamp = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      step++;
      final done = step >= steps || _disposed;
      player.setSpeed(done ? to : from + (to - from) * step / steps).ignore();
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

  /// Apply or remove ([cut] null) an AutoMix cut on the song at [index] playing on [player].
  Future<void> _setCut(AudioPlayer player, int? index, AutomixCut? cut) async {
    final slot = _players.indexOf(player);
    if (_desktop) {
      final key = index == null ? null : sourceKeyForIndex?.call(index);
      if (key == null) return;
      JustAudioMediaKit.setSourceFilter(key, cut?.mpvFilter);
      cut != null ? _bassCutKeys.add(key) : _bassCutKeys.remove(key);
    } else if (_equalizers.isNotEmpty && _bassCut[slot] != cut) {
      _bassCut[slot] = cut;
      await _applyEqualizer();
    }
  }

  Future<void> _clearBassCuts() async {
    for (final key in _bassCutKeys) {
      JustAudioMediaKit.setSourceFilter(key, null);
    }
    _bassCutKeys.clear();
    if (_bassCut.any((cut) => cut != null)) {
      _bassCut.fillRange(0, 2, null);
      await _applyEqualizer();
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
      // The current song may have started drifting toward the next one's tempo.
      _speedRamp?.cancel();
      await fade.outgoing.setSpeed(_speed);
      await _clearBassCuts();
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
      if (fade.plan?.beatMatched ?? false) {
        _rampSpeed(fade.incoming, _speed * fade.plan!.speed, _speed, const Duration(seconds: 8));
      }
    } finally {
      _editing = false;
      automixing.value = false;
      _emitCurrent();
    }
    // Release the old playlist's decoder; its factories remain ready for the next fade.
    await fade.outgoing.stop();
    await fade.outgoing.setSpeed(_speed);
    await _clearBassCuts();
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
    automixing.dispose();
    for (final stream in [_states, _indices, _positions, _durations, _loops, _events, _errors]) {
      await stream.close();
    }
  }
}
