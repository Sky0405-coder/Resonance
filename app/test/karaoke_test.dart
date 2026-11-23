import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/player/karaoke.dart';
import 'package:resonance/ui/widgets/karaoke_view.dart';

List<LyricLine> _lines(List<(int, String)> lines) => [
  for (final (ms, text) in lines) LyricLine(timeMs: ms, text: text),
];

void main() {
  test('a line fills until shortly before the next one', () {
    final lines = _lines([(10000, 'Hello darkness my old friend'), (13000, 'I come to talk')]);
    expect(karaokeLineEnd(lines, 0), 10000 + 2760);
    expect(karaokeProgress(lines, 0, 10000), 0);
    expect(karaokeProgress(lines, 0, 11380), closeTo(0.5, 0.01));
    expect(karaokeProgress(lines, 0, 12900), 1);
  });

  test('before a long instrumental part the fill follows the length of the line', () {
    final lines = _lines([(10000, 'Short'), (40000, 'After the solo')]);
    expect(karaokeLineEnd(lines, 0), 10000 + 900 + 5 * 70);
  });

  test('kana and kanji take longer to sing than Latin letters', () {
    final latin = _lines([(0, 'abcdef'), (60000, 'x')]);
    final japanese = _lines([(0, '君の名は今'), (60000, 'x')]);
    expect(karaokeLineEnd(japanese, 0), greaterThan(karaokeLineEnd(latin, 0)));
  });

  test('dots count down the last three seconds of a long pause', () {
    final lines = _lines([(0, 'Intro line'), (2000, ''), (20000, 'Back again')]);
    expect(karaokeCountdown(lines, 0, 1000), 0);
    expect(karaokeCountdown(lines, 1, 10000), 0);
    expect(karaokeCountdown(lines, 1, 17500), 3);
    expect(karaokeCountdown(lines, 1, 18500), 2);
    expect(karaokeCountdown(lines, 1, 19500), 1);
    expect(karaokeCountdown(lines, 2, 20500), 0);
    // Before the first line too, and not between lines close together.
    expect(karaokeCountdown(_lines([(8000, 'First')]), -1, 6000), 2);
    expect(karaokeCountdown(_lines([(0, 'One'), (3000, 'Two')]), 0, 2500), 0);
  });

  test('songs play without their voice only while karaoke is on', () {
    const songs = {'a': 'ready', 'b': 'pending'};
    expect(const KaraokeState(on: true, songs: songs).ready('a'), isTrue);
    expect(const KaraokeState(on: true, songs: songs).ready('b'), isFalse);
    expect(const KaraokeState(songs: songs).ready('a'), isFalse);
  });

  test('furigana survive saving lyrics offline', () {
    final line = LyricLine.fromJson({
      'time_ms': 0,
      'text': '君の名',
      'ruby': [
        ['君', 'きみ'],
        ['の', null],
        ['名', 'な'],
      ],
    });
    expect(line.ruby, [(text: '君', reading: 'きみ'), (text: 'の', reading: null), (text: '名', reading: 'な')]);
    expect(LyricLine.fromJson(line.toJson()).ruby, line.ruby);
  });

  testWidgets('the original Japanese shows furigana, the sung part coloured', (tester) async {
    const line = LyricLine(
      timeMs: 0,
      text: '君の名',
      kana: 'きみのな',
      latin: 'Kimi no na',
      ruby: [(text: '君', reading: 'きみ'), (text: 'の', reading: null), (text: '名', reading: 'な')],
    );
    Future<void> show(LyricsScript script, double progress) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KaraokeLine(line: line, script: script, progress: progress, fontSize: 30, sungColor: Colors.red),
        ),
      ),
    );

    await show(LyricsScript.original, 0.4);
    expect(find.text('きみ'), findsOneWidget);
    expect(find.text('な'), findsOneWidget);
    final sung = tester.widgetList<Text>(find.byType(Text)).where((t) => t.data == 'きみ').single;
    expect(sung.style?.color, Colors.red);

    await show(LyricsScript.latin, 0.5);
    expect(find.text('きみ'), findsNothing);
    final rich = tester.widget<Text>(find.byType(Text).first).textSpan! as TextSpan;
    expect(rich.toPlainText(), 'Kimi no na');
    expect((rich.children!.first as TextSpan).style?.color, Colors.red);
    expect((rich.children!.first as TextSpan).text, 'Kimi ');
  });
}
