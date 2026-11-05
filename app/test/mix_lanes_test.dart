import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/mix_fx.dart';
import 'package:resonance/player/mix_lanes.dart';

const _points = MixPoints(bpm: 120, mixIn: 0.5, mixOut: 200, end: 210);

void main() {
  test('every lane ends with the next song as it is and starts with the current one untouched', () {
    for (final volume in VolumeLane.values) {
      for (final eq in EqLane.values) {
        for (final filter in FilterLane.values) {
          final lanes = MixLanes(volume: volume, eq: eq, filter: filter, effect: EffectLane.echoBeatTail);
          final (out0, _) = laneStates(lanes, 0, 4);
          final (_, in1) = laneStates(lanes, 1, 4);
          expect(in1.values, FxState.neutral.values, reason: '$volume $eq $filter');
          if (eq != EqLane.longBassCut && eq != EqLane.swapStart && eq != EqLane.threeBand) {
            expect(out0.low, 0, reason: '$eq');
          }
          expect(out0.highpass, mixHighpassOff);
          expect(out0.lowpass, mixLowpassOff);
        }
      }
    }
  });

  test('volume lanes cut, fade and overlap where their names say', () {
    const bar = 1 / 4;
    expect(laneVolumes(VolumeLane.centerCut, 0.49, bar), (1, 0));
    expect(laneVolumes(VolumeLane.centerCut, 0.5, bar), (0, 1));
    expect(laneVolumes(VolumeLane.overlap, 0.99, bar), (1, 1));
    expect(laneVolumes(VolumeLane.fadeInHardOut, 0.25, bar), (1, 0.5));
    expect(laneVolumes(VolumeLane.overlapCutBar, 0.74, bar).$1, 1);
    expect(laneVolumes(VolumeLane.overlapCutBar, 0.76, bar).$1, 0);
    expect(laneVolumes(VolumeLane.fadeInQuickOut, 0.875, bar).$1, closeTo(0.5, 1e-9));
    final (o, i) = laneVolumes(VolumeLane.smooth, 0.5, bar);
    expect(o, closeTo(i, 1e-9));
  });

  test('EQ hands the bass over; three bands go one after another', () {
    const swap = MixLanes();
    expect(laneStates(swap, 0.3, 4).$1.low, 0);
    expect(laneStates(swap, 0.3, 4).$2.low, mixCutDb);
    expect(laneStates(swap, 0.7, 4).$1.low, mixCutDb);
    expect(laneStates(swap, 0.7, 4).$2.low, 0);
    final (out, inc) = laneStates(const MixLanes(eq: EqLane.threeBand), 0.5, 4);
    expect(out.low, mixCutDb);
    expect(out.mid, closeTo(mixCutDb / 2, 1e-9));
    expect(out.high, 0);
    expect(inc.high, mixCutDb);
  });

  test('filters sweep in octaves; the noise riser swells and stops', () {
    final half = laneStates(const MixLanes(filter: FilterLane.highpassInLowpassOut), 0.25, 4);
    expect(half.$2.highpass, closeTo(155, 1));
    expect(half.$1.lowpass, mixLowpassOff);
    expect(laneStates(const MixLanes(filter: FilterLane.highpassInLowpassOut), 0.99, 4).$1.lowpass, lessThan(300));
    const noise = MixLanes(filter: FilterLane.noiseEnd);
    expect(laneStates(noise, 0.4, 4).$1.noise, 0);
    expect(laneStates(noise, 0.99, 4).$1.noise, greaterThan(0.9));
    expect(laneStates(noise, 1, 4).$1.noise, 0);
  });

  test('a tail effect stops the song a bar early while its echo rings on', () {
    const lanes = MixLanes(volume: VolumeLane.overlap, effect: EffectLane.echoHalfTail);
    expect(laneStates(lanes, 0.4, 4).$1.fxIn, 0);
    expect(laneStates(lanes, 0.6, 4).$1.fxIn, 1);
    final last = laneStates(lanes, 0.9, 4).$1;
    expect((last.dry, last.fxIn, last.echo, last.level), (0, 0, 0.6, 1));
    // Cut ones keep the song to the end.
    expect(laneStates(lanes.copyWith(effect: EffectLane.echoHalfCut), 0.9, 4).$1.dry, 1);
  });

  test('loops fit into the first half', () {
    expect(fittingLoopBeats(const MixLanes(loopBeats: 16), 4), 8);
    expect(fittingLoopBeats(const MixLanes(loopBeats: 16), 1), 2);
    expect(fittingLoopBeats(const MixLanes(loopBeats: 4), 16), 4);
  });

  test('saved lanes round-trip; older apps get the closest style and older transitions get lanes', () {
    const lanes = MixLanes(
      volume: VolumeLane.fadeInCutBar,
      eq: EqLane.quickBassCut,
      filter: FilterLane.lowpassOut,
      effect: EffectLane.reverbTail,
      loopBeats: 8,
      beatmatch: false,
    );
    const transition = CustomTransition(
      style: TransitionStyle.fadeIn,
      bars: 8,
      start: 180,
      incomingStart: 4,
      lanes: lanes,
    );
    final back = CustomTransition.fromJson(transition.toJson())!;
    expect(back, transition);
    expect(CustomTransition.styleForLanes(lanes), TransitionStyle.fadeIn);
    expect(transition.copyWith(lanes: const MixLanes(filter: FilterLane.highpassOut)).style, TransitionStyle.filter);
    const old = CustomTransition(style: TransitionStyle.fadeOut, bars: 4, start: 1, incomingStart: 0);
    expect(old.effectiveLanes.volume, VolumeLane.fadeInOut);
    expect(MixLanes.fromJson({'volume': 'nope', 'loop': 3}), const MixLanes());
  });

  test('without beatmatching the songs keep their tempos; lanes swap in the middle', () {
    const fast = MixPoints(bpm: 128, mixIn: 0.5, mixOut: 200, end: 210);
    const transition = CustomTransition(
      style: TransitionStyle.crossfade,
      bars: 4,
      start: 190,
      incomingStart: 0,
      lanes: MixLanes(beatmatch: false),
    );
    final plan = customAutomixPlan(_points, fast, transition);
    expect((plan.speed, plan.outgoingSpeed, plan.beatMatched), (1.0, 1.0, false));
    expect(plan.bassSwap, plan.duration ~/ 2);
    final matched = customAutomixPlan(_points, fast, transition.copyWith(lanes: const MixLanes()));
    expect(matched.beatMatched, isTrue);
  });

  test('the Android automation is keyed by song time and carries the echo and loop on the beat', () {
    const lanes = MixLanes(effect: EffectLane.echoThreeQuarterCut, loopBeats: 4);
    final automation = buildAutomation(
      lanes: lanes,
      bars: 4,
      outgoing: true,
      duration: 8,
      songStart: 180,
      rate: 1.05,
      beat: 0.5,
    );
    expect(automation.startUs, 180000000);
    expect(automation.stepUs, 21000);
    expect(automation.values, hasLength(10));
    expect(automation.values.first, hasLength(401));
    expect(automation.echoDelay, 0.375);
    expect(automation.loopAtUs, ((180 + 4 * 1.05) * 1e6).round());
    expect(automation.loopSeconds, 2);
    expect(automation.shifted(1000).startUs, 180001000);
    final incoming = buildAutomation(
      lanes: lanes,
      bars: 4,
      outgoing: false,
      duration: 8,
      songStart: 3,
      rate: 1,
      beat: 0.5,
    );
    expect(incoming.loopAtUs, isNull);
  });

  test('desktop commands only send what changed, with the volume left to the player', () {
    final all = mpvFxCommands(FxState.neutral, null);
    expect(all.map((c) => c.last), contains('volume@dry'));
    expect(mpvFxCommands(FxState.neutral, FxState.neutral), isEmpty);
    const tail = FxState(level: 0.5, dry: 0, fxIn: 0.5, echo: 0.6);
    final commands = mpvFxCommands(tail, FxState.neutral, echoFeedback: 0.5);
    String value(String target) => commands.firstWhere((c) => c.last == target)[3];
    expect(value('volume@dry'), '0.000');
    expect(value('volume@fx'), '1.000');
    expect(value('volume@g1'), '0.600');
    expect(value('volume@g2'), '0.300');
    expect(mpvEchoDelayCommands(0.375).map((c) => c[3]), ['375', '750', '1125']);
    expect(mixMpvFilter, contains('bass@lo'));
    expect(mixMpvFilter, contains('highpass@hp'));
  });
}
