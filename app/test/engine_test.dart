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
    MixPoints points({double? bpm, double mixIn = 0.5, double mixOut = 200, double end = 210}) =>
        MixPoints(bpm: bpm, mixIn: mixIn, mixOut: mixOut, end: end);

    test('matches close tempos and starts the next song at its first beat', () {
      final plan = automixPlan(points(bpm: 124, mixOut: 200.25), points(bpm: 120, mixIn: 1.5))!;
      expect(plan.start, const Duration(milliseconds: 200250));
      expect(plan.incomingStart, const Duration(milliseconds: 1500));
      expect(plan.duration, const Duration(milliseconds: 9750));
      expect(plan.speed, closeTo(124 / 120, 1e-9));
      expect(plan.beatMatched, isTrue);
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

    test('limits the overlap and skips songs without a usable outro', () {
      expect(automixPlan(points(mixOut: 100, end: 130), points())!.duration, const Duration(seconds: 14));
      expect(automixPlan(points(mixOut: 100, end: 102), points())!.duration, const Duration(seconds: 3));
      expect(automixPlan(points(mixOut: 100, end: 101), points()), isNull);
      expect(automixPlan(points(mixOut: 0, end: 5), points()), isNull);
    });

    test('swaps the bass on a beat near the middle of the overlap', () {
      // 9.75 s overlap at 124 BPM: the middle (4.875 s) rounds to beat 10 (4.84 s).
      final plan = automixPlan(points(bpm: 124, mixOut: 200.25), points(bpm: 120, mixIn: 1.5))!;
      expect(plan.bassSwap.inMicroseconds / 1e6, closeTo(10 * 60 / 124, 1e-3));
      expect(automixPlan(points(mixOut: 100, end: 110), points())!.bassSwap, const Duration(seconds: 5));
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
