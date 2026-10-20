import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/player/harmonic.dart';

void main() {
  test('Camelot compatibility includes neighbors, wraparound and relative major/minor', () {
    for (final pair in [('8A', '8A'), ('8A', '9A'), ('12A', '1A'), ('12B', '1B'), ('8A', '8B')]) {
      expect(camelotCompatible(pair.$1, pair.$2), isTrue);
      expect(camelotCompatible(pair.$2, pair.$1), isTrue);
    }
    for (final pair in [('8A', '10A'), ('8A', '9B'), ('0A', '1A'), ('13A', '12A'), ('C', 'C')]) {
      expect(camelotCompatible(pair.$1, pair.$2), isFalse);
    }
  });

  test('harmonic scores combine keys, folded tempos and unknowns', () {
    expect(harmonicScore('8A', 120, '8B', 120), 1);
    expect(harmonicScore('8A', 120, '8A', 60), 1);
    expect(harmonicScore('8A', 60, '8A', 120), 1);
    expect(harmonicScore('8A', 129.6, '8A', 120), closeTo(0.85, 1e-10));
    expect(harmonicScore('8A', 150, '8A', 120), 0.7);
    expect(harmonicScore('8A', 150, '8A', 100), 0.7);
    expect(harmonicScore('8A', 120, '3B', 120), 0.3);
    expect(harmonicScore('8A', 150, '3B', 120), 0);
    expect(harmonicScore(null, null, null, null), 0.5);
    expect(harmonicScore('8A', null, '8B', null), closeTo(0.85, 1e-10));
    expect(harmonicScore(null, 120, '8B', 120), closeTo(0.65, 1e-10));
    expect(harmonicScore(null, 0, null, double.nan), 0.5);
  });

  test('greedy ordering prefers compatible keys and keeps ties in their given order', () {
    final keys = {'start': '8A', 'bad': '3B', 'good': '9A', 'relative': '9B'};
    final items = ['bad', 'good', 'relative'];
    expect(harmonicOrder('start', items, (id) => (key: keys[id], bpm: 120)), ['good', 'relative', 'bad']);
    expect(items, ['bad', 'good', 'relative']);
    expect(harmonicOrder('start', items, (_) => (key: null, bpm: null)), items);
    expect(harmonicOrder('start', <String>[], (_) => (key: null, bpm: null)), isEmpty);
    expect(() => harmonicOrder('start', items, (_) => (key: null, bpm: null), window: 0), throwsArgumentError);
  });

  test('ordering searches only the window and preserves seeded shuffle randomness', () {
    List<int> ordered(int seed) {
      final items = List.generate(30, (i) => i)..shuffle(Random(seed));
      final result = harmonicOrder(
        -1,
        items,
        (i) => (key: i.isEven ? '8A' : '3B', bpm: 120),
        window: 3,
        random: Random(seed),
      );
      final remaining = [...items];
      for (final item in result) {
        expect(remaining.indexOf(item), lessThan(3));
        remaining.remove(item);
      }
      return result;
    }

    expect(ordered(7), ordered(7));
    expect(ordered(7), isNot(ordered(8)));
    expect(harmonicOrder('8A', ['3B', '9A'], (key) => (key: key, bpm: null), window: 1), ['3B', '9A']);
  });
}
