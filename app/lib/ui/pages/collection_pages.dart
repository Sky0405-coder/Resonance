import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../widgets/collection.dart';
import 'admin/metadata_editor.dart';
import '../widgets/common.dart';
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
}) {
  final p = ref.read(playerProvider);
  final ctrl = ref.read(playerProvider.notifier);
  if (p.context == contextId && p.current != null) {
    ctrl.togglePlay();
  } else {
    playMusic(context, ref, tracks, index: index, contextId: contextId);
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
      body: AsyncBody(
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
                    if (ref.watch(sessionProvider.select((s) => s.user?.isAdmin ?? false)))
                      PopupMenuButton<String>(
                        useRootNavigator: true,
                        tooltip: context.l10n.editorCorrectAlbum,
                        iconSize: 28,
                        icon: const Icon(Icons.more_horiz, color: Palette.textMuted),
                        onSelected: (action) async {
                          if (action == 'cover') {
                            await showCoverPicker(context, ref, id);
                            return;
                          }
                          final album = await showAlbumMatcher(context, ref, d);
                          // The songs may now live in another (new or existing) album.
                          if (album != null && album.id != id && context.mounted) {
                            context.pushReplacement('/album/${album.id}');
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(
                            value: 'match',
                            child: ListTile(
                              leading: Icon(Icons.manage_search),
                              title: Text(context.l10n.editorMatchAlbum),
                            ),
                          ),
                          PopupMenuItem(
                            value: 'cover',
                            child: ListTile(
                              leading: Icon(Icons.image_search),
                              title: Text(context.l10n.editorChangeCover),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverList.list(children: rows),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
            ],
          );
        },
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
                image: CoverImage(albumId: d.artist.coverAlbumId, size: 600, radius: 0, icon: Icons.person),
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

class PlaylistPage extends ConsumerWidget {
  const PlaylistPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(playlistDetailProvider(id));
    final ctx = 'playlist:$id';
    final playing = _isPlayingContext(ref, ctx);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AsyncBody(
        value: value,
        onRetry: () => ref.invalidate(playlistDetailProvider(id)),
        builder: (d) {
          final tracks = [for (final e in d.entries) e.track];
          final actions = ref.read(libraryActionsProvider);
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: CollectionHeader(
                  image: PlaylistCover(albumIds: d.playlist.coverAlbumIds),
                  kind: d.playlist.isPublic ? context.l10n.libraryPublicPlaylist : context.l10n.commonPlaylist,
                  title: d.playlist.name,
                  description: d.playlist.description,
                  meta: Text(
                    '${d.playlist.owner.name} • ${songs(context.l10n, d.playlist.trackCount)}'
                    '${d.playlist.duration > 0 ? ', ${formatLongDuration(context.l10n, d.playlist.duration)}' : ''}',
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: ActionBar(
                  playing: playing,
                  onPlay: tracks.isEmpty ? null : () => _playOrToggle(context, ref, ctx, tracks),
                  canShuffle: tracks.isNotEmpty,
                  children: [
                    if (d.editable)
                      PopupMenuButton<String>(
                        useRootNavigator: true,
                        icon: const Icon(Icons.more_horiz, color: Palette.textMuted, size: 28),
                        onSelected: (v) async {
                          switch (v) {
                            case 'rename':
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
                            case 'public':
                              await ref.read(apiProvider).updatePlaylist(id, {'is_public': !d.playlist.isPublic});
                              ref.invalidate(playlistDetailProvider(id));
                              ref.invalidate(playlistsProvider);
                            case 'delete':
                              await actions.deletePlaylist(id);
                              if (context.mounted) context.go('/library');
                          }
                        },
                        itemBuilder: (_) => [
                          PopupMenuItem(value: 'rename', child: Text(context.l10n.commonRename)),
                          PopupMenuItem(
                            value: 'public',
                            child: Text(
                              d.playlist.isPublic ? context.l10n.libraryMakePrivate : context.l10n.librarySharePlaylist,
                            ),
                          ),
                          PopupMenuItem(value: 'delete', child: Text(context.l10n.commonDelete)),
                        ],
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
                      onPlay: () => playMusic(context, ref, tracks, index: i, contextId: ctx),
                      extraActions: [
                        if (d.editable)
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
      body: AsyncBody(
        value: value,
        onRetry: () => ref.invalidate(likedTracksProvider),
        builder: (tracks) => CustomScrollView(
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
    );
  }
}
