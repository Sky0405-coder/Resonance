import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';

import 'jam_sheet.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import 'catalog.dart';
import 'common.dart';

class SeekBar extends ConsumerStatefulWidget {
  const SeekBar({super.key, this.showTimes = true, this.compact = false, this.visualizer = false});
  final bool showTimes;
  final bool compact;

  /// A faint spectrum of the song behind the slider (desktop player bar).
  final bool visualizer;

  @override
  ConsumerState<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends ConsumerState<SeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    final book = ref.watch(playerProvider.select((p) => p.book));
    final station = ref.watch(playerProvider.select((p) => p.station));
    final track = ref.watch(playerProvider.select((p) => p.current));
    if (station != null) return const Center(child: LiveBadge());
    // Audiobooks: the whole book, not the current file.
    final pos = book != null
        ? Duration(milliseconds: (ref.watch(bookPositionProvider) * 1000).round())
        : ref.watch(positionProvider).value ?? Duration.zero;
    final dur = book != null
        ? Duration(milliseconds: (book.duration * 1000).round())
        : ref.watch(durationProvider).value ?? track?.length ?? Duration.zero;
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
        final ctrl = ref.read(playerProvider.notifier);
        if (book != null) {
          ctrl.seekBook(v / 1000);
        } else {
          ctrl.seek(Duration(milliseconds: v.round()));
        }
        setState(() => _dragValue = null);
      },
    );
    final bars = widget.visualizer && track != null && book == null && ref.watch(visualizerEnabledProvider)
        ? Stack(
            alignment: Alignment.center,
            children: [
              Positioned.fill(
                left: 24,
                right: 24,
                child: IgnorePointer(
                  child: SpectrumVisualizer(
                    trackId: track.id,
                    color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3),
                    gap: 0.45,
                    minHeight: 0,
                  ),
                ),
              ),
              slider,
            ],
          )
        : slider;
    if (!widget.showTimes) return bars;
    return Row(
      children: [
        SizedBox(
          width: 44,
          child: Text(
            formatDuration(Duration(milliseconds: value.round())),
            style: style,
            textAlign: TextAlign.right,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: bars),
        const SizedBox(width: 8),
        SizedBox(width: 44, child: Text(formatDuration(dur), style: style)),
      ],
    );
  }
}

class TransportControls extends ConsumerWidget {
  const TransportControls({super.key, this.big = false, this.playPauseOnly = false});
  final bool big;
  final bool playPauseOnly;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = ref.watch(playerProvider);
    final ctrl = ref.read(playerProvider.notifier);
    final accent = Theme.of(context).colorScheme.primary;
    final iconSize = big ? 36.0 : 24.0;
    final playButton = Material(
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
    );
    if (playPauseOnly) return playButton;
    if (p.station != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(icon: const Icon(Icons.skip_previous), iconSize: iconSize, onPressed: null),
          playButton,
          IconButton(icon: const Icon(Icons.skip_next), iconSize: iconSize, onPressed: null),
          if (big) const SleepTimerButton(),
        ],
      );
    }
    if (p.book != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SpeedButton(),
          IconButton(
            tooltip: context.l10n.playerSkipBack,
            iconSize: iconSize,
            icon: const Icon(Icons.replay_30),
            onPressed: () => ctrl.skipBook(-30),
          ),
          SizedBox(width: big ? 12 : 4),
          playButton,
          SizedBox(width: big ? 12 : 4),
          IconButton(
            tooltip: context.l10n.playerSkipForward,
            iconSize: iconSize,
            icon: const Icon(Icons.forward_30),
            onPressed: () => ctrl.skipBook(30),
          ),
          const SleepTimerButton(),
        ],
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const ShuffleButton(),
        IconButton(
          tooltip: context.l10n.playerPrevious,
          iconSize: iconSize,
          icon: const Icon(Icons.skip_previous),
          onPressed: ctrl.previous,
        ),
        SizedBox(width: big ? 12 : 4),
        playButton,
        SizedBox(width: big ? 12 : 4),
        IconButton(
          tooltip: context.l10n.playerNext,
          iconSize: iconSize,
          icon: const Icon(Icons.skip_next),
          onPressed: ctrl.next,
        ),
        IconButton(
          tooltip: context.l10n.playerRepeat,
          icon: Icon(p.loop == LoopMode.one ? Icons.repeat_one : Icons.repeat),
          color: p.loop == LoopMode.off ? Palette.textMuted : accent,
          onPressed: p.inJam ? null : ctrl.cycleLoop,
        ),
      ],
    );
  }
}

class SpeedButton extends ConsumerWidget {
  const SpeedButton({super.key});

  static const speeds = [0.75, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final speed = ref.watch(playerProvider.select((p) => p.speed));
    String label(double v) =>
        '${NumberFormat(v == v.roundToDouble() ? '0' : '0.00', context.l10n.localeName).format(v)}×';
    return PopupMenuButton<double>(
      useRootNavigator: true,
      tooltip: context.l10n.playerSpeed,
      initialValue: speed,
      onSelected: ref.read(playerProvider.notifier).setSpeed,
      itemBuilder: (_) => [for (final v in speeds) PopupMenuItem(value: v, child: Text(label(v)))],
      child: SizedBox(
        width: 48,
        child: Center(
          child: Text(
            label(speed),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: speed == 1 ? Palette.textMuted : Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
      ),
    );
  }
}

class SleepTimerButton extends ConsumerWidget {
  const SleepTimerButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sleepAt = ref.watch(playerProvider.select((p) => p.sleepAt));
    final ctrl = ref.read(playerProvider.notifier);
    return PopupMenuButton<int>(
      useRootNavigator: true,
      tooltip: sleepAt == null
          ? context.l10n.playerSleepTimer
          : context.l10n.playerSleepTimerTime((TimeOfDay.fromDateTime(sleepAt).format(context)).toString()),
      icon: Icon(
        sleepAt == null ? Icons.bedtime_outlined : Icons.bedtime,
        color: sleepAt == null ? Palette.textMuted : Theme.of(context).colorScheme.primary,
      ),
      onSelected: (m) => ctrl.setSleepTimer(m == 0 ? null : Duration(minutes: m)),
      itemBuilder: (_) => [
        for (final m in const [5, 10, 15, 30, 45, 60, 90])
          PopupMenuItem(value: m, child: Text(context.l10n.playerTimerMinutes(m))),
        if (sleepAt != null) PopupMenuItem(value: 0, child: Text(context.l10n.playerDisableTimer)),
      ],
    );
  }
}

/// Cover, title and author/chapter of the playing audiobook (player bars).
class _BookInfo extends ConsumerWidget {
  const _BookInfo({required this.book, this.coverSize = 56});
  final BookPlayback book;
  final double coverSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chapter = book.chapterAt(ref.watch(bookPositionProvider));
    return InkWell(
      onTap: () => context.push('/audiobooks/item/${book.itemId}'),
      child: Row(
        children: [
          SizedBox(
            width: coverSize,
            child: NetworkCover(url: book.coverUrl, icon: Icons.headphones),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Text(
                  chapter?.title ?? book.author ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
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
      tooltip: track.liked ? context.l10n.playerRemoveLiked : context.l10n.playerAddLiked,
      icon: Icon(track.liked ? Icons.favorite : Icons.favorite_border, size: size),
      color: track.liked ? accent : Palette.textMuted,
      onPressed: () => ref.read(libraryActionsProvider).setLiked(track, !track.liked).catchError((e) {
        if (context.mounted) showError(context, e);
      }),
    );
  }
}

/// Desktop: full-width bar at the bottom of the window.
/// Shown while an AutoMix transition plays.
class AutomixChip extends ConsumerWidget {
  const AutomixChip({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => ValueListenableBuilder<bool>(
    valueListenable: ref.read(playerProvider.notifier).engine.automixing,
    builder: (context, mixing, _) => AnimatedOpacity(
      opacity: mixing ? 1 : 0,
      duration: const Duration(milliseconds: 300),
      child: mixing
          ? Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                border: Border.all(color: Theme.of(context).colorScheme.primary),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.graphic_eq, size: 12, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 3),
                  Text(
                    context.l10n.settingsAutomix,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    ),
  );
}

class DesktopPlayerBar extends ConsumerWidget {
  const DesktopPlayerBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = ref.watch(playerProvider.select((p) => p.current));
    final book = ref.watch(playerProvider.select((p) => p.book));
    final station = ref.watch(playerProvider.select((p) => p.station));
    final stationNow = ref.watch(playerProvider.select((p) => p.stationNow));
    return Container(
      height: 84,
      color: Palette.sidebar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: station != null
                ? StationInfo(station: station, now: stationNow)
                : book != null
                ? _BookInfo(book: book)
                : track == null
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
                            Row(
                              children: [
                                Flexible(
                                  child: InkWell(
                                    onTap: () => context.push('/album/${track.album.id}'),
                                    child: TrackTitle(
                                      track: track,
                                      smart: ref.watch(playerProvider.select((p) => p.smartIds.contains(track.id))),
                                    ),
                                  ),
                                ),
                                const JamChip(),
                                const AutomixChip(),
                              ],
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
                ConstrainedBox(constraints: const BoxConstraints(maxWidth: 600), child: const SeekBar(visualizer: true)),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (book == null && station == null) const JamButton(size: 20),
                if (book == null && station == null)
                  IconButton(
                    tooltip: context.l10n.lyricsTitle,
                    icon: const Icon(Icons.lyrics_outlined),
                    color: Palette.textMuted,
                    onPressed: () => context.push('/lyrics'),
                  ),
                if (book == null && station == null)
                  IconButton(
                    tooltip: context.l10n.playerQueue,
                    icon: const Icon(Icons.queue_music),
                    color: Palette.textMuted,
                    onPressed: () => context.push('/queue'),
                  ),
                const Icon(Icons.volume_up, color: Palette.textMuted, size: 20),
                SizedBox(
                  width: 120,
                  child: ValueListenableBuilder<double>(
                    valueListenable: ref.read(playerProvider.notifier).userVolume,
                    builder: (_, volume, _) =>
                        Slider(value: volume, onChanged: ref.read(playerProvider.notifier).setUserVolume),
                  ),
                ),
                IconButton(
                  tooltip: context.l10n.playerFullscreen,
                  icon: const Icon(Icons.open_in_full, size: 18),
                  color: Palette.textMuted,
                  onPressed: track == null && book == null && station == null
                      ? null
                      : () => context.push('/now-playing'),
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
    if (track == null && p.book == null && p.station == null) return const SizedBox.shrink();
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
                    if (p.station != null) ...[
                      Expanded(child: StationInfo(station: p.station!, now: p.stationNow, coverSize: 42)),
                    ] else if (p.book != null) ...[
                      Expanded(child: _BookInfo(book: p.book!, coverSize: 42)),
                      IconButton(icon: const Icon(Icons.replay_30), onPressed: () => ctrl.skipBook(-30)),
                    ] else ...[
                      SizedBox(width: 42, child: CoverImage(albumId: track!.album.id, size: 64)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: TrackTitle(
                                    track: track,
                                    smart: ref.watch(playerProvider.select((p) => p.smartIds.contains(track.id))),
                                    style: const TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ),
                                const JamChip(),
                              ],
                            ),
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
                    ],
                    IconButton(icon: Icon(p.playing ? Icons.pause : Icons.play_arrow), onPressed: ctrl.togglePlay),
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

class LiveBadge extends StatelessWidget {
  const LiveBadge({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.circle, size: 8, color: Colors.redAccent),
        const SizedBox(width: 5),
        Text(context.l10n.worldRadioLive, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
      ],
    ),
  );
}

class StationInfo extends StatelessWidget {
  const StationInfo({super.key, required this.station, this.now, this.coverSize = 56});
  final Station station;
  final StationNowPlaying? now;
  final double coverSize;

  @override
  Widget build(BuildContext context) => InkWell(
    onTap: () => context.push('/now-playing'),
    child: Row(
      children: [
        SizedBox(
          width: coverSize,
          height: coverSize,
          child: NetworkCover(url: now?.coverUrl ?? station.favicon, radius: 6, icon: Icons.radio),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                now?.title ?? station.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                now?.title != null
                    ? now!.subtitle(station.name)
                    : '${context.l10n.worldRadioTitle} · ${station.country}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}
