import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';

String formatDuration(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60);
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

String formatLongDuration(double seconds) {
  final d = Duration(seconds: seconds.round());
  if (d.inHours > 0) return '${d.inHours} Std. ${d.inMinutes.remainder(60)} Min.';
  return '${d.inMinutes} Min. ${d.inSeconds.remainder(60)} Sek.';
}

/// "1 Song" / "3 Songs".
String songs(int n) => n == 1 ? '1 Song' : '$n Songs';

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
class PlaylistCover extends StatelessWidget {
  const PlaylistCover({super.key, required this.albumIds, this.radius = 4, this.icon = Icons.queue_music});

  final List<String> albumIds;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
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
    subtitle: 'Künstler',
    onTap: () => context.push('/artist/${artist.id}'),
  );
}

class PlaylistCard extends StatelessWidget {
  const PlaylistCard({super.key, required this.playlist});
  final Playlist playlist;

  @override
  Widget build(BuildContext context) => MediaCard(
    image: PlaylistCover(albumIds: playlist.coverAlbumIds),
    title: playlist.name,
    subtitle: 'Playlist • ${playlist.owner.name}',
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
            Text(ApiException.from(e).message, textAlign: TextAlign.center),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(onPressed: onRetry, child: const Text('Erneut versuchen')),
            ],
          ],
        ),
      ),
    ),
  );
}

void showError(BuildContext context, Object e) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ApiException.from(e).message)));
}

void showInfo(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
