import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import 'tv_shelves.dart';

TvCardData tvAlbum(BuildContext context, Album album) => TvCardData(
  title: album.title,
  subtitle: album.artist.name,
  image: CoverImage(albumId: album.hasCover ? album.id : null),
  onActivate: () => context.push('/album/${album.id}'),
);

TvCardData tvArtist(BuildContext context, Artist artist) => TvCardData(
  title: artist.name,
  image: ArtistImage(artist: artist),
  onActivate: () => context.push('/artist/${artist.id}'),
);

TvCardData tvPlaylist(BuildContext context, Playlist playlist) => TvCardData(
  title: playlist.name,
  image: PlaylistCover(playlistId: playlist.id, coverKey: playlist.coverKey, albumIds: playlist.coverAlbumIds),
  onActivate: () => context.push('/playlist/${playlist.id}'),
);

/// Like music on the TV, a station opens the full-screen player once it plays.
Future<void> tvPlayStation(BuildContext context, WidgetRef ref, Station station) async {
  try {
    await ref.read(playerProvider.notifier).playStation(station);
    if (context.mounted) context.push('/now-playing');
  } catch (error) {
    if (context.mounted) showError(context, error);
  }
}

TvCardData tvStation(BuildContext context, WidgetRef ref, Station station) => TvCardData(
  title: station.name,
  subtitle: station.country,
  image: NetworkCover(url: station.favicon, icon: Icons.radio),
  onActivate: () => tvPlayStation(context, ref, station),
);

class TvHomePage extends ConsumerWidget {
  const TvHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mixes = ref.watch(mixesProvider).value;
    final stations = ref.watch(worldRadioFavoritesProvider).value ?? [];
    return TvAsync(
      value: ref.watch(homeProvider),
      onRetry: () => ref.invalidate(homeProvider),
      builder: (home) => TvShelves(
        title: context.l10n.navHome,
        shelves: [
          TvShelfData(context.l10n.homeRecentlyPlayed, [for (final a in home.recentlyPlayed) tvAlbum(context, a)]),
          TvShelfData(context.l10n.homeYourPlaylists, [
            TvCardData(
              title: context.l10n.libraryLikedSongs,
              image: const LikedCover(),
              onActivate: () => context.push('/liked'),
            ),
            for (final p in home.playlists) tvPlaylist(context, p),
          ]),
          TvShelfData(context.l10n.worldRadioYourStations, [for (final s in stations) tvStation(context, ref, s)]),
          if (mixes != null) ...[
            TvShelfData(context.l10n.homeMadeForYou, [
              if (mixes.$3 case final discover?) tvPlaylist(context, discover),
              for (final p in mixes.$1) tvPlaylist(context, p),
            ]),
            TvShelfData(context.l10n.homeCharts, [for (final p in mixes.$5) tvPlaylist(context, p)]),
            TvShelfData(context.l10n.homeGenreMixes, [for (final p in mixes.$2) tvPlaylist(context, p)]),
            TvShelfData(context.l10n.homeDecadeMixes, [for (final p in mixes.$4) tvPlaylist(context, p)]),
          ],
          TvShelfData(context.l10n.homeRecentlyAdded, [for (final a in home.recentlyAdded) tvAlbum(context, a)]),
        ],
      ),
    );
  }
}

final _libraryProvider = FutureProvider.autoDispose((ref) async {
  final playlists = ref.watch(playlistsProvider.future);
  final saved = ref.watch(savedAlbumsProvider.future);
  final albums = ref.watch(allAlbumsProvider.future);
  final artists = ref.watch(allArtistsProvider.future);
  return await (playlists, saved, albums, artists).wait;
});

class TvLibraryPage extends ConsumerWidget {
  const TvLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => TvAsync(
    value: ref.watch(_libraryProvider),
    onRetry: () {
      ref.invalidate(playlistsProvider);
      ref.invalidate(savedAlbumsProvider);
      ref.invalidate(allAlbumsProvider);
      ref.invalidate(allArtistsProvider);
    },
    builder: (data) => TvShelves(
      title: context.l10n.navLibrary,
      shelves: [
        TvShelfData(context.l10n.libraryPlaylists, [
          TvCardData(
            title: context.l10n.libraryLikedSongs,
            image: const LikedCover(),
            onActivate: () => context.push('/liked'),
          ),
          for (final p in data.$1) tvPlaylist(context, p),
        ]),
        TvShelfData(context.l10n.librarySavedAlbums, [for (final a in data.$2) tvAlbum(context, a)]),
        TvShelfData(context.l10n.libraryAllAlbums, [for (final a in data.$3) tvAlbum(context, a)]),
        TvShelfData(context.l10n.commonArtists, [for (final a in data.$4) tvArtist(context, a)]),
      ],
    ),
  );
}
