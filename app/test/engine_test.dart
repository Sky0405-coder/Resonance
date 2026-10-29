import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:resonance/player/engine.dart';

void main() {
  group('linear crossfade volumes', () {
    (double, double) volumes(int milliseconds, {int seconds = 4}) => fadeVolumes(
      elapsed: Duration(milliseconds: milliseconds),
      crossfade: Duration(seconds: seconds),
      outgoingTarget: 0.4,
      incomingTarget: 0.8,
    );

    test('each track uses its own ReplayGain and user volume target', () {
      expect(volumes(0), (0.4, 0.0));
      final (outgoing, incoming) = volumes(1000);
      expect(outgoing, closeTo(0.3, 1e-10));
      expect(incoming, closeTo(0.2, 1e-10));
      expect(volumes(2000), (0.2, 0.4));
      expect(volumes(4000), (0.0, 0.8));
    });

    test('times outside the fade clamp to the endpoints', () {
      expect(volumes(-100), (0.4, 0.0));
      expect(volumes(5000), (0.0, 0.8));
      expect(volumes(0, seconds: 0), (0.0, 0.8));
    });
  });

  group('start fade decision', () {
    bool start({
      int crossfade = 4,
      bool playing = true,
      bool book = false,
      LoopMode loop = LoopMode.off,
      int? index = 0,
      int length = 2,
      int position = 96000,
      int? duration = 100000,
    }) => shouldStartFade(
      crossfadeSeconds: crossfade,
      playing: playing,
      isBook: book,
      loopMode: loop,
      index: index,
      length: length,
      position: Duration(milliseconds: position),
      duration: duration == null ? null : Duration(milliseconds: duration),
    );

    test('starts at the threshold, including a late position tick', () {
      expect(start(position: 95999), false);
      expect(start(), true);
      expect(start(position: 96050), true);
    });

    test('disabled crossfade preserves playlist gapless playback', () {
      expect(start(crossfade: 0), false);
    });

    test('paused playback and audiobooks never fade', () {
      expect(start(playing: false), false);
      expect(start(book: true), false);
    });

    test('repeat one never fades', () {
      expect(start(loop: LoopMode.one), false);
    });

    test('last item fades only when repeat all wraps the queue', () {
      expect(start(index: 1), false);
      expect(start(index: 1, loop: LoopMode.all), true);
      expect(start(length: 1, loop: LoopMode.all), true);
    });

    test('short tracks need more than twice the fade duration', () {
      expect(start(duration: 7999, position: 4000), false);
      expect(start(duration: 8000, position: 4000), false);
      expect(start(duration: 8001, position: 4001), true);
    });

    test('unknown duration, empty queue and completed tracks do not fade', () {
      expect(start(duration: null), false);
      expect(start(index: null), false);
      expect(start(length: 0), false);
      expect(start(position: 100000), false);
    });
  });

  group('shuffle and original queue order', () {
    test('keeps the selected track first and every other entry exactly once', () {
      final original = List.generate(20, (index) => 'track-$index');
      final shuffled = shuffleQueue(original, 7, random: Random(42));
      expect(shuffled.first, original[7]);
      expect(shuffled, unorderedEquals(original));
      expect(shuffled.skip(1), isNot(original.where((track) => track != original[7])));
      expect(original[7], 'track-7');
    });

    test('unshuffle restores the original order and current track index', () {
      final original = ['a', 'b', 'c', 'd'];
      final shuffled = shuffleQueue(original, 2, random: Random(1));
      final (restored, index) = unshuffleQueue(original, shuffled[2]);
      expect(restored, original);
      expect(restored[index], shuffled[2]);
      expect(identical(restored, original), false);
    });

    test('single-track queues work in both directions', () {
      expect(shuffleQueue(['a'], 0), ['a']);
      final (restored, index) = unshuffleQueue(['a'], 'a');
      expect(restored, ['a']);
      expect(index, 0);
    });

    test('duplicate tracks retain distinct queue entries', () {
      final a = Object();
      final b = Object();
      final original = [a, b, a];
      final shuffled = shuffleQueue(original, 1, random: Random(1));
      expect(shuffled.first, same(b));
      expect(shuffled.where((track) => identical(track, a)).length, 2);
      final (restored, index) = unshuffleQueue(original, b);
      expect(restored, orderedEquals(original));
      expect(index, 1);
    });
  });

  group('replace upcoming queue', () {
    test('keeps the current object and removes every matching seed id', () {
      const current = (id: 'seed', title: 'Playing');
      final tracks = [
        (id: 'a', title: 'First'),
        (id: 'seed', title: 'Other metadata'),
        (id: 'b', title: 'Second'),
        current,
      ];
      final (queue, original) = replaceUpcomingQueue(current, tracks, id: (track) => track.id, shuffle: false);
      expect(queue, [current, tracks[0], tracks[2]]);
      expect(original, queue);
      expect(identical(queue, original), false);
      expect(tracks, hasLength(4));
    });

    test('shuffles only upcoming songs and retains the order for unshuffle', () {
      final tracks = ['seed', ...List.generate(20, (index) => 'track-$index')];
      final (queue, original) = replaceUpcomingQueue(
        'seed',
        tracks,
        id: (track) => track,
        shuffle: true,
        random: Random(42),
      );
      expect(queue.first, 'seed');
      expect(queue.skip(1), unorderedEquals(tracks.skip(1)));
      expect(queue.skip(1), isNot(orderedEquals(tracks.skip(1))));
      expect(original, tracks);
      final (restored, index) = unshuffleQueue(original, queue[4]);
      expect(restored, tracks);
      expect(restored[index], queue[4]);
    });

    test('an empty radio leaves the seed as the sole item with either shuffle setting', () {
      for (final shuffle in [false, true]) {
        final (queue, original) = replaceUpcomingQueue('seed', <String>[], id: (track) => track, shuffle: shuffle);
        expect(queue, ['seed']);
        expect(original, ['seed']);
      }
    });
  });

  group('automix plan', () {
    MixPoints points({
      double? bpm,
      double mixIn = 0.5,
      double mixOut = 200,
      double end = 210,
      double? vocalsIn,
      double? vocalsOut,
    }) => MixPoints(bpm: bpm, mixIn: mixIn, mixOut: mixOut, end: end, vocalsIn: vocalsIn, vocalsOut: vocalsOut);

    test('parses optional vocal bounds as doubles', () {
      final json = <String, dynamic>{'bpm': 120, 'mix_in': 0.5, 'mix_out': 200, 'end': 210};
      final missing = MixPoints.fromJson(json);
      expect((missing.vocalsIn, missing.vocalsOut), (null, null));
      final vocals = MixPoints.fromJson({...json, 'vocals_in': 8, 'vocals_out': 204.25});
      expect((vocals.vocalsIn, vocals.vocalsOut), (8.0, 204.25));
      final absent = MixPoints.fromJson({...json, 'vocals_in': null, 'vocals_out': null});
      expect((absent.vocalsIn, absent.vocalsOut), (null, null));
    });

    Duration secs(double s) => Duration(microseconds: (s * 1e6).round());

    test('matches close tempos and starts the next song at its first beat', () {
      final plan = automixPlan(points(bpm: 120, mixOut: 200.25), points(bpm: 120, mixIn: 1.5))!;
      expect(plan.incomingStart, const Duration(milliseconds: 1500));
      expect(plan.speed, closeTo(1, 1e-6));
      expect(plan.beatMatched, isTrue);
      expect(automixPlan(points(bpm: 124), points(bpm: 120))!.speed, closeTo(124 / 120, 1e-9));
    });

    test('folds double and half time', () {
      expect(automixPlan(points(bpm: 172), points(bpm: 86))!.speed, closeTo(1, 1e-6));
      expect(automixPlan(points(bpm: 90), points(bpm: 176))!.speed, closeTo(180 / 176, 1e-9));
      expect(automixPlan(points(bpm: 120), points(bpm: 120))!.beatMatched, isTrue);
    });

    test('blends without tempo change when tempos are too far apart or unknown', () {
      expect(automixPlan(points(bpm: 128), points(bpm: 100))!.beatMatched, isFalse);
      expect(automixPlan(points(), points(bpm: 100))!.speed, 1);
    });

    test('blends run about 32 beats, starting earlier by whole bars when the outro is shorter', () {
      // 120 BPM: 32 beats are 16 s, one bar 2 s. The outro has 10 s, so the blend starts three bars earlier.
      final plan = automixPlan(points(bpm: 120, mixOut: 200, end: 210), points(bpm: 120))!;
      expect(plan.start, const Duration(seconds: 194));
      expect(plan.duration, const Duration(seconds: 16));
      expect(plan.bassSwap, const Duration(seconds: 8));
      // Slow songs are capped at 20 s, fast ones last at least 6 s; without a tempo 12 s.
      expect(automixPlan(points(bpm: 70, mixOut: 150), points(bpm: 70))!.duration, const Duration(seconds: 20));
      expect(automixPlan(points(mixOut: 150), points())!.duration, const Duration(seconds: 12));
      // A long outro is not used up entirely.
      expect(
        automixPlan(points(bpm: 120, mixOut: 100, end: 130), points(bpm: 120))!.duration,
        const Duration(seconds: 16),
      );
    });

    test('skips songs without a usable outro and never starts in the first half', () {
      expect(automixPlan(points(mixOut: 100, end: 101), points()), isNull);
      expect(automixPlan(points(mixOut: 0, end: 5), points()), isNull);
      final early = automixPlan(points(bpm: 120, mixOut: 20, end: 30), points(bpm: 120))!;
      expect(early.start, const Duration(seconds: 16));
      expect(early.duration, const Duration(seconds: 14));
      // A short outro: the blend reaches back into the song.
      final short = automixPlan(points(mixOut: 100, end: 102), points())!;
      expect((short.start, short.duration), (const Duration(seconds: 90), const Duration(seconds: 12)));
    });

    test('the crossfade setting asks for longer blends, up to 30 seconds', () {
      final plan = automixPlan(points(bpm: 120, mixOut: 200, end: 210), points(bpm: 120), minSeconds: 24)!;
      expect(plan.start, const Duration(seconds: 186));
      expect(plan.duration, const Duration(seconds: 24));
      expect(
        automixPlan(points(mixOut: 100, end: 130), points(), minSeconds: 40)!.duration,
        const Duration(seconds: 30),
      );
      expect(automixPlan(points(bpm: 120), points(bpm: 120), minSeconds: 5)!.duration, const Duration(seconds: 16));
    });

    test('the next voice comes in after the current one stopped, starting later by whole bars', () {
      // The blend would start at 194 s: the current voice ends 9 s in, the next one starts 5 s in. Two bars later
      // the voices follow each other and the bass swaps between them.
      final plan = automixPlan(points(bpm: 120, vocalsOut: 203), points(bpm: 120, mixIn: 1, vocalsIn: 6))!;
      expect(plan.start, const Duration(seconds: 198));
      expect(plan.duration, const Duration(seconds: 12));
      expect(plan.bassSwap, const Duration(seconds: 5));
    });

    test('voices that already follow each other keep the full blend and swap the bass between them', () {
      final plan = automixPlan(points(bpm: 120, vocalsOut: 195), points(bpm: 120, vocalsIn: 14.5))!;
      expect(plan.start, const Duration(seconds: 194));
      expect(plan.duration, const Duration(seconds: 16));
      expect(plan.bassSwap, const Duration(seconds: 8));
      final late = automixPlan(points(bpm: 120, vocalsOut: 205), points(bpm: 120, vocalsIn: 30))!;
      // Not before the current voice has ended (11 s in).
      expect(late.bassSwap, const Duration(seconds: 11));
    });

    test('when the voices cannot be separated the blend moves as late as the song allows', () {
      final plan = automixPlan(points(bpm: 120, vocalsOut: 209), points(bpm: 120, vocalsIn: 0.5))!;
      // At most until six seconds before the end, on a bar.
      expect(plan.start, const Duration(seconds: 204));
      expect(plan.duration, const Duration(seconds: 6));
      final unknownTempo = automixPlan(points(vocalsOut: 209.5), points(vocalsIn: 0.5))!;
      expect(unknownTempo.start, const Duration(seconds: 204));
      expect(unknownTempo.duration, const Duration(seconds: 6));
    });

    test('with only one voice known the other is assumed in the middle of the blend', () {
      // The current voice ends 12 s into a 16 s blend: start four seconds later.
      final outgoing = automixPlan(points(bpm: 120, vocalsOut: 206), points(bpm: 120))!;
      expect(outgoing.start, const Duration(seconds: 198));
      expect(outgoing.duration, const Duration(seconds: 12));
      // The next voice right at the start is fine when nothing is known about the current one.
      final incoming = automixPlan(points(bpm: 120), points(bpm: 120, vocalsIn: 0.5))!;
      expect(incoming.duration, const Duration(seconds: 16));
      expect(incoming.bassSwap, const Duration(milliseconds: 500));
    });

    test('null vocal bounds keep the blend', () {
      final outgoing = MixPoints.fromJson({
        'bpm': 120,
        'mix_in': 0.5,
        'mix_out': 200.25,
        'end': 210.25,
        'vocals_in': null,
        'vocals_out': null,
      });
      final incoming = MixPoints.fromJson({
        'bpm': 120,
        'mix_in': 1.5,
        'mix_out': 200,
        'end': 210,
        'vocals_in': null,
        'vocals_out': null,
      });
      final plan = automixPlan(outgoing, incoming)!;
      expect(plan.start, const Duration(milliseconds: 194250));
      expect(plan.incomingStart, const Duration(milliseconds: 1500));
      expect(plan.duration, const Duration(seconds: 16));
      expect(plan.bassSwap, const Duration(seconds: 8));
      expect(plan.filterOut, isFalse);
    });

    test('vocal bounds leave the filter-out transition unchanged', () {
      final plan = automixPlan(points(bpm: 128, vocalsOut: 210), points(bpm: 100, vocalsIn: 0), minSeconds: 20)!;
      expect(plan.filterOut, isTrue);
      // Eight beats at 128 BPM = 3.75 s, at least 4 s, starting 6 s before the end.
      expect(plan.duration, const Duration(seconds: 4));
      expect(plan.start, const Duration(seconds: 204));
      expect(plan.bassSwap, Duration.zero);
    });

    test('swaps the bass on a beat near the middle of the overlap', () {
      final plan = automixPlan(points(bpm: 124, mixOut: 200.25), points(bpm: 120, mixIn: 1.5))!;
      final beat = 60 / 124;
      expect(plan.duration, secs(32 * beat));
      expect(plan.bassSwap.inMicroseconds / 1e6, closeTo(16 * beat, 1e-3));
      expect(automixPlan(points(mixOut: 100, end: 110), points())!.bassSwap, const Duration(seconds: 6));
      // Up to 16 % tempo difference is matched.
      expect(automixPlan(points(bpm: 115), points(bpm: 100))!.beatMatched, isTrue);
      expect(automixPlan(points(bpm: 120), points(bpm: 100))!.beatMatched, isFalse);
    });

    test('larger tempo differences meet in the middle', () {
      final small = automixPlan(points(bpm: 103), points(bpm: 100))!;
      expect(small.outgoingSpeed, 1);
      expect(small.speed, closeTo(1.03, 1e-9));
      final large = automixPlan(points(bpm: 112), points(bpm: 100))!;
      // Both move about 5.8 %, and the incoming song still follows the outgoing beat.
      expect(large.outgoingSpeed, closeTo(1 / sqrt(1.12), 1e-9));
      expect(large.speed, closeTo(sqrt(1.12), 1e-9));
      expect(large.ratio, closeTo(1.12, 1e-9));
      expect(112 * large.outgoingSpeed, closeTo(100 * large.speed, 1e-9));
    });

    test('camelot compatibility', () {
      expect(camelotCompatible('8A', '8A'), isTrue);
      expect(camelotCompatible('8A', '9A'), isTrue);
      expect(camelotCompatible('12B', '1B'), isTrue);
      expect(camelotCompatible('8A', '8B'), isTrue);
      expect(camelotCompatible('8A', '10A'), isFalse);
      expect(camelotCompatible('8A', '9B'), isFalse);
    });

    test('clashing keys blend for half as long, clashing tempos filter out', () {
      MixPoints keyed({double? bpm, String? key}) =>
          MixPoints(bpm: bpm, mixIn: 0.5, mixOut: 190, end: 210, key: key, keyConfidence: 0.3);
      final clash = automixPlan(keyed(bpm: 120, key: '8A'), keyed(bpm: 121, key: '3B'))!;
      expect(clash.filterOut, isFalse);
      expect(clash.beatMatched, isTrue);
      expect(clash.duration, const Duration(seconds: 8));
      final tempo = automixPlan(keyed(bpm: 128), keyed(bpm: 100))!;
      expect((tempo.filterOut, tempo.beatMatched), (true, false));
      expect(tempo.duration, const Duration(seconds: 4));
      expect(tempo.start, const Duration(seconds: 204));
      expect(
        automixPlan(keyed(bpm: 120, key: '8A'), keyed(bpm: 120, key: '9A'))!.duration,
        const Duration(seconds: 16),
      );
      expect(automixPlan(keyed(), keyed())!.filterOut, isFalse);
    });

    test('filter-out volumes and sweep steps', () {
      const d = Duration(seconds: 4);
      final (outStart, inStart) = filterOutVolumes(
        elapsed: Duration.zero,
        duration: d,
        outgoingTarget: 1,
        incomingTarget: 1,
      );
      expect((outStart, inStart), (1.0, 0.0));
      final (_, inEarly) = filterOutVolumes(
        elapsed: const Duration(milliseconds: 1600),
        duration: d,
        outgoingTarget: 1,
        incomingTarget: 1,
      );
      expect(inEarly, closeTo(1, 1e-9));
      expect(filterOutCut(1).lowUpTo, 250);
      expect(filterOutCut(4).lowUpTo, 2000);
      expect(filterOutCut(4).lowDb, -24);
      expect(filterOutCut(2, bpm: 120).echoMs, 250);
      expect(filterOutCut(3, bpm: 120).mpvFilter, 'lavfi=[highpass=f=1000:p=2,aecho=0.8:0.6:250:0.35]');
      expect(AutomixCut.bassSwap.reductionAt(100), automixBassCutDb);
      expect(AutomixCut.bassSwap.reductionAt(1000), automixVocalCutDb);
      expect(AutomixCut.bassSwap.reductionAt(8000), 0);
    });

    test('equal-power volumes', () {
      final (start, _) = automixVolumes(
        elapsed: Duration.zero,
        duration: const Duration(seconds: 10),
        outgoingTarget: 1,
        incomingTarget: 0.5,
      );
      expect(start, 1);
      final (out, inc) = automixVolumes(
        elapsed: const Duration(seconds: 5),
        duration: const Duration(seconds: 10),
        outgoingTarget: 1,
        incomingTarget: 1,
      );
      expect(out * out + inc * inc, closeTo(1, 1e-9));
      final (end, last) = automixVolumes(
        elapsed: const Duration(seconds: 11),
        duration: const Duration(seconds: 10),
        outgoingTarget: 1,
        incomingTarget: 0.5,
      );
      expect(end, closeTo(0, 1e-9));
      expect(last, 0.5);
    });

    test('reads server json', () {
      final p = MixPoints.fromJson({'bpm': null, 'mix_in': 1, 'mix_out': 200.5, 'end': 210});
      expect((p.bpm, p.mixIn, p.mixOut, p.end), (null, 1.0, 200.5, 210.0));
    });
  });
}
