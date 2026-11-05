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
  delayThreeQuarterCut('delay_3q_cut', 0.75, 0);

  const EffectLane(this.json, this.echoBeats, this.echoFeedback);
  final String json;

  /// The echo's delay in beats (0: no echo) and how much of each repeat comes back (0: a single repeat).
  final double echoBeats;
  final double echoFeedback;

  bool get reverb => this == reverbMiddle || this == reverbCut || this == reverbTail;
  bool get echo => echoBeats > 0;

  /// The current song stops before the end and only the effect rings on.
  bool get tail => this == reverbTail || this == echoHalfTail || this == echoThreeQuarterTail || this == echoBeatTail;
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
  });

  final VolumeLane volume;
  final EqLane eq;
  final FilterLane filter;
  final EffectLane effect;

  /// The current song repeats its last [loopBeats] beats before the middle until it is gone (0: no loop).
  final int loopBeats;
  final bool beatmatch;

  static const loopChoices = [0, 1, 2, 4, 8, 16];

  /// Whether the sound needs the players' mix effects (beyond the volume): EQ, filters, effects and loops.
  bool get usesEffects => effect != EffectLane.none || filter != FilterLane.none || loopBeats > 0;

  static MixLanes? fromJson(Object? json) {
    if (json is! Map) return null;
    return MixLanes(
      volume: _fromJson(VolumeLane.values, json['volume'], (v) => v.json) ?? VolumeLane.smooth,
      eq: _fromJson(EqLane.values, json['eq'], (v) => v.json) ?? EqLane.swapMiddle,
      filter: _fromJson(FilterLane.values, json['filter'], (v) => v.json) ?? FilterLane.none,
      effect: _fromJson(EffectLane.values, json['effect'], (v) => v.json) ?? EffectLane.none,
      loopBeats: loopChoices.contains(json['loop']) ? json['loop'] as int : 0,
      beatmatch: json['beatmatch'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'volume': volume.json,
    'eq': eq.json,
    'filter': filter.json,
    'effect': effect.json,
    'loop': loopBeats,
    'beatmatch': beatmatch,
  };

  MixLanes copyWith({
    VolumeLane? volume,
    EqLane? eq,
    FilterLane? filter,
    EffectLane? effect,
    int? loopBeats,
    bool? beatmatch,
  }) => MixLanes(
    volume: volume ?? this.volume,
    eq: eq ?? this.eq,
    filter: filter ?? this.filter,
    effect: effect ?? this.effect,
    loopBeats: loopBeats ?? this.loopBeats,
    beatmatch: beatmatch ?? this.beatmatch,
  );

  @override
  bool operator ==(Object other) =>
      other is MixLanes &&
      other.volume == volume &&
      other.eq == eq &&
      other.filter == filter &&
      other.effect == effect &&
      other.loopBeats == loopBeats &&
      other.beatmatch == beatmatch;

  @override
  int get hashCode => Object.hash(volume, eq, filter, effect, loopBeats, beatmatch);
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
  final (vo, vi) = laneVolumes(lanes.volume, u, bar);

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

  // Effects on the outgoing song: fed from the middle (reverb into the middle for [reverbMiddle]); "tail" ones stop
  // the song a bar early (the middle for [reverbMiddle]) and let the effect ring on.
  final effect = lanes.effect;
  var feed = 0.0, dryGate = 1.0, echo = 0.0, reverb = 0.0;
  if (effect == EffectLane.reverbMiddle) {
    feed = u < m ? 1 : 0;
    dryGate = u < m ? 1 : 0;
    reverb = _smooth(_ramp(u, 0, m));
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

/// The beats the current song loops at the middle, so the loop fits into the first half.
int fittingLoopBeats(MixLanes lanes, int bars) {
  var beats = lanes.loopBeats;
  while (beats > 0 && beats > bars * 2) {
    beats ~/= 2;
  }
  return beats;
}
