import 'dart:math' as math;

import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/models.dart';
import '../../core/library.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import '../../player/visualizer_themes.dart';
import 'audiobook_pages.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/player_bar.dart';
import '../widgets/reflection.dart';
import '../widgets/track_list.dart';
import '../widgets/jam_sheet.dart';
import '../../player/jam.dart';

class NowPlayingPage extends ConsumerWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((p) => p.current));
    final book = ref.watch(playerProvider.select((p) => p.book));
    final station = ref.watch(playerProvider.select((p) => p.station));
    final stationNow = ref.watch(playerProvider.select((p) => p.stationNow));
    final accent = Theme.of(context).colorScheme.primary;
    final coverColor = track != null && book == null && station == null && ref.watch(visualizerEnabledProvider)
        ? ref.watch(coverColorProvider(coverImageProvider(ref, track.album.id, size: 300))).value
        : null;
    final hsl = coverColor == null ? null : HSLColor.fromColor(coverColor);
    final topColor = hsl == null
        ? accent.withValues(alpha: 0.45)
        : hsl
              .withLightness(math.min(hsl.lightness, 0.22))
              .withSaturation(math.min(hsl.saturation, 0.65))
              .withAlpha(1)
              .toColor();
    return Scaffold(
      body: TweenAnimationBuilder<Color?>(
        duration: const Duration(milliseconds: 600),
        tween: ColorTween(end: topColor),
        builder: (context, color, child) => DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color!, Palette.background],
              stops: coverColor == null ? null : const [0.0, 0.85],
            ),
          ),
          child: child,
        ),
        child: SafeArea(
          child: station != null
              ? _StationNowPlaying(station: station, now: stationNow)
              : book != null
              ? _BookNowPlaying(book: book)
              : track == null
              ? Center(child: Text(context.l10n.playerNothingPlaying))
              : LayoutBuilder(
                  builder: (context, constraints) => ListView(
                    padding: EdgeInsets.zero,
                    children: [
                      SizedBox(
                        height: constraints.maxHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.keyboard_arrow_down, size: 32),
                                    onPressed: () => context.pop(),
                                  ),
                                  Expanded(
                                    child: Text(
                                      track.album.name,
                                      textAlign: TextAlign.center,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  const JamButton(),
                                  IconButton(
                                    icon: const Icon(Icons.more_vert),
                                    onPressed: () => showTrackMenu(context, ref, track),
                                  ),
                                ],
                              ),
                              Expanded(
                                child: ref.watch(coverflowProvider) ? const _Coverflow() : _TrackCover(track: track),
                              ),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 600),
                                child: Column(
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Flexible(
                                                    child: TrackTitle(
                                                      track: track,
                                                      smart: ref.watch(
                                                        playerProvider.select((p) => p.smartIds.contains(track.id)),
                                                      ),
                                                      style: Theme.of(context).textTheme.headlineSmall
                                                          ?.copyWith(fontWeight: FontWeight.w800),
                                                    ),
                                                  ),
                                                  const AutomixChip(),
                                                ],
                                              ),
                                              InkWell(
                                                onTap: () {
                                                  context.pop();
                                                  context.push('/artist/${track.artist.id}');
                                                },
                                                child: Text(
                                                  track.artistCredit,
                                                  maxLines: 1,
                                                  overflow: TextOverflow.ellipsis,
                                                  style: const TextStyle(color: Palette.textMuted, fontSize: 16),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                        LikeButton(track: track, size: 28),
                                      ],
                                    ),
                                    const SizedBox(height: 12),
                                    const SeekBar(),
                                    const SizedBox(height: 8),
                                    const TransportControls(big: true),
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.end,
                                      children: [
                                        const SleepTimerButton(),
                                        IconButton(
                                          tooltip: context.l10n.lyricsTitle,
                                          icon: const Icon(Icons.lyrics_outlined),
                                          onPressed: () => context.push('/lyrics'),
                                        ),
                                        IconButton(
                                          tooltip: context.l10n.playerQueue,
                                          icon: const Icon(Icons.queue_music),
                                          onPressed: () => context.push('/queue'),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                            ],
                          ),
                        ),
                      ),
                      _LyricsCard(trackId: track.id),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}

class _TrackCover extends ConsumerWidget {
  const _TrackCover({required this.track, this.centered = true});
  final Track track;
  final bool centered;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(visualizerThemeProvider);
    final enabled = ref.watch(visualizerEnabledProvider) && centered;
    Widget artwork({required bool visualizer}) => Stack(
      fit: StackFit.expand,
      children: [
        CoverImage(albumId: track.album.id, size: 600, radius: 8),
        if (visualizer) Positioned.fill(child: _CoverVisualizer(track: track)),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final height = math.min(480.0, constraints.maxHeight);
        final size = math.max(0.0, math.min(constraints.maxWidth, (height - 3) / 1.22));
        return Center(
          child: SizedBox(
            width: size,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  onTap: centered && theme.peaks
                      ? () {
                          final peaks = !ref.read(visualizerPeaksProvider);
                          ref.read(visualizerPeaksProvider.notifier).set(peaks);
                          showInfo(context, peaks ? context.l10n.visualizerPeaksOn : context.l10n.visualizerPeaksOff);
                        }
                      : null,
                  child: Material(
                    elevation: 16,
                    borderRadius: BorderRadius.circular(8),
                    clipBehavior: Clip.antiAlias,
                    child: SizedBox.square(
                      dimension: size,
                      child: artwork(visualizer: enabled),
                    ),
                  ),
                ),
                const SizedBox(height: 3),
                CoverReflection(child: artwork(visualizer: enabled && theme.reflect)),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Coverflow extends ConsumerStatefulWidget {
  const _Coverflow();

  @override
  ConsumerState<_Coverflow> createState() => _CoverflowState();
}

class _CoverflowState extends ConsumerState<_Coverflow> {
  late final PageController _controller;
  int? _targetIndex;
  bool _swiping = false;

  @override
  void initState() {
    super.initState();
    _controller = PageController(initialPage: ref.read(playerProvider).index ?? 0, viewportFraction: 0.72);
  }

  void _syncIndex(int index) {
    _targetIndex = index;
    _swiping = false;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_controller.hasClients || _targetIndex != index) return;
      await _controller.animateToPage(index, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      if (mounted && _targetIndex == index) _targetIndex = null;
    });
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification && notification.dragDetails != null) {
      _targetIndex = null;
      _swiping = true;
    }
    if (notification is ScrollEndNotification && _swiping && _targetIndex == null) {
      _swiping = false;
      final index = _controller.page!.round();
      final player = ref.read(playerProvider);
      if (index != player.index && index < player.queue.length) {
        ref.read(playerProvider.notifier).jumpTo(index);
      }
    }
    return false;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider.select((p) => (queue: p.queue, index: p.index)));
    ref.listen(playerProvider.select((p) => p.index), (previous, next) {
      if (next != null && next != previous) _syncIndex(next);
    });
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: PageView.builder(
        controller: _controller,
        itemCount: player.queue.length,
        itemBuilder: (context, index) => AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final page = _controller.hasClients && _controller.position.hasContentDimensions
                ? _controller.page ?? _controller.initialPage.toDouble()
                : _controller.initialPage.toDouble();
            final delta = (index - page).clamp(-1.0, 1.0);
            final scale = 1 - 0.18 * delta.abs();
            return Transform(
              alignment: Alignment.center,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateY(-delta * 0.9),
              child: Transform.scale(
                scale: scale,
                child: _TrackCover(track: player.queue[index], centered: (index - page).abs() < 0.001),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StationNowPlaying extends StatelessWidget {
  const _StationNowPlaying({required this.station, this.now});
  final Station station;
  final StationNowPlaying? now;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 24),
    child: Column(
      children: [
        Row(
          children: [
            IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => context.pop()),
            Expanded(child: Text(context.l10n.worldRadioTitle, textAlign: TextAlign.center)),
            const SizedBox(width: 48),
          ],
        ),
        const Spacer(),
        if (now?.coverUrl != null) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: 28,
                height: 28,
                child: NetworkCover(url: station.favicon, radius: 4, icon: Icons.radio),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  station.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
        ],
        Flexible(
          flex: 5,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
            child: NetworkCover(url: now?.coverUrl ?? station.favicon, radius: 8, icon: Icons.radio),
          ),
        ),
        const Spacer(),
        Text(
          now?.title ?? station.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        if (now?.title != null) ...[
          if (now!.artistYear.isNotEmpty) Text(now!.artistYear, style: const TextStyle(color: Palette.textMuted)),
          Text(station.name, style: const TextStyle(color: Palette.textMuted, fontSize: 12)),
        ] else
          Text(
            '${context.l10n.worldRadioTitle} · ${station.country}',
            style: const TextStyle(color: Palette.textMuted),
          ),
        const SizedBox(height: 16),
        const LiveBadge(),
        const SizedBox(height: 16),
        const TransportControls(big: true),
        const SizedBox(height: 24),
      ],
    ),
  );
}

class _LyricsCard extends ConsumerWidget {
  const _LyricsCard({required this.trackId});
  final String trackId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(lyricsProvider(trackId));
    final lyrics = value.isLoading || value.hasError ? null : value.value;
    if (lyrics == null || lyrics.lines.isEmpty) return const SizedBox.shrink();
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final current = lyrics.synced ? lyrics.lines.lastIndexWhere((line) => line.timeMs! <= position.inMilliseconds) : -1;
    final start = current < 0 ? 0 : current;
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Material(
        color: Color.alphaBlend(Colors.black.withValues(alpha: 0.55), accent),
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/lyrics'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.lyricsTitle,
                        style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () => context.push('/lyrics'),
                      style: TextButton.styleFrom(foregroundColor: Colors.white),
                      icon: const Icon(Icons.open_in_full, size: 16),
                      label: Text(context.l10n.lyricsExpand),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                for (var i = start; i < lyrics.lines.length && i < start + 8; i++)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      lyrics.lines[i].text.isEmpty ? '♪' : lyrics.lines[i].text,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: !lyrics.synced || i == current ? Colors.white : Colors.white.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BookNowPlaying extends ConsumerWidget {
  const _BookNowPlaying({required this.book});
  final BookPlayback book;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapter = book.chapterAt(ref.watch(bookPositionProvider));
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          Row(
            children: [
              IconButton(icon: const Icon(Icons.keyboard_arrow_down, size: 32), onPressed: () => context.pop()),
              Expanded(
                child: Text(
                  context.l10n.audiobooksBook,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: context.l10n.playerGoToAudiobook,
                icon: const Icon(Icons.info_outline),
                onPressed: () {
                  context.pop();
                  context.push('/audiobooks/item/${book.itemId}');
                },
              ),
            ],
          ),
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
            child: Material(
              elevation: 16,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: NetworkCover(url: book.coverUrl, radius: 8, icon: Icons.headphones),
            ),
          ),
          const Spacer(),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(
                  [?book.author, ?chapter?.title].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Palette.textMuted, fontSize: 16),
                ),
                const SizedBox(height: 12),
                const SeekBar(),
                const SizedBox(height: 8),
                const Center(child: TransportControls(big: true)),
                if (book.chapters.isNotEmpty)
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: () => showChapterSheet(context, ref, book),
                      icon: const Icon(Icons.format_list_bulleted),
                      label: Text(context.l10n.audiobooksChapters),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

class QueuePage extends ConsumerWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playerProvider);
    final ctrl = ref.read(playerProvider.notifier);
    final upcoming = p.index == null ? <int>[] : [for (var i = p.index! + 1; i < p.queue.length; i++) i];
    final jam = ref.watch(jamProvider);
    String? addedBy(int i) {
      final queue = jam?.state.queue;
      return queue != null && i < queue.length ? context.l10n.jamAddedBy(queue[i].addedByName) : null;
    }

    bool canRemove(int i) {
      final queue = jam?.state.queue;
      if (jam == null) return true;
      return jam.isHost || (queue != null && i < queue.length && queue[i].addedById == jam.myId);
    }

    return Scaffold(
      appBar: AppBar(title: Text(jam == null ? context.l10n.playerQueue : context.l10n.jamQueue)),
      body: p.current == null
          ? Center(
              child: Text(context.l10n.playerEmptyQueue, style: TextStyle(color: Palette.textMuted)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, kBottomInset),
              children: [
                _QueueHeading(context.l10n.playerNowPlaying),
                TrackRow(track: p.current!, onPlay: ctrl.togglePlay, smart: p.smartIds.contains(p.current!.id)),
                if (addedBy(p.index!) case final label?) _AddedBy(label),
                for (final i in upcoming) ...[
                  if (i == upcoming.first ||
                      p.autoplayIds.contains(p.queue[i].id) != p.autoplayIds.contains(p.queue[i - 1].id))
                    _QueueHeading(
                      p.autoplayIds.contains(p.queue[i].id)
                          ? context.l10n.playerAutoplaySection
                          : context.l10n.playerNextUp,
                    ),
                  TrackRow(
                    key: ValueKey('q$i-${p.queue[i].id}'),
                    track: p.queue[i],
                    smart: p.smartIds.contains(p.queue[i].id),
                    onPlay: () => ctrl.jumpTo(i),
                    extraActions: [
                      if (canRemove(i))
                        TrackAction(
                          context.l10n.playerRemoveFromQueue,
                          Icons.remove_circle_outline,
                          () => ctrl.removeAt(i),
                        ),
                    ],
                  ),
                  if (addedBy(i) case final label?) _AddedBy(label),
                ],
              ],
            ),
    );
  }
}

class _AddedBy extends StatelessWidget {
  const _AddedBy(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
    child: Text(text, style: const TextStyle(color: Palette.textMuted, fontSize: 12)),
  );
}

class _QueueHeading extends StatelessWidget {
  const _QueueHeading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium),
  );
}

/// The spectrum over the lower part of the cover, on a dark fade.
class _CoverVisualizer extends ConsumerWidget {
  const _CoverVisualizer({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = ref.watch(coverColorProvider(coverImageProvider(ref, track.album.id, size: 300))).value;
    final theme = ref.watch(visualizerThemeProvider);
    return IgnorePointer(
      child: Column(
        children: [
          const Spacer(flex: 3),
          Expanded(
            flex: 2,
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x00000000), Color(0x8C000000)],
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 24, 12, 0),
                child: SpectrumVisualizer(
                  trackId: track.id,
                  color: (color ?? Colors.white).withValues(alpha: 0.85),
                  theme: theme.id == 'auto' ? null : theme,
                  mirrored: true,
                  gap: 0.35,
                  minHeight: 0.015,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
