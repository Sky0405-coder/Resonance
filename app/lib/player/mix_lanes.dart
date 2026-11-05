import 'dart:math' as math;

/// The lanes of a transition made in the transition editor, like a DJ's: how the volumes cross, how the EQ hands
/// the bass (and mids and highs) over, which filter sweeps, which effect the current song leaves with, whether it
/// loops its last beats and whether the tempos are matched.
///
/// Times below are fractions of the transition (0 to 1); the middle (0.5) is on a beat, as every transition lasts
/// whole bars.

enum VolumeLane {
  smooth('smooth'),
  overlap('overlap'),
  fadeInOut('fade_in_out'),
  hardInFadeOut('hard_in_fade_out'),
  fadeInHardOut('fade_in_hard_out'),
  centerCut('center_cut'),
  crossfade('crossfade'),
  fadeInQuickOut('fade_in_quick_out'),
  fadeInCutBar('fade_in_cut_bar'),
  overlapCutBar('overlap_cut_bar');

  const VolumeLane(this.json);
  final String json;
}

enum EqLane {
  swapMiddle('swap_middle'),
  swapEnd('swap_end'),
  swapStart('swap_start'),
  threeBand('three_band'),
  quickBassCut('quick_bass_cut'),
  longBassCut('long_bass_cut'),
  bassFadeOut('bass_fade_out'),
  none('none');

  const EqLane(this.json);
  final String json;
}

enum FilterLane {
  none('none'),
  lowpassOut('lowpass_out'),
  lowpassIn('lowpass_in'),
  lowpassInOut('lowpass_in_out'),
  lowpassInHighpassOut('lowpass_in_highpass_out'),
  highpassOut('highpass_out'),
  highpassIn('highpass_in'),
  highpassInOut('highpass_in_out'),
  highpassInLowpassOut('highpass_in_lowpass_out'),
  highpassHalf('highpass_half'),
  noiseEnd('noise_end');

  const FilterLane(this.json);
  final String json;
}

enum EffectLane {
  none('none', 0, 0),
  reverbMiddle('reverb_middle', 0, 0),
  reverbCut('reverb_cut', 0, 0),
  reverbTail('reverb_tail', 0, 0),
  echoHalfCut('echo_half_cut', 0.5, 0.5),
  echoHalfTail('echo_half_tail', 0.5, 0.5),
  echoThreeQuarterCut('echo_3q_cut', 0.75, 0.5),
  echoThreeQuarterTail('echo_3q_tail', 0.75, 0.5),
  echoBeatCut('echo_beat_cut', 1, 0.5),
  echoBeatTail('echo_beat_tail', 1, 0.5),
  delayHalfCut('delay_half_cut', 0.5, 0),
  delayThreeQuarterCut('delay_3q_cut', 0.75, 0),
  // Desktop only (mpv's filters): a jet sweep, a phase sweep, the sound chopped on eighth notes, and the last beat
  // repeating ever faster (a beat roll: 1, ½, ¼, ⅛, 1/16 beat).
  flanger('flanger', 0, 0),
  phaser('phaser', 0, 0),
  gate('gate', 0, 0),
  beatRoll('beat_roll', 0, 0),
  // The current song stops like a turntable whose motor is switched off: two beats from the middle.
  brake('brake', 0, 0);

  const EffectLane(this.json, this.echoBeats, this.echoFeedback);
  final String json;

  /// The echo's delay in beats (0: no echo) and how much of each repeat comes back (0: a single repeat).
  final double echoBeats;
  final double echoFeedback;

  bool get reverb => this == reverbMiddle || this == reverbCut || this == reverbTail;

  /// Only the desktop players have these (Android plays the transition without the effect).
  bool get desktopOnly => this == flanger || this == phaser || this == gate || this == beatRoll || this == brake;
  bool get echo => echoBeats > 0;

  /// The current song stops before the end and only the effect rings on.
  bool get tail => this == reverbTail || this == echoHalfTail || this == echoThreeQuarterTail || this == echoBeatTail;
}

/// A curve drawn by hand in the transition editor; it replaces what the lanes compute for one song. Values: the
/// volume (0 to 1), how much bass is left (1: all, 0: cut by [mixCutDb]) and the filter like a DJ mixer's knob (-1:
/// low-pass closed, 0: open, 1: high-pass closed).
enum MixCurve {
  volumeOut('volume_out', 0, 1),
  volumeIn('volume_in', 0, 1),
  bassOut('bass_out', 0, 1),
  bassIn('bass_in', 0, 1),
  filterOut('filter_out', -1, 1),
  filterIn('filter_in', -1, 1);

  const MixCurve(this.json, this.min, this.max);
  final String json;
  final double min;
  final double max;

  bool get outgoing => this == volumeOut || this == bassOut || this == filterOut;

  /// The value of this curve's quantity in a player's [state].
  double valueOf(FxState state) => switch (this) {
    volumeOut || volumeIn => state.level,
    bassOut || bassIn => (1 - state.low / mixCutDb).clamp(0.0, 1.0),
    filterOut || filterIn => filterKnob(state),
  };

  /// What the lanes alone make of this curve: sampled finely, then reduced to the points that shape it.
  List<CurvePoint> sample(MixLanes lanes, int bars) {
    final plain = lanes.copyWith(curves: const {});
    final steps = math.max(32, bars * 16);
    final points = <CurvePoint>[
      for (var i = 0; i <= steps; i++)
        () {
          final u = i / steps;
          // Just before the end: at 1 the transition is over.
          final (out, inc) = laneStates(plain, math.min(u, 1 - 1e-6), bars);
          return (u, valueOf(outgoing ? out : inc));
        }(),
    ];
    return simplifyCurve(points, 0.02 * (max - min));
  }
}

/// A point of a [MixCurve]: where in the transition (0 to 1) and its value.
typedef CurvePoint = (double, double);

/// [points]' value at [u]: straight lines between them, flat before the first and after the last.
double curveAt(List<CurvePoint> points, double u) {
  if (points.isEmpty) return 0;
  if (u <= points.first.$1) return points.first.$2;
  for (var i = 1; i < points.length; i++) {
    final (u1, v1) = points[i];
    if (u <= u1) {
      final (u0, v0) = points[i - 1];
      return u1 <= u0 ? v1 : v0 + (v1 - v0) * (u - u0) / (u1 - u0);
    }
  }
  return points.last.$2;
}

/// Fewer points drawing the same line within [tolerance] (Ramer–Douglas–Peucker), at most 64.
List<CurvePoint> simplifyCurve(List<CurvePoint> points, double tolerance) {
  if (points.length <= 2) return [...points];
  final keep = List<bool>.filled(points.length, false)
    ..[0] = true
    ..[points.length - 1] = true;
  void reduce(int first, int last) {
    final (u0, v0) = points[first];
    final (u1, v1) = points[last];
    var worst = -1.0, index = -1;
    for (var i = first + 1; i < last; i++) {
      final (u, v) = points[i];
      final expected = u1 == u0 ? v0 : v0 + (v1 - v0) * (u - u0) / (u1 - u0);
      final off = (v - expected).abs();
      if (off > worst) {
        worst = off;
        index = i;
      }
    }
    if (index >= 0 && worst > tolerance) {
      keep[index] = true;
      reduce(first, index);
      reduce(index, last);
    }
  }

  reduce(0, points.length - 1);
  final result = [
    for (var i = 0; i < points.length; i++)
      if (keep[i]) points[i],
  ];
  return result.length <= 64 ? result : simplifyCurve(points, tolerance * 2);
}

/// A filter state as a DJ mixer's knob: -1 low-pass closed (250 Hz), 0 open, 1 high-pass closed (2.4 kHz).
double filterKnob(FxState state) {
  if (state.highpass > mixHighpassOff * 1.01) {
    return (math.log(state.highpass / mixHighpassOff) / math.log(2400 / mixHighpassOff)).clamp(0.0, 1.0);
  }
  if (state.lowpass < mixLowpassOff * 0.99) {
    return -(math.log(mixLowpassOff / state.lowpass) / math.log(mixLowpassOff / 250)).clamp(0.0, 1.0);
  }
  return 0;
}

/// The filter frequencies (high-pass, low-pass) of a knob at [value] (see [filterKnob]).
(double, double) filterFrequencies(double value) => value > 0
    ? (_sweep(mixHighpassOff, 2400, value), mixLowpassOff)
    : (mixHighpassOff, _sweep(mixLowpassOff, 250, -value));

bool _sameCurves(Map<MixCurve, List<CurvePoint>> a, Map<MixCurve, List<CurvePoint>> b) {
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    final other = b[key];
    if (other == null || other.length != value.length) return false;
    for (var i = 0; i < value.length; i++) {
      if (other[i] != value[i]) return false;
    }
  }
  return true;
}

Map<MixCurve, List<CurvePoint>> _curvesFromJson(Object? json) {
  if (json is! Map) return const {};
  return {
    for (final curve in MixCurve.values)
      if (json[curve.json] case final List points when points.length >= 2)
        curve: [
          for (final p in points)
            if (p is List && p.length == 2 && p[0] is num && p[1] is num)
              ((p[0] as num).toDouble().clamp(0.0, 1.0), (p[1] as num).toDouble().clamp(curve.min, curve.max)),
        ]..sort((a, b) => a.$1.compareTo(b.$1)),
  };
}

T? _fromJson<T extends Enum>(List<T> values, Object? json, String Function(T) key) =>
    values.where((v) => key(v) == json).firstOrNull;

class MixLanes {
  const MixLanes({
    this.volume = VolumeLane.smooth,
    this.eq = EqLane.swapMiddle,
    this.filter = FilterLane.none,
    this.effect = EffectLane.none,
    this.loopBeats = 0,
    this.beatmatch = true,
    this.curves = const {},
  });

  final VolumeLane volume;
  final EqLane eq;
  final FilterLane filter;
  final EffectLane effect;

  /// The current song repeats its last [loopBeats] beats before the middle until it is gone (0: no loop).
  final int loopBeats;
  final bool beatmatch;

  /// Curves drawn by hand, each replacing what the lanes above compute for its song.
  final Map<MixCurve, List<CurvePoint>> curves;

  static const loopChoices = [0, 1, 2, 4, 8, 16];

  /// Whether the sound needs the players' mix effects (beyond the volume): EQ, filters, effects and loops.
  bool get usesEffects =>
      effect != EffectLane.none ||
      filter != FilterLane.none ||
      loopBeats > 0 ||
      curves.containsKey(MixCurve.filterOut) ||
      curves.containsKey(MixCurve.filterIn);

  static MixLanes? fromJson(Object? json) {
    if (json is! Map) return null;
    return MixLanes(
      volume: _fromJson(VolumeLane.values, json['volume'], (v) => v.json) ?? VolumeLane.smooth,
      eq: _fromJson(EqLane.values, json['eq'], (v) => v.json) ?? EqLane.swapMiddle,
      filter: _fromJson(FilterLane.values, json['filter'], (v) => v.json) ?? FilterLane.none,
      effect: _fromJson(EffectLane.values, json['effect'], (v) => v.json) ?? EffectLane.none,
      loopBeats: loopChoices.contains(json['loop']) ? json['loop'] as int : 0,
      beatmatch: json['beatmatch'] != false,
      curves: _curvesFromJson(json['curves']),
    );
  }

  Map<String, dynamic> toJson() => {
    'volume': volume.json,
    'eq': eq.json,
    'filter': filter.json,
    'effect': effect.json,
    'loop': loopBeats,
    'beatmatch': beatmatch,
    if (curves.isNotEmpty)
      'curves': {
        for (final MapEntry(:key, :value) in curves.entries)
          key.json: [
            for (final (u, v) in value) [u, v],
          ],
      },
  };

  MixLanes copyWith({
    VolumeLane? volume,
    EqLane? eq,
    FilterLane? filter,
    EffectLane? effect,
    int? loopBeats,
    bool? beatmatch,
    Map<MixCurve, List<CurvePoint>>? curves,
  }) => MixLanes(
    volume: volume ?? this.volume,
    eq: eq ?? this.eq,
    filter: filter ?? this.filter,
    effect: effect ?? this.effect,
    loopBeats: loopBeats ?? this.loopBeats,
    beatmatch: beatmatch ?? this.beatmatch,
    curves: curves ?? this.curves,
  );

  @override
  bool operator ==(Object other) =>
      other is MixLanes &&
      other.volume == volume &&
      other.eq == eq &&
      other.filter == filter &&
      other.effect == effect &&
      other.loopBeats == loopBeats &&
      other.beatmatch == beatmatch &&
      _sameCurves(other.curves, curves);

  @override
  int get hashCode => Object.hash(volume, eq, filter, effect, loopBeats, beatmatch, curves.length);
}

/// How far an EQ band is cut when it is handed over (dB).
const mixCutDb = -15.0;

/// Neutral filter frequencies: a high-pass at 10 Hz and a low-pass at 20 kHz change nothing audible.
const mixHighpassOff = 10.0;
const mixLowpassOff = 20000.0;

/// One player's mix effects at a moment: its level ([dry]), EQ gains (dB), filter frequencies (Hz), how much of
/// it feeds the effects ([fxIn]), the echo's and reverb's levels and the noise riser's.
class FxState {
  const FxState({
    this.level = 1,
    this.dry = 1,
    this.low = 0,
    this.mid = 0,
    this.high = 0,
    this.highpass = mixHighpassOff,
    this.lowpass = mixLowpassOff,
    this.fxIn = 0,
    this.echo = 0,
    this.reverb = 0,
    this.noise = 0,
    this.flanger = 0,
    this.phaser = 0,
    this.gate = 0,
  });

  /// The volume curve; [dry] is it times the effect's gate (a "tail" effect stops the song but not its echo).
  final double level;
  final double dry;
  final double low;
  final double mid;
  final double high;
  final double highpass;
  final double lowpass;
  final double fxIn;
  final double echo;
  final double reverb;
  final double noise;

  /// Desktop only: how much of the song goes through the flanger or phaser instead of straight on, and whether
  /// the eighth-note gate is on (0 or 1).
  final double flanger;
  final double phaser;
  final double gate;

  static const neutral = FxState();

  List<double> get values => [dry, low, mid, high, highpass, lowpass, fxIn, echo, reverb, noise];
}

double _clamp01(double v) => v.clamp(0.0, 1.0).toDouble();

/// 0 before [from], 1 after [to], linear between (a step when they are equal).
double _ramp(double u, double from, double to) => to <= from ? (u < from ? 0 : 1) : _clamp01((u - from) / (to - from));

double _smooth(double t) => t * t * (3 - 2 * t);

/// From [a] to [b] Hz along [t], evenly in octaves.
double _sweep(double a, double b, double t) => a * math.pow(b / a, _clamp01(t)).toDouble();

/// The volumes (outgoing, incoming) of [lane] at [u]; [bar] is one bar as a fraction of the transition.
(double, double) laneVolumes(VolumeLane lane, double u, double bar) {
  if (u >= 1) return (0, 1);
  const m = 0.5;
  final fadeIn = _ramp(u, 0, m);
  final fadeOut = 1 - _ramp(u, m, 1);
  final lastBar = u < 1 - bar ? 1.0 : 0.0;
  return switch (lane) {
    VolumeLane.smooth => (math.cos(_smooth(u) * math.pi / 2), math.sin(_smooth(u) * math.pi / 2)),
    VolumeLane.overlap => (1, 1),
    VolumeLane.fadeInOut => (fadeOut, fadeIn),
    VolumeLane.hardInFadeOut => (fadeOut, 1),
    VolumeLane.fadeInHardOut => (1, fadeIn),
    VolumeLane.centerCut => (u < m ? 1 : 0, u < m ? 0 : 1),
    VolumeLane.crossfade => (1 - u, u),
    VolumeLane.fadeInQuickOut => (1 - _ramp(u, 0.75, 1), fadeIn),
    VolumeLane.fadeInCutBar => (lastBar, fadeIn),
    VolumeLane.overlapCutBar => (lastBar, 1),
  };
}

/// The state of both players [u] into a transition with these [lanes] lasting [bars] bars.
(FxState, FxState) laneStates(MixLanes lanes, double u, int bars) {
  final bar = 1 / math.max(1, bars);
  final beat = bar / 4;
  const m = 0.5;
  var (vo, vi) = laneVolumes(lanes.volume, u, bar);
  final curves = lanes.curves;
  double? drawn(MixCurve curve) => curves[curve] == null ? null : curveAt(curves[curve]!, u);
  if (u < 1) {
    vo = drawn(MixCurve.volumeOut) ?? vo;
    vi = drawn(MixCurve.volumeIn) ?? vi;
  }

  // EQ: the outgoing band's cut (0 to 1) and the incoming one's.
  var lowOut = 0.0, lowIn = 0.0, midOut = 0.0, midIn = 0.0, highOut = 0.0, highIn = 0.0;
  // A swap takes a beat around its point; a cut an eighth of one.
  double swapAt(double point) => _ramp(u, point - beat / 2, point + beat / 2);
  double cutAt(double point) => _ramp(u, point, point + beat / 8);
  switch (lanes.eq) {
    case EqLane.swapMiddle:
      lowOut = swapAt(m);
      lowIn = 1 - lowOut;
    case EqLane.swapEnd:
      lowOut = swapAt(1 - beat);
      lowIn = 1 - lowOut;
    case EqLane.swapStart:
      lowOut = swapAt(beat);
      lowIn = 1 - lowOut;
    case EqLane.threeBand:
      lowOut = _smooth(_ramp(u, 0, 0.5));
      midOut = _smooth(_ramp(u, 0.25, 0.75));
      highOut = _smooth(_ramp(u, 0.5, 1));
      (lowIn, midIn, highIn) = (1 - lowOut, 1 - midOut, 1 - highOut);
    case EqLane.quickBassCut:
      lowOut = cutAt(0.75);
      lowIn = 1 - cutAt(1 - beat);
    case EqLane.longBassCut:
      lowOut = cutAt(0);
      lowIn = 1 - cutAt(1 - beat);
    case EqLane.bassFadeOut:
      lowOut = _smooth(_ramp(u, 0, m));
    case EqLane.none:
      break;
  }
  if (drawn(MixCurve.bassOut) case final bass?) lowOut = 1 - bass;
  if (drawn(MixCurve.bassIn) case final bass?) lowIn = 1 - bass;

  // Filters: sweeps in octaves, the incoming song's opening up until the middle, the outgoing one's closing after.
  final opening = _ramp(u, 0, m), closing = _ramp(u, m, 1);
  var hpOut = mixHighpassOff, hpIn = mixHighpassOff, lpOut = mixLowpassOff, lpIn = mixLowpassOff, noise = 0.0;
  double highpassClosing([double to = 2400]) => _sweep(mixHighpassOff, to, closing);
  double highpassOpening() => _sweep(2400, mixHighpassOff, opening);
  double lowpassClosing() => _sweep(mixLowpassOff, 250, closing);
  double lowpassOpening() => _sweep(250, mixLowpassOff, opening);
  switch (lanes.filter) {
    case FilterLane.none:
      break;
    case FilterLane.lowpassOut:
      lpOut = lowpassClosing();
    case FilterLane.lowpassIn:
      lpIn = lowpassOpening();
    case FilterLane.lowpassInOut:
      (lpIn, lpOut) = (lowpassOpening(), lowpassClosing());
    case FilterLane.lowpassInHighpassOut:
      (lpIn, hpOut) = (lowpassOpening(), highpassClosing());
    case FilterLane.highpassOut:
      hpOut = highpassClosing();
    case FilterLane.highpassIn:
      hpIn = highpassOpening();
    case FilterLane.highpassInOut:
      (hpIn, hpOut) = (highpassOpening(), highpassClosing());
    case FilterLane.highpassInLowpassOut:
      (hpIn, lpOut) = (highpassOpening(), lowpassClosing());
    case FilterLane.highpassHalf:
      hpOut = highpassClosing(500);
    case FilterLane.noiseEnd:
      // Noise swells over the second half and stops with the transition.
      noise = u >= 1 ? 0 : math.pow(_smooth(closing), 2).toDouble();
  }
  if (drawn(MixCurve.filterOut) case final knob?) (hpOut, lpOut) = filterFrequencies(knob);
  if (drawn(MixCurve.filterIn) case final knob?) (hpIn, lpIn) = filterFrequencies(knob);

  // Effects on the outgoing song: fed from the middle (reverb into the middle for [reverbMiddle]); "tail" ones stop
  // the song a bar early (the middle for [reverbMiddle]) and let the effect ring on.
  final effect = lanes.effect;
  var feed = 0.0, dryGate = 1.0, echo = 0.0, reverb = 0.0, flanger = 0.0, phaser = 0.0, gate = 0.0;
  if (effect == EffectLane.reverbMiddle) {
    feed = u < m ? 1 : 0;
    dryGate = u < m ? 1 : 0;
    reverb = _smooth(_ramp(u, 0, m));
  } else if (effect.desktopOnly) {
    // Swept in toward the middle, on until the song is gone; the gate and the roll from the middle.
    final sweep = _smooth(_ramp(u, 0.25, m));
    if (effect == EffectLane.flanger) flanger = sweep;
    if (effect == EffectLane.phaser) phaser = sweep;
    if (effect == EffectLane.gate) gate = u >= m && u < 1 ? 1 : 0;
    // Braked to a stop, the song stays silent.
    if (effect == EffectLane.brake && u >= m + 2 * beat) dryGate = 0;
  } else if (effect != EffectLane.none) {
    final stop = effect.tail ? 1 - bar : 1.0;
    feed = u >= m && u < stop ? 1 : 0;
    dryGate = u < stop ? 1 : 0;
    if (effect.reverb) reverb = _smooth(_ramp(u, m, math.min(1, m + 2 * bar)));
    if (effect.echo) echo = 0.6;
  }

  final out = FxState(
    level: vo,
    dry: vo * dryGate,
    low: lowOut * mixCutDb,
    mid: midOut * mixCutDb,
    high: highOut * mixCutDb,
    highpass: hpOut,
    lowpass: lpOut,
    fxIn: vo * feed,
    echo: echo,
    reverb: reverb,
    noise: noise,
    flanger: flanger,
    phaser: phaser,
    gate: gate,
  );
  final incoming = FxState(
    level: vi,
    dry: vi,
    low: lowIn * mixCutDb,
    mid: midIn * mixCutDb,
    high: highIn * mixCutDb,
    highpass: hpIn,
    lowpass: lpIn,
  );
  return (out, incoming);
}

/// Brake: the current song's speed (a share of its speed) [u] into a transition of [bars] bars; null outside the
/// two beats from the middle in which it slows to a stop.
double? brakeSpeed(double u, int bars) {
  final beat = 1 / (math.max(1, bars) * 4);
  if (u < 0.5 || u >= 0.5 + 2 * beat) return null;
  final p = (u - 0.5) / (2 * beat);
  return math.max(0.05, (1 - p) * (1 - p));
}

/// Beat roll: the length (beats) of the loop the current song repeats [u] into a transition of [bars] bars, null
/// before the middle. It halves every beat, from one beat down to a sixteenth.
double? beatRollBeats(double u, int bars) {
  if (u < 0.5 || u >= 1) return null;
  final beatsIn = ((u - 0.5) * bars * 4).floor();
  return 1 / math.pow(2, math.min(4, beatsIn));
}

/// The beats the current song loops at the middle, so the loop fits into the first half.
int fittingLoopBeats(MixLanes lanes, int bars) {
  var beats = lanes.loopBeats;
  while (beats > 0 && beats > bars * 2) {
    beats ~/= 2;
  }
  return beats;
}
