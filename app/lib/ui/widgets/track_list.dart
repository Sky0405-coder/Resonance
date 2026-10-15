import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../pages/admin/metadata_editor.dart';
import 'common.dart';

/// One row in a track list. [number] shows a track number instead of the cover.
class TrackRow extends ConsumerStatefulWidget {
  const TrackRow({
    super.key,
    required this.track,
    required this.onPlay,
    this.number,
    this.showCover = true,
    this.showAlbum = true,
    this.extraActions = const [],
  });

  final Track track;
  final VoidCallback onPlay;
  final int? number;
  final bool showCover;
  final bool showAlbum;
  final List<TrackAction> extraActions;

  @override
  ConsumerState<TrackRow> createState() => _TrackRowState();
}

class TrackAction {
  const TrackAction(this.label, this.icon, this.onSelected);
  final String label;
  final IconData icon;
  final VoidCallback onSelected;
}

class _TrackRowState extends ConsumerState<TrackRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.track;
    final current = ref.watch(playerProvider.select((p) => p.current?.id == t.id));
    final playing = current && ref.watch(playerProvider.select((p) => p.playing));
    final accent = Theme.of(context).colorScheme.primary;
    final wide = isWide(context);
    final muted = Theme.of(context).textTheme.bodyMedium?.copyWith(color: Palette.textMuted);

    Widget leading;
    if (widget.number != null && !widget.showCover) {
      leading = SizedBox(
        width: 32,
        child: Center(
          child: _hover && wide
              ? const Icon(Icons.play_arrow, size: 20)
              : playing
              ? Icon(Icons.graphic_eq, size: 18, color: accent)
              : Text('${widget.number}', style: muted?.copyWith(color: current ? accent : null)),
        ),
      );
    } else {
      leading = SizedBox(width: 44, child: CoverImage(albumId: t.album.id, size: 64));
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: widget.onPlay,
        onLongPress: () => showTrackMenu(context, ref, t, widget.extraActions),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _hover ? Colors.white10 : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Row(
            children: [
              leading,
              const SizedBox(width: 12),
              Expanded(
                flex: 4,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: current ? accent : Colors.white, fontSize: 15),
                    ),
                    Text(
                      t.artistCredit,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: muted?.copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (wide && widget.showAlbum)
                Expanded(
                  flex: 3,
                  child: Text(t.album.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: muted),
                ),
              if (wide || t.liked)
                IconButton(
                  tooltip: t.liked ? context.l10n.playerRemoveLiked : context.l10n.playerAddLiked,
                  icon: Icon(t.liked ? Icons.favorite : Icons.favorite_border, size: 18),
                  color: t.liked ? accent : Palette.textMuted,
                  onPressed: () => ref.read(libraryActionsProvider).setLiked(t, !t.liked).catchError((e) {
                    if (context.mounted) showError(context, e);
                  }),
                ),
              if (wide) SizedBox(width: 48, child: Text(formatDuration(t.length), style: muted)),
              IconButton(
                icon: const Icon(Icons.more_horiz, size: 20),
                color: Palette.textMuted,
                onPressed: () => showTrackMenu(context, ref, t, widget.extraActions),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showTrackMenu(BuildContext context, WidgetRef ref, Track t, [List<TrackAction> extra = const []]) {
  final player = ref.read(playerProvider.notifier);
  return showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF282828),
    showDragHandle: true,
    builder: (sheet) {
      void run(VoidCallback fn) {
        Navigator.pop(sheet);
        fn();
      }

      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: SizedBox(width: 48, child: CoverImage(albumId: t.album.id, size: 64)),
                title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text(t.artistCredit, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const Divider(),
              ListTile(
                leading: Icon(t.liked ? Icons.favorite : Icons.favorite_border),
                title: Text(t.liked ? context.l10n.playerRemoveLiked : context.l10n.playerAddLiked),
                onTap: () => run(() => ref.read(libraryActionsProvider).setLiked(t, !t.liked)),
              ),
              ListTile(
                leading: const Icon(Icons.playlist_add),
                title: Text(context.l10n.playerAddToPlaylist),
                onTap: () => run(() => showAddToPlaylist(context, ref, [t.id])),
              ),
              ListTile(
                leading: const Icon(Icons.queue_play_next),
                title: Text(context.l10n.playerPlayNext),
                onTap: () => run(() => player.playNext(t)),
              ),
              ListTile(
                leading: const Icon(Icons.queue_music),
                title: Text(context.l10n.playerAddToQueue),
                onTap: () => run(() => player.addToQueue(t)),
              ),
              ListTile(
                leading: const Icon(Icons.album),
                title: Text(context.l10n.playerGoToAlbum),
                onTap: () => run(() => context.push('/album/${t.album.id}')),
              ),
              ListTile(
                leading: const Icon(Icons.person),
                title: Text(context.l10n.playerGoToArtist),
                onTap: () => run(() => context.push('/artist/${t.artist.id}')),
              ),
              for (final a in extra)
                ListTile(leading: Icon(a.icon), title: Text(a.label), onTap: () => run(a.onSelected)),
              if (ref.read(sessionProvider).user?.isAdmin ?? false) ...[
                ListTile(
                  leading: const Icon(Icons.edit_note),
                  title: Text(context.l10n.editorCorrectMetadata),
                  onTap: () => run(() => showTrackEditor(context, ref, t)),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: Text(context.l10n.adminDeleteSong),
                  onTap: () => run(() => deleteTrackAsAdmin(context, ref, t)),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

Future<void> showAddToPlaylist(BuildContext context, WidgetRef ref, List<String> trackIds) async {
  final playlists = await ref.read(playlistsProvider.future);
  if (!context.mounted) return;
  final actions = ref.read(libraryActionsProvider);
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    backgroundColor: const Color(0xFF282828),
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: ListView(
        shrinkWrap: true,
        children: [
          ListTile(
            leading: const Icon(Icons.add),
            title: Text(context.l10n.libraryNewPlaylist),
            onTap: () async {
              Navigator.pop(sheet);
              final name = await promptText(context, context.l10n.libraryNewPlaylist, context.l10n.commonName);
              if (name == null || name.isEmpty) return;
              final p = await actions.createPlaylist(name);
              await actions.addToPlaylist(p.id, trackIds);
              if (context.mounted) showInfo(context, context.l10n.libraryAddedToPlaylist((p.name).toString()));
            },
          ),
          for (final p in playlists.where((p) => p.owner.id == ref.read(currentUserIdProvider)))
            ListTile(
              leading: SizedBox(width: 40, child: PlaylistCover(albumIds: p.coverAlbumIds)),
              title: Text(p.name),
              subtitle: Text(songs(context.l10n, p.trackCount)),
              onTap: () async {
                Navigator.pop(sheet);
                try {
                  await actions.addToPlaylist(p.id, trackIds);
                  if (context.mounted) showInfo(context, context.l10n.libraryAddedToPlaylist((p.name).toString()));
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
        ],
      ),
    ),
  );
}

Future<String?> promptText(BuildContext context, String title, String label, {String? initial}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(dialog, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog), child: Text(context.l10n.commonCancel)),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, controller.text.trim()),
          child: Text(context.l10n.commonSave),
        ),
      ],
    ),
  );
}

Future<bool> confirmDelete(BuildContext context, String title, String message) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(context.l10n.commonCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(dialog, true),
            child: Text(context.l10n.commonDelete),
          ),
        ],
      ),
    ) ??
    false;

/// Admin only: deletes the song (database row and file) from the server.
Future<void> deleteTrackAsAdmin(BuildContext context, WidgetRef ref, Track t) async {
  if (!await confirmDelete(context, context.l10n.adminDeleteSong, context.l10n.adminDeleteSongConfirm(t.title))) {
    return;
  }
  try {
    await ref.read(apiProvider).deleteLibraryTrack(t.id);
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  invalidateLibrary(ref);
  ref.invalidate(albumProvider(t.album.id));
  if (context.mounted) showInfo(context, context.l10n.adminDeleted);
}

/// Refresh the library lists after songs or albums were deleted.
void invalidateLibrary(WidgetRef ref) {
  ref.invalidate(homeProvider);
  ref.invalidate(likedTracksProvider);
  ref.invalidate(playlistsProvider);
  ref.invalidate(savedAlbumsProvider);
  ref.invalidate(allAlbumsProvider);
  ref.invalidate(allArtistsProvider);
  ref.invalidate(playlistDetailProvider);
  ref.invalidate(artistProvider);
}

/// Owner only: pick the users a playlist is shared with.
Future<void> showShareWithUsers(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final api = ref.read(apiProvider);
  final List<NamedRef> users;
  try {
    users = await api.otherUsers();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  final selected = {for (final u in playlist.sharedWith) u.id};
  final result = await showDialog<Set<String>>(
    context: context,
    builder: (dialog) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(context.l10n.libraryShareWithUsers),
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: SizedBox(
          width: 400,
          child: users.isEmpty
              ? Padding(padding: const EdgeInsets.all(16), child: Text(context.l10n.libraryNoOtherUsers))
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final u in users)
                      CheckboxListTile(
                        title: Text(u.name),
                        value: selected.contains(u.id),
                        onChanged: (v) => setState(() => v! ? selected.add(u.id) : selected.remove(u.id)),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialog), child: Text(context.l10n.commonCancel)),
          FilledButton(
            onPressed: users.isEmpty ? null : () => Navigator.pop(dialog, selected),
            child: Text(context.l10n.commonSave),
          ),
        ],
      ),
    ),
  );
  if (result == null) return;
  try {
    await api.setPlaylistShares(playlist.id, result.toList());
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  ref.invalidate(playlistDetailProvider(playlist.id));
  ref.invalidate(playlistsProvider);
}
