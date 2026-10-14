import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';

String _greeting() {
  final h = DateTime.now().hour;
  if (h < 5) return 'Gute Nacht';
  if (h < 11) return 'Guten Morgen';
  if (h < 18) return 'Guten Tag';
  return 'Guten Abend';
}

Future<void> playAlbum(BuildContext context, WidgetRef ref, String albumId, {bool shuffle = false}) async {
  final detail = await ref.read(albumProvider(albumId).future);
  if (!context.mounted) return;
  await playMusic(context, ref, detail.tracks, contextId: 'album:$albumId', shuffle: shuffle);
}

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final home = ref.watch(homeProvider);
    final user = ref.watch(sessionProvider).user;
    final accent = Theme.of(context).colorScheme.primary;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: const Alignment(0, -0.3),
          colors: [accent.withValues(alpha: 0.22), Palette.background],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: () => ref.refresh(homeProvider.future),
        child: AsyncBody(
          value: home,
          onRetry: () => ref.invalidate(homeProvider),
          builder: (h) => ListView(
            padding: const EdgeInsets.only(bottom: kBottomInset),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Row(
                  children: [
                    Expanded(child: Text(_greeting(), style: Theme.of(context).textTheme.headlineMedium)),
                    if (!isWide(context))
                      IconButton(
                        icon: CircleAvatar(
                          radius: 16,
                          backgroundColor: accent,
                          child: Text(
                            (user?.displayName ?? '?').characters.first.toUpperCase(),
                            style: TextStyle(color: onColor(accent), fontWeight: FontWeight.bold),
                          ),
                        ),
                        onPressed: () => context.push('/settings'),
                      ),
                  ],
                ),
              ),
              _QuickGrid(home: h),
              Shelf(
                title: 'Zuletzt gehört',
                children: [
                  for (final a in h.recentlyPlayed) AlbumCard(album: a, onPlay: () => playAlbum(context, ref, a.id)),
                ],
              ),
              Shelf(
                title: 'Deine Playlists',
                children: [for (final p in h.playlists) PlaylistCard(playlist: p)],
              ),
              Shelf(
                title: 'Neu in der Bibliothek',
                children: [
                  for (final a in h.recentlyAdded) AlbumCard(album: a, onPlay: () => playAlbum(context, ref, a.id)),
                ],
              ),
              if (h.recentlyAdded.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'Deine Bibliothek ist noch leer.\nEin Admin kann im Dashboard einen Bibliotheks-Scan starten.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Palette.textMuted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact tiles at the top of home (Spotify's "recent" grid).
class _QuickGrid extends ConsumerWidget {
  const _QuickGrid({required this.home});
  final Home home;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tiles = <Widget>[
      _QuickTile(image: const LikedCover(radius: 0), title: 'Lieblingssongs', onTap: () => context.push('/liked')),
      for (final p in home.playlists.take(3))
        _QuickTile(
          image: PlaylistCover(albumIds: p.coverAlbumIds, radius: 0),
          title: p.name,
          onTap: () => context.push('/playlist/${p.id}'),
        ),
      for (final a in home.recentlyPlayed.take(4))
        _QuickTile(
          image: CoverImage(albumId: a.hasCover ? a.id : null, radius: 0, size: 128),
          title: a.title,
          onTap: () => context.push('/album/${a.id}'),
        ),
    ].take(8).toList();

    final cols = isWide(context) ? 4 : 2;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, c) {
          final w = (c.maxWidth - (cols - 1) * 8) / cols;
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final t in tiles) SizedBox(width: w, height: 56, child: t)],
          );
        },
      ),
    );
  }
}

class _QuickTile extends StatelessWidget {
  const _QuickTile({required this.image, required this.title, required this.onTap});
  final Widget image;
  final String title;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Colors.white.withValues(alpha: 0.08),
    borderRadius: BorderRadius.circular(4),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Row(
        children: [
          SizedBox(width: 56, height: 56, child: image),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
          ),
        ],
      ),
    ),
  );
}
