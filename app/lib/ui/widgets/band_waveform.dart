import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../player/spectrum.dart';

/// Colours of the three-band waveform, as in DJ software: bass blue, mids amber, highs white.
const waveLowColor = Color(0xFF2F7BEA);
const waveMidColor = Color(0xFFF2A33A);
const waveHighColor = Color(0xFFF4F1EA);

/// The bass, mids and highs of a song over time (0–1 each, every band scaled to its own loudest moment), read from
/// its spectrum for drawing.
class BandEnvelope {
  BandEnvelope._(this._spectrum, this._groups, this._counts, this._scale);

  static final _cache = Expando<BandEnvelope>();

  /// The envelope of [spectrum] (computed once per spectrum).
  factory BandEnvelope.of(Spectrum spectrum) => _cache[spectrum] ??= BandEnvelope._build(spectrum);

  factory BandEnvelope._build(Spectrum spectrum) {
    final bands = spectrum.bands;
    final groups = [
      for (var i = 0; i < bands; i++)
        switch (Spectrum.bandFrequency(i, bands)) {
          < 200 => 0,
          < 2500 => 1,
          _ => 2,
        },
    ];
    final counts = [0, 0, 0];
    for (final g in groups) {
      counts[g]++;
    }
    final envelope = BandEnvelope._(spectrum, groups, counts, [1, 1, 1]);
    // The loudest moment fills the height; the bands keep their balance.
    final peaks = [0.0, 0.0, 0.0], out = [0.0, 0.0, 0.0];
    final step = math.max(1, spectrum.frameCount ~/ 2000);
    for (var frame = 0; frame < spectrum.frameCount; frame += step) {
      envelope._raw(frame / spectrum.fps, out);
      for (var g = 0; g < 3; g++) {
        peaks[g] = math.max(peaks[g], out[g]);
      }
    }
    final peak = peaks.reduce(math.max);
    envelope._scale.fillRange(0, 3, peak <= _floor ? 1 : 1 / (peak - _floor));
    return envelope;
  }

  final Spectrum _spectrum;
  final List<int> _groups;
  final List<int> _counts;
  final List<double> _scale;
  late final _levels = List<double>.filled(_spectrum.bands, 0);

  /// Levels below this (the spectrum maps 48 dB onto 0–1) count as silence.
  static const _floor = 0.3;

  void _raw(double seconds, List<double> out) {
    _spectrum.levelsAt(Duration(microseconds: (seconds * 1e6).round()), _levels);
    out.fillRange(0, 3, 0);
    for (var i = 0; i < _levels.length; i++) {
      out[_groups[i]] += _levels[i];
    }
    for (var g = 0; g < 3; g++) {
      out[g] = _counts[g] == 0 ? 0 : out[g] / _counts[g];
    }
  }

  /// Bass, mids and highs at [seconds] into [out], each 0–1.
  void at(double seconds, List<double> out) {
    _raw(seconds, out);
    for (var g = 0; g < 3; g++) {
      out[g] = ((out[g] - _floor) * _scale[g]).clamp(0.0, 1.0);
    }
  }
}

/// Draws [spectrum] as a three-band waveform across [rect]: for each x, [songTime] gives the song's time there
/// (null where it has none) and [opacity] how strongly it shows. Bass is the outer shape, mids and highs sit inside it.
void paintBandWaveform(
  Canvas canvas,
  Rect rect,
  Spectrum spectrum, {
  required double? Function(double x) songTime,
  double Function(double x)? opacity,
  Color background = const Color(0xFF121212),
}) {
  final envelope = BandEnvelope.of(spectrum);
  final center = rect.center.dy;
  final half = rect.height / 2;
  final levels = [0.0, 0.0, 0.0];
  const step = 2.0;
  // Runs of columns with a song time and the same opacity, each filled as one shape per band.
  final xs = <double>[];
  final heights = [<double>[], <double>[], <double>[]];
  double? runOpacity;

  void flush() {
    if (xs.length >= 2) {
      final alpha = runOpacity ?? 1;
      for (final (band, color, share) in const [
        (0, waveLowColor, 1.0),
        (1, waveMidColor, 0.85),
        (2, waveHighColor, 0.6),
      ]) {
        final path = Path()..moveTo(xs.first, center);
        for (var i = 0; i < xs.length; i++) {
          path.lineTo(xs[i], center - heights[band][i] * half * share);
        }
        for (var i = xs.length - 1; i >= 0; i--) {
          path.lineTo(xs[i], center + heights[band][i] * half * share);
        }
        path.close();
        // Dimmed by mixing with the background, so the layers do not show through each other.
        canvas.drawPath(path, Paint()..color = Color.lerp(background, color, alpha)!);
      }
    }
    xs.clear();
    for (final h in heights) {
      h.clear();
    }
  }

  for (var x = rect.left; x <= rect.right; x += step) {
    final t = songTime(x);
    final alpha = opacity?.call(x) ?? 1;
    if (t == null || t < 0 || alpha != runOpacity) {
      if (xs.isNotEmpty) {
        // Close the run at this column so neighbouring runs meet without a gap.
        if (t != null && t >= 0) {
          envelope.at(t, levels);
          xs.add(x);
          for (var g = 0; g < 3; g++) {
            heights[g].add(levels[g]);
          }
        }
        flush();
      }
      runOpacity = alpha;
      if (t == null || t < 0) continue;
    }
    envelope.at(t, levels);
    xs.add(x);
    for (var g = 0; g < 3; g++) {
      heights[g].add(levels[g]);
    }
  }
  flush();
}
