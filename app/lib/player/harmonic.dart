import 'dart:math';

import 'engine.dart' show camelotCompatible;

export 'engine.dart' show camelotCompatible;

double harmonicScore(String? keyA, double? bpmA, String? keyB, double? bpmB) {
  final keyPart = keyA == null || keyB == null ? 0.5 : (camelotCompatible(keyA, keyB) ? 1.0 : 0.0);
  var tempoPart = 0.5;
  if (bpmA != null && bpmB != null && bpmA.isFinite && bpmB.isFinite && bpmA > 0 && bpmB > 0) {
    var ratio = bpmA / bpmB;
    if (ratio.isFinite && ratio > 0) {
      while (ratio >= 1.5) {
        ratio /= 2;
      }
      while (ratio < 0.75) {
        ratio *= 2;
      }
      tempoPart = 1 - min(1, (ratio - 1).abs() / 0.16);
    }
  }
  return 0.7 * keyPart + 0.3 * tempoPart;
}

List<T> harmonicOrder<T>(
  T start,
  List<T> items,
  ({String? key, double? bpm}) Function(T) info, {
  int window = 6,
  Random? random,
}) {
  if (window < 1) throw ArgumentError.value(window, 'window');
  final remaining = [...items];
  final ordered = <T>[];
  var previous = start;
  while (remaining.isNotEmpty) {
    final from = info(previous);
    var best = 0;
    var bestScore = -1.0;
    for (var i = 0; i < min(window, remaining.length); i++) {
      final to = info(remaining[i]);
      final score = harmonicScore(from.key, from.bpm, to.key, to.bpm);
      if (score > bestScore) {
        best = i;
        bestScore = score;
      }
    }
    previous = remaining.removeAt(best);
    ordered.add(previous);
  }
  return ordered;
}
