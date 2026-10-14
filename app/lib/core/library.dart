import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player.dart';
import 'models.dart';
import 'session.dart';

final homeProvider = FutureProvider.autoDispose<Home>((ref) => ref.watch(apiProvider).home());

final albumProvider = FutureProvider.autoDispose.family<AlbumDetail, String>(
  (ref, id) => ref.watch(apiProvider).album(id),
);

final artistProvider = FutureProvider.autoDispose.family<ArtistDetail, String>(
  (ref, id) => ref.watch(apiProvider).artist(id),
);

final playlistDetailProvider = FutureProvider.autoDispose.family<PlaylistDetail, String>(
  (ref, id) => ref.watch(apiProvider).playlist(id),
);

final playlistsProvider = FutureProvider<List<Playlist>>((ref) => ref.watch(apiProvider).playlists());

final likedTracksProvider = FutureProvider<List<Track>>((ref) => ref.watch(apiProvider).likedTracks());

final savedAlbumsProvider = FutureProvider.autoDispose<List<Album>>(
  (ref) => ref.watch(apiProvider).albums(saved: true),
);

final allAlbumsProvider = FutureProvider.autoDispose<List<Album>>(
  (ref) => ref.watch(apiProvider).albums(sort: 'title', limit: 500),
);

final allArtistsProvider = FutureProvider.autoDispose<List<Artist>>((ref) => ref.watch(apiProvider).artists());

final searchProvider = FutureProvider.autoDispose.family<SearchResult, String>(
  (ref, q) => ref.watch(apiProvider).search(q),
);

/// Per-album counter bumped when an admin replaces a cover, so cached images are fetched again.
final coverVersionsProvider = NotifierProvider<CoverVersions, Map<String, int>>(CoverVersions.new);

class CoverVersions extends Notifier<Map<String, int>> {
  @override
  Map<String, int> build() => {};

  Future<void> bump(String albumId) async {
    // Same cache keys as CoverImage, so the next app start does not show the old cover either.
    for (final size in const [64, 128, 150, 300, 600]) {
      await CachedNetworkImage.evictFromCache('', cacheKey: 'cover:$albumId:$size');
    }
    state = {...state, albumId: (state[albumId] ?? 0) + 1};
  }
}

/// Library mutations that need to refresh several views.
class LibraryActions {
  LibraryActions(this.ref);
  final Ref ref;

  Future<void> setLiked(Track track, bool liked) async {
    await ref.read(apiProvider).setLiked(track.id, liked);
    ref.read(playerProvider.notifier).setLikedLocally(track.id, liked);
    ref.invalidate(likedTracksProvider);
    ref.invalidate(albumProvider);
    ref.invalidate(playlistDetailProvider);
    ref.invalidate(artistProvider);
    ref.invalidate(searchProvider);
  }

  /// After an admin changed tags or files, every view showing library metadata may be stale.
  void libraryChanged() {
    for (final p in [
      homeProvider,
      albumProvider,
      artistProvider,
      playlistDetailProvider,
      playlistsProvider,
      likedTracksProvider,
      savedAlbumsProvider,
      allAlbumsProvider,
      allArtistsProvider,
      searchProvider,
    ]) {
      ref.invalidate(p);
    }
  }

  Future<void> setAlbumSaved(String albumId, bool saved) async {
    await ref.read(apiProvider).setAlbumSaved(albumId, saved);
    ref.invalidate(albumProvider(albumId));
    ref.invalidate(savedAlbumsProvider);
  }

  Future<Playlist> createPlaylist(String name) async {
    final p = await ref.read(apiProvider).createPlaylist(name);
    ref.invalidate(playlistsProvider);
    return p;
  }

  Future<void> addToPlaylist(String playlistId, List<String> trackIds) async {
    await ref.read(apiProvider).addToPlaylist(playlistId, trackIds);
    ref.invalidate(playlistDetailProvider(playlistId));
    ref.invalidate(playlistsProvider);
  }

  Future<void> removeFromPlaylist(String playlistId, String entryId) async {
    await ref.read(apiProvider).removeFromPlaylist(playlistId, entryId);
    ref.invalidate(playlistDetailProvider(playlistId));
    ref.invalidate(playlistsProvider);
  }

  Future<void> deletePlaylist(String playlistId) async {
    await ref.read(apiProvider).deletePlaylist(playlistId);
    ref.invalidate(playlistsProvider);
  }
}

final libraryActionsProvider = Provider((ref) => LibraryActions(ref));
