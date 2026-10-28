import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/audiobooks.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../l10n/locale.dart';
import '../../offline/media_downloads.dart';
import '../../player/player.dart';
import 'catalog.dart';
import 'common.dart';
import 'offline.dart';

/// Saves a podcast episode, audiobook or ebook on the device, or removes it again.
class MediaDownloadButton extends ConsumerStatefulWidget {
  const MediaDownloadButton({super.key, required this.kind, required this.id, required this.onAdd, this.size = 30});
  final String kind;
  final String id;
  final Future<void> Function(MediaDownloadsController controller) onAdd;
  final double size;

  @override
  ConsumerState<MediaDownloadButton> createState() => _MediaDownloadButtonState();
}

class _MediaDownloadButtonState extends ConsumerState<MediaDownloadButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    final downloads = ref.watch(mediaDownloadsProvider);
    final phase = downloads.phase(widget.kind, widget.id);
    final key = '${widget.kind}:${widget.id}';
    final size = widget.size;
    return IconButton(
      tooltip: switch (phase) {
        MediaDownloadPhase.none => context.l10n.mediaDownload,
        MediaDownloadPhase.downloading => context.l10n.mediaDownloading,
        MediaDownloadPhase.done => context.l10n.mediaRemove,
        MediaDownloadPhase.failed => context.l10n.mediaFailed,
      },
      color: phase == MediaDownloadPhase.done ? Theme.of(context).colorScheme.primary : Palette.textMuted,
      iconSize: size,
      onPressed: _busy ? null : () => _tap(key, phase),
      icon: switch (phase) {
        MediaDownloadPhase.downloading => SizedBox(
          width: size,
          height: size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(value: downloads.progress[key], strokeWidth: 2),
              Icon(Icons.arrow_downward, size: size * 0.6),
            ],
          ),
        ),
        MediaDownloadPhase.done => const Icon(Icons.download_for_offline),
        MediaDownloadPhase.failed => Icon(Icons.error_outline, color: Theme.of(context).colorScheme.error),
        MediaDownloadPhase.none => const Icon(Icons.download_for_offline_outlined),
      },
    );
  }

  Future<void> _tap(String key, MediaDownloadPhase phase) async {
    final controller = ref.read(mediaDownloadsProvider.notifier);
    if (phase == MediaDownloadPhase.failed) return controller.retry(key);
    setState(() => _busy = true);
    try {
      if (phase == MediaDownloadPhase.none) {
        await widget.onAdd(controller);
      } else if (await confirmOfflineDelete(context, context.l10n.mediaRemoveTitle)) {
        await controller.remove(key);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Plays a downloaded episode or audiobook, or opens a downloaded ebook in a reader app.
Future<void> openMediaDownload(BuildContext context, WidgetRef ref, MediaDownload item) async {
  try {
    switch (item.kind) {
      case 'episode':
        await ref.read(playerProvider.notifier).playEpisode(item.episode);
      case 'audiobook':
        final l10n = lookupAppLocalizations(ref.read(appLocaleProvider));
        await ref.read(playerProvider.notifier).playBook(AbsItem.fromJson(item.data, l10n));
      default:
        await openEbookFile(context, ref.read(mediaDownloadsProvider).filePath(item, 0));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> openEbookFile(BuildContext context, String path) async {
  // Hands the file to a reader app (Android, iOS) or the system's default program (desktop).
  if (!await FileDownloader().openFile(filePath: path) && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.l10n.mediaOpenFailed)));
  }
}

/// The downloaded episodes, audiobooks and ebooks, below the music on the offline page.
class MediaDownloadsSection extends ConsumerWidget {
  const MediaDownloadsSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();
    final downloads = ref.watch(mediaDownloadsProvider);
    if (downloads.items.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
          child: Text(context.l10n.mediaSection, style: Theme.of(context).textTheme.titleLarge),
        ),
        for (final item in downloads.items.values.toList().reversed) _MediaTile(item: item, downloads: downloads),
      ],
    );
  }
}

class _MediaTile extends ConsumerWidget {
  const _MediaTile({required this.item, required this.downloads});
  final MediaDownload item;
  final MediaDownloadsState downloads;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cover = downloads.coverPath(item);
    final icon = switch (item.kind) {
      'episode' => Icons.podcasts,
      'audiobook' => Icons.headphones,
      _ => Icons.menu_book,
    };
    final phase = downloads.phase(item.kind, item.id);
    final kind = switch (item.kind) {
      'episode' => context.l10n.mediaKindEpisode,
      'audiobook' => context.l10n.audiobooksBook,
      _ => context.l10n.mediaKindEbook,
    };
    return ListTile(
      leading: SizedBox(
        width: 56,
        child: cover == null
            ? NetworkCover(url: item.coverUrl, icon: icon, radius: 6)
            : ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: AspectRatio(aspectRatio: 1, child: Image.file(File(cover), fit: BoxFit.cover)),
              ),
      ),
      title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [
          kind,
          ?item.subtitle,
          if (phase == MediaDownloadPhase.downloading) context.l10n.mediaDownloading,
          if (phase == MediaDownloadPhase.failed) context.l10n.mediaFailed,
        ].join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: MediaDownloadButton(kind: item.kind, id: item.id, size: 24, onAdd: (_) async {}),
      onTap: phase == MediaDownloadPhase.done ? () => openMediaDownload(context, ref, item) : null,
    );
  }
}
