import 'package:flutter/foundation.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../player/player.dart';
import '../offline/offline_store.dart';
import 'api.dart';
import 'models.dart';
import 'session.dart';

/// Generated playlists; null when unavailable (offline, server error) – home simply hides them then.
final mixesProvider = FutureProvider.autoDispose<(List<Playlist>, List<Playlist>, Playlist?)?>((ref) async {
  try {
    return await ref.watch(apiProvider).mixes();
  } catch (_) {
    return null;
  }
});

final homeProvider = FutureProvider.autoDispose<Home>((ref) => ref.watch(apiProvider).home());

final lyricsProvider = FutureProvider.family<Lyrics, String>((ref, id) {
  final cached = kIsWeb ? null : ref.watch(offlineProvider.select((s) => s.lyrics(id)));
  return cached ?? ref.watch(apiProvider).lyrics(id);
});

final albumProvider = FutureProvider.autoDispose.family<AlbumDetail, String>(
  (ref, id) =>
      _withOffline(ref, 'album:$id', () => ref.watch(apiProvider).album(id), (data) => AlbumDetail.fromJson(data)),
);

final artistProvider = FutureProvider.autoDispose.family<ArtistDetail, String>(
  (ref, id) => ref.watch(apiProvider).artist(id),
);

final playlistDetailProvider = FutureProvider.autoDispose.family<PlaylistDetail, String>(
  (ref, id) => _withOffline(
    ref,
    'playlist:$id',
    () => ref.watch(apiProvider).playlist(id),
    (data) => PlaylistDetail.fromJson(data),
  ),
);

final playlistsProvider = FutureProvider<List<Playlist>>((ref) async {
  ref.watch(sessionProvider.select((s) => s.offline));
  final cached = kIsWeb ? null : ref.watch(offlineProvider.select((s) => s.collections));
  try {
    return await ref.watch(apiProvider).playlists();
  } on ApiException catch (e) {
    if (e.statusCode != null || cached == null) rethrow;
    return [
      for (final collection in cached.values)
        if (collection.kind == 'playlist') Playlist.fromJson(collection.data),
    ];
  }
});

final likedTracksProvider = FutureProvider<List<Track>>(
  (ref) => _withOffline(
    ref,
    'liked',
    () => ref.watch(apiProvider).likedTracks(),
    (data) => [for (final track in data) Track.fromJson(track)],
  ),
);

Future<T> _withOffline<T>(Ref ref, String key, Future<T> Function() fetch, T Function(dynamic) parse) async {
  ref.watch(sessionProvider.select((s) => s.offline));
  final cached = kIsWeb ? null : ref.watch(offlineProvider.select((s) => s.collections[key]));
  try {
    return await fetch();
  } on ApiException catch (e) {
    if (e.statusCode != null || cached == null) rethrow;
    return parse(cached.data);
  }
}

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

final worldRadioFavoritesProvider = FutureProvider<List<Station>>(
  (ref) => ref.watch(apiProvider).worldRadioFavorites(),
);

final worldRadioCountriesProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>(
  (ref) => ref.watch(apiProvider).worldRadioCountries(),
);

final worldRadioTagsProvider = FutureProvider.autoDispose<List<String>>(
  (ref) => ref.watch(apiProvider).worldRadioTags(),
);
