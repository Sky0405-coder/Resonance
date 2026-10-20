import '../../l10n/l10n.dart';

import 'package:file_picker/file_picker.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/downloads.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../widgets/catalog.dart';
import '../widgets/action_sheet.dart';
import '../widgets/collection.dart';
import 'admin/metadata_editor.dart';
import '../widgets/common.dart';
import '../widgets/offline.dart';
import '../widgets/track_list.dart';

/// Whether [contextId] is what's currently playing (for the play/pause toggle).
bool _isPlayingContext(WidgetRef ref, String contextId) =>
    ref.watch(playerProvider.select((p) => p.context == contextId && p.playing));

void _playOrToggle(
  BuildContext context,
  WidgetRef ref,
  String contextId,
  List<Track> tracks, {
  int? index,
  bool isRadio = false,
}) {
  final p = ref.read(playerProvider);
  final ctrl = ref.read(playerProvider.notifier);
  if (p.context == contextId && p.current != null) {
    ctrl.togglePlay();
  } else {
    playMusic(context, ref, tracks, index: index, contextId: contextId, isRadio: isRadio);
  }
}

/// Opens the catalog page of a library album, where its missing songs can be downloaded.
Future<void> _openInCatalog(BuildContext context, WidgetRef ref, String albumId) async {
  try {
    final catalogId = await ref.read(apiProvider).albumCatalogId(albumId);
    if (context.mounted) context.push('/catalog/album/$catalogId');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> _deleteAlbum(BuildContext context, WidgetRef ref, AlbumDetail d) async {
  final l10n = context.l10n;
  if (!await confirmDelete(context, l10n.adminDeleteAlbum, l10n.adminDeleteAlbumConfirm(d.album.title))) return;
  try {
    await ref.read(apiProvider).deleteLibraryAlbum(d.album.id);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  invalidateLibrary(ref);
  if (!context.mounted) return;
  showInfo(context, l10n.adminDeleted);
  context.canPop() ? context.pop() : context.go('/library');
}

/// Songs of the album that are not downloaded yet, greyed out below the album's songs.
class _MissingSongs extends ConsumerWidget {
  const _MissingSongs({required this.albumId});
  final String albumId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final missing = ref.watch(albumMissingProvider(albumId)).value;
    if (missing == null || missing.$2.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    final (catalogId, tracks) = missing;
    return SliverPadding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      sliver: SliverList.list(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 24, 12, 4),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(context.l10n.albumMissingTitle(tracks.length), style: Theme.of(context).textTheme.titleMedium),
                RequestButton(
                  kind: 'album',
                  catalogId: catalogId,
                  inLibrary: false,
                  label: tracks.length == 1
                      ? context.l10n.catalogDownloadMissingSong
                      : context.l10n.catalogDownloadMissingSongs(tracks.length),
                ),
              ],
            ),
          ),
          for (final t in tracks)
            Opacity(
              opacity: 0.5,
              child: CatalogTrackRow(track: t, number: t.trackNo, showCover: false),
            ),
        ],
      ),
    );
  }
}

class AlbumPage extends ConsumerWidget {
  const AlbumPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(albumProvider(id));
    final ctx = 'album:$id';
    final playing = _isPlayingContext(ref, ctx);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: OfflineCollectionRefresh(
        collectionKey: ctx,
        onRefresh: () => ref.refresh(albumProvider(id).future).then<void>((_) {}),
        child: AsyncBody(
          value: value,
          onRetry: () => ref.invalidate(albumProvider(id)),
          builder: (d) {
            final multiDisc = d.tracks.map((t) => t.discNo ?? 1).toSet().length > 1;
            final rows = <Widget>[];
            int? disc;
            for (final (i, t) in d.tracks.indexed) {
              if (multiDisc && t.discNo != disc) {
                disc = t.discNo;
                rows.add(
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                    child: Text(
                      context.l10n.commonDiscNumber(disc ?? 1),
                      style: const TextStyle(color: Palette.textMuted, fontWeight: FontWeight.w700),
                    ),
                  ),
                );
              }
              rows.add(
                TrackRow(
                  track: t,
                  number: t.trackNo ?? i + 1,
                  showCover: false,
                  showAlbum: false,
                  onPlay: () => playMusic(context, ref, d.tracks, index: i, contextId: ctx),
                ),
              );
            }
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: CollectionHeader(
                    image: CoverImage(albumId: d.album.hasCover ? id : null, size: 600, icon: Icons.album),
                    kind: context.l10n.commonAlbum,
                    title: d.album.title,
                    meta: Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        InkWell(
                          onTap: () => context.push('/artist/${d.album.artist.id}'),
                          child: Text(
                            d.album.artist.name,
                            style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                          ),
                        ),
                        Text(
                          [
                            if (d.album.year != null) ' • ${d.album.year}',
                            ' • ${songs(context.l10n, d.tracks.length)}, ${formatLongDuration(context.l10n, d.duration)}',
                          ].join(),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: ActionBar(
                    playing: playing,
                    onPlay: d.tracks.isEmpty ? null : () => _playOrToggle(context, ref, ctx, d.tracks),
                    canShuffle: d.tracks.isNotEmpty,
                    children: [
                      OfflineDownloadButton(kind: 'album', id: id),
                      IconButton(
                        tooltip: d.saved ? context.l10n.libraryRemoveAlbum : context.l10n.librarySaveAlbum,
                        iconSize: 30,
                        color: d.saved ? Theme.of(context).colorScheme.primary : Palette.textMuted,
                        icon: Icon(d.saved ? Icons.check_circle : Icons.add_circle_outline),
                        onPressed: () => ref.read(libraryActionsProvider).setAlbumSaved(id, !d.saved),
                      ),
                      IconButton(
                        tooltip: context.l10n.playerAddToPlaylist,
                        iconSize: 28,
                        color: Palette.textMuted,
                        icon: const Icon(Icons.playlist_add),
                        onPressed: () => showAddToPlaylist(context, ref, [for (final t in d.tracks) t.id]),
                      ),
                      IconButton(
                        iconSize: 28,
                        color: Palette.textMuted,
                        icon: const Icon(Icons.more_horiz),
                        onPressed: () => showActionSheet(
                          context,
                          header: ListTile(
                            leading: SizedBox(width: 48, child: CoverImage(albumId: id, size: 64)),
                            title: Text(d.album.title),
                            subtitle: Text(d.album.artist.name),
                          ),
                          actions: [
                            SheetAction(
                              icon: Icons.radio,
                              label: context.l10n.radioStartAlbum,
                              onSelected: () => startRadio(context, ref, 'album', id),
                            ),
                            SheetAction(
                              icon: Icons.download,
                              label: context.l10n.albumFindMissing,
                              onSelected: () => _openInCatalog(context, ref, id),
                            ),
                            if (ref.read(sessionProvider).user?.isAdmin ?? false) ...[
                              SheetAction(
                                icon: Icons.manage_search,
                                label: context.l10n.editorMatchAlbum,
                                onSelected: () async {
                                  final album = await showAlbumMatcher(context, ref, d);
                                  // The songs may now live in another (new or existing) album.
                                  if (album != null && album.id != id && context.mounted) {
                                    context.pushReplacement('/album/${album.id}');
                                  }
                                },
                              ),
                              SheetAction(
                                icon: Icons.image_search,
                                label: context.l10n.editorChangeCover,
                                onSelected: () => showCoverPicker(context, ref, id),
                              ),
                              SheetAction(
                                icon: Icons.delete_outline,
                                label: context.l10n.adminDeleteAlbum,
                                onSelected: () => _deleteAlbum(context, ref, d),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  sliver: SliverList.list(children: rows),
                ),
                _MissingSongs(albumId: id),
                const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class ArtistPage extends ConsumerWidget {
  const ArtistPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(artistProvider(id));
    final ctx = 'artist:$id';
    final playing = _isPlayingContext(ref, ctx);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AsyncBody(
        value: value,
        onRetry: () => ref.invalidate(artistProvider(id)),
        builder: (d) => CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: CollectionHeader(
                circleImage: true,
                image: ArtistImage(artist: d.artist, size: 600),
                kind: context.l10n.commonArtist,
                title: d.artist.name,
                meta: Text(context.l10n.artistLibraryAlbums(d.albums.length)),
              ),
            ),
            SliverToBoxAdapter(
              child: ActionBar(
                playing: playing,
                onPlay: d.topTracks.isEmpty ? null : () => _playOrToggle(context, ref, ctx, d.topTracks),
                canShuffle: d.topTracks.isNotEmpty,
              ),
            ),
            if (d.topTracks.isNotEmpty) ...[
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Text(context.l10n.artistPopular, style: Theme.of(context).textTheme.titleLarge),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverList.list(
                  children: [
                    for (final (i, t) in d.topTracks.take(5).indexed)
                      TrackRow(
                        track: t,
                        onPlay: () => playMusic(context, ref, d.topTracks, index: i, contextId: ctx),
                      ),
                  ],
                ),
              ),
            ],
            if (d.bio?.trim().isNotEmpty ?? false) SliverToBoxAdapter(child: _ArtistBiography(bio: d.bio!)),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                child: Text(context.l10n.artistDiscography, style: Theme.of(context).textTheme.titleLarge),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              sliver: SliverGrid.extent(
                maxCrossAxisExtent: 200,
                childAspectRatio: 0.72,
                children: [for (final a in d.albums) AlbumCard(album: a)],
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
          ],
        ),
      ),
    );
  }
}

class _ArtistBiography extends StatefulWidget {
  const _ArtistBiography({required this.bio});
  final String bio;

  @override
  State<_ArtistBiography> createState() => _ArtistBiographyState();
}

class _ArtistBiographyState extends State<_ArtistBiography> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(context.l10n.artistAbout, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(widget.bio, maxLines: _expanded ? null : 4, overflow: _expanded ? null : TextOverflow.ellipsis),
        TextButton(
          onPressed: () => setState(() => _expanded = !_expanded),
          child: Text(_expanded ? context.l10n.artistShowLess : context.l10n.artistShowMore),
        ),
      ],
    ),
  );
}

class PlaylistPage extends ConsumerWidget {
  const PlaylistPage({super.key, required this.id});
  final String id;

  Future<void> _changeCover(BuildContext context, WidgetRef ref, {bool remove = false}) async {
    try {
      final api = ref.read(apiProvider);
      if (remove) {
        await api.deletePlaylistCover(id);
      } else {
        final file = await FilePicker.pickFile(type: FileType.image);
        if (file == null) return;
        final bytes = await file.readAsBytes();
        await api.uploadPlaylistCover(id, bytes, file.name);
      }
      ref.invalidate(playlistDetailProvider(id));
      ref.invalidate(playlistsProvider);
      if (context.mounted) {
        showInfo(context, remove ? context.l10n.playlistCoverRemoved : context.l10n.editorCoverSaved);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(playlistDetailProvider(id));
    final userId = ref.watch(sessionProvider.select((s) => s.user?.id));
    final ctx = 'playlist:$id';
    final playing = _isPlayingContext(ref, ctx);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: OfflineCollectionRefresh(
        collectionKey: ctx,
        onRefresh: () => ref.refresh(playlistDetailProvider(id).future).then<void>((_) {}),
        child: AsyncBody(
          value: value,
          onRetry: () => ref.invalidate(playlistDetailProvider(id)),
          builder: (d) {
            final tracks = [for (final e in d.entries) e.track];
            final actions = ref.read(libraryActionsProvider);
            return CustomScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: CollectionHeader(
                    image: d.playlist.mixKey == 'discover-weekly' && d.playlist.coverKey == null
                        ? const DiscoverCover()
                        : PlaylistCover(
                            playlistId: d.playlist.id,
                            coverKey: d.playlist.coverKey,
                            albumIds: d.playlist.coverAlbumIds,
                          ),
                    kind: d.playlist.isRadio
                        ? context.l10n.radioKind
                        : d.playlist.isMix
                        ? context.l10n.mixKind
                        : d.playlist.isPublic
                        ? context.l10n.libraryPublicPlaylist
                        : context.l10n.commonPlaylist,
                    title: d.playlist.name,
                    description: d.playlist.description,
                    meta: Text(
                      '${d.playlist.owner.name} • ${songs(context.l10n, d.playlist.trackCount)}'
                      '${d.playlist.duration > 0 ? ', ${formatLongDuration(context.l10n, d.playlist.duration)}' : ''}'
                      '${d.playlist.sharedWith.isEmpty ? '' : '\n${context.l10n.librarySharedWith(d.playlist.sharedWith.map((u) => u.name).join(', '))}'}',
                    ),
                  ),
                ),
                SliverToBoxAdapter(
                  child: ActionBar(
                    playing: playing,
                    onPlay: tracks.isEmpty
                        ? null
                        : () => _playOrToggle(context, ref, ctx, tracks, isRadio: d.playlist.isRadio),
                    canShuffle: tracks.isNotEmpty,
                    children: [
                      OfflineDownloadButton(kind: 'playlist', id: id),
                      if (d.editable)
                        IconButton(
                          iconSize: 28,
                          color: Palette.textMuted,
                          icon: const Icon(Icons.more_horiz),
                          onPressed: () => showActionSheet(
                            context,
                            header: ListTile(
                              leading: SizedBox(
                                width: 48,
                                child: PlaylistCover(
                                  albumIds: d.playlist.coverAlbumIds,
                                  playlistId: d.playlist.id,
                                  coverKey: d.playlist.coverKey,
                                ),
                              ),
                              title: Text(d.playlist.name),
                              subtitle: Text(d.playlist.owner.name),
                            ),
                            actions: [
                              if (d.playlist.isMix)
                                SheetAction(
                                  icon: Icons.bookmark_add,
                                  label: context.l10n.mixSave,
                                  onSelected: () async {
                                    final kept = await ref.read(apiProvider).keepPlaylist(id);
                                    ref.invalidate(playlistDetailProvider(id));
                                    ref.invalidate(playlistsProvider);
                                    if (kept.id != id && context.mounted) context.push('/playlist/${kept.id}');
                                  },
                                )
                              else if (d.playlist.isRadio)
                                SheetAction(
                                  icon: Icons.bookmark_add,
                                  label: context.l10n.radioKeep,
                                  onSelected: () async {
                                    final kept = await ref.read(apiProvider).keepPlaylist(id);
                                    ref.invalidate(playlistDetailProvider(id));
                                    ref.invalidate(playlistsProvider);
                                    if (kept.id != id && context.mounted) context.push('/playlist/${kept.id}');
                                  },
                                )
                              else ...[
                                SheetAction(
                                  icon: Icons.edit,
                                  label: context.l10n.commonRename,
                                  onSelected: () async {
                                    final name = await promptText(
                                      context,
                                      context.l10n.libraryRenamePlaylist,
                                      context.l10n.commonName,
                                      initial: d.playlist.name,
                                    );
                                    if (name != null && name.isNotEmpty) {
                                      await ref.read(apiProvider).updatePlaylist(id, {'name': name});
                                      ref.invalidate(playlistDetailProvider(id));
                                      ref.invalidate(playlistsProvider);
                                    }
                                  },
                                ),
                                SheetAction(
                                  icon: d.playlist.isPublic ? Icons.lock : Icons.public,
                                  label: d.playlist.isPublic
                                      ? context.l10n.libraryMakePrivate
                                      : context.l10n.librarySharePlaylist,
                                  onSelected: () async {
                                    await ref.read(apiProvider).updatePlaylist(id, {'is_public': !d.playlist.isPublic});
                                    ref.invalidate(playlistDetailProvider(id));
                                    ref.invalidate(playlistsProvider);
                                  },
                                ),
                                SheetAction(
                                  icon: Icons.group_add,
                                  label: context.l10n.libraryShareWithUsers,
                                  onSelected: () => showShareWithUsers(context, ref, d.playlist),
                                ),
                              ],
                              if (d.playlist.kind == 'user' && d.playlist.owner.id == userId)
                                SheetAction(
                                  icon: Icons.sync,
                                  label: context.l10n.spotifySyncMenu,
                                  onSelected: () => context.push('/playlist/$id/spotify'),
                                ),
                              if (d.playlist.kind == 'user')
                                SheetAction(
                                  icon: Icons.image,
                                  label: context.l10n.editorChangeCover,
                                  onSelected: () => _changeCover(context, ref),
                                ),
                              if (d.playlist.coverKey != null)
                                SheetAction(
                                  icon: Icons.hide_image,
                                  label: context.l10n.playlistRemoveCover,
                                  onSelected: () => _changeCover(context, ref, remove: true),
                                ),
                              if (!d.playlist.isMix)
                                SheetAction(
                                  icon: Icons.delete_outline,
                                  label: context.l10n.commonDelete,
                                  onSelected: () async {
                                    await actions.deletePlaylist(id);
                                    if (context.mounted) context.go('/library');
                                  },
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (tracks.isEmpty)
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        context.l10n.libraryEmptyPlaylist,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Palette.textMuted),
                      ),
                    ),
                  ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  sliver: SliverList.builder(
                    itemCount: d.entries.length,
                    itemBuilder: (_, i) {
                      final e = d.entries[i];
                      return TrackRow(
                        key: ValueKey(e.entryId),
                        track: e.track,
                        number: e.rank,
                        onPlay: () =>
                            playMusic(context, ref, tracks, index: i, contextId: ctx, isRadio: d.playlist.isRadio),
                        extraActions: [
                          if (d.editable && !d.playlist.isMix)
                            TrackAction(
                              context.l10n.libraryRemoveFromPlaylist,
                              Icons.remove_circle_outline,
                              () => actions.removeFromPlaylist(id, e.entryId),
                            ),
                        ],
                      );
                    },
                  ),
                ),
                const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
              ],
            );
          },
        ),
      ),
    );
  }
}

class LikedPage extends ConsumerWidget {
  const LikedPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(likedTracksProvider);
    const ctx = 'liked';
    final playing = _isPlayingContext(ref, ctx);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: OfflineCollectionRefresh(
        collectionKey: ctx,
        onRefresh: () => ref.refresh(likedTracksProvider.future).then<void>((_) {}),
        child: AsyncBody(
          value: value,
          onRetry: () => ref.invalidate(likedTracksProvider),
          builder: (tracks) => CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: CollectionHeader(
                  image: const LikedCover(),
                  kind: context.l10n.commonPlaylist,
                  title: context.l10n.libraryLikedSongs,
                  meta: Text(songs(context.l10n, tracks.length)),
                ),
              ),
              SliverToBoxAdapter(
                child: ActionBar(
                  playing: playing,
                  onPlay: tracks.isEmpty ? null : () => _playOrToggle(context, ref, ctx, tracks),
                  canShuffle: tracks.isNotEmpty,
                  children: [OfflineDownloadButton(kind: 'liked', id: "liked")],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverList.builder(
                  itemCount: tracks.length,
                  itemBuilder: (_, i) => TrackRow(
                    track: tracks[i],
                    onPlay: () => playMusic(context, ref, tracks, index: i, contextId: ctx),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
            ],
          ),
        ),
      ),
    );
  }
}
