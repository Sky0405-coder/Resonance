import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/tv_mode.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import '../pages/now_playing_page.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import 'tv_ambient.dart';
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
  const TvPlaybackArtwork({super.key, required this.player, this.visualizer = false, this.size = 300});
  final PlayerView player;
  final bool visualizer;
  final int size;

  @override
  Widget build(BuildContext context) {
    if (player.station case final station?) {
      return NetworkCover(url: player.stationNow?.coverUrl ?? station.favicon, icon: Icons.radio);
    }
    if (player.book case final book?) return NetworkCover(url: book.coverUrl, icon: Icons.headphones);
    if (player.current case final track?) {
      return visualizer
          ? TrackCover(track: track, interactive: false)
          : CoverImage(albumId: track.album.id, size: size);
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
    final loaded = track != null || player.book != null || player.station != null;
    final mediaKey = player.station != null
        ? 'station:${player.station!.id}'
        : player.book != null
        ? 'book:${player.book!.itemId}'
        : track == null
        ? null
        : 'track:${track.id}';
    final favorites = player.station == null
        ? const <Station>[]
        : ref.watch(worldRadioFavoritesProvider).value ?? const <Station>[];
    final favorite = player.station != null && favorites.any((station) => station.id == player.station!.id);
    final ambientMode = ref.watch(tvAmbientModeProvider);
    final position = ref.watch(positionProvider).value ?? Duration.zero;
    final duration = ref.watch(durationProvider).value ?? Duration.zero;
    final coverColor =
        track != null && player.book == null && player.station == null && ref.watch(visualizerEnabledProvider)
        ? ref.watch(coverColorProvider(coverImageProvider(ref, track.album.id, size: 300))).value
        : null;
    final hsl = coverColor == null ? null : HSLColor.fromColor(coverColor);
    final topColor = hsl == null
        ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.45)
        : hsl
              .withLightness(math.min(hsl.lightness, 0.25))
              .withSaturation(math.min(hsl.saturation, 0.7))
              .withAlpha(1)
              .toColor();
    final background = Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Palette.background),
        if (loaded)
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 800),
              child: KeyedSubtree(
                key: ValueKey('tv-now-playing-artwork-$mediaKey'),
                child: Opacity(
                  opacity: 0.55,
                  child: SizedBox.expand(
                    child: ImageFiltered(
                      imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80),
                      child: Transform.scale(
                        scale: 1.3,
                        child: SizedBox.expand(child: TvPlaybackArtwork(player: player, size: 600)),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        if (loaded)
          Positioned.fill(
            child: TweenAnimationBuilder<Color?>(
              duration: const Duration(milliseconds: 800),
              tween: ColorTween(end: topColor),
              builder: (context, color, child) => DecoratedBox(
                key: const ValueKey('tv-now-playing-gradient'),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [(color ?? topColor).withValues(alpha: 0.6), Palette.background.withValues(alpha: 0.92)],
                  ),
                ),
              ),
            ),
          ),
        if (loaded)
          const Positioned.fill(
            child: DecoratedBox(
              key: ValueKey('tv-now-playing-bottom-gradient'),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, Color(0x99000000)],
                  stops: [0.6, 1],
                ),
              ),
            ),
          ),
      ],
    );
    return Scaffold(
      backgroundColor: Palette.background,
      body: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: background),
          SafeArea(
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
                        final coverflow = track != null && player.queue.length > 1;
                        final cover = SizedBox(
                          key: const ValueKey('tv-now-playing-cover'),
                          width: coverflow
                              ? math.min(900, constraints.maxWidth * 0.5)
                              : math.min(540, constraints.maxWidth * 0.42),
                          height: math.min(620, constraints.maxHeight),
                          child: coverflow
                              ? const Coverflow(interactive: false, maxSide: 620)
                              : TvPlaybackArtwork(player: player, visualizer: true),
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
                                    value: position.inMilliseconds.toDouble().clamp(
                                      0,
                                      duration.inMilliseconds.toDouble(),
                                    ),
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
                                      icon: Icons.shuffle,
                                      active: player.shuffle,
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
                                  if (player.station case final station?)
                                    TvButton(
                                      icon: favorite ? Icons.star : Icons.star_border,
                                      label: favorite ? context.l10n.tvFavoriteRemove : context.l10n.tvFavoriteAdd,
                                      onPressed: () async {
                                        try {
                                          final api = ref.read(apiProvider);
                                          if (favorite) {
                                            await api.removeWorldRadioFavorite(station.id);
                                          } else {
                                            await api.addWorldRadioFavorite(station.id);
                                          }
                                          ref.invalidate(worldRadioFavoritesProvider);
                                        } catch (error) {
                                          if (context.mounted) showError(context, error);
                                        }
                                      },
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
                                  TvButton(
                                    icon: ambientMode ? Icons.dark_mode : Icons.dark_mode_outlined,
                                    label: ambientMode ? context.l10n.tvAmbientOn : context.l10n.tvAmbientOff,
                                    onPressed: () {
                                      ref.read(tvAmbientModeProvider.notifier).set(!ambientMode);
                                      if (!ambientMode) TvAmbient.showNow();
                                    },
                                  ),
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
        ],
      ),
    );
  }
}
