import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/player/equalizer.dart';

void main() {
  group('equalizer settings', () {
    test('defaults to a disabled, flat ten-band equalizer', () {
      final settings = EqualizerSettings();
      expect(settings.enabled, isFalse);
      expect(settings.preset, 'flat');
      expect(settings.gains, List.filled(10, 0));
      expect(equalizerFrequencies, [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]);
    });

    test('presets use the specified gains and keep the enabled state', () {
      const expected = {
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
      expect(equalizerPresets.keys, expected.keys);
      for (final preset in expected.entries) {
        final settings = EqualizerSettings(enabled: true).withPreset(preset.key);
        expect(settings.preset, preset.key);
        expect(settings.gains, preset.value);
        expect(settings.enabled, isTrue);
      }
    });

    test('editing a band selects custom without changing the previous settings', () {
      final bass = EqualizerSettings(enabled: true).withPreset('bass');
      final custom = bass.withGain(3, -4.5);
      expect(custom.preset, 'custom');
      expect(custom.gains, [6, 5, 4, -4.5, 0, 0, 0, 0, 0, 0]);
      expect(custom.withPreset('custom').gains, custom.gains);
      expect(bass.gains[3], 2);
      expect(custom.withPreset('flat').gains, List.filled(10, 0));
    });

    test('gains are clamped, rounded to half decibels, and copied', () {
      final gains = [-20.0, 20.0, -1.3, 1.2, double.nan, double.infinity];
      final settings = EqualizerSettings(gains: gains);
      expect(settings.gains, [-12, 12, -1.5, 1, 0, 0, 0, 0, 0, 0]);
      gains[0] = 0;
      expect(settings.gains[0], -12);
      expect(() => settings.gains[0] = 0, throwsUnsupportedError);
    });

    test('JSON round trip retains enabled, preset and half-decibel gains', () {
      final settings = EqualizerSettings(enabled: true).withPreset('vocal').withGain(8, 2.5);
      final restored = EqualizerSettings.fromJson(jsonDecode(jsonEncode(settings.toJson())));
      expect(restored.enabled, settings.enabled);
      expect(restored.preset, 'custom');
      expect(restored.gains, settings.gains);
    });

    test('missing or malformed JSON fields fall back to valid defaults', () {
      expect(EqualizerSettings.fromJson({}).toJson(), EqualizerSettings().toJson());
      final restored = EqualizerSettings.fromJson({
        'enabled': 'yes',
        'preset': 'unknown',
        'gains': [15, -15, 'broken'],
      });
      expect(restored.enabled, isFalse);
      expect(restored.preset, 'flat');
      expect(restored.gains, [12, -12, 0, 0, 0, 0, 0, 0, 0, 0]);
    });
  });

  group('mpv equalizer filter', () {
    test('disabled and all-zero settings remove the filter', () {
      expect(mpvEqualizerFilter(EqualizerSettings().withPreset('bass')), isNull);
      expect(mpvEqualizerFilter(EqualizerSettings(enabled: true)), isNull);
    });

    test('includes only nonzero bands and adds a single clipping preamp at the end', () {
      expect(
        mpvEqualizerFilter(EqualizerSettings(enabled: true).withPreset('bass')),
        'lavfi=[equalizer=f=31:t=o:w=1:g=6,equalizer=f=62:t=o:w=1:g=5,'
        'equalizer=f=125:t=o:w=1:g=4,equalizer=f=250:t=o:w=1:g=2,volume=-6dB]',
      );
    });

    test('formats fractional and negative gains without trailing zeros', () {
      final settings = EqualizerSettings(enabled: true).withGain(2, -1.5).withGain(9, 3.5);
      expect(
        mpvEqualizerFilter(settings),
        'lavfi=[equalizer=f=125:t=o:w=1:g=-1.5,equalizer=f=16000:t=o:w=1:g=3.5,volume=-3.5dB]',
      );
    });

    test('cuts alone do not add a preamp', () {
      expect(
        mpvEqualizerFilter(EqualizerSettings(enabled: true).withGain(4, -6)),
        'lavfi=[equalizer=f=500:t=o:w=1:g=-6]',
      );
    });
  });

  group('Android band levels', () {
    test('averages fixed bands into five device bands before subtracting the preamp', () {
      expect(androidBandLevels(equalizerPresets['bass']!, [60000, 230000, 910000, 3600000, 14000000], -1500, 1500), [
        -50,
        -300,
        -600,
        -600,
        -600,
      ]);
    });

    test('uses logarithmic distance rather than linear distance', () {
      expect(androidBandLevels([0, 0, 0, 0, -10, 0, 0, 0, 0, 0], [100000, 1000000], -1500, 1500), [0, -167]);
    });

    test('converts millihertz to hertz and decibels to millibels, then clamps', () {
      expect(
        androidBandLevels(
          [6, 5.5, -12, 2, 0, 0, 0, 0, 0, 0],
          [for (final frequency in equalizerFrequencies) frequency * 1000],
          -450,
          450,
        ),
        [0, -50, -450, -400, -450, -450, -450, -450, -450, -450],
      );
    });

    test('negative gains need no preamp and device limits still apply', () {
      expect(androidBandLevels(List.filled(10, -2.5), [1000000], -200, 200), [-200]);
      expect(androidBandLevels(List.filled(10, -2.5), [1000000], -1500, 1500), [-250]);
      expect(androidBandLevels(List.filled(10, 0), [1000000], -1500, 1500), [0]);
    });

    test('device bands with no assigned fixed band use the nearest fixed gain', () {
      expect(androidBandLevels(List.filled(10, -2), [31000, 32000, 62000], -1500, 1500), [-200, -200, -200]);
      expect(androidBandLevels(List.filled(10, 0), [], -1500, 1500), isEmpty);
    });
  });
}
