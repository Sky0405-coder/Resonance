import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import 'common.dart';

/// Space at the bottom of scroll views so the mobile mini player never hides content.
const double kBottomInset = 96;

/// Spotify-like header for album / playlist / artist pages.
class CollectionHeader extends StatelessWidget {
  const CollectionHeader({
    super.key,
    required this.image,
    required this.kind,
    required this.title,
    required this.meta,
    this.description,
    this.circleImage = false,
  });

  final Widget image;
  final String kind;
  final String title;
  final Widget meta;
  final String? description;
  final bool circleImage;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final wide = isWide(context);
    final theme = Theme.of(context);
    final img = SizedBox(
      width: wide ? 220 : 220,
      child: circleImage ? ClipOval(child: image) : image,
    );
    final text = Column(
      crossAxisAlignment: wide ? CrossAxisAlignment.start : CrossAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (wide) Text(kind, style: theme.textTheme.labelMedium),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: wide ? TextAlign.start : TextAlign.center,
          style: (wide ? theme.textTheme.displayMedium : theme.textTheme.headlineMedium)?.copyWith(
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: -1.5,
          ),
        ),
        if (description != null && description!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(description!, style: const TextStyle(color: Palette.textMuted)),
        ],
        const SizedBox(height: 8),
        DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 13, color: Colors.white70),
          child: meta,
        ),
      ],
    );
    final header = Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [accent.withValues(alpha: 0.35), Palette.background],
        ),
      ),
      padding: EdgeInsets.fromLTRB(24, (wide ? 64 : 56) + MediaQuery.paddingOf(context).top, 24, 24),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                img,
                const SizedBox(width: 24),
                Expanded(child: text),
              ],
            )
          : Column(children: [img, const SizedBox(height: 16), text]),
    );
    if (!context.canPop()) return header;
    return Stack(
      children: [
        header,
        Positioned(
          left: 8,
          top: 8 + MediaQuery.paddingOf(context).top,
          child: IconButton.filledTonal(
            style: IconButton.styleFrom(backgroundColor: Colors.black45),
            icon: const Icon(Icons.arrow_back),
            onPressed: context.pop,
          ),
        ),
      ],
    );
  }
}

/// Play / shuffle / extra action row beneath a [CollectionHeader].
class ActionBar extends StatelessWidget {
  const ActionBar({super.key, required this.onPlay, this.onShuffle, this.playing = false, this.children = const []});
  final VoidCallback? onPlay;
  final VoidCallback? onShuffle;
  final bool playing;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Row(
      children: [
        if (onPlay != null) PlayButton(onPressed: onPlay!, playing: playing),
        const SizedBox(width: 8),
        if (onShuffle != null)
          IconButton(
            tooltip: 'Zufallswiedergabe',
            iconSize: 30,
            color: Palette.textMuted,
            icon: const Icon(Icons.shuffle),
            onPressed: onShuffle,
          ),
        ...children,
      ],
    ),
  );
}
