import 'dart:convert';

import '../l10n/locale.dart';
import '../l10n/l10n.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_sections.dart';
import 'session.dart';

// Audiobookshelf data as returned by its API (proxied through /api/abs/api/…).

double _num(Object? v) => (v as num?)?.toDouble() ?? 0;

class AbsStatus {
  const AbsStatus({required this.enabled, required this.url, required this.linked, this.username});
  final bool enabled;
  final String url;
  final bool linked;
  final String? username;

  factory AbsStatus.fromJson(Map<String, dynamic> j) => AbsStatus(
    enabled: j['enabled'] ?? false,
    url: j['url'] ?? '',
    linked: j['linked'] ?? false,
    username: j['username'],
  );
}

class AbsLibrary {
  const AbsLibrary({required this.id, required this.name, required this.mediaType});
  final String id;
  final String name;
  final String mediaType;

  factory AbsLibrary.fromJson(Map<String, dynamic> j) =>
      AbsLibrary(id: j['id'], name: j['name'] ?? '', mediaType: j['mediaType'] ?? 'book');
}

class AbsChapter {
  const AbsChapter({required this.start, required this.end, required this.title});
  final double start;
  final double end;
  final String title;

  factory AbsChapter.fromJson(Map<String, dynamic> j) =>
      AbsChapter(start: _num(j['start']), end: _num(j['end']), title: j['title'] ?? '');
}

class AbsProgress {
  const AbsProgress({required this.progress, required this.currentTime, required this.isFinished});
  final double progress;
  final double currentTime;
  final bool isFinished;

  factory AbsProgress.fromJson(Map<String, dynamic> j) => AbsProgress(
    progress: _num(j['progress']),
    currentTime: _num(j['currentTime']),
    isFinished: j['isFinished'] ?? false,
  );
}

class AbsItem {
  const AbsItem({
    required this.id,
    required this.title,
    required this.duration,
    this.author,
    this.narrator,
    this.series,
    this.description,
    this.year,
    this.chapters = const [],
    this.progress,
  });
  final String id;
  final String title;
  final double duration;
  final String? author;
  final String? narrator;
  final String? series;
  final String? description;
  final String? year;
  final List<AbsChapter> chapters;
  final AbsProgress? progress;

  factory AbsItem.fromJson(Map<String, dynamic> j, AppLocalizations l10n) {
    final media = (j['media'] as Map?)?.cast<String, dynamic>() ?? const {};
    final meta = (media['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    String? names(Object? list) {
      if (list is! List || list.isEmpty) return null;
      return list.map((e) => e is Map ? e['name'] : '$e').join(', ');
    }

    final progress = j['userMediaProgress'] ?? j['mediaProgress'];
    return AbsItem(
      id: j['id'],
      title: meta['title'] ?? l10n.commonUnknown,
      duration: _num(media['duration']),
      author: meta['authorName'] ?? names(meta['authors']),
      narrator: meta['narratorName'] ?? names(meta['narrators']),
      series: meta['seriesName'] ?? names(meta['series']),
      description: meta['description'],
      year: meta['publishedYear']?.toString(),
      chapters: [for (final c in (media['chapters'] as List? ?? const [])) AbsChapter.fromJson(c)],
      progress: progress is Map ? AbsProgress.fromJson(progress.cast<String, dynamic>()) : null,
    );
  }
}

class AbsShelf {
  const AbsShelf({required this.id, required this.label, required this.items});
  final String id;
  final String label;
  final List<AbsItem> items;
}

final absStatusProvider = FutureProvider<AbsStatus>(
  (ref) async => AbsStatus.fromJson(await ref.watch(apiProvider).absStatus()),
);

final audiobooksVisibleProvider = Provider<bool>(
  (ref) =>
      (ref.watch(absStatusProvider).value?.enabled ?? false) &&
      !ref.watch(hiddenMediaSectionsProvider).contains(MediaSection.audiobooks),
);

final absLibrariesProvider = FutureProvider.autoDispose<List<AbsLibrary>>((ref) async {
  final j = await ref.watch(apiProvider).absGet('libraries');
  final list = j is Map ? j['libraries'] as List : j as List;
  return [for (final l in list) AbsLibrary.fromJson(l)];
});

/// Progress of the logged-in ABS user, keyed by library item id.
final absProgressProvider = FutureProvider.autoDispose<Map<String, AbsProgress>>((ref) async {
  final j = await ref.watch(apiProvider).absGet('me');
  return {
    for (final p in (j['mediaProgress'] as List? ?? const []))
      if (p['episodeId'] == null) p['libraryItemId'] as String: AbsProgress.fromJson(p),
  };
});

/// Book shelves only (continue listening, recently added, …); series/authors shelves are skipped.
final absShelvesProvider = FutureProvider.autoDispose.family<List<AbsShelf>, String>((ref, libraryId) async {
  final j = await ref.watch(apiProvider).absGet('libraries/$libraryId/personalized', {'limit': 12});
  return [
    for (final s in j as List)
      if (s['type'] == 'book' && (s['entities'] as List).isNotEmpty)
        AbsShelf(
          id: s['id'],
          label: s['label'] ?? '',
          items: [
            for (final e in s['entities']) AbsItem.fromJson(e, lookupAppLocalizations(ref.read(appLocaleProvider))),
          ],
        ),
  ];
});

final absItemsProvider = FutureProvider.autoDispose.family<List<AbsItem>, String>((ref, libraryId) async {
  final j = await ref.watch(apiProvider).absGet('libraries/$libraryId/items', {
    'limit': 500,
    'page': 0,
    'sort': 'media.metadata.title',
    'minified': 1,
  });
  return [for (final i in j['results']) AbsItem.fromJson(i, lookupAppLocalizations(ref.read(appLocaleProvider)))];
});

final absItemProvider = FutureProvider.autoDispose.family<AbsItem, String>((ref, id) async {
  final j = await ref.watch(apiProvider).absGet('items/$id', {'expanded': 1, 'include': 'progress'});
  return AbsItem.fromJson(j, lookupAppLocalizations(ref.read(appLocaleProvider)));
});

final absSearchProvider = FutureProvider.autoDispose.family<List<AbsItem>, (String, String)>((ref, key) async {
  final j = await ref.watch(apiProvider).absGet('libraries/${key.$1}/search', {'q': key.$2, 'limit': 30});
  return [
    for (final b in (j['book'] as List? ?? const []))
      AbsItem.fromJson(b['libraryItem'], lookupAppLocalizations(ref.read(appLocaleProvider))),
  ];
});

class AbsSeries {
  const AbsSeries({required this.id, required this.name, required this.bookCount, this.coverItemId});
  final String id;
  final String name;
  final int bookCount;
  // A book of the series whose cover represents it.
  final String? coverItemId;
}

/// An author or narrator with the item filter that lists their books.
class AbsPerson {
  const AbsPerson({required this.name, required this.bookCount, required this.filter});
  final String name;
  final int bookCount;
  final String filter;
}

/// ABS item filters are `group.base64(value)` (author/series id, narrator name).
String absFilter(String group, String value) => '$group.${base64.encode(utf8.encode(value))}';

final absSeriesProvider = FutureProvider.autoDispose.family<List<AbsSeries>, String>((ref, libraryId) async {
  final j = await ref.watch(apiProvider).absGet('libraries/$libraryId/series', {'limit': 1000, 'sort': 'name'});
  return [
    for (final s in j['results'] as List)
      if ((s['books'] as List? ?? const []).isNotEmpty)
        AbsSeries(
          id: s['id'],
          name: s['name'] ?? '',
          bookCount: (s['books'] as List).length,
          coverItemId: (s['books'] as List).first['id'],
        ),
  ];
});

final absAuthorsProvider = FutureProvider.autoDispose.family<List<AbsPerson>, String>((ref, libraryId) async {
  final j = await ref.watch(apiProvider).absGet('libraries/$libraryId/authors');
  final list = [
    for (final a in j['authors'] as List)
      if ((a['numBooks'] ?? 0) > 0)
        AbsPerson(name: a['name'] ?? '', bookCount: a['numBooks'] ?? 0, filter: absFilter('authors', a['id'])),
  ];
  return list..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

final absNarratorsProvider = FutureProvider.autoDispose.family<List<AbsPerson>, String>((ref, libraryId) async {
  final j = await ref.watch(apiProvider).absGet('libraries/$libraryId/narrators');
  final list = [
    for (final n in j['narrators'] as List)
      AbsPerson(name: n['name'] ?? '', bookCount: n['numBooks'] ?? 0, filter: absFilter('narrators', n['name'] ?? '')),
  ];
  return list..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
});

/// Books matching an ABS filter; series are listed in series order, everything else by title.
final absFilteredItemsProvider = FutureProvider.autoDispose.family<List<AbsItem>, (String, String)>((ref, key) async {
  final (libraryId, filter) = key;
  final j = await ref.watch(apiProvider).absGet('libraries/$libraryId/items', {
    'filter': filter,
    'limit': 1000,
    'page': 0,
    'sort': filter.startsWith('series.') ? 'sequence' : 'media.metadata.title',
    'minified': 1,
  });
  return [for (final i in j['results']) AbsItem.fromJson(i, lookupAppLocalizations(ref.read(appLocaleProvider)))];
});

/// Listening statistics of the linked Audiobookshelf account (like Absorb's stats screen).
class AbsStats {
  const AbsStats({
    required this.total,
    required this.days,
    required this.items,
    required this.finished,
    required this.finishedThisYear,
  });

  /// Seconds listened in total.
  final double total;

  /// Seconds listened per local day ("2026-10-27").
  final Map<String, double> days;

  /// Most listened books: item id, title, author and seconds, most first.
  final List<({String id, String title, String? author, double seconds})> items;
  final int finished;
  final int finishedThisYear;

  static String dayKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  double on(DateTime day) => days[dayKey(day)] ?? 0;

  /// Seconds from [from] through [today] (both local days, inclusive).
  double between(DateTime from, DateTime today) {
    var sum = 0.0;
    for (
      var d = DateTime(from.year, from.month, from.day);
      !d.isAfter(today);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      sum += on(d);
    }
    return sum;
  }

  int get daysActive => days.values.where((s) => s > 0).length;

  /// Days in a row with listening up to today; a streak still counts while today has no listening yet.
  int currentStreak(DateTime today) {
    var day = DateTime(today.year, today.month, today.day);
    if (on(day) <= 0) day = DateTime(day.year, day.month, day.day - 1);
    var streak = 0;
    while (on(day) > 0) {
      streak++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return streak;
  }

  int get bestStreak {
    final active = [
      for (final e in days.entries)
        if (e.value > 0) DateTime.parse(e.key),
    ]..sort();
    var best = 0;
    var run = 0;
    DateTime? previous;
    for (final day in active) {
      run = previous != null && DateTime(previous.year, previous.month, previous.day + 1) == day ? run + 1 : 1;
      if (run > best) best = run;
      previous = day;
    }
    return best;
  }

  factory AbsStats.fromJson(Map<String, dynamic> stats, Map<String, dynamic> me, {DateTime? now}) {
    final year = (now ?? DateTime.now()).year;
    final progress = [
      for (final p in (me['mediaProgress'] as List? ?? const []))
        if (p['episodeId'] == null) p,
    ];
    final finished = progress.where((p) => p['isFinished'] == true).toList();
    final items = [
      for (final e in (stats['items'] as Map? ?? const {}).entries)
        (
          id: e.key as String,
          title: (e.value['mediaMetadata']?['title'] as String?) ?? '',
          author: ((e.value['mediaMetadata']?['authors'] as List?)?.firstOrNull?['name']) as String?,
          seconds: _num(e.value['timeListening']),
        ),
    ]..sort((a, b) => b.seconds.compareTo(a.seconds));
    return AbsStats(
      total: _num(stats['totalTime']),
      days: {for (final e in (stats['days'] as Map? ?? const {}).entries) e.key as String: _num(e.value)},
      items: items,
      finished: finished.length,
      finishedThisYear: finished.where((p) {
        final at = p['finishedAt'] as num?;
        return at != null && DateTime.fromMillisecondsSinceEpoch(at.toInt()).year == year;
      }).length,
    );
  }
}

final absStatsProvider = FutureProvider.autoDispose<AbsStats>((ref) async {
  final api = ref.watch(apiProvider);
  final results = await Future.wait([api.absGet('me/listening-stats'), api.absGet('me')]);
  return AbsStats.fromJson(Map<String, dynamic>.from(results[0]), Map<String, dynamic>.from(results[1]));
});
