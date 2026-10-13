import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import 'common.dart';

class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({super.key, this.showTimes = true, this.compact = false});
  final bool showTimes;
  final bool compact;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final pos = ref.watch(positionProvider).value ?? Duration.zero;
    final track = ref.watch(playerProvider.select((p) => p.current));
    final dur = ref.watch(durationProvider).value ?? track?.length ?? Duration.zero;
    final max = dur.inMilliseconds.toDouble().clamp(1.0, double.infinity);
    final value = (_dragValue ?? pos.inMilliseconds.toDouble()).clamp(0.0, max);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: Palette.textMuted, fontSize: 11);

    if (widget.compact) {
      return LinearProgressIndicator(
        value: value / max,
        minHeight: 2,
        backgroundColor: Colors.white24,
        color: Colors.white,
      );
    }

    final slider = Slider(
      value: value,
      max: max,
      onChanged: (v) => setState(() => _dragValue = v),
      onChangeEnd: (v) {
        ref.read(playerProvider.notifier).seek(Duration(milliseconds: v.round()));
        setState(() => _dragValue = null);
      },
    );
    if (!widget.showTimes) return slider;
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(formatDuration(Duration(milliseconds: value.round())), style: style, textAlign: TextAlign.right),
        ),
        const SizedBox(width: 8),
        Expanded(child: slider),
        const SizedBox(width: 8),
        SizedBox(width: 44, child: Text(formatDuration(dur), style: style)),
      ],
    );
  }
}

class TransportControls extends ConsumerWidget {
  const TransportControls({super.key, this.big = false});
  final bool big;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playerProvider);
    final ctrl = ref.read(playerProvider.notifier);
    final accent = Theme.of(context).colorScheme.primary;
    final iconSize = big ? 36.0 : 24.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          tooltip: 'Zufallswiedergabe',
          icon: const Icon(Icons.shuffle),
          color: p.shuffle ? accent : Palette.textMuted,
          onPressed: ctrl.toggleShuffle,
        ),
        IconButton(
          tooltip: 'Zurück',
          iconSize: iconSize,
          icon: const Icon(Icons.skip_previous),
          onPressed: ctrl.previous,
        ),
        SizedBox(width: big ? 12 : 4),
        Material(
          color: Colors.white,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: ctrl.togglePlay,
            child: SizedBox(
              width: big ? 68 : 36,
              height: big ? 68 : 36,
              child: p.buffering && !p.playing
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                    )
                  : Icon(p.playing ? Icons.pause : Icons.play_arrow, color: Colors.black, size: big ? 40 : 24),
            ),
          ),
        ),
        SizedBox(width: big ? 12 : 4),
        IconButton(tooltip: 'Weiter', iconSize: iconSize, icon: const Icon(Icons.skip_next), onPressed: ctrl.next),
        IconButton(
          tooltip: 'Wiederholen',
          icon: Icon(p.loop == LoopMode.one ? Icons.repeat_one : Icons.repeat),
          color: p.loop == LoopMode.off ? Palette.textMuted : accent,
          onPressed: ctrl.cycleLoop,
        ),
      ],
    );
  }
}

class LikeButton extends ConsumerWidget {
  const LikeButton({super.key, required this.track, this.size = 20});
  final Track track;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = Theme.of(context).colorScheme.primary;
    return IconButton(
      tooltip: track.liked ? 'Aus Lieblingssongs entfernen' : 'Zu Lieblingssongs hinzufügen',
      icon: Icon(track.liked ? Icons.favorite : Icons.favorite_border, size: size),
      color: track.liked ? accent : Palette.textMuted,
      onPressed: () => ref.read(libraryActionsProvider).setLiked(track, !track.liked).catchError((e) {
        if (context.mounted) showError(context, e);
      }),
    );
  }
}

/// Desktop: full-width bar at the bottom of the window.
class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((p) => p.current));
    return Container(
      height: 84,
      color: Palette.sidebar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: track == null
                ? const SizedBox.shrink()
                : Row(
                    children: [
                      GestureDetector(
                        onTap: () => context.push('/now-playing'),
                        child: SizedBox(width: 56, child: CoverImage(albumId: track.album.id, size: 128)),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            InkWell(
                              onTap: () => context.push('/album/${track.album.id}'),
                              child: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            ),
                            InkWell(
                              onTap: () => context.push('/artist/${track.artist.id}'),
                              child: Text(
                                track.artistCredit,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ),
                      LikeButton(track: track),
                    ],
                  ),
          ),
          Expanded(
            flex: 4,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const TransportControls(),
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 600), child: const SeekBar()),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'Warteschlange',
                  icon: const Icon(Icons.queue_music),
                  color: Palette.textMuted,
                  onPressed: () => context.push('/queue'),
                ),
                const Icon(Icons.volume_up, color: Palette.textMuted, size: 20),
                SizedBox(
                  width: 120,
                  child: ValueListenableBuilder<double>(
                    valueListenable: ref.read(playerProvider.notifier).userVolume,
                    builder: (_, volume, _) => Slider(
                      value: volume,
                      onChanged: ref.read(playerProvider.notifier).setUserVolume,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Vollbild',
                  icon: const Icon(Icons.open_in_full, size: 18),
                  color: Palette.textMuted,
                  onPressed: track == null ? null : () => context.push('/now-playing'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Mobile: floating mini player above the bottom navigation.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playerProvider);
    final track = p.current;
    if (track == null) return const SizedBox.shrink();
    final ctrl = ref.read(playerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Material(
        color: const Color(0xFF3A3A3A),
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => context.push('/now-playing'),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: Row(
                  children: [
                    SizedBox(width: 42, child: CoverImage(albumId: track.album.id, size: 64)),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                          Text(
                            track.artistCredit,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    LikeButton(track: track),
                    IconButton(
                      icon: Icon(p.playing ? Icons.pause : Icons.play_arrow),
                      onPressed: ctrl.togglePlay,
                    ),
                  ],
                ),
              ),
              const SeekBar(compact: true),
            ],
          ),
        ),
      ),
    );
  }
}
