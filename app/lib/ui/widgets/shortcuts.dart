import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../../router.dart';

/// Spotify-like keyboard shortcuts (desktop and web). Keys typed into a text field are left alone.
/// Sits above the router (MaterialApp.builder), so it navigates through [routerProvider].
class PlayerShortcuts extends ConsumerWidget {
  const PlayerShortcuts({super.key, required this.child});
  final Widget child;

  static bool get _typing {
    final context = FocusManager.instance.primaryFocus?.context;
    return context != null &&
        (context.widget is EditableText || context.findAncestorWidgetOfExactType<EditableText>() != null);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyUpEvent || _typing) return KeyEventResult.ignored;
        final action = _action(ref, event.logicalKey, repeat: event is KeyRepeatEvent);
        if (action == null) return KeyEventResult.ignored;
        action();
        return KeyEventResult.handled;
      },
      child: child,
    );
  }

  VoidCallback? _action(WidgetRef ref, LogicalKeyboardKey key, {required bool repeat}) {
    final keys = HardwareKeyboard.instance;
    final ctrl = keys.isControlPressed || keys.isMetaPressed;
    final shift = keys.isShiftPressed;
    // In the browser Ctrl+F/L/R/S belong to the browser.
    final letters = ctrl && !repeat && !kIsWeb;
    final player = ref.read(playerProvider.notifier);
    final view = ref.read(playerProvider);
    void volume(double delta) => player.setUserVolume(player.userVolume.value + delta);
    void seek(int seconds) {
      final current = view.jamRemote ? player.jamPosition : player.engine.position;
      final position = current + Duration(seconds: seconds);
      player.seek(position < Duration.zero ? Duration.zero : position);
    }

    // Holding a key down repeats only volume and seeking.
    return switch (key) {
      LogicalKeyboardKey.space when !ctrl && !shift && !repeat => player.togglePlay,
      LogicalKeyboardKey.arrowRight when ctrl && !repeat => player.next,
      LogicalKeyboardKey.arrowLeft when ctrl && !repeat => player.previous,
      LogicalKeyboardKey.arrowRight when shift => () => seek(10),
      LogicalKeyboardKey.arrowLeft when shift => () => seek(-10),
      LogicalKeyboardKey.arrowUp when ctrl => () => volume(0.1),
      LogicalKeyboardKey.arrowDown when ctrl => () => volume(-0.1),
      LogicalKeyboardKey.keyS when letters && !view.inJam => player.toggleShuffle,
      LogicalKeyboardKey.keyR when letters && !view.inJam => player.cycleLoop,
      LogicalKeyboardKey.keyF || LogicalKeyboardKey.keyL when letters => () => ref.read(routerProvider).go('/search'),
      _ => null,
    };
  }
}

/// Overview of [PlayerShortcuts] (desktop settings).
Future<void> showShortcutsDialog(BuildContext context) {
  final l10n = context.l10n;
  final rows = [
    (l10n.shortcutPlayPause, 'Leertaste / Space'),
    (l10n.shortcutNextPrevious, 'Strg / Ctrl + → / ←'),
    (l10n.shortcutSeek, 'Shift + → / ←'),
    (l10n.shortcutVolume, 'Strg / Ctrl + ↑ / ↓'),
    (l10n.shortcutShuffle, 'Strg / Ctrl + S'),
    (l10n.shortcutRepeat, 'Strg / Ctrl + R'),
    (l10n.shortcutSearch, 'Strg / Ctrl + F'),
  ];
  return showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(l10n.shortcutsTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, keys) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(child: Text(label)),
                  const SizedBox(width: 24),
                  Text(keys, style: const TextStyle(fontWeight: FontWeight.w700)),
                ],
              ),
            ),
        ],
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(dialog), child: Text(l10n.commonClose))],
    ),
  );
}
