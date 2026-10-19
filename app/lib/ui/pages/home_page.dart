import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/offline.dart';
import 'world_radio_page.dart';

String _greeting(AppLocalizations l10n) {
  final h = DateTime.now().hour;
  if (h < 5) return l10n.homeGreetingNight;
  if (h < 11) return l10n.homeGreetingMorning;
  if (h < 18) return l10n.homeGreetingAfternoon;
  return l10n.homeGreetingEvening;
}

Future<void> playAlbum(BuildContext context, WidgetRef ref, String albumId) async {
  final detail = await ref.read(albumProvider(albumId).future);
  if (!context.mounted) return;
  await playMusic(context, ref, detail.tracks, contextId: 'album:$albumId');
}

class HomePage extends ConsumerWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).user;
    final accent = Theme.of(context).colorScheme.primary;

    final heading = Padding(
      // The gradient runs behind the Android status bar; only the content moves below it.
      padding: EdgeInsets.fromLTRB(16, 24 + MediaQuery.paddingOf(context).top, 16, 8),
      child: Row(
        children: [
          Expanded(child: Text(_greeting(context.l10n), style: Theme.of(context).textTheme.headlineMedium)),
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
    );
    if (!kIsWeb && ref.watch(sessionProvider.select((s) => s.offline))) {
      return OfflineCollections(heading: heading);
    }
    final home = ref.watch(homeProvider);
    final mixes = ref.watch(mixesProvider).value;
    final stations = ref.watch(worldRadioFavoritesProvider).value ?? <Station>[];

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: const Alignment(0, -0.3),
          colors: [accent.withValues(alpha: 0.22), Palette.background],
        ),
      ),
      child: RefreshIndicator(
        onRefresh: () {
          ref.invalidate(mixesProvider);
          ref.invalidate(worldRadioFavoritesProvider);
          return ref.refresh(homeProvider.future);
        },
        child: AsyncBody(
          value: home,
          onRetry: () => ref.invalidate(homeProvider),
          builder: (h) => ListView(
            padding: const EdgeInsets.only(bottom: kBottomInset),
            children: [
              heading,
              _QuickGrid(home: h),
              if (stations.isNotEmpty)
                Shelf(
                  title: context.l10n.worldRadioYourStations,
                  children: [for (final station in stations) StationCard(station: station)],
                ),
              if (mixes != null)
                Shelf(
                  title: context.l10n.homeMadeForYou,
                  children: [
                    if (mixes.$3 case final discover?) PlaylistCard(playlist: discover),
                    for (final p in mixes.$1) PlaylistCard(playlist: p),
                  ],
                ),
              Shelf(
                title: context.l10n.homeRecentlyPlayed,
                children: [
                  for (final a in h.recentlyPlayed) AlbumCard(album: a, onPlay: () => playAlbum(context, ref, a.id)),
                ],
              ),
              Shelf(
                title: context.l10n.homeYourPlaylists,
                children: [for (final p in h.playlists) PlaylistCard(playlist: p)],
              ),
              if (mixes != null)
                Shelf(
                  title: context.l10n.homeGenreMixes,
                  children: [for (final p in mixes.$2) PlaylistCard(playlist: p)],
                ),
              if (mixes != null)
                Shelf(
                  title: context.l10n.homeDecadeMixes,
                  children: [for (final p in mixes.$4) PlaylistCard(playlist: p)],
                ),
              Shelf(
                title: context.l10n.homeRecentlyAdded,
                children: [
                  for (final a in h.recentlyAdded) AlbumCard(album: a, onPlay: () => playAlbum(context, ref, a.id)),
                ],
              ),
              if (h.recentlyAdded.isEmpty)
                Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    context.l10n.homeEmptyLibrary,
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
      _QuickTile(
        image: const LikedCover(radius: 0),
        title: context.l10n.libraryLikedSongs,
        onTap: () => context.push('/liked'),
      ),
      for (final p in home.playlists.take(3))
        _QuickTile(
          image: PlaylistCover(playlistId: p.id, coverKey: p.coverKey, albumIds: p.coverAlbumIds, radius: 0),
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
