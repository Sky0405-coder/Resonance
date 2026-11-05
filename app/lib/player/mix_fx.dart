import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';

import 'mix_lanes.dart';

/// How the players' mix effects (transition editor lanes) are driven.
///
/// Android: the app's copy of just_audio runs a processor in each player's audio sink, which follows an automation
/// sent ahead of time and keyed by the song's own position, so it is heard exactly where planned although audio is
/// processed well before it plays.
///
/// Desktop: [mixMpvFilter] stays in every player while AutoMix is on; a transition changes its values live.

/// One player's automation: [values] (per [FxState.values] entry) every [stepUs] of song time from [startUs]; an
/// echo of [echoDelay] seconds (song time); a loop of the [loopSeconds] before [loopAtUs].
class MixAutomation {
  MixAutomation({
    required this.startUs,
    required this.stepUs,
    required this.values,
    this.echoDelay = 0.5,
    this.echoFeedback = 0.5,
    this.loopAtUs,
    this.loopSeconds = 0,
  });

  final int startUs;
  final int stepUs;
  final List<List<double>> values;
  final double echoDelay;
  final double echoFeedback;
  final int? loopAtUs;
  final double loopSeconds;

  MixAutomation shifted(int us) => MixAutomation(
    startUs: startUs + us,
    stepUs: stepUs,
    values: values,
    echoDelay: echoDelay,
    echoFeedback: echoFeedback,
    loopAtUs: loopAtUs == null ? null : loopAtUs! + us,
    loopSeconds: loopSeconds,
  );

  Map<String, Object?> toJson() => {
    'startUs': startUs,
    'stepUs': stepUs,
    'values': values,
    'echoDelay': echoDelay,
    'echoFeedback': echoFeedback,
    'loopAtUs': loopAtUs,
    'loopSeconds': loopSeconds,
  };
}

/// The automation of one side of a transition with [lanes]: [duration] seconds of real time, the song starting at
/// [songStart] and running at [rate] (song seconds per second); [beat] is a beat of the outgoing song in its own time.
MixAutomation buildAutomation({
  required MixLanes lanes,
  required int bars,
  required bool outgoing,
  required double duration,
  required double songStart,
  required double rate,
  required double beat,
  double stepSeconds = 0.02,
}) {
  final steps = (duration / stepSeconds).ceil();
  final values = List.generate(10, (_) => List<double>.filled(steps + 1, 0));
  for (var k = 0; k <= steps; k++) {
    final u = duration <= 0 ? 1.0 : (k * stepSeconds / duration).clamp(0.0, 1.0);
    final (out, inc) = laneStates(lanes, u, bars);
    final state = outgoing ? out : inc;
    for (final (p, v) in state.values.indexed) {
      values[p][k] = v;
    }
  }
  final loop = outgoing ? fittingLoopBeats(lanes, bars) : 0;
  return MixAutomation(
    startUs: (songStart * 1e6).round(),
    stepUs: (stepSeconds * rate * 1e6).round(),
    values: values,
    echoDelay: outgoing && lanes.effect.echo ? lanes.effect.echoBeats * beat : 0.5,
    echoFeedback: lanes.effect.echoFeedback,
    loopAtUs: loop > 0 ? ((songStart + duration / 2 * rate) * 1e6).round() : null,
    loopSeconds: loop * beat,
  );
}

/// Android: the mix processors of the app's just_audio.
class AndroidMixFx {
  static const _channel = MethodChannel('com.ryanheise.just_audio.mixfx');

  /// Sends [automation] to [player]'s processor; false when it has none.
  static Future<bool> set(AudioPlayer player, MixAutomation automation) async {
    final id = player.playerId;
    if (id == null) return false;
    try {
      return await _channel.invokeMethod<bool>('set', {'id': id, ...automation.toJson()}) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> clear(AudioPlayer player) async {
    final id = player.playerId;
    if (id == null) return;
    try {
      await _channel.invokeMethod<bool>('clear', {'id': id});
    } on MissingPluginException {
      // No processor.
    } on PlatformException {
      // No processor.
    }
  }

  /// The song position of the audio [player]'s processor is working on (ahead of what is heard).
  static Future<Duration?> position(AudioPlayer player) async {
    final id = player.playerId;
    if (id == null) return null;
    try {
      final us = await _channel.invokeMethod<int>('position', {'id': id});
      return us == null ? null : Duration(microseconds: us);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}

/// The desktop filter chain: three EQ bands, high- and low-pass, the eighth-note gate, then the dry sound beside a
/// flanger, a phaser, an echo (three taps on the beat), a reverb and a noise riser. Every value is changed live with
/// `af-command` ([mpvFxCommands]); the gate gets an expression on the song's beat grid ([mpvGateCommand]).
const mixMpvFilter =
    '@automix:lavfi=[bass@lo=g=0:f=150:w=0.6,equalizer@mid=f=1000:t=o:w=2:g=0,treble@hi=g=0:f=4000:w=0.6,'
    'highpass@hp=f=10:p=2,lowpass@lp=f=20000:p=2,volume@gate=1:eval=frame,asplit=4[dry][wet][fl][ph];'
    '[dry]volume@dry=1[d];'
    '[fl]flanger=delay=1:depth=5:regen=60:width=70:speed=0.25,volume@flw=0[f];'
    '[ph]aphaser=in_gain=0.5:out_gain=0.8:delay=3:decay=0.5:speed=0.5:type=t,volume@phw=0[p];'
    '[wet]volume@fx=0,asplit=4[e1][e2][e3][r];'
    '[e1]adelay@t1=delays=500:all=1,volume@g1=0[o1];[e2]adelay@t2=delays=1000:all=1,volume@g2=0[o2];'
    '[e3]adelay@t3=delays=1500:all=1,volume@g3=0[o3];'
    '[r]aecho=0.8:0.9:23|37|53|71|97|131:0.5|0.45|0.4|0.35|0.3|0.25,lowpass=f=5000,volume@rv=0[rr];'
    'anoisesrc=c=pink:a=0.5,highpass=f=300,volume@noise=0[n];'
    '[d][f][p][o1][o2][o3][rr][n]amix=inputs=8:normalize=0:duration=first]';

/// The gate's volume: on for the first half of every eighth note counted from [downbeat] (song seconds; mpv's
/// filters see song time), almost silent for the second half; [beat] in song seconds. Off: a plain 1.
List<String> mpvGateCommand({double? beat, double downbeat = 0}) => [
  'af-command',
  'automix',
  'volume',
  beat == null
      ? '1'
      : 'if(lt(mod(t-${downbeat.toStringAsFixed(3)},${(beat / 2).toStringAsFixed(4)}),'
            '${(beat / 4).toStringAsFixed(4)}),1,0.05)',
  'volume@gate',
];

List<String> _command(String target, String name, double value, [int digits = 3]) => [
  'af-command',
  'automix',
  name,
  value.toStringAsFixed(digits),
  target,
];

/// The commands that move a desktop player's chain to [state] (its volume is the player's: [FxState.level]); only
/// values that differ from [previous] (all without one).
List<List<String>> mpvFxCommands(FxState state, FxState? previous, {double echoFeedback = 0.5}) {
  // The player's volume already follows the volume curve; the chain only adds the effect's gate and feed.
  final level = state.level;
  final gate = level <= 0 ? 0.0 : (state.dry / level).clamp(0.0, 1.0);
  final feed = level <= 0 ? 0.0 : (state.fxIn / level).clamp(0.0, 1.0);
  final commands = <List<String>>[];
  void add(double now, double? before, List<String> command) {
    if (before == null || (now - before).abs() > 1e-3) commands.add(command);
  }

  double? prevGate, prevFeed;
  if (previous != null) {
    prevGate = previous.level <= 0 ? 0.0 : (previous.dry / previous.level).clamp(0.0, 1.0);
    prevFeed = previous.level <= 0 ? 0.0 : (previous.fxIn / previous.level).clamp(0.0, 1.0);
  }
  add(state.low, previous?.low, _command('bass@lo', 'g', state.low, 1));
  add(state.mid, previous?.mid, _command('equalizer@mid', 'g', state.mid, 1));
  add(state.high, previous?.high, _command('treble@hi', 'g', state.high, 1));
  add(state.highpass, previous?.highpass, _command('highpass@hp', 'f', state.highpass, 0));
  add(state.lowpass, previous?.lowpass, _command('lowpass@lp', 'f', state.lowpass, 0));
  // The flanger and the phaser take over from the dry sound as they come in.
  double through(FxState s, double g) => g * (1 - s.flanger - s.phaser).clamp(0.0, 1.0);
  add(
    through(state, gate),
    prevGate == null ? null : through(previous!, prevGate),
    _command('volume@dry', 'volume', through(state, gate)),
  );
  add(
    gate * state.flanger,
    prevGate == null ? null : prevGate * previous!.flanger,
    _command('volume@flw', 'volume', gate * state.flanger),
  );
  add(
    gate * state.phaser,
    prevGate == null ? null : prevGate * previous!.phaser,
    _command('volume@phw', 'volume', gate * state.phaser),
  );
  add(feed, prevFeed, _command('volume@fx', 'volume', feed));
  for (final (i, target) in ['volume@g1', 'volume@g2', 'volume@g3'].indexed) {
    double tap(FxState s) => s.echo * _pow(echoFeedback, i);
    add(tap(state), previous == null ? null : tap(previous), _command(target, 'volume', tap(state)));
  }
  add(state.reverb, previous?.reverb, _command('volume@rv', 'volume', state.reverb));
  add(state.noise, previous?.noise, _command('volume@noise', 'volume', state.noise * 0.4));
  return commands;
}

double _pow(double base, int exponent) {
  var result = 1.0;
  for (var i = 0; i < exponent; i++) {
    result *= base;
  }
  return result;
}

/// Sets the echo's taps to [seconds] apart (real time: the desktop's tempo change runs before the chain).
List<List<String>> mpvEchoDelayCommands(double seconds) => [
  for (var i = 1; i <= 3; i++)
    ['af-command', 'automix', 'delays', (seconds * i * 1000).toStringAsFixed(0), 'adelay@t$i'],
];
