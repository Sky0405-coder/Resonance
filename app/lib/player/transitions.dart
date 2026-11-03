import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../l10n/l10n.dart';
import '../ui/pages/transition_editor_page.dart';
import 'engine.dart';

/// The transition editor is optional (off by default): on, playlists show the transitions between their songs.
class TransitionEditorSetting extends Notifier<bool> {
  static const key = 'transition_editor';

  @override
  bool build() => ref.read(prefsProvider).getBool(key) ?? false;

  void set(bool enabled) {
    state = enabled;
    ref.read(prefsProvider).setBool(key, enabled).ignore();
  }
}

final transitionEditorProvider = NotifierProvider<TransitionEditorSetting, bool>(TransitionEditorSetting.new);

/// Transitions saved for a playlist, by "fromId>toId".
final playlistTransitionsProvider = FutureProvider.autoDispose.family<Map<String, CustomTransition>, String>(
  (ref, playlistId) => ref.read(apiProvider).transitions(playlistId),
);

/// Tempo and key of a playlist's songs (stored analyses only; songs not analyzed yet are missing).
final playlistMixKeysProvider = FutureProvider.autoDispose.family<Map<String, ({String? key, double? bpm})?>, String>((
  ref,
  ids,
) {
  return ref.read(apiProvider).mixKeys(ids.split(','));
});

String transitionStyleLabel(AppLocalizations l10n, TransitionStyle? style) => switch (style) {
  null => l10n.transitionAuto,
  TransitionStyle.crossfade => l10n.transitionCrossfade,
  TransitionStyle.fadeIn => l10n.transitionFadeIn,
  TransitionStyle.fadeOut => l10n.transitionFadeOut,
  TransitionStyle.filter => l10n.transitionFilter,
};

/// The Camelot wheel's colours: neighbouring keys (which mix well) get neighbouring hues.
Color camelotColor(String key) {
  final number = int.tryParse(key.substring(0, key.length - 1)) ?? 1;
  return HSLColor.fromAHSL(1, ((number - 1) * 30 + 90) % 360, 0.65, key.endsWith('A') ? 0.62 : 0.72).toColor();
}

/// "84 bpm" over a coloured Camelot key, as in DJ software.
class MixInfo extends StatelessWidget {
  const MixInfo({super.key, required this.bpm, required this.musicalKey});
  final double? bpm;
  final String? musicalKey;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.white70);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (bpm != null) Text('${bpm!.round()} bpm', style: muted),
        if (musicalKey != null)
          Container(
            margin: const EdgeInsets.only(top: 2),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: camelotColor(musicalKey!), borderRadius: BorderRadius.circular(4)),
            child: Text(
              musicalKey!,
              style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

/// The button between two songs of a playlist: the transition's preset, opens the editor.
class TransitionChip extends ConsumerWidget {
  const TransitionChip({
    super.key,
    required this.playlistId,
    required this.from,
    required this.to,
    required this.canEdit,
  });
  final String playlistId;
  final Track from;
  final Track to;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(playlistTransitionsProvider(playlistId)).value?['${from.id}>${to.id}'];
    final accent = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.only(left: 28, top: 2, bottom: 2),
      child: Row(
        children: [
          Container(width: 2, height: 36, color: Colors.white12),
          const SizedBox(width: 12),
          Material(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.of(context, rootNavigator: true).push(
                MaterialPageRoute<void>(
                  fullscreenDialog: true,
                  builder: (_) => TransitionEditorPage(playlistId: playlistId, from: from, to: to, canEdit: canEdit),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(saved == null ? Icons.auto_awesome : Icons.tune, size: 16, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      saved == null
                          ? context.l10n.transitionAuto
                          : '${transitionStyleLabel(context.l10n, saved.style)} · '
                                '${context.l10n.transitionBars(saved.bars)}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    const SizedBox(width: 4),
                    const Icon(Icons.chevron_right, size: 18, color: Colors.white54),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
