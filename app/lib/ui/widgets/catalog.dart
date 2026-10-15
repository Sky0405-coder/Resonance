import '../../l10n/l10n.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/downloads.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import 'common.dart';

/// Image from an external URL (catalog covers / artist pictures), same placeholder as [CoverImage].
class NetworkCover extends StatelessWidget {
  const NetworkCover({super.key, required this.url, this.radius = 4, this.icon = Icons.album});
  final String? url;
  final double radius;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
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
        child: url == null
            ? placeholder
            : CachedNetworkImage(
                imageUrl: url!,
                fit: BoxFit.cover,
                fadeInDuration: const Duration(milliseconds: 150),
                placeholder: (_, _) => placeholder,
                errorWidget: (_, _, _) => placeholder,
              ),
      ),
    );
  }
}

/// "Request download" button with three states: in library, requested, requestable.
class RequestButton extends ConsumerStatefulWidget {
  const RequestButton({super.key, required this.kind, required this.catalogId, required this.inLibrary, this.label});
  final String kind;
  final String catalogId;
  final bool inLibrary;

  /// Shows a text button instead of an icon button.
  final String? label;

  @override
  ConsumerState<RequestButton> createState() => _RequestButtonState();
}

class _RequestButtonState extends ConsumerState<RequestButton> {
  bool _busy = false;

  Future<void> _request() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(downloadActionsProvider).request(widget.kind, widget.catalogId);
      if (!mounted) return;
      showInfo(context, switch (r.status) {
        'pending_approval' => context.l10n.catalogAwaitingApproval((r.title).toString()),
        'done' => context.l10n.catalogAlreadyInLibrary((r.title).toString()),
        _ => context.l10n.catalogDownloadingTitle((r.title).toString()),
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final requested = ref.watch(openRequestIdsProvider).contains(widget.catalogId);
    final label = widget.label;

    if (widget.inLibrary) {
      return label == null
          ? Tooltip(
              message: context.l10n.catalogInYourLibrary,
              child: Icon(Icons.check_circle, color: accent, size: 22),
            )
          : const SizedBox.shrink();
    }
    if (requested) {
      return label == null
          ? Tooltip(
              message: context.l10n.catalogRequested,
              child: Icon(Icons.downloading, color: Palette.textMuted, size: 22),
            )
          : OutlinedButton(onPressed: null, child: Text(context.l10n.catalogRequested));
    }
    if (_busy) {
      return const SizedBox(
        width: 40,
        height: 40,
        child: Padding(padding: EdgeInsets.all(10), child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return label == null
        ? IconButton(
            tooltip: context.l10n.catalogDownload,
            color: Palette.textMuted,
            icon: const Icon(Icons.download_for_offline_outlined),
            onPressed: _request,
          )
        : FilledButton.icon(onPressed: _request, icon: const Icon(Icons.download), label: Text(label));
  }
}

/// Track row for catalog results: no playback, but a request button.
class CatalogTrackRow extends StatelessWidget {
  const CatalogTrackRow({super.key, required this.track, this.number, this.showCover = true});
  final CatalogTrack track;
  final int? number;
  final bool showCover;

  @override
  Widget build(BuildContext context) {
    final t = track;
    final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Palette.textMuted);
    final inLibrary = t.libraryId != null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          if (showCover)
            SizedBox(
              width: 44,
              child: NetworkCover(url: t.coverUrl, icon: Icons.music_note),
            )
          else
            SizedBox(
              width: 32,
              child: Center(child: Text('${number ?? ''}', style: muted)),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  t.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: inLibrary ? Colors.white : Colors.white70),
                ),
                Text(
                  [t.artist, if (showCover && t.album != null) t.album!].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted?.copyWith(fontSize: 13),
                ),
              ],
            ),
          ),
          if (t.duration != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(formatDuration(Duration(seconds: t.duration!.round())), style: muted),
            ),
          SizedBox(
            width: 48,
            child: Center(
              child: RequestButton(kind: 'track', catalogId: t.id, inLibrary: inLibrary),
            ),
          ),
        ],
      ),
    );
  }
}

class CatalogAlbumCard extends StatelessWidget {
  const CatalogAlbumCard({super.key, required this.album, this.showArtist = true});
  final CatalogAlbum album;
  final bool showArtist;

  @override
  Widget build(BuildContext context) => MediaCard(
    image: Stack(
      children: [
        NetworkCover(url: album.coverUrl),
        if (album.libraryId != null)
          Positioned(
            left: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(4)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.check, size: 12, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 3),
                  Text(context.l10n.catalogInLibrary, style: TextStyle(fontSize: 11)),
                ],
              ),
            ),
          ),
      ],
    ),
    title: album.title,
    subtitle: [
      if (album.year != null) '${album.year}',
      showArtist ? album.artist : album.typeLabel(context.l10n),
    ].join(' • '),
    onTap: () => context.push('/catalog/album/${album.id}'),
  );
}

class CatalogArtistCard extends StatelessWidget {
  const CatalogArtistCard({super.key, required this.artist});
  final CatalogArtist artist;

  @override
  Widget build(BuildContext context) => MediaCard(
    circle: true,
    image: NetworkCover(url: artist.pictureUrl, radius: 0, icon: Icons.person),
    title: artist.name,
    subtitle: context.l10n.commonArtist,
    onTap: () => context.push('/catalog/artist/${artist.id}'),
  );
}

/// Human-readable status of a request / item.
String requestStatusLabel(AppLocalizations l10n, String status) => switch (status) {
  'pending_approval' => l10n.downloadsStatusPendingApproval,
  'active' => l10n.downloadsStatusRunning,
  'done' => l10n.commonDone,
  'partial' => l10n.downloadsStatusPartial,
  'failed' => l10n.downloadsStatusFailed,
  'rejected' => l10n.downloadsStatusRejected,
  'cancelled' => l10n.downloadsStatusCancelled,
  'waiting' => l10n.downloadsStatusPendingApproval,
  'queued' => l10n.downloadsStatusQueued,
  'searching' => l10n.downloadsStatusSearching,
  'downloading' => l10n.downloadsStatusDownloading,
  'processing' => l10n.downloadsStatusProcessing,
  'exists' => l10n.downloadsStatusExisting,
  _ => status,
};

IconData requestStatusIcon(String status) => switch (status) {
  'done' || 'exists' => Icons.check_circle,
  'failed' || 'partial' => Icons.error_outline,
  'rejected' || 'cancelled' => Icons.block,
  'pending_approval' || 'waiting' => Icons.hourglass_empty,
  'queued' => Icons.schedule,
  _ => Icons.downloading,
};

Color requestStatusColor(BuildContext context, String status) => switch (status) {
  'done' || 'exists' => Theme.of(context).colorScheme.primary,
  'failed' || 'partial' => Theme.of(context).colorScheme.error,
  _ => Palette.textMuted,
};
