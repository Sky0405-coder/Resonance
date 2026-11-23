import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../player/player.dart';

final _wide = RegExp(r'[぀-ヿ㐀-鿿豈-﫿가-힯]');

/// When the singing of line [i] ends, in ms: the line's time until the next one, or an estimate from its length
/// when a long instrumental part follows (the fill would otherwise crawl through it).
int karaokeLineEnd(List<LyricLine> lines, int i) {
  final start = lines[i].timeMs!;
  final next = i + 1 < lines.length ? lines[i + 1].timeMs! : null;
  final text = lines[i].text;
  final wide = _wide.allMatches(text).length;
  // About a third of a second per kana or kanji, less per Latin letter.
  final estimate = 900 + wide * 330 + (text.length - wide) * 70;
  if (next == null) return start + estimate;
  final gap = next - start;
  return start + (gap <= estimate * 1.6 ? (gap * 0.92).round() : estimate);
}

/// How far line [i] is sung at [ms], from 0 to 1.
double karaokeProgress(List<LyricLine> lines, int i, int ms) {
  final start = lines[i].timeMs!;
  final end = karaokeLineEnd(lines, i);
  return end <= start ? 1 : ((ms - start) / (end - start)).clamp(0.0, 1.0);
}

/// The dots counting down to the next sung line after a pause of at least six seconds: 3, 2, 1 in the last three
/// seconds, else 0.
int karaokeCountdown(List<LyricLine> lines, int current, int ms) {
  final next = lines.indexWhere((line) => line.text.trim().isNotEmpty, current + 1);
  if (next < 0) return 0;
  final previous = lines.lastIndexWhere((line) => line.text.trim().isNotEmpty, math.max(current, 0));
  final pauseFrom = previous < 0 || previous >= next || current < 0 ? 0 : karaokeLineEnd(lines, previous);
  final nextStart = lines[next].timeMs!;
  if (nextStart - pauseFrom < 6000 || ms < pauseFrom) return 0;
  final left = nextStart - ms;
  return left <= 0 || left > 3000 ? 0 : (left / 1000).ceil();
}

/// Sing along: the current line large, filling with colour as it is sung, the next lines below, and dots counting
/// down after long instrumental parts. Japanese in its original script gets furigana over the kanji.
class KaraokeView extends ConsumerWidget {
  const KaraokeView({super.key, required this.lyrics});
  final Lyrics lyrics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ms = (ref.watch(positionProvider).value ?? Duration.zero).inMilliseconds;
    final script = lyrics.shownIn(ref.watch(lyricsScriptProvider));
    final lines = lyrics.lines;
    final current = lines.lastIndexWhere((line) => line.timeMs! <= ms);
    final accent = Theme.of(context).colorScheme.primary;
    final sung = HSLColor.fromColor(accent).withLightness(0.72).withSaturation(0.9).toColor();
    final countdown = karaokeCountdown(lines, current, ms);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = (constraints.maxWidth / 18).clamp(28.0, 64.0);
        Widget line(int i, double scale, double opacity, {double progress = 0}) {
          if (i < 0 || i >= lines.length) return SizedBox(height: size * scale * 1.4);
          return GestureDetector(
            onTap: () => ref.read(playerProvider.notifier).seek(Duration(milliseconds: lines[i].timeMs!)),
            child: Opacity(
              opacity: opacity,
              child: KaraokeLine(
                line: lines[i],
                script: script,
                progress: progress,
                fontSize: size * scale,
                sungColor: sung,
              ),
            ),
          );
        }

        final shown = current < 0 ? -1 : current;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              line(shown - 1, 0.6, 0.45),
              SizedBox(height: size * 0.6),
              SizedBox(
                height: size * 0.8,
                child: countdown == 0
                    ? null
                    : Text(
                        List.filled(countdown, '●').join(' '),
                        style: TextStyle(color: sung, fontSize: size * 0.5, letterSpacing: 4),
                      ),
              ),
              line(shown, 1, 1, progress: shown < 0 ? 0 : karaokeProgress(lines, shown, ms)),
              SizedBox(height: size * 0.7),
              line(shown + 1, 0.75, 0.7),
              SizedBox(height: size * 0.4),
              line(shown + 2, 0.6, 0.4),
            ],
          ),
        );
      },
    );
  }
}

/// One line, sung up to [progress] (by characters); furigana over kanji in the original script.
class KaraokeLine extends StatelessWidget {
  const KaraokeLine({
    super.key,
    required this.line,
    required this.script,
    required this.progress,
    required this.fontSize,
    required this.sungColor,
  });

  final LyricLine line;
  final LyricsScript script;
  final double progress;
  final double fontSize;
  final Color sungColor;

  @override
  Widget build(BuildContext context) {
    final ruby = script == LyricsScript.original ? line.ruby : null;
    final text = line.textIn(script);
    final base = TextStyle(fontSize: fontSize, fontWeight: FontWeight.w800, height: 1.25, color: Colors.white);
    final sungStyle = base.copyWith(color: sungColor);
    if (text.trim().isEmpty) return Text('♪', style: base, textAlign: TextAlign.center);
    final pieces = ruby ?? [(text: text, reading: null)];
    final total = pieces.fold<int>(0, (sum, piece) => sum + piece.text.characters.length);
    var left = (progress * total).round();

    List<TextSpan> split(String part) {
      final chars = part.characters;
      final n = math.min(math.max(left, 0), chars.length);
      left -= chars.length;
      return [
        if (n > 0) TextSpan(text: chars.take(n).toString(), style: sungStyle),
        if (n < chars.length) TextSpan(text: chars.skip(n).toString(), style: base),
      ];
    }

    if (ruby == null) {
      return Text.rich(TextSpan(children: split(text)), textAlign: TextAlign.center);
    }
    // With furigana every piece is a small column (reading over text); plain text is split into words and single
    // characters so the line still wraps.
    final readingStyle = base.copyWith(fontSize: fontSize * 0.45, fontWeight: FontWeight.w600, height: 1.1);
    final spans = <InlineSpan>[];
    for (final piece in pieces) {
      final parts = piece.reading == null
          ? RegExp(r"\s+|[A-Za-z0-9'’]+|.", unicode: true).allMatches(piece.text).map((m) => m[0]!)
          : [piece.text];
      for (final part in parts) {
        final sungBefore = left;
        final children = split(part);
        final readingSung = piece.reading != null && sungBefore >= part.characters.length / 2;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.bottom,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(piece.reading ?? '', style: readingSung ? readingStyle.copyWith(color: sungColor) : readingStyle),
                Text.rich(TextSpan(children: children)),
              ],
            ),
          ),
        );
      }
    }
    return Text.rich(TextSpan(children: spans), textAlign: TextAlign.center);
  }
}
