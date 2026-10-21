import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/library.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../pages/now_playing_page.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import 'tv_focusable.dart';

String tvPlaybackTitle(BuildContext context, PlayerView player) =>
    player.stationNow?.title ??
    player.station?.name ??
    player.book?.title ??
    player.current?.title ??
    context.l10n.playerNothingPlaying;

String tvPlaybackArtist(PlayerView player) =>
    player.stationNow?.artistYear ??
    player.station?.country ??
    player.book?.author ??
    player.current?.artistCredit ??
    '';

class TvPlaybackArtwork extends StatelessWidget {
  const TvPlaybackArtwork({super.key, required this.player, this.visualizer = false});
  final PlayerView player;
  final bool visualizer;

  @override
  Widget build(BuildContext context) {
    if (player.station case final station?) {
      return NetworkCover(url: player.stationNow?.coverUrl ?? station.favicon, icon: Icons.radio);
    }
    if (player.book case final book?) return NetworkCover(url: book.coverUrl, icon: Icons.headphones);
    if (player.current case final track?) {
      return visualizer ? TrackCover(track: track, interactive: false) : CoverImage(albumId: track.album.id);
    }
    return const CoverImage();
  }
}

class TvNowPlayingBar extends ConsumerWidget {
  const TvNowPlayingBar({super.key, this.focusNode});
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              focusNode: focusNode,
              focusScale: 1.01,
              label: context.l10n.playerNowPlaying,
              onActivate: () => context.push('/now-playing'),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    SizedBox(width: 64, height: 64, child: TvPlaybackArtwork(player: player)),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(tvPlaybackTitle(context, player), maxLines: 1, overflow: TextOverflow.ellipsis),
                          Text(
                            tvPlaybackArtist(player),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Palette.textMuted, fontSize: 18),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 24),
          TvButton(
            icon: player.playing ? Icons.pause : Icons.play_arrow,
            label: player.playing ? context.l10n.tvPause : context.l10n.tvPlay,
            onPressed: ref.read(playerProvider.notifier).togglePlay,
          ),
        ],
      ),
    );
  }
}

class TvNowPlayingPage extends ConsumerWidget {
  const TvNowPlayingPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(playerProvider);
    final controller = ref.read(playerProvider.notifier);
    final track = player.current;
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? Duration.zero;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TvButton(
                icon: Icons.arrow_back,
                label: context.l10n.tvBack,
                onPressed: () => context.canPop() ? context.pop() : context.go('/'),
              ),
              const SizedBox(height: 24),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final cover = SizedBox(
                      width: math.min(540, constraints.maxWidth * 0.42),
                      height: math.min(620, constraints.maxHeight),
                      child: TvPlaybackArtwork(player: player, visualizer: true),
                    );
                    final details = SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tvPlaybackTitle(context, player),
                            style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            tvPlaybackArtist(player),
                            style: const TextStyle(fontSize: 28, color: Palette.textMuted),
                          ),
                          const SizedBox(height: 32),
                          if (player.station == null) ...[
                            TvFocusable(
                              skipTraversal: true,
                              descendantsAreFocusable: true,
                              onActivate: () {},
                              child: Slider(
                                value: position.inMilliseconds.toDouble().clamp(0, duration.inMilliseconds.toDouble()),
                                max: math.max(1, duration.inMilliseconds.toDouble()),
                                onChanged: duration > Duration.zero
                                    ? (value) => controller.seek(Duration(milliseconds: value.round()))
                                    : null,
                              ),
                            ),
                            Text('${formatDuration(position)} / ${formatDuration(duration)}'),
                            const SizedBox(height: 24),
                          ],
                          Wrap(
                            spacing: 16,
                            runSpacing: 16,
                            children: [
                              if (track != null)
                                TvButton(
                                  icon: player.shuffle ? Icons.shuffle_on : Icons.shuffle,
                                  label: context.l10n.playerShuffle,
                                  onPressed: player.inJam ? null : controller.toggleShuffle,
                                ),
                              TvButton(
                                icon: Icons.skip_previous,
                                label: context.l10n.playerPrevious,
                                onPressed: controller.previous,
                              ),
                              TvButton(
                                icon: player.playing ? Icons.pause : Icons.play_arrow,
                                label: player.playing ? context.l10n.tvPause : context.l10n.tvPlay,
                                autofocus: true,
                                onPressed: controller.togglePlay,
                              ),
                              TvButton(
                                icon: Icons.skip_next,
                                label: context.l10n.playerNext,
                                onPressed: controller.next,
                              ),
                              if (track != null) ...[
                                TvButton(
                                  icon: player.loop == LoopMode.one ? Icons.repeat_one : Icons.repeat,
                                  label: context.l10n.playerRepeat,
                                  onPressed: player.inJam ? null : controller.cycleLoop,
                                ),
                                TvButton(
                                  icon: track.liked ? Icons.favorite : Icons.favorite_border,
                                  label: track.liked ? context.l10n.playerRemoveLiked : context.l10n.playerAddLiked,
                                  onPressed: () async {
                                    try {
                                      await ref.read(libraryActionsProvider).setLiked(track, !track.liked);
                                    } catch (error) {
                                      if (context.mounted) showError(context, error);
                                    }
                                  },
                                ),
                                TvButton(
                                  icon: Icons.lyrics_outlined,
                                  label: context.l10n.lyricsTitle,
                                  onPressed: () => context.push('/lyrics'),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    );
                    return Row(
                      children: [
                        cover,
                        const SizedBox(width: 48),
                        Expanded(child: details),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
