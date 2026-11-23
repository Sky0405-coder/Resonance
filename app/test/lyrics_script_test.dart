import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/models.dart';

Lyrics _lyrics(List<Map<String, dynamic>> lines) =>
    Lyrics.fromJson({'synced': false, 'instrumental': false, 'source': 'lrclib', 'lines': lines});

void main() {
  test('Japanese lyrics offer kana and romaji, unread lines keep their text', () {
    final lyrics = _lyrics([
      {'time_ms': null, 'text': '君の名は', 'kana': 'きみのなは', 'latin': 'Kimi no na wa'},
      {'time_ms': null, 'text': 'Baby', 'kana': null, 'latin': null},
    ]);
    expect(lyrics.scripts, [LyricsScript.original, LyricsScript.kana, LyricsScript.latin]);
    expect(lyrics.japanese, isTrue);
    expect([for (final l in lyrics.lines) l.textIn(LyricsScript.kana)], ['きみのなは', 'Baby']);
    expect([for (final l in lyrics.lines) l.textIn(LyricsScript.latin)], ['Kimi no na wa', 'Baby']);
    expect(lyrics.missingScripts, isFalse);
  });

  test('other scripts fall back from kana to the original', () {
    final lyrics = _lyrics([
      {'time_ms': null, 'text': 'Привет', 'kana': null, 'latin': 'Privet'},
    ]);
    expect(lyrics.scripts, [LyricsScript.original, LyricsScript.latin]);
    expect(lyrics.shownIn(LyricsScript.kana), LyricsScript.original);
    expect(lyrics.shownIn(LyricsScript.latin), LyricsScript.latin);
  });

  test('lyrics saved offline before readings existed ask again only for other scripts', () {
    expect(
      _lyrics([
        {'time_ms': null, 'text': '君の名は'},
      ]).missingScripts,
      isTrue,
    );
    expect(
      _lyrics([
        {'time_ms': null, 'text': 'Café, über'},
      ]).missingScripts,
      isFalse,
    );
    final saved = Lyrics.fromJson(
      _lyrics([
        {'time_ms': null, 'text': '君の名は'},
      ]).toJson(),
    );
    expect(saved.missingScripts, isFalse);
    expect(saved.scripts, [LyricsScript.original]);
  });
}
