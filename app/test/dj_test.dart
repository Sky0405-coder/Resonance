import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/ui/pages/dj_page.dart';

void main() {
  test('sync matches the other deck, counting double and half time, within 16 %', () {
    expect(syncSpeed(120, 126), closeTo(1.05, 1e-9));
    expect(syncSpeed(70, 140), 1, reason: 'half time');
    expect(syncSpeed(172, 87), closeTo(174 / 172, 1e-9));
    expect(syncSpeed(100, 130), isNull);
    expect(syncSpeed(0, 120), isNull);
  });

  test('beat phase counts from the downbeat', () {
    expect(beatPhase(10.25, 0.25, 0.5), 0);
    expect(beatPhase(10.5, 0.25, 0.5), closeTo(0.5, 1e-9));
    expect(beatPhase(0.0, 0.25, 0.5), closeTo(0.5, 1e-9), reason: 'before the downbeat');
  });

  test('the next bar counts four beats from the downbeat and keeps a minimum distance', () {
    expect(untilNextBar(10, 0, 0.5), closeTo(0, 1e-9), reason: 'right on a bar');
    expect(untilNextBar(10.5, 0, 0.5), closeTo(1.5, 1e-9));
    expect(untilNextBar(9.9, 0.1, 0.5), closeTo(0.2, 1e-9));
    expect(untilNextBar(9.9, 0.1, 0.5, minimum: 0.3), closeTo(2.2, 1e-9));
  });

  test('the crossfader keeps the power even', () {
    final (onlyA, none) = crossfaderGains(-1);
    expect((onlyA, none.abs() < 1e-9), (1.0, true));
    final (a, b) = crossfaderGains(0);
    expect(a * a + b * b, closeTo(1, 1e-9));
    expect(a, closeTo(math.sqrt(0.5), 1e-9));
    final (left, right) = crossfaderGains(1);
    expect(left, closeTo(0, 1e-9));
    expect(right, 1.0);
  });
}
