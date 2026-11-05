import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'action_sheet.dart';
import 'common.dart';
import 'track_list.dart';

/// The library's create button: a playlist or a blend with another user (like Spotify's create sheet).
Future<void> showCreateSheet(BuildContext context, WidgetRef ref) => showActionSheet(
  context,
  header: ListTile(
    title: Text(context.l10n.libraryCreate, style: const TextStyle(fontWeight: FontWeight.w800)),
  ),
  actions: [
    SheetAction(
      icon: Icons.queue_music,
      label: context.l10n.libraryNewPlaylist,
      onSelected: () async {
        final p = await createPlaylistInteractive(context, ref);
        if (p != null && context.mounted) context.push('/playlist/${p.id}');
      },
    ),
    SheetAction(icon: Icons.join_inner, label: context.l10n.blendCreate, onSelected: () => createBlend(context, ref)),
  ],
);

/// Picks another user and makes a blend with them; opens it when both already listened to something.
Future<void> createBlend(BuildContext context, WidgetRef ref) async {
  final api = ref.read(apiProvider);
  final List<NamedRef> users;
  try {
    users = await api.otherUsers();
  } catch (e) {
    if (context.mounted) showError(context, e);
    return;
  }
  if (!context.mounted) return;
  if (users.isEmpty) {
    showInfo(context, context.l10n.blendNoUsers);
    return;
  }
  final partner = await showDialog<NamedRef>(
    context: context,
    builder: (dialog) => SimpleDialog(
      title: Text(context.l10n.blendPickUser),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(context.l10n.blendHint, style: const TextStyle(color: Palette.textMuted)),
        ),
        for (final user in users)
          ListTile(
            leading: CircleAvatar(child: Text(user.name.characters.first.toUpperCase())),
            title: Text(user.name),
            onTap: () => Navigator.pop(dialog, user),
          ),
      ],
    ),
  );
  if (partner == null || !context.mounted) return;
  try {
    final blend = await api.createBlend(partner.id);
    ref.invalidate(mixesProvider);
    if (!context.mounted) return;
    if (blend.playlistId == null) {
      showInfo(context, context.l10n.blendWaiting(partner.name));
    } else {
      context.push('/playlist/${blend.playlistId}');
    }
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Ends the blend of [playlist] for both users.
Future<void> leaveBlend(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final api = ref.read(apiProvider);
  try {
    final blends = await api.blends();
    final blend = blends.where((b) => b.playlistId == playlist.id).firstOrNull;
    if (blend == null || !context.mounted) return;
    final confirmed = await confirmDelete(
      context,
      context.l10n.blendLeave,
      context.l10n.blendLeaveConfirm(blend.partner.name),
    );
    if (!confirmed) return;
    await api.leaveBlend(blend.id);
    ref.invalidate(mixesProvider);
    if (context.mounted) context.go('/');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}
