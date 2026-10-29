import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'library.dart';
import 'models.dart';
import 'session.dart';

/// Re-runs the provider after [every] while [active] – used for live download progress.
void _pollWhile(Ref ref, bool active, Duration every) {
  if (!active) return;
  final timer = Timer(every, ref.invalidateSelf);
  ref.onDispose(timer.cancel);
}

final catalogSearchProvider = FutureProvider.autoDispose.family<CatalogSearch, String>(
  (ref, q) => ref.watch(apiProvider).catalogSearch(q),
);

final catalogPlaylistsProvider = FutureProvider.autoDispose.family<List<CatalogPlaylist>, String>(
  (ref, q) => ref.watch(apiProvider).catalogPlaylists(q),
);

final catalogPlaylistProvider = FutureProvider.autoDispose.family<CatalogPlaylistDetail, String>(
  (ref, link) => ref.watch(apiProvider).catalogPlaylist(link),
);

final catalogAlbumProvider = FutureProvider.autoDispose.family<CatalogAlbumDetail, String>(
  (ref, id) => ref.watch(apiProvider).catalogAlbum(id),
);

/// Missing songs of a library album; null if the album is not in the catalog or the catalog is unreachable.
final albumMissingProvider = FutureProvider.autoDispose.family<(String, List<CatalogTrack>)?, String>((ref, id) async {
  try {
    return await ref.watch(apiProvider).albumMissing(id);
  } catch (_) {
    return null;
  }
});

final catalogArtistProvider = FutureProvider.autoDispose.family<CatalogArtistDetail, String>(
  (ref, id) => ref.watch(apiProvider).catalogArtist(id),
);

/// Request lists, keyed by (scope, state, count) – scope `mine` or `all` (admins), state
/// `open`/`finished`/`failed`/`all`, count how many of the newest to load.
final requestsProvider = FutureProvider.autoDispose
    .family<({List<DownloadRequest> items, int total}), (String, String, int)>((ref, key) async {
      final page = await ref.watch(apiProvider).requests(scope: key.$1, state: key.$2, limit: key.$3);
      _pollWhile(ref, page.items.any((r) => r.status == 'active'), const Duration(seconds: 2));
      return page;
    });

final requestDetailProvider = FutureProvider.autoDispose.family<DownloadRequest, String>((ref, id) async {
  final r = await ref.watch(apiProvider).request(id);
  _pollWhile(ref, r.isOpen, const Duration(seconds: 2));
  return r;
});

/// Badge counts for the navigation; polls slowly when idle and quickly while downloads run.
final downloadSummaryProvider = FutureProvider.autoDispose<DownloadSummary>((ref) async {
  if (!ref.watch(sessionProvider.select((s) => s.loggedIn))) return const DownloadSummary();
  final s = await ref.watch(apiProvider).downloadSummary();
  _pollWhile(ref, true, Duration(seconds: s.running > 0 ? 3 : 15));
  return s;
});

/// Catalog IDs the current user has open requests for, so request buttons can show "requested".
final openRequestIdsProvider = Provider.autoDispose<Set<String>>((ref) {
  final list = ref.watch(requestsProvider(('mine', 'open', 100))).value?.items ?? const [];
  return {for (final r in list) ?r.catalogId};
});

class DownloadActions {
  DownloadActions(this.ref);
  final Ref ref;

  void _refresh() {
    ref.invalidate(requestsProvider);
    ref.invalidate(requestDetailProvider);
    ref.invalidate(downloadSummaryProvider);
  }

  Future<DownloadRequest> request(String kind, String catalogId) async {
    final r = await ref.read(apiProvider).createRequest(kind, catalogId);
    _refresh();
    // Items that already existed are linked to the library right away.
    ref.invalidate(catalogAlbumProvider);
    ref.invalidate(catalogSearchProvider);
    return r;
  }

  Future<void> action(String id, String action) async {
    await ref.read(apiProvider).requestAction(id, action);
    _refresh();
  }

  Future<({int requests, int songs})> retryAllFailed(String scope) async {
    final result = await ref.read(apiProvider).retryAllFailed(scope);
    _refresh();
    return result;
  }

  Future<void> reject(String id, {String? note}) async {
    await ref.read(apiProvider).rejectRequest(id, note: note);
    _refresh();
  }

  Future<void> setItemSource(String requestId, String itemId, String url) async {
    await ref.read(apiProvider).setItemSource(requestId, itemId, url);
    _refresh();
  }

  Future<void> delete(String id) async {
    await ref.read(apiProvider).deleteRequest(id);
    _refresh();
  }

  /// Called when a request finishes so library views pick up the new songs.
  void libraryChanged() {
    ref.invalidate(homeProvider);
    ref.invalidate(searchProvider);
    ref.invalidate(allAlbumsProvider);
    ref.invalidate(allArtistsProvider);
    ref.invalidate(catalogAlbumProvider);
    ref.invalidate(catalogArtistProvider);
    ref.invalidate(catalogSearchProvider);
  }
}

final downloadActionsProvider = Provider((ref) => DownloadActions(ref));
