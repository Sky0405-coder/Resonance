import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../core/models.dart';
import '../../core/library.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import 'audiobook_pages.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/player_bar.dart';
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
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [accent.withValues(alpha: 0.45), Palette.background],
          ),
        ),
        child: SafeArea(
          child: station != null
              ? _StationNowPlaying(station: station)
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
                              const Spacer(),
                              ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
                                child: Stack(
                                  clipBehavior: Clip.none,
                                  children: [
                                    // The bars rise behind the cover and show around it.
                                    if (ref.watch(visualizerEnabledProvider))
                                      Positioned(
                                        left: -24,
                                        right: -24,
                                        bottom: -20,
                                        height: 200,
                                        child: IgnorePointer(
                                          child: SpectrumVisualizer(
                                            trackId: track.id,
                                            color: accent.withValues(alpha: 0.75),
                                            mirrored: true,
                                          ),
                                        ),
                                      ),
                                    Material(
                                      elevation: 16,
                                      borderRadius: BorderRadius.circular(8),
                                      clipBehavior: Clip.antiAlias,
                                      child: CoverImage(albumId: track.album.id, size: 600, radius: 8),
                                    ),
                                  ],
                                ),
                              ),
                              const Spacer(),
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
                                                    child: Text(
                                                      track.title,
                                                      maxLines: 1,
                                                      overflow: TextOverflow.ellipsis,
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

class _StationNowPlaying extends StatelessWidget {
  const _StationNowPlaying({required this.station});
  final Station station;

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
        Flexible(
          flex: 5,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480, maxHeight: 480),
            child: NetworkCover(url: station.favicon, radius: 8, icon: Icons.radio),
          ),
        ),
        const Spacer(),
        Text(
          station.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        Text('${context.l10n.worldRadioTitle} · ${station.country}', style: const TextStyle(color: Palette.textMuted)),
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
                TrackRow(track: p.current!, onPlay: ctrl.togglePlay),
                if (addedBy(p.index!) case final label?) _AddedBy(label),
                if (upcoming.isNotEmpty) _QueueHeading(context.l10n.playerNextUp),
                for (final i in upcoming) ...[
                  TrackRow(
                    key: ValueKey('q$i-${p.queue[i].id}'),
                    track: p.queue[i],
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
