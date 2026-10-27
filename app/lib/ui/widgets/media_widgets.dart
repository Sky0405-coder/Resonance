import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Rounded pill switch between a few sections (media tabs, audiobook views); scrolls when it does not fit.
class PillTabs extends StatelessWidget {
  const PillTabs({
    super.key,
    required this.items,
    required this.selected,
    required this.onSelected,
    this.dense = false,
  });
  final List<({IconData? icon, String label})> items;
  final int selected;
  final ValueChanged<int> onSelected;

  /// Smaller pills without the track behind them, for views inside a tab.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final pills = [for (final (i, item) in items.indexed) _pill(context, i, item)];
    if (dense) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final (i, pill) in pills.indexed) ...[if (i > 0) const SizedBox(width: 8), pill],
          ],
        ),
      );
    }
    // The main sections share the width evenly, like a segmented control.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final (i, pill) in pills.indexed) ...[if (i > 0) const SizedBox(width: 8), Expanded(child: pill)],
        ],
      ),
    );
  }

  Widget _pill(BuildContext context, int i, ({IconData? icon, String label}) item) {
    final accent = Theme.of(context).colorScheme.primary;
    final active = i == selected;
    final foreground = active ? (dense ? Colors.black : onColor(accent)) : (item.icon == null ? Colors.white : null);
    return Semantics(
      button: true,
      selected: active,
      child: Material(
        color: active ? (dense ? Colors.white : accent) : Colors.white.withValues(alpha: dense ? 0.06 : 0.08),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => onSelected(i),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: dense ? 14 : 10, vertical: dense ? 7 : 10),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (item.icon != null) ...[
                    Icon(item.icon, size: 18, color: foreground ?? Palette.textMuted),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    item.label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: dense ? 13 : 14,
                      color: foreground ?? Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A section heading in the media tabs, optionally with an action on the right.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.action, this.padding = const EdgeInsets.fromLTRB(16, 28, 8, 12)});
  final String title;
  final Widget? action;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(
          child: Text(title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        ),
        ?action,
      ],
    ),
  );
}

/// The one thing to pick up again, big: cover, what it is, progress, time left and a play button.
class ContinueCard extends StatelessWidget {
  const ContinueCard({
    super.key,
    required this.cover,
    required this.kicker,
    required this.title,
    this.subtitle,
    required this.progress,
    this.remaining,
    required this.onPlay,
    required this.onTap,
    this.tint,
  });
  final Widget cover;
  final String kicker;
  final String title;
  final String? subtitle;
  final double progress;
  final String? remaining;
  final VoidCallback onPlay;
  final VoidCallback onTap;

  /// The cover's color, glowing in from the left.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    final glow = HSLColor.fromColor(tint ?? accent);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        color: Palette.card,
        child: InkWell(
          onTap: onTap,
          child: Ink(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [glow.withLightness(glow.lightness.clamp(0.0, 0.28)).toColor(), Palette.card],
                stops: const [0, 0.8],
              ),
            ),
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                SizedBox(
                  width: 96,
                  height: 96,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 14, offset: Offset(0, 6))],
                    ),
                    child: ClipRRect(borderRadius: BorderRadius.circular(10), child: cover),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kicker.toUpperCase(),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, letterSpacing: 1.2, color: accent, fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16, height: 1.2),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Palette.textMuted, fontSize: 13),
                        ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: progress.clamp(0, 1),
                                minHeight: 4,
                                color: accent,
                                backgroundColor: Colors.white12,
                              ),
                            ),
                          ),
                          if (remaining != null) ...[
                            const SizedBox(width: 10),
                            Text(remaining!, style: const TextStyle(color: Palette.textMuted, fontSize: 12)),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Material(
                  color: accent,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: onPlay,
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Icon(Icons.play_arrow_rounded, size: 30, color: onColor(accent)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
