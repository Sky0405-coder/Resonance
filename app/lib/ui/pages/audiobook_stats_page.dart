import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/audiobooks.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/media_widgets.dart';

/// "2 Std. 5 Min." / "45 Min." for a stat value.
String statTime(AppLocalizations l10n, double seconds) {
  final minutes = (seconds / 60).floor();
  return minutes >= 60 ? l10n.statsHoursMinutesShort(minutes ~/ 60, minutes % 60) : l10n.statsMinutesShort(minutes);
}

/// Listening statistics of the Audiobookshelf account: totals, streaks, the last seven days and the top books.
class AudiobookStatsPage extends ConsumerWidget {
  const AudiobookStatsPage({super.key, this.now});

  /// Today, for tests.
  final DateTime? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.statsTitle, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncBody(
        value: ref.watch(absStatsProvider),
        onRetry: () => ref.invalidate(absStatsProvider),
        builder: (stats) {
          final clock = now ?? DateTime.now();
          final today = DateTime(clock.year, clock.month, clock.day);
          final weekStart = today.subtract(Duration(days: today.weekday - 1));
          final active = stats.daysActive;
          return RefreshIndicator(
            onRefresh: () => ref.refresh(absStatsProvider.future),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
              children: [
                _TotalCard(seconds: stats.total),
                const SizedBox(height: 12),
                Row(
                  children: [
                    for (final (i, (label, seconds)) in [
                      (l10n.statsToday, stats.on(today)),
                      (l10n.statsThisWeek, stats.between(weekStart, today)),
                      (l10n.statsThisMonth, stats.between(DateTime(today.year, today.month), today)),
                    ].indexed) ...[
                      if (i > 0) const SizedBox(width: 10),
                      Expanded(
                        child: _Tile(
                          child: Column(
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  statTime(l10n, seconds),
                                  style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(label, style: const TextStyle(color: Palette.textMuted, fontSize: 12.5)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                SectionTitle(l10n.statsActivity, padding: const EdgeInsets.fromLTRB(0, 28, 0, 12)),
                _Pair(
                  _Stat(
                    icon: Icons.local_fire_department_rounded,
                    color: const Color(0xFFFF8A3D),
                    value: l10n.statsDays(stats.currentStreak(today)),
                    label: l10n.statsCurrentStreak,
                  ),
                  _Stat(
                    icon: Icons.emoji_events_rounded,
                    color: const Color(0xFFF2C14E),
                    value: l10n.statsDays(stats.bestStreak),
                    label: l10n.statsBestStreak,
                  ),
                ),
                const SizedBox(height: 10),
                _Pair(
                  _Stat(
                    icon: Icons.auto_stories_rounded,
                    color: const Color(0xFF5BC27A),
                    value: '${stats.finished}',
                    label: l10n.statsBooksFinished,
                  ),
                  _Stat(
                    icon: Icons.menu_book_rounded,
                    color: const Color(0xFF3FB8AF),
                    value: '${stats.finishedThisYear}',
                    label: l10n.statsBooksThisYear,
                  ),
                ),
                const SizedBox(height: 10),
                _Pair(
                  _Stat(
                    icon: Icons.calendar_month_rounded,
                    color: const Color(0xFF5B8DEF),
                    value: '$active',
                    label: l10n.statsDaysActive,
                  ),
                  _Stat(
                    icon: Icons.speed_rounded,
                    color: const Color(0xFFA78BFA),
                    value: statTime(l10n, active == 0 ? 0 : stats.total / active),
                    label: l10n.statsDailyAverage,
                  ),
                ),
                SectionTitle(l10n.statsLast7Days, padding: const EdgeInsets.fromLTRB(0, 28, 0, 12)),
                _Tile(
                  child: _WeekChart(stats: stats, today: today),
                ),
                if (stats.items.isNotEmpty) ...[
                  SectionTitle(l10n.statsMostListened, padding: const EdgeInsets.fromLTRB(0, 28, 0, 8)),
                  for (final item in stats.items.take(5)) _TopBook(item: item, max: stats.items.first.seconds),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
    decoration: BoxDecoration(
      color: Palette.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
    ),
    child: child,
  );
}

class _TotalCard extends StatelessWidget {
  const _TotalCard({required this.seconds});
  final double seconds;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = Theme.of(context).colorScheme.primary;
    final minutes = (seconds / 60).floor();
    const big = TextStyle(fontSize: 64, fontWeight: FontWeight.w900, height: 1, letterSpacing: -2);
    const unit = TextStyle(fontSize: 22, fontWeight: FontWeight.w500, color: Palette.textMuted);
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 26, 20, 24),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color.alphaBlend(accent.withValues(alpha: 0.16), Palette.card), Palette.card],
        ),
      ),
      child: Column(
        children: [
          Text(
            l10n.statsTotal.toUpperCase(),
            style: const TextStyle(letterSpacing: 2.5, fontSize: 12, color: Palette.textMuted),
          ),
          const SizedBox(height: 14),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: '${minutes ~/ 60}', style: big),
                  TextSpan(text: ' ${l10n.statsUnitHours}  ', style: unit),
                  TextSpan(text: '${minutes % 60}', style: big),
                  TextSpan(text: ' ${l10n.statsUnitMinutes}', style: unit),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            l10n.statsDaysOfAudio(NumberFormat('0.0', l10n.localeName).format(seconds / 86400)),
            style: const TextStyle(color: Palette.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Pair extends StatelessWidget {
  const _Pair(this.a, this.b);
  final Widget a;
  final Widget b;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(child: a),
      const SizedBox(width: 10),
      Expanded(child: b),
    ],
  );
}

class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.color, required this.value, required this.label});
  final IconData icon;
  final Color color;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => _Tile(
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(color: color.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              ),
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Palette.textMuted, fontSize: 12.5),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Minutes per day of the last week as bars; the busiest day and today carry their value, the rest on hover/tap.
class _WeekChart extends StatelessWidget {
  const _WeekChart({required this.stats, required this.today});
  final AbsStats stats;
  final DateTime today;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = Theme.of(context).colorScheme.primary;
    final days = [for (var i = 6; i >= 0; i--) DateTime(today.year, today.month, today.day - i)];
    final values = [for (final d in days) stats.on(d)];
    final peak = values.fold(0.0, math.max);
    // At least half an hour tall, so a week of a few seconds does not look like a busy one.
    final scale = math.max(peak, 1800.0);
    final weekday = DateFormat.E(l10n.localeName);
    const height = 120.0;
    return Column(
      children: [
        SizedBox(
          height: height + 22,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (final (i, day) in days.indexed)
                Expanded(
                  child: Tooltip(
                    message: '${weekday.format(day)}: ${statTime(l10n, values[i])}',
                    triggerMode: TooltipTriggerMode.tap,
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        if (values[i] >= 60 && (values[i] == peak || i == 6))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                statTime(l10n, values[i]),
                                style: const TextStyle(fontSize: 11, color: Palette.textMuted),
                              ),
                            ),
                          ),
                        Container(
                          width: 22,
                          // Empty days keep a sliver so the week's shape still reads.
                          height: math.max(3, values[i] / scale * height),
                          decoration: BoxDecoration(
                            color: values[i] > 0 ? accent : Colors.white12,
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const Divider(height: 1, color: Palette.divider),
        const SizedBox(height: 8),
        Row(
          children: [
            for (final (i, day) in days.indexed)
              Expanded(
                child: Text(
                  weekday.format(day),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: i == 6 ? Colors.white : Palette.textMuted,
                    fontWeight: i == 6 ? FontWeight.w700 : FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _TopBook extends ConsumerWidget {
  const _TopBook({required this.item, required this.max});
  final ({String id, String title, String? author, double seconds}) item;
  final double max;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = Theme.of(context).colorScheme.primary;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => context.push('/audiobooks/item/${item.id}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 52,
              child: NetworkCover(
                url: ref.watch(apiProvider).absUrl('items/${item.id}/cover', {'width': '200'}),
                icon: Icons.headphones,
                radius: 6,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  if (item.author != null)
                    Text(
                      item.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Palette.textMuted, fontSize: 12.5),
                    ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: max <= 0 ? 0 : item.seconds / max,
                      minHeight: 3,
                      color: accent,
                      backgroundColor: Colors.white10,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(statTime(context.l10n, item.seconds), style: const TextStyle(color: Palette.textMuted, fontSize: 13)),
          ],
        ),
      ),
    );
  }
}
