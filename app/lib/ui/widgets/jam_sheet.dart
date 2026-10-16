import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../player/jam.dart';
import '../../core/theme.dart';
import 'action_sheet.dart';
import 'common.dart';

/// "Jam" button for the now-playing page and the desktop player bar.
class JamButton extends ConsumerWidget {
  const JamButton({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(jamProvider) != null;
    return IconButton(
      tooltip: context.l10n.jamTitle,
      iconSize: size,
      icon: const Icon(Icons.groups),
      color: active ? Theme.of(context).colorScheme.primary : Palette.textMuted,
      onPressed: () => showJamSheet(context, ref),
    );
  }
}

Future<void> showJamSheet(BuildContext context, WidgetRef ref) async {
  if (ref.read(jamProvider) == null) {
    return showActionSheet(
      context,
      header: ListTile(
        leading: const Icon(Icons.groups, size: 40),
        title: Text(context.l10n.jamTitle),
        subtitle: Text(context.l10n.jamIntro),
      ),
      actions: [
        SheetAction(
          icon: Icons.play_circle_outline,
          label: context.l10n.jamStart,
          onSelected: () =>
              _run(context, () => ref.read(jamProvider.notifier).start(), then: () => showJamSheet(context, ref)),
        ),
        SheetAction(icon: Icons.login, label: context.l10n.jamJoin, onSelected: () => promptJoinJam(context, ref)),
      ],
    );
  }
  await showModalBottomSheet<void>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: const Color(0xFF282828),
    showDragHandle: true,
    builder: (_) => const _JamPanel(),
  );
}

Future<void> promptJoinJam(BuildContext context, WidgetRef ref, [String? code]) async {
  final value =
      code ??
      await showDialog<String>(
        context: context,
        builder: (dialog) {
          final controller = TextEditingController();
          return AlertDialog(
            title: Text(context.l10n.jamJoin),
            content: TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              maxLength: 6,
              decoration: InputDecoration(hintText: context.l10n.jamCodeHint),
              onSubmitted: (v) => Navigator.pop(dialog, v),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog), child: Text(context.l10n.commonCancel)),
              FilledButton(onPressed: () => Navigator.pop(dialog, controller.text), child: Text(context.l10n.jamJoin)),
            ],
          );
        },
      );
  if (value == null || value.trim().isEmpty || !context.mounted) return;
  await _run(context, () => ref.read(jamProvider.notifier).join(value.trim()), then: () => showJamSheet(context, ref));
}

Future<void> _run(BuildContext context, Future<void> Function() action, {VoidCallback? then}) async {
  try {
    await action();
    if (context.mounted) then?.call();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class _JamPanel extends ConsumerWidget {
  const _JamPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(jamProvider);
    if (view == null) {
      // The Jam ended while the sheet was open.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) Navigator.maybePop(context);
      });
      return const SizedBox.shrink();
    }
    final jam = view.state;
    final ctrl = ref.read(jamProvider.notifier);
    final link = '${ref.read(sessionProvider).serverUrl}/jam/${jam.code}';
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.only(bottom: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(context.l10n.jamTitle, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            SelectableText(
              jam.code,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.displaySmall?.copyWith(letterSpacing: 6, fontWeight: FontWeight.w800),
            ),
            if (!view.connected)
              Text(
                context.l10n.jamConnecting,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.textMuted),
              ),
            Center(
              child: TextButton.icon(
                icon: const Icon(Icons.link),
                label: Text(context.l10n.jamCopyLink),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: link));
                  if (context.mounted) showInfo(context, context.l10n.jamLinkCopied);
                },
              ),
            ),
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(context.l10n.jamMembers, style: Theme.of(context).textTheme.titleSmall),
            ),
            for (final m in jam.members)
              ListTile(
                leading: CircleAvatar(child: Text(m.name.isEmpty ? '?' : m.name.characters.first.toUpperCase())),
                title: Text(m.name),
                subtitle: m.isHost ? Text(context.l10n.jamHost) : null,
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 10, color: m.online ? Colors.greenAccent : Palette.textMuted),
                    if (view.isHost && !m.isHost)
                      IconButton(
                        tooltip: context.l10n.jamKick,
                        icon: const Icon(Icons.person_remove_outlined),
                        onPressed: () => _run(context, () => ctrl.kick(m.id)),
                      ),
                  ],
                ),
              ),
            const Divider(),
            if (view.isHost)
              SwitchListTile(
                title: Text(context.l10n.jamMembersControl),
                value: jam.membersControl,
                onChanged: ctrl.setMembersControl,
              ),
            SwitchListTile(
              title: Text(context.l10n.jamListenHere),
              subtitle: Text(context.l10n.jamListenHereHint),
              value: view.listenHere,
              onChanged: ctrl.setListenHere,
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: Text(view.isHost ? context.l10n.jamEnd : context.l10n.jamLeave),
              onTap: () async {
                if (view.isHost) {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (d) => AlertDialog(
                      title: Text(context.l10n.jamEnd),
                      content: Text(context.l10n.jamEndConfirm),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.l10n.commonCancel)),
                        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.jamEnd)),
                      ],
                    ),
                  );
                  if (ok != true) return;
                }
                if (!context.mounted) return;
                await _run(context, ctrl.leave);
                if (context.mounted) Navigator.pop(context);
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Small "Jam · n" badge for the player while in a Jam.
class JamChip extends ConsumerWidget {
  const JamChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(jamProvider.select((v) => v?.state.members.length));
    if (count == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(left: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(4)),
      child: Text(
        context.l10n.jamChip(count),
        style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
  }
}

/// Target of `/jam/<code>` links: joins the Jam and opens the player.
class JoinJamPage extends ConsumerStatefulWidget {
  const JoinJamPage({super.key, required this.code});
  final String code;

  @override
  ConsumerState<JoinJamPage> createState() => _JoinJamPageState();
}

class _JoinJamPageState extends ConsumerState<JoinJamPage> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    _join();
  }

  Future<void> _join() async {
    try {
      final current = ref.read(jamProvider);
      if (current?.state.code != widget.code.toUpperCase()) {
        await ref.read(jamProvider.notifier).join(widget.code);
      }
      if (!mounted) return;
      context.go('/');
      context.push('/now-playing');
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.jamJoin)),
    body: Center(
      child: _error == null
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$_error'),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => context.go('/'), child: Text(context.l10n.commonOk)),
              ],
            ),
    ),
  );
}
