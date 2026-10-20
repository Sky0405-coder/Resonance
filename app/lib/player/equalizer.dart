import 'dart:math' as math;

const equalizerFrequencies = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

const equalizerPresets = <String, List<double>>{
  'flat': [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  'bass': [6, 5, 4, 2, 0, 0, 0, 0, 0, 0],
  'treble': [0, 0, 0, 0, 0, 0, 2, 4, 5, 6],
  'vocal': [-2, -2, -1, 1, 3, 4, 3, 1, 0, -1],
  'rock': [4, 3, 2, 0, -1, -1, 1, 2, 3, 4],
  'pop': [-1, 0, 2, 3, 3, 1, 0, 0, 1, 1],
  'hiphop': [5, 4, 2, 1, -1, -1, 1, 0, 1, 2],
  'electronic': [4, 4, 2, 0, -2, 0, 1, 2, 4, 4],
  'acoustic': [2, 2, 1, 0, 1, 1, 2, 2, 1, 1],
  'loudness': [5, 3, 0, 0, -1, 0, -1, 2, 4, 5],
};

double _gain(double gain) => gain.isFinite ? (gain.clamp(-12.0, 12.0) * 2).round() / 2 : 0;

class EqualizerSettings {
  EqualizerSettings({this.enabled = false, this.preset = 'flat', List<double>? gains})
    : gains = List.unmodifiable(
        List.generate(equalizerFrequencies.length, (i) => _gain(gains != null && i < gains.length ? gains[i] : 0)),
      );

  final bool enabled;
  final String preset;
  final List<double> gains;

  EqualizerSettings copyWith({bool? enabled, String? preset, List<double>? gains}) =>
      EqualizerSettings(enabled: enabled ?? this.enabled, preset: preset ?? this.preset, gains: gains ?? this.gains);

  EqualizerSettings withPreset(String preset) => copyWith(preset: preset, gains: equalizerPresets[preset] ?? gains);

  EqualizerSettings withGain(int band, double gain) => copyWith(preset: 'custom', gains: [...gains]..[band] = gain);

  Map<String, dynamic> toJson() => {'enabled': enabled, 'preset': preset, 'gains': gains};

  factory EqualizerSettings.fromJson(Map<String, dynamic> json) {
    final preset = json['preset'];
    final gains = json['gains'];
    return EqualizerSettings(
      enabled: json['enabled'] == true,
      preset: preset is String && (equalizerPresets.containsKey(preset) || preset == 'custom') ? preset : 'flat',
      gains: gains is List ? [for (final gain in gains) gain is num ? gain.toDouble() : 0] : null,
    );
  }
}

String _number(double number) => number == number.roundToDouble() ? number.toInt().toString() : number.toString();

String? mpvEqualizerFilter(EqualizerSettings s) {
  if (!s.enabled || s.gains.every((gain) => gain == 0)) return null;
  final filters = [
    for (var i = 0; i < equalizerFrequencies.length; i++)
      if (s.gains[i] != 0) 'equalizer=f=${equalizerFrequencies[i]}:t=o:w=1:g=${_number(s.gains[i])}',
  ];
  final preamp = s.gains.fold<double>(0, math.max);
  if (preamp > 0) filters.add('volume=-${_number(preamp)}dB');
  return 'lavfi=[${filters.join(',')}]';
}

/// Assign each fixed band to the closest device band in octaves, then average its gains.
List<int> androidBandLevels(List<double> gains, List<int> centerFrequenciesMilliHz, int minMb, int maxMb) {
  if (centerFrequenciesMilliHz.isEmpty) return [];
  final sums = List<double>.filled(centerFrequenciesMilliHz.length, 0);
  final counts = List<int>.filled(centerFrequenciesMilliHz.length, 0);
  double distance(int fixed, int device) =>
      (math.log(equalizerFrequencies[fixed]) - math.log(centerFrequenciesMilliHz[device] / 1000)).abs();
  for (var fixed = 0; fixed < equalizerFrequencies.length; fixed++) {
    var nearest = 0;
    for (var device = 1; device < sums.length; device++) {
      if (distance(fixed, device) < distance(fixed, nearest)) nearest = device;
    }
    sums[nearest] += gains[fixed];
    counts[nearest]++;
  }
  final preamp = gains.fold<double>(0, math.max);
  return List.generate(sums.length, (device) {
    var nearest = 0;
    for (var fixed = 1; fixed < equalizerFrequencies.length; fixed++) {
      if (distance(fixed, device) < distance(nearest, device)) nearest = fixed;
    }
    final gain = counts[device] == 0 ? gains[nearest] : sums[device] / counts[device];
    return ((gain - preamp) * 100).round().clamp(minMb, maxMb);
  });
}

/// The gain of the nearest band (in log frequency) at [frequency] Hz.
double equalizerGainAt(List<double> gains, double frequency) {
  var best = 0;
  for (var i = 1; i < equalizerFrequencies.length; i++) {
    if ((math.log(equalizerFrequencies[i] / frequency)).abs() <
        (math.log(equalizerFrequencies[best] / frequency)).abs()) {
      best = i;
    }
  }
  return gains[best];
}
