import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../offline/export.dart';
import '../../offline/offline_store.dart';
import '../../player/player.dart';
import '../widgets/common.dart';
import '../widgets/collection.dart' show kBottomInset;
import '../widgets/offline.dart';

/// One downloaded song file with what is known about it.
typedef StorageFile = ({String id, String file, int size, Track? track, List<String> collections});

/// The downloaded song files, biggest first, with their songs from the downloaded collections.
List<StorageFile> storageFiles(OfflineState offline) {
  final known = <String, Track>{
    for (final collection in offline.collections.values)
      for (final track in collection.orderedTracks) track.id: track,
  };
  return [
    for (final MapEntry(key: id, value: track) in offline.tracks.entries)
      if (track.file != null)
        (id: id, file: track.file!, size: track.size, track: known[id], collections: track.collections),
  ]..sort((a, b) => b.size.compareTo(a.size));
}

/// The bytes each downloaded collection takes (a song in two collections counts for both).
Map<String, int> collectionBytes(OfflineState offline) {
  final sizes = <String, int>{};
  for (final track in offline.tracks.values) {
    for (final key in track.collections) {
      sizes[key] = (sizes[key] ?? 0) + track.size;
    }
  }
  return sizes;
}

/// Settings → storage used: what the downloads consist of, with the folder they are in.
class StoragePage extends ConsumerWidget {
  const StoragePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offline = ref.watch(offlineProvider);
    final l10n = context.l10n;
    final files = storageFiles(offline);
    final sizes = collectionBytes(offline);
    final directory = offline.directory;
    final desktop = !kIsWeb && (Platform.isLinux || Platform.isWindows || Platform.isMacOS);
    final playable = [for (final file in files) ?file.track];
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.offlineStorage),
        actions: [
          if (offline.collections.isNotEmpty)
            TextButton.icon(
              icon: const Icon(Icons.ios_share),
              label: Text(l10n.storageExportAll),
              onPressed: () => exportDownloads(context, ref),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: kBottomInset),
        children: [
          ListTile(
            leading: const Icon(Icons.storage),
            title: Text(l10n.offlineStorageUsed(formatStorage(context, offline.totalBytes), files.length)),
            subtitle: directory == null ? null : SelectableText(directory),
            trailing: desktop && directory != null
                ? TextButton.icon(
                    icon: const Icon(Icons.folder_open),
                    label: Text(l10n.storageOpenFolder),
                    onPressed: () => launchUrl(Uri.directory(directory)).ignore(),
                  )
                : null,
          ),
          if (offline.collections.isNotEmpty) _Heading(l10n.storageCollections),
          for (final collection in offline.collections.values)
            ListTile(
              leading: Icon(switch (collection.kind) {
                'album' => Icons.album,
                'liked' => Icons.favorite,
                _ => Icons.queue_music,
              }),
              title: Text(collection.kind == 'liked' ? l10n.libraryLikedSongs : collection.name),
              subtitle: Text(formatStorage(context, sizes[collection.key] ?? 0)),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: l10n.storageExport,
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => exportDownloads(context, ref, collections: [collection.key]),
                  ),
                  IconButton(
                    tooltip: l10n.offlineRemoveTitle,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (!await confirmOfflineDelete(context, l10n.offlineRemoveTitle)) return;
                      await ref.read(offlineProvider.notifier).remove(collection.key);
                    },
                  ),
                ],
              ),
            ),
          if (files.isNotEmpty) _Heading(l10n.storageFiles),
          for (final file in files)
            ListTile(
              dense: true,
              leading: file.track == null
                  ? const Icon(Icons.audio_file_outlined)
                  : SizedBox(width: 40, child: CoverImage(albumId: file.track!.album.id, size: 64)),
              title: Text(file.track?.title ?? file.file, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                [if (file.track != null) file.track!.artistCredit, file.file.split('/').last].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.textMuted),
              ),
              trailing: Text(formatStorage(context, file.size), style: const TextStyle(color: Palette.textMuted)),
              onTap: file.track == null
                  ? null
                  : () => ref
                        .read(playerProvider.notifier)
                        .playTracks(playable, index: playable.indexOf(file.track!))
                        .catchError((Object e) {
                          if (context.mounted) showError(context, e);
                        }),
            ),
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(text, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
  );
}

/// Copies downloaded songs where other apps see them: Music/Resonance on Android, a picked folder on desktop.
Future<void> exportDownloads(BuildContext context, WidgetRef ref, {List<String>? collections}) async {
  final l10n = context.l10n;
  try {
    if (!await exportSupported()) {
      if (context.mounted) showInfo(context, l10n.storageExportUnsupported);
      return;
    }
    final items = exportItems(ref.read(offlineProvider), collections: collections);
    if (items.isEmpty) return;
    String? target;
    if (exportNeedsFolder) {
      target = await FilePicker.getDirectoryPath(dialogTitle: l10n.storageExport);
      if (target == null) return;
    }
    if (!context.mounted) return;
    final done = ValueNotifier(0);
    final navigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      builder: (_) => AlertDialog(
        title: Text(l10n.storageExport),
        content: ValueListenableBuilder(
          valueListenable: done,
          builder: (_, value, _) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(value: value / items.length),
              const SizedBox(height: 12),
              Text(l10n.storageExportProgress(value, items.length)),
            ],
          ),
        ),
      ),
    ).ignore();
    final int added;
    try {
      added = await exportSongs(items, target: target, progress: (value) => done.value = value);
    } finally {
      navigator.pop();
      done.dispose();
    }
    if (context.mounted) {
      showInfo(context, l10n.storageExported(added, target ?? 'Music/Resonance'));
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
