import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../widgets/common.dart';
import '../widgets/player_bar.dart';

class LyricsPage extends ConsumerWidget {
  const LyricsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final track = player.book == null ? player.current : null;
    final accent = Theme.of(context).colorScheme.primary;
    final background = Color.alphaBlend(Colors.black.withValues(alpha: 0.55), accent);
    return Scaffold(
      backgroundColor: background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 24, 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: MaterialLocalizations.of(context).closeButtonTooltip,
                    icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                    onPressed: () => context.pop(),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track?.title ?? context.l10n.lyricsTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                        if (track != null)
                          Text(
                            track.artistCredit,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white70),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: track == null
                  ? Center(child: Text(context.l10n.lyricsNotFound))
                  : AsyncBody(
                      value: ref.watch(lyricsProvider(track.id)),
                      onRetry: () => ref.invalidate(lyricsProvider(track.id)),
                      builder: (lyrics) => lyrics.instrumental
                          ? Center(child: Text(context.l10n.lyricsInstrumental))
                          : lyrics.lines.isEmpty
                          ? Center(child: Text(context.l10n.lyricsNotFound))
                          : _LyricsLines(key: ValueKey(track.id), lyrics: lyrics),
                    ),
            ),
            if (track != null)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 24, 16),
                child: Row(
                  children: [
                    Expanded(child: SeekBar(showTimes: false)),
                    SizedBox(width: 8),
                    TransportControls(playPauseOnly: true),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _LyricsLines extends ConsumerStatefulWidget {
  const _LyricsLines({super.key, required this.lyrics});
  final Lyrics lyrics;

  @override
  ConsumerState<_LyricsLines> createState() => _LyricsLinesState();
}

class _LyricsLinesState extends ConsumerState<_LyricsLines> {
  final _scroll = ScrollController();
  Timer? _manualScroll;
  int _current = -2;
  List<double> _offsets = [];
  double? _width;
  double? _height;

  @override
  void dispose() {
    _manualScroll?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _follow() {
    if (!mounted || !_scroll.hasClients || _manualScroll?.isActive == true || _current < 0) return;
    final position = _scroll.position;
    final target = (_offsets[_current] - position.viewportDimension * 0.35).clamp(0.0, position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  bool _onScroll(ScrollNotification notification) {
    if (widget.lyrics.synced &&
        ((notification is ScrollStartNotification && notification.dragDetails != null) ||
            (notification is ScrollUpdateNotification && notification.dragDetails != null) ||
            (notification is UserScrollNotification && notification.direction != ScrollDirection.idle))) {
      _manualScroll?.cancel();
      _manualScroll = Timer(const Duration(seconds: 4), _follow);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final lyrics = widget.lyrics;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final current = lyrics.synced ? lyrics.lines.lastIndexWhere((line) => line.timeMs! <= position.inMilliseconds) : -1;
    const style = TextStyle(fontSize: 26, fontWeight: FontWeight.w800, height: 1.3);
    return LayoutBuilder(
      builder: (context, constraints) {
        _offsets = [];
        var offset = 24.0;
        for (final line in lyrics.lines) {
          _offsets.add(offset + 7);
          final painter = TextPainter(
            text: TextSpan(text: line.text.isEmpty ? '♪' : line.text, style: style),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
          )..layout(maxWidth: constraints.maxWidth - 48);
          offset += painter.height + 14;
          painter.dispose();
        }
        if (current != _current || _width != constraints.maxWidth || _height != constraints.maxHeight) {
          _current = current;
          _width = constraints.maxWidth;
          _height = constraints.maxHeight;
          if (lyrics.synced) WidgetsBinding.instance.addPostFrameCallback((_) => _follow());
        }
        return NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ListView(
            controller: _scroll,
            padding: EdgeInsets.fromLTRB(24, 24, 24, lyrics.synced ? constraints.maxHeight * 0.65 : 24),
            children: [
              if (!lyrics.synced)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Text(context.l10n.lyricsUnsynced, style: const TextStyle(color: Colors.white60, fontSize: 12)),
                ),
              for (var i = 0; i < lyrics.lines.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 7),
                  child: GestureDetector(
                    onTap: !lyrics.synced
                        ? null
                        : () async {
                            final ctrl = ref.read(playerProvider.notifier);
                            await ctrl.seek(Duration(milliseconds: lyrics.lines[i].timeMs!));
                            if (mounted && !ref.read(playerProvider).playing) ctrl.togglePlay();
                          },
                    child: Text(
                      lyrics.lines[i].text.isEmpty ? '♪' : lyrics.lines[i].text,
                      style: style.copyWith(
                        color: !lyrics.synced || i <= current ? Colors.white : Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ),
              if (lyrics.source == 'lrclib')
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Text(
                    context.l10n.lyricsAttribution,
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
