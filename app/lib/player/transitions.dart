import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../core/session.dart';
import '../l10n/l10n.dart';
import '../ui/pages/transition_editor_page.dart';
import 'engine.dart';
import 'mix_lanes.dart';

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

/// The playlists switched to mixing (the slider button in their action bar): only these show their transitions.
class MixModePlaylists extends Notifier<Set<String>> {
  static const key = 'transition_editor_playlists';

  @override
  Set<String> build() => {...?ref.read(prefsProvider).getStringList(key)};

  void toggle(String playlistId) {
    state = state.contains(playlistId) ? ({...state}..remove(playlistId)) : {...state, playlistId};
    ref.read(prefsProvider).setStringList(key, state.toList()).ignore();
  }
}

final mixModeProvider = NotifierProvider<MixModePlaylists, Set<String>>(MixModePlaylists.new);

/// The slider button that switches a playlist to mixing: its transitions appear between the songs.
class MixModeButton extends ConsumerWidget {
  const MixModeButton({super.key, required this.playlistId});
  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final on = ref.watch(mixModeProvider.select((ids) => ids.contains(playlistId)));
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      iconSize: 26,
      tooltip: on ? context.l10n.transitionMixOff : context.l10n.transitionMixOn,
      isSelected: on,
      color: on ? accent : Colors.white70,
      style: on ? IconButton.styleFrom(backgroundColor: accent.withValues(alpha: 0.18)) : null,
      icon: const Icon(Icons.tune),
      onPressed: () => ref.read(mixModeProvider.notifier).toggle(playlistId),
    );
  }
}

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

String volumeLaneLabel(AppLocalizations l10n, VolumeLane lane) => switch (lane) {
  VolumeLane.smooth => l10n.volumeSmooth,
  VolumeLane.overlap => l10n.volumeOverlap,
  VolumeLane.fadeInOut => l10n.volumeFadeInOut,
  VolumeLane.hardInFadeOut => l10n.volumeHardInFadeOut,
  VolumeLane.fadeInHardOut => l10n.volumeFadeInHardOut,
  VolumeLane.centerCut => l10n.volumeCenterCut,
  VolumeLane.crossfade => l10n.volumeCrossfade,
  VolumeLane.fadeInQuickOut => l10n.volumeFadeInQuickOut,
  VolumeLane.fadeInCutBar => l10n.volumeFadeInCutBar,
  VolumeLane.overlapCutBar => l10n.volumeOverlapCutBar,
};

String eqLaneLabel(AppLocalizations l10n, EqLane lane) => switch (lane) {
  EqLane.swapMiddle => l10n.eqSwapMiddle,
  EqLane.swapEnd => l10n.eqSwapEnd,
  EqLane.swapStart => l10n.eqSwapStart,
  EqLane.threeBand => l10n.eqThreeBand,
  EqLane.quickBassCut => l10n.eqQuickBassCut,
  EqLane.longBassCut => l10n.eqLongBassCut,
  EqLane.bassFadeOut => l10n.eqBassFadeOut,
  EqLane.none => l10n.transitionNone,
};

String filterLaneLabel(AppLocalizations l10n, FilterLane lane) => switch (lane) {
  FilterLane.none => l10n.transitionNone,
  FilterLane.lowpassOut => l10n.filterLowpassOut,
  FilterLane.lowpassIn => l10n.filterLowpassIn,
  FilterLane.lowpassInOut => l10n.filterLowpassInOut,
  FilterLane.lowpassInHighpassOut => l10n.filterLowpassInHighpassOut,
  FilterLane.highpassOut => l10n.filterHighpassOut,
  FilterLane.highpassIn => l10n.filterHighpassIn,
  FilterLane.highpassInOut => l10n.filterHighpassInOut,
  FilterLane.highpassInLowpassOut => l10n.filterHighpassInLowpassOut,
  FilterLane.highpassHalf => l10n.filterHighpassHalf,
  FilterLane.noiseEnd => l10n.filterNoiseEnd,
};

String effectLaneLabel(AppLocalizations l10n, EffectLane lane) {
  final beat = switch (lane.echoBeats) {
    0.5 => '½',
    0.75 => '¾',
    _ => '1',
  };
  return switch (lane) {
    EffectLane.none => l10n.transitionNone,
    EffectLane.reverbMiddle => l10n.effectReverbMiddle,
    EffectLane.reverbCut => l10n.effectReverbCut,
    EffectLane.reverbTail => l10n.effectReverbTail,
    EffectLane.delayHalfCut || EffectLane.delayThreeQuarterCut => l10n.effectDelayCut(beat),
    _ => lane.tail ? l10n.effectEchoTail(beat) : l10n.effectEchoCut(beat),
  };
}

String loopLabel(AppLocalizations l10n, int beats) => beats == 0 ? l10n.transitionNone : l10n.loopBeats(beats);

/// The editor's presets: a name and the lanes it sets.
List<(String, MixLanes)> transitionPresets(AppLocalizations l10n) => [
  (l10n.transitionCrossfade, const MixLanes()),
  (l10n.transitionFadeIn, const MixLanes(volume: VolumeLane.fadeInHardOut)),
  (l10n.transitionFadeOut, const MixLanes(volume: VolumeLane.fadeInOut, eq: EqLane.bassFadeOut)),
  (
    l10n.transitionFilter,
    const MixLanes(volume: VolumeLane.crossfade, filter: FilterLane.highpassOut, effect: EffectLane.echoHalfCut),
  ),
  (
    l10n.transitionEchoOut,
    const MixLanes(volume: VolumeLane.fadeInHardOut, effect: EffectLane.echoBeatTail, filter: FilterLane.lowpassOut),
  ),
  (l10n.transitionLoopOut, const MixLanes(volume: VolumeLane.fadeInCutBar, eq: EqLane.quickBassCut, loopBeats: 4)),
  (l10n.transitionCut, const MixLanes(volume: VolumeLane.centerCut)),
];

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
                          : '${_presetName(context.l10n, saved)} · ${context.l10n.transitionBars(saved.bars)}',
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

String _presetName(AppLocalizations l10n, CustomTransition transition) {
  final lanes = transition.lanes;
  if (lanes == null) return transitionStyleLabel(l10n, transition.style);
  return transitionPresets(l10n).where((p) => p.$2 == lanes).firstOrNull?.$1 ?? l10n.transitionCustom;
}
