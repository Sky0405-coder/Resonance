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
import '../widgets/devices_sheet.dart';
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
                  builder: (context, constraints) {
                    // Phones in landscape count as wide (about 1000 x 450), so the height decides, not isWide.
                    final landscape = constraints.maxWidth > constraints.maxHeight && constraints.maxHeight < 600;
                    final maxSide = MediaQuery.sizeOf(context).width >= 900 ? 720.0 : 480.0;
                    return ListView(
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
                                    const DevicesButton(),
                                    const JamButton(),
                                    IconButton(
                                      icon: const Icon(Icons.more_vert),
                                      onPressed: () => showTrackMenu(context, ref, track),
                                    ),
                                  ],
                                ),
                                if (landscape)
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 12, bottom: 16),
                                      child: LayoutBuilder(
                                        builder: (context, available) {
                                          final side = math.min(available.maxHeight, available.maxWidth * 0.45);
                                          return Row(
                                            children: [
                                              SizedBox.square(
                                                dimension: side,
                                                child: TrackCover(
                                                  track: track,
                                                  allowReflection: false,
                                                ),
                                              ),
                                              const SizedBox(width: 24),
                                              Expanded(
                                                child: Center(child: _TrackControls(track: track)),
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                    ),
                                  )
                                else ...[
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 16),
                                      child: ref.watch(coverflowProvider)
                                          ? Coverflow(maxSide: maxSide)
                                          : TrackCover(track: track, maxSide: maxSide),
                                    ),
                                  ),
                                  _TrackControls(track: track),
                                  const SizedBox(height: 16),
                                ],
                              ],
                            ),
                          ),
                        ),
                        _LyricsCard(trackId: track.id),
                      ],
                    );
                  },
                ),
        ),
      ),
    );
  }
}

class _TrackControls extends ConsumerWidget {
  const _TrackControls({required this.track});
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 600),
    child: Column(
      mainAxisSize: MainAxisSize.min,
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
                          smart: ref.watch(playerProvider.select((p) => p.smartIds.contains(track.id))),
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
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
  );
}

class TrackCover extends ConsumerWidget {
  const TrackCover({
    super.key,
    required this.track,
    this.centered = true,
    this.allowReflection = true,
    this.dim = 0,
    this.interactive = true,
    this.maxSide = 480,
  });
  final Track track;
  final bool centered;
  final bool allowReflection;
  final double dim;
  final bool interactive;
  final double maxSide;

  static double sideFor(BoxConstraints constraints, bool reflect, {double maxSide = 480}) {
    final height = reflect ? (constraints.maxHeight - 3) / 1.22 : constraints.maxHeight;
    return math.max(0.0, math.min(math.min(constraints.maxWidth, maxSide), height));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = ref.watch(visualizerThemeProvider);
    final enabled = ref.watch(visualizerEnabledProvider) && centered;
    final reflect = ref.watch(visualizerReflectionProvider) && allowReflection;
    Widget artwork() => Stack(
      fit: StackFit.expand,
      children: [
        CoverImage(albumId: track.album.id, size: 600, radius: 8),
        if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
      ],
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = sideFor(constraints, reflect, maxSide: maxSide);
        final reflection = reflect ? size * 0.22 : 0.0;
        return Center(
          child: SizedBox(
            width: size,
            height: size + (reflect ? 3 + reflection : 0),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (reflect)
                  Positioned(
                    top: size + 3,
                    left: 0,
                    right: 0,
                    child: CoverReflection(child: artwork()),
                  ),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: size,
                  child: GestureDetector(
                    onTap: interactive && centered && theme.peaks
                        ? () {
                            final peaks = !ref.read(visualizerPeaksProvider);
                            ref.read(visualizerPeaksProvider.notifier).set(peaks);
                            showInfo(context, peaks ? context.l10n.visualizerPeaksOn : context.l10n.visualizerPeaksOff);
                          }
                        : null,
                    child: Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.none,
                      children: [
                        Material(
                          elevation: 16,
                          borderRadius: BorderRadius.circular(8),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              artwork(),
                              if (enabled)
                                Positioned(
                                  top: size * 0.6,
                                  bottom: 0,
                                  left: 0,
                                  right: 0,
                                  child: const DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [Color(0x00000000), Color(0x8C000000)],
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (enabled)
                          Positioned(
                            top: size * 0.6 + 24,
                            height: math.max(0.0, size * 0.4 - 24),
                            left: 12,
                            right: 12,
                            child: _CoverVisualizer(track: track, reflection: reflection),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class Coverflow extends ConsumerStatefulWidget {
  const Coverflow({super.key, this.interactive = true, this.maxSide = 480});
  final bool interactive;
  final double maxSide;

  @override
  ConsumerState<Coverflow> createState() => _CoverflowState();
}

class _CoverflowState extends ConsumerState<Coverflow> with SingleTickerProviderStateMixin {
  late final AnimationController _position;
  List<String> _queue = const [];
  int? _index;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _position = AnimationController.unbounded(vsync: this, value: (ref.read(playerProvider).index ?? 0).toDouble());
  }

  Future<void> _snapTo(int index, {bool select = false}) async {
    final generation = ++_generation;
    try {
      await _position
          .animateTo(index.toDouble(), duration: const Duration(milliseconds: 300), curve: Curves.easeOutCubic)
          .orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted || generation != _generation || !select) return;
    final player = ref.read(playerProvider);
    if (index != player.index && index >= 0 && index < player.queue.length) {
      ref.read(playerProvider.notifier).jumpTo(index);
    }
  }

  void _release(double velocity) {
    final last = ref.read(playerProvider).queue.length - 1;
    if (last < 0) return;
    var target = _position.value.round();
    if (velocity.abs() > 600) {
      target = velocity < 0 ? (_position.value + 1).floor() : (_position.value - 1).ceil();
    }
    _snapTo(target.clamp(0, last), select: true);
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = ref.watch(playerProvider.select((p) => (queue: p.queue, index: p.index)));
    final reflect = ref.watch(visualizerReflectionProvider);
    final index = player.index;
    final validIndex = index != null && index >= 0 && index < player.queue.length;
    final queueChanged =
        _queue.length != player.queue.length || (validIndex && _queue[index] != player.queue[index].id);
    if (validIndex && (queueChanged || index != _index)) {
      if (queueChanged) {
        _generation++;
        _position.value = index.toDouble();
      } else {
        _snapTo(index);
      }
    }
    _queue = [for (final track in player.queue) track.id];
    _index = index;
    return LayoutBuilder(
      builder: (context, constraints) {
        // The centered cover is a bit smaller than without coverflow so the tilted neighbors fit beside it; they
        // reach out to the screen edges, past the page padding.
        final large = widget.maxSide > 480;
        final side = TrackCover.sideFor(constraints, reflect, maxSide: widget.maxSide) * (large ? 0.85 : 0.78);
        final height = side + (reflect ? 3 + side * 0.22 : 0);
        // Neighbors spread beside the cover, but never past the screen edge.
        final spread = math.max(
          0.0,
          math.min(side * (large ? 0.35 : 0.25), MediaQuery.sizeOf(context).width / 2 - 4 - side / 2),
        );
        final flow = GestureDetector(
          key: const ValueKey('coverflow'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: widget.interactive
              ? (_) {
                  _generation++;
                  _position.stop();
                }
              : null,
          onHorizontalDragUpdate: widget.interactive
              ? (details) {
                  if (side <= 0 || player.queue.isEmpty) return;
                  _position.value = (_position.value - details.delta.dx / (0.42 * side)).clamp(
                    0.0,
                    player.queue.length - 1.0,
                  );
                }
              : null,
          onHorizontalDragEnd: widget.interactive
              ? (details) => _release(details.velocity.pixelsPerSecond.dx)
              : null,
          onHorizontalDragCancel: widget.interactive ? () => _release(0) : null,
          child: AnimatedBuilder(
            animation: _position,
            builder: (context, child) {
              final position = _position.value;
              final centered = position.round();
              final first = math.max(0, (position - 2).ceil());
              final last = math.min(player.queue.length - 1, (position + 2).floor());
              final visible = [for (var i = first; i <= last; i++) i]
                ..sort((a, b) {
                  final distance = (b - position).abs().compareTo((a - position).abs());
                  if (distance != 0 || a == b) return distance;
                  if (a == centered) return 1;
                  if (b == centered) return -1;
                  return a.compareTo(b);
                });
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  for (final i in visible)
                    Positioned(
                      key: ValueKey('coverflow-cover-$i'),
                      left: (constraints.maxWidth - side) / 2,
                      top: (constraints.maxHeight - height) / 2,
                      width: side,
                      height: height,
                      child: _transformedCover(
                        player.queue[i],
                        i - position,
                        i == centered,
                        side,
                        height,
                        spread,
                        widget.maxSide,
                      ),
                    ),
                ],
              );
            },
          ),
        );
        return widget.interactive ? flow : IgnorePointer(child: flow);
      },
    );
  }

  Widget _transformedCover(
    Track track,
    double delta,
    bool centered,
    double side,
    double height,
    double spread,
    double maxSide,
  ) {
    final distance = delta.abs();
    final tilt = delta.clamp(-1.0, 1.0);
    // Neighbors shrink to 60 % so their near edge, which the tilt brings towards the viewer, stays below the
    // centered cover's height.
    final scale = 1 - 0.40 * math.min(distance, 1.0);
    final x = distance < 1 ? delta * spread : delta.sign * (spread + 0.2 * side * (distance - 1));
    return Transform.translate(
      offset: Offset(x, 0),
      child: Transform(
        // Move the pivot continuously from the center to the neighbor's outer edge.
        alignment: Alignment(tilt, height > 0 ? -(height - side) / height : 0),
        transform: Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateY(-tilt * 1.05)
          ..scaleByDouble(scale, scale, scale, 1),
        child: IgnorePointer(
          ignoring: !centered,
          child: TrackCover(
            track: track,
            centered: centered,
            dim: 0.35 * math.min(distance, 1.0),
            maxSide: maxSide,
            interactive: widget.interactive,
          ),
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
                  book.episode != null ? context.l10n.podcastsEpisode : context.l10n.audiobooksBook,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: book.episode != null ? context.l10n.podcastsOpen : context.l10n.playerGoToAudiobook,
                icon: const Icon(Icons.info_outline),
                onPressed: () {
                  context.pop();
                  context.push(
                    book.episode != null ? '/podcasts/${book.episode!.podcastId}' : '/audiobooks/item/${book.itemId}',
                  );
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
              child: NetworkCover(url: book.coverUrl.isEmpty ? null : book.coverUrl, radius: 8, icon: Icons.headphones),
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

/// The spectrum and its reflection, painted outside the cover's clipped Material.
class _CoverVisualizer extends ConsumerWidget {
  const _CoverVisualizer({required this.track, required this.reflection});
  final Track track;
  final double reflection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = ref.watch(coverColorProvider(coverImageProvider(ref, track.album.id, size: 300))).value;
    final theme = ref.watch(visualizerThemeProvider);
    return IgnorePointer(
      child: SpectrumVisualizer(
        trackId: track.id,
        color: (color ?? Colors.white).withValues(alpha: 0.85),
        theme: theme.id == 'auto' ? null : theme,
        mirrored: true,
        gap: 0.35,
        minHeight: 0.015,
        reflection: reflection,
      ),
    );
  }
}
