import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  factory AbsItem.fromJson(Map<String, dynamic> j) {
    final media = (j['media'] as Map?)?.cast<String, dynamic>() ?? const {};
    final meta = (media['metadata'] as Map?)?.cast<String, dynamic>() ?? const {};
    String? names(Object? list) {
      if (list is! List || list.isEmpty) return null;
      return list.map((e) => e is Map ? e['name'] : '$e').join(', ');
    }

    final progress = j['userMediaProgress'] ?? j['mediaProgress'];
    return AbsItem(
      id: j['id'],
      title: meta['title'] ?? 'Unbekannt',
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
        AbsShelf(id: s['id'], label: s['label'] ?? '', items: [for (final e in s['entities']) AbsItem.fromJson(e)]),
  ];
});

final absItemsProvider = FutureProvider.autoDispose.family<List<AbsItem>, String>((ref, libraryId) async {
  final j = await ref.watch(apiProvider).absGet('libraries/$libraryId/items', {
    'limit': 500,
    'page': 0,
    'sort': 'media.metadata.title',
    'minified': 1,
  });
  return [for (final i in j['results']) AbsItem.fromJson(i)];
});

final absItemProvider = FutureProvider.autoDispose.family<AbsItem, String>((ref, id) async {
  final j = await ref.watch(apiProvider).absGet('items/$id', {'expanded': 1, 'include': 'progress'});
  return AbsItem.fromJson(j);
});

final absSearchProvider = FutureProvider.autoDispose.family<List<AbsItem>, (String, String)>((ref, key) async {
  final j = await ref.watch(apiProvider).absGet('libraries/${key.$1}/search', {'q': key.$2, 'limit': 30});
  return [for (final b in (j['book'] as List? ?? const [])) AbsItem.fromJson(b['libraryItem'])];
});
