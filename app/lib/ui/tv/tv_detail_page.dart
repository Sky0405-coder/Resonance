import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../widgets/common.dart';
import 'tv_browse_pages.dart';
import 'tv_focusable.dart';
import 'tv_shelves.dart';

class _Collection {
  const _Collection(this.title, this.image, this.tracks, {this.albums = const []});
  final String title;
  final Widget image;
  final List<Track> tracks;
  final List<Album> albums;
}

class TvDetailPage extends ConsumerWidget {
  const TvDetailPage({super.key, required this.kind, required this.id});
  final String kind;
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = switch (kind) {
      'album' =>
        ref
            .watch(albumProvider(id))
            .whenData(
              (d) => _Collection(d.album.title, CoverImage(albumId: d.album.hasCover ? id : null, size: 600), d.tracks),
            ),
      'artist' =>
        ref
            .watch(artistProvider(id))
            .whenData(
              (d) =>
                  _Collection(d.artist.name, ArtistImage(artist: d.artist, size: 600), d.topTracks, albums: d.albums),
            ),
      'playlist' =>
        ref
            .watch(playlistDetailProvider(id))
            .whenData(
              (d) => _Collection(
                d.playlist.name,
                PlaylistCover(playlistId: id, coverKey: d.playlist.coverKey, albumIds: d.playlist.coverAlbumIds),
                [for (final entry in d.entries) entry.track],
              ),
            ),
      _ =>
        ref
            .watch(likedTracksProvider)
            .whenData((tracks) => _Collection(context.l10n.libraryLikedSongs, const LikedCover(), tracks)),
    };
    return TvAsync(
      value: value,
      onRetry: () {
        switch (kind) {
          case 'album':
            ref.invalidate(albumProvider(id));
          case 'artist':
            ref.invalidate(artistProvider(id));
          case 'playlist':
            ref.invalidate(playlistDetailProvider(id));
          default:
            ref.invalidate(likedTracksProvider);
        }
      },
      builder: (data) => _DetailBody(data: data, contextId: '$kind:$id'),
    );
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.data, required this.contextId});
  final _Collection data;
  final String contextId;

  Future<void> _play(
    BuildContext context,
    WidgetRef ref, {
    int index = 0,
    bool? shuffle,
    bool openNowPlaying = false,
  }) async {
    try {
      final player = ref.read(playerProvider.notifier);
      if (shuffle != null) await player.setShuffle(shuffle);
      if (!context.mounted) return;
      await player.playTracks(data.tracks, index: index, context: contextId);
      if (context.mounted && openNowPlaying && GoRouter.of(context).state.uri.path != '/now-playing') {
        unawaited(context.push('/now-playing'));
      }
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => CustomScrollView(
    // Keep the requested prebuilt range on Flutter versions that still expose cacheExtent.
    // ignore: deprecated_member_use
    cacheExtent: 800,
    slivers: [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(36, 36, 36, 32),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 220, height: 220, child: data.image),
              const SizedBox(width: 32),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(data.title, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 28),
                    Wrap(
                      spacing: 20,
                      runSpacing: 20,
                      children: [
                        TvButton(
                          icon: Icons.play_arrow,
                          label: context.l10n.tvPlay,
                          autofocus: true,
                          onPressed: data.tracks.isEmpty
                              ? null
                              : () => _play(context, ref, shuffle: false, openNowPlaying: true),
                        ),
                        TvButton(
                          icon: Icons.shuffle,
                          label: context.l10n.playerShuffle,
                          onPressed: data.tracks.isEmpty
                              ? null
                              : () => _play(context, ref, shuffle: true, openNowPlaying: true),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        sliver: SliverList.builder(
          itemCount: data.tracks.length,
          itemBuilder: (context, index) {
            final track = data.tracks[index];
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: TvFocusable(
                label: track.title,
                focusScale: 1.015,
                onActivate: () => _play(context, ref, index: index),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 48,
                        child: Text('${index + 1}', style: const TextStyle(color: Palette.textMuted)),
                      ),
                      SizedBox(width: 64, height: 64, child: CoverImage(albumId: track.album.id, size: 128)),
                      const SizedBox(width: 20),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(track.artistCredit, style: const TextStyle(color: Palette.textMuted, fontSize: 18)),
                          ],
                        ),
                      ),
                      Text(formatDuration(track.length)),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
      if (data.albums.isNotEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 36),
            child: TvShelves(
              title: context.l10n.commonAlbums,
              shelves: [
                TvShelfData(context.l10n.commonAlbums, [for (final album in data.albums) tvAlbum(context, album)]),
              ],
            ),
          ),
        )
      else
        const SliverToBoxAdapter(child: SizedBox(height: 36)),
    ],
  );
}
