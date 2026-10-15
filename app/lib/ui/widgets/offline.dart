import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../offline/offline_store.dart';
import 'collection.dart';
import 'common.dart';

class OfflineDownloadButton extends ConsumerStatefulWidget {
  const OfflineDownloadButton({super.key, required this.kind, required this.id});
  final String kind;
  final String id;

  @override
  ConsumerState<OfflineDownloadButton> createState() => _OfflineDownloadButtonState();
}

class _OfflineDownloadButtonState extends ConsumerState<OfflineDownloadButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    final key = widget.kind == 'liked' ? 'liked' : '${widget.kind}:${widget.id}';
    final status = ref.watch(offlineProvider).status(key);
    final present = status.phase != CollectionPhase.none;
    final complete = status.phase == CollectionPhase.downloaded;
    return IconButton(
      tooltip: present ? context.l10n.offlineRemoveTitle : context.l10n.offlineDownload,
      color: complete ? Theme.of(context).colorScheme.primary : Palette.textMuted,
      iconSize: 30,
      onPressed: _busy ? null : () => _toggle(key, present),
      icon: status.phase == CollectionPhase.downloading
          ? SizedBox(
              width: 30,
              height: 30,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  CircularProgressIndicator(value: status.done / status.total, strokeWidth: 2),
                  const Icon(Icons.arrow_downward, size: 18),
                ],
              ),
            )
          : Icon(complete ? Icons.download_for_offline : Icons.download_for_offline_outlined),
    );
  }

  Future<void> _toggle(String key, bool present) async {
    setState(() => _busy = true);
    try {
      if (present && !await confirmOfflineDelete(context, context.l10n.offlineRemoveTitle)) return;
      if (!mounted) return;
      final controller = ref.read(offlineProvider.notifier);
      if (present) {
        await controller.remove(key);
      } else {
        await controller.add(widget.kind, widget.id);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

Future<bool> confirmOfflineDelete(BuildContext context, String title) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(context.l10n.commonDelete)),
        ],
      ),
    ) ??
    false;

/// Shared by the offline home page and the first library tab.
class OfflineCollections extends ConsumerWidget {
  const OfflineCollections({super.key, this.heading});
  final Widget? heading;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();
    final offline = ref.watch(offlineProvider);
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(top: 8, bottom: kBottomInset),
      children: [
        ?heading,
        if (offline.collections.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              context.l10n.offlineEmptyHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Palette.textMuted),
            ),
          ),
        for (final collection in offline.collections.values)
          _CollectionTile(collection: collection, status: offline.status(collection.key)),
      ],
    );
  }
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({required this.collection, required this.status});
  final OfflineCollection collection;
  final CollectionStatus status;

  @override
  Widget build(BuildContext context) {
    final kind = switch (collection.kind) {
      'album' => context.l10n.commonAlbum,
      'playlist' when Playlist.fromJson(collection.data).isRadio => context.l10n.radioKind,
      _ => context.l10n.commonPlaylist,
    };
    final image = switch (collection.kind) {
      'album' => CoverImage(albumId: collection.id, icon: Icons.album),
      'playlist' => PlaylistCover(albumIds: Playlist.fromJson(collection.data).coverAlbumIds),
      _ => const LikedCover(),
    };
    return ListTile(
      leading: SizedBox(width: 56, child: image),
      title: Text(collection.kind == 'liked' ? context.l10n.libraryLikedSongs : collection.name),
      subtitle: Text(
        '$kind • ${status.phase == CollectionPhase.downloaded ? context.l10n.offlineDownloaded : context.l10n.offlineProgress(status.done, status.total)}',
      ),
      trailing: status.phase == CollectionPhase.downloaded
          ? Icon(Icons.download_for_offline, color: Theme.of(context).colorScheme.primary)
          : SizedBox(width: 24, height: 24, child: CircularProgressIndicator(value: status.done / status.total)),
      onTap: () => context.push(collection.kind == 'liked' ? '/liked' : '/${collection.kind}/${collection.id}'),
    );
  }
}

/// Pull-to-refresh also synchronizes the saved membership before refetching page data.
class OfflineCollectionRefresh extends ConsumerWidget {
  const OfflineCollectionRefresh({
    super.key,
    required this.collectionKey,
    required this.onRefresh,
    required this.child,
  });
  final String collectionKey;
  final Future<void> Function() onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb || !ref.watch(offlineProvider.select((s) => s.collections.containsKey(collectionKey)))) return child;
    return RefreshIndicator(
      onRefresh: () async {
        try {
          await ref.read(offlineProvider.notifier).sync();
          await onRefresh();
        } catch (e) {
          if (context.mounted) showError(context, e);
        }
      },
      child: child,
    );
  }
}
