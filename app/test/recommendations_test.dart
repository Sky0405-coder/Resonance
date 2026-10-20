import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:resonance/player/engine.dart';

void main() {
  group('smart shuffle interleaving', () {
    test('inserts after every three upcoming tracks, counting inserted positions', () {
      final upcoming = List.generate(10, (i) => i);
      expect(interleaveEvery(upcoming, [100, 101, 102, 103], 3), [0, 1, 2, 100, 3, 4, 5, 101, 6, 7, 8, 102, 9]);
      expect(upcoming, List.generate(10, (i) => i));
    });

    test('handles empty lists, short queues and too few recommendations', () {
      expect(interleaveEvery<int>([], [9], 3), isEmpty);
      expect(interleaveEvery([1, 2], [9], 3), [1, 2]);
      expect(interleaveEvery([1, 2, 3], <int>[], 3), [1, 2, 3]);
      expect(interleaveEvery([1, 2, 3, 4, 5, 6], [9], 3), [1, 2, 3, 9, 4, 5, 6]);
      expect(interleaveEvery([1, 2], [8, 9], 1), [1, 8, 2, 9]);
      expect(() => interleaveEvery([1], [2], 0), throwsArgumentError);
    });
  });

  group('shuffle modes', () {
    test('supported contexts cycle off, shuffle, smart shuffle, off', () {
      var mode = (false, false);
      for (final expected in [(true, false), (true, true), (false, false)]) {
        mode = nextShuffleMode(shuffle: mode.$1, smartShuffle: mode.$2, allowSmart: true);
        expect(mode, expected);
      }
    });

    test('other contexts cycle off and shuffle', () {
      expect(nextShuffleMode(shuffle: false, smartShuffle: false, allowSmart: false), (true, false));
      expect(nextShuffleMode(shuffle: true, smartShuffle: false, allowSmart: false), (false, false));
      for (final context in ['liked', 'playlist:id', 'album:id', 'mix:id']) {
        expect(supportsSmartShuffle(context), isTrue);
      }
      for (final context in [null, 'search', 'artist:id', 'radio:pending', 'book:id', 'station:id', 'jam:id']) {
        expect(supportsSmartShuffle(context), isFalse);
      }
      expect(supportsSmartShuffle('playlist:id', isRadio: true), isFalse);
    });
  });

  group('autoplay condition', () {
    bool trigger({
      bool enabled = true,
      int length = 4,
      int? index = 3,
      LoopMode loop = LoopMode.off,
      bool playing = true,
      bool book = false,
      bool station = false,
      bool jam = false,
    }) => shouldAutoplay(
      enabled: enabled,
      length: length,
      index: index,
      loopMode: loop,
      playing: playing,
      isBook: book,
      isStation: station,
      inJam: jam,
    );

    test('starts only on the playing last item of a nonempty queue', () {
      expect(trigger(), isTrue);
      expect(trigger(length: 1, index: 0), isTrue);
      expect(trigger(index: 2), isFalse);
      expect(trigger(index: null), isFalse);
      expect(trigger(index: 4), isFalse);
      expect(trigger(length: 0, index: -1), isFalse);
      expect(trigger(playing: false), isFalse);
      expect(trigger(enabled: false), isFalse);
    });

    test('repeat, books, stations and jams suppress autoplay', () {
      expect(trigger(loop: LoopMode.all), isFalse);
      expect(trigger(loop: LoopMode.one), isFalse);
      expect(trigger(book: true), isFalse);
      expect(trigger(station: true), isFalse);
      expect(trigger(jam: true), isFalse);
    });
  });
}
