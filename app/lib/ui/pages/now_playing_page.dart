import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../../player/player.dart';
import 'audiobook_pages.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/player_bar.dart';
import '../widgets/track_list.dart';

class NowPlayingPage extends ConsumerWidget {
  const NowPlayingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((p) => p.current));
    final book = ref.watch(playerProvider.select((p) => p.book));
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
          child: book != null
              ? _BookNowPlaying(book: book)
              : track == null
              ? const Center(child: Text('Gerade läuft nichts'))
              : Padding(
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
                          IconButton(
                            icon: const Icon(Icons.more_vert),
                            onPressed: () => showTrackMenu(context, ref, track),
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
                          child: CoverImage(albumId: track.album.id, size: 600, radius: 8),
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
                                      Text(
                                        track.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context).textTheme.headlineSmall
                                            ?.copyWith(fontWeight: FontWeight.w800),
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
                                  tooltip: 'Warteschlange',
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
              const Expanded(
                child: Text(
                  'Hörbuch',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Zum Hörbuch',
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
                      label: const Text('Kapitel'),
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
    final order = ctrl.player.effectiveIndices;
    final pos = p.index == null ? -1 : order.indexOf(p.index!);
    final upcoming = pos < 0 ? <int>[] : order.sublist(pos + 1);

    return Scaffold(
      appBar: AppBar(title: const Text('Warteschlange')),
      body: p.current == null
          ? const Center(
              child: Text('Die Warteschlange ist leer', style: TextStyle(color: Palette.textMuted)),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, kBottomInset),
              children: [
                const _QueueHeading('Läuft gerade'),
                TrackRow(track: p.current!, onPlay: ctrl.togglePlay),
                if (upcoming.isNotEmpty) const _QueueHeading('Als Nächstes'),
                for (final i in upcoming)
                  TrackRow(
                    key: ValueKey('q$i-${p.queue[i].id}'),
                    track: p.queue[i],
                    onPlay: () => ctrl.jumpTo(i),
                    extraActions: [
                      TrackAction('Aus Warteschlange entfernen', Icons.remove_circle_outline, () => ctrl.removeAt(i)),
                    ],
                  ),
              ],
            ),
    );
  }
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
