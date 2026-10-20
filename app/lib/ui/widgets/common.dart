import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../../player/engine.dart' show supportsSmartShuffle;
import '../../offline/offline_store.dart';

class ShuffleButton extends ConsumerWidget {
  const ShuffleButton({super.key, this.iconSize = 24});
  final double iconSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playerProvider);
    final allowSmart = supportsSmartShuffle(p.context, isRadio: p.isRadio);
    return IconButton(
      tooltip: !p.shuffle
          ? context.l10n.playerShuffle
          : !p.smartShuffle && allowSmart
          ? context.l10n.playerSmartShuffle
          : context.l10n.playerShuffleOff,
      iconSize: iconSize,
      color: p.shuffle ? Theme.of(context).colorScheme.primary : Palette.textMuted,
      onPressed: p.inJam ? null : ref.read(playerProvider.notifier).toggleShuffle,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.shuffle),
          if (p.smartShuffle) const Positioned(top: -3, right: -4, child: Icon(Icons.auto_awesome, size: 10)),
        ],
      ),
    );
  }
}

class TrackTitle extends StatelessWidget {
  const TrackTitle({super.key, required this.track, this.smart = false, this.style});
  final Track track;
  final bool smart;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final title = Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    return smart
        ? Row(
            children: [
              Icon(Icons.auto_awesome, size: 14, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Flexible(child: title),
            ],
          )
        : title;
  }
}

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

String formatLongDuration(AppLocalizations l10n, double seconds) {
  final d = Duration(seconds: seconds.round());
  if (d.inHours > 0) {
    return l10n.commonDurationHoursMinutes(d.inHours, d.inMinutes.remainder(60));
  }
  return l10n.commonDurationMinutesSeconds(d.inMinutes, d.inSeconds.remainder(60));
}

/// "1 Song" / "3 Songs".
String songs(AppLocalizations l10n, int n) => l10n.commonSongs(n);

bool isWide(BuildContext context) => MediaQuery.sizeOf(context).width >= 900;

/// Album cover with a neutral placeholder.
class CoverImage extends ConsumerWidget {
  const CoverImage({super.key, this.albumId, this.size = 300, this.radius = 4, this.icon = Icons.music_note});

  final String? albumId;
  final int size;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final localCover = kIsWeb || albumId == null
        ? null
        : ref.watch(offlineProvider.select((s) => s.coverPath(albumId!)));
    final version = albumId == null ? 0 : ref.watch(coverVersionsProvider.select((v) => v[albumId] ?? 0));
    final placeholder = Container(
      color: const Color(0xFF282828),
      alignment: Alignment.center,
      child: LayoutBuilder(
        builder: (_, c) => Icon(icon, color: Palette.textMuted, size: (c.maxWidth * 0.4).clamp(12, 64)),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 1,
        child: albumId == null
            ? placeholder
            : localCover != null
            ? Image.file(File(localCover), fit: BoxFit.cover, errorBuilder: (_, _, _) => placeholder)
            : CachedNetworkImage(
                imageUrl: '${ref.watch(apiProvider).coverUrl(albumId!, size: size)}${version > 0 ? '&v=$version' : ''}',
                // Cache key without the token so a re-login keeps the cache.
                cacheKey: 'cover:$albumId:$size${version > 0 ? ':$version' : ''}',
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 150),
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// 2x2 mosaic for playlists, like Spotify.
class PlaylistCover extends ConsumerWidget {
  const PlaylistCover({
    super.key,
    required this.albumIds,
    this.playlistId,
    this.coverKey,
    this.radius = 4,
    this.icon = Icons.queue_music,
  });

  final List<String> albumIds;
  final String? playlistId;
  final String? coverKey;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (playlistId != null && coverKey != null && !ref.watch(sessionProvider.select((s) => s.offline))) {
      final placeholder = Container(
        color: const Color(0xFF282828),
        alignment: Alignment.center,
        child: LayoutBuilder(
          builder: (_, c) => Icon(icon, color: Palette.textMuted, size: (c.maxWidth * 0.4).clamp(12, 64)),
        ),
      );
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: AspectRatio(
          aspectRatio: 1,
          child: CachedNetworkImage(
            imageUrl: ref.watch(apiProvider).playlistCoverUrl(playlistId!, coverKey!),
            cacheKey: 'playlist-cover:$playlistId:$coverKey:300',
            fit: BoxFit.cover,
            fadeInDuration: const Duration(milliseconds: 150),
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          ),
        ),
      );
    }
    if (albumIds.length < 4) {
      return CoverImage(albumId: albumIds.firstOrNull, radius: radius, icon: icon);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 1,
        child: GridView.count(
          crossAxisCount: 2,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [for (final id in albumIds.take(4)) CoverImage(albumId: id, size: 150, radius: 0)],
        ),
      ),
    );
  }
}

class LikedCover extends StatelessWidget {
  const LikedCover({super.key, this.radius = 4});
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF450AF5), Color(0xFFC4EFD9)],
          ),
        ),
        child: LayoutBuilder(
          builder: (_, c) => Icon(Icons.favorite, color: Colors.white, size: (c.maxWidth * 0.4).clamp(12, 72)),
        ),
      ),
    ),
  );
}

class DiscoverCover extends StatelessWidget {
  const DiscoverCover({super.key, this.radius = 4});
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: AspectRatio(
      aspectRatio: 1,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
          ),
        ),
        child: LayoutBuilder(
          builder: (_, c) => Padding(
            padding: EdgeInsets.all(c.maxWidth * 0.08),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.explore, color: Colors.white, size: (c.maxWidth * 0.4).clamp(12, 72)),
                SizedBox(height: c.maxWidth * 0.06),
                Text(
                  context.l10n.discoverWeekly,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: (c.maxWidth * 0.1).clamp(8, 24),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Card used in horizontal shelves and grids (album / artist / playlist).
class MediaCard extends StatefulWidget {
  const MediaCard({
    super.key,
    required this.image,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.circle = false,
    this.onPlay,
  });

  final Widget image;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onPlay;
  final bool circle;

  @override
  State<MediaCard> createState() => _MediaCardState();
}

class _MediaCardState extends State<MediaCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: _hover ? Palette.cardHover : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: widget.circle ? CrossAxisAlignment.center : CrossAxisAlignment.start,
            children: [
              Stack(
                children: [
                  widget.circle ? ClipOval(child: widget.image) : widget.image,
                  if (widget.onPlay != null)
                    Positioned(
                      right: 8,
                      bottom: 8,
                      child: AnimatedOpacity(
                        opacity: _hover ? 1 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: PlayButton(onPressed: widget.onPlay!, size: 44),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall),
              const SizedBox(height: 2),
              Text(
                widget.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: widget.circle ? TextAlign.center : TextAlign.start,
                style: theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PlayButton extends StatelessWidget {
  const PlayButton({super.key, required this.onPressed, this.size = 56, this.playing = false});
  final VoidCallback onPressed;
  final double size;
  final bool playing;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      shape: const CircleBorder(),
      elevation: 4,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(playing ? Icons.pause : Icons.play_arrow, color: scheme.onPrimary, size: size * 0.55),
        ),
      ),
    );
  }
}

class AlbumCard extends StatelessWidget {
  const AlbumCard({super.key, required this.album, this.onPlay});
  final Album album;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) => MediaCard(
    image: CoverImage(albumId: album.hasCover ? album.id : null, icon: Icons.album),
    title: album.title,
    subtitle: [if (album.year != null) '${album.year}', album.artist.name].join(' • '),
    onTap: () => context.push('/album/${album.id}'),
    onPlay: onPlay,
  );
}

class ArtistCard extends StatelessWidget {
  const ArtistCard({super.key, required this.artist});
  final Artist artist;

  @override
  Widget build(BuildContext context) => MediaCard(
    circle: true,
    image: CoverImage(albumId: artist.coverAlbumId, radius: 0, icon: Icons.person),
    title: artist.name,
    subtitle: context.l10n.commonArtist,
    onTap: () => context.push('/artist/${artist.id}'),
  );
}

class PlaylistCard extends StatelessWidget {
  const PlaylistCard({super.key, required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) => MediaCard(
    image: playlist.mixKey == 'discover-weekly' && playlist.coverKey == null
        ? const DiscoverCover()
        : PlaylistCover(playlistId: playlist.id, coverKey: playlist.coverKey, albumIds: playlist.coverAlbumIds),
    title: playlist.name,
    subtitle: playlist.isMix && playlist.description != null
        ? playlist.description!
        : context.l10n.libraryPlaylistBy((playlist.owner.name).toString()),
    onTap: () => context.push('/playlist/${playlist.id}'),
  );
}

/// Horizontal shelf with a heading, like Spotify's home rows.
class Shelf extends StatelessWidget {
  const Shelf({super.key, required this.title, required this.children, this.itemWidth = 180});
  final String title;
  final List<Widget> children;
  final double itemWidth;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(
          height: itemWidth + 72,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            itemCount: children.length,
            itemBuilder: (_, i) => SizedBox(width: itemWidth, child: children[i]),
          ),
        ),
      ],
    );
  }
}

/// Renders an AsyncValue with consistent loading / error states.
class AsyncBody<T> extends StatelessWidget {
  const AsyncBody({super.key, required this.value, required this.builder, this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => value.when(
    data: builder,
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (e, _) => Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48, color: Palette.textMuted),
            const SizedBox(height: 12),
            Text(ApiException.from(e, context.l10n).message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: Text(context.l10n.commonRetry)),
            ],
          ],
        ),
      ),
    ),
  );
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ApiException.from(e, context.l10n).message)));
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}

/// Music entry points share the same error presentation as audiobook playback.
Future<void> playMusic(
  BuildContext context,
  WidgetRef ref,
  List<Track> tracks, {
  int? index,
  String? contextId,
  bool isRadio = false,
}) async {
  try {
    await ref.read(playerProvider.notifier).playTracks(tracks, index: index, context: contextId, isRadio: isRadio);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
