import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'media_sections.dart';
import 'session.dart';

String formatEpisodeDate(DateTime date, String locale) => DateFormat.yMMMEd(locale).format(date);

class Podcast {
  const Podcast({
    required this.id,
    required this.feedUrl,
    required this.title,
    this.author,
    this.description,
    this.imageUrl,
    this.subscribed = false,
    this.unplayedCount = 0,
    this.episodes = const [],
  });

  final String id;
  final String feedUrl;
  final String title;
  final String? author;
  final String? description;
  final String? imageUrl;
  final bool subscribed;
  final int unplayedCount;
  final List<PodcastEpisode> episodes;

  factory Podcast.fromJson(Map<String, dynamic> j) => Podcast(
    id: j['id'],
    feedUrl: j['feed_url'],
    title: j['title'],
    author: j['author'],
    description: j['description'],
    imageUrl: j['image_url'],
    subscribed: j['subscribed'] ?? false,
    unplayedCount: j['unplayed_count'] ?? 0,
    episodes: [for (final e in j['episodes'] ?? const []) PodcastEpisode.fromJson(e)],
  );
}

class PodcastEpisode {
  const PodcastEpisode({
    required this.id,
    required this.podcastId,
    required this.title,
    required this.podcastTitle,
    this.description,
    this.imageUrl,
    this.podcastImageUrl,
    this.publishedAt,
    this.durationSeconds,
    this.positionSeconds = 0,
    this.completed = false,
  });

  final String id;
  final String podcastId;
  final String title;
  final String podcastTitle;
  final String? description;
  final String? imageUrl;
  final String? podcastImageUrl;
  final DateTime? publishedAt;
  final double? durationSeconds;
  final double positionSeconds;
  final bool completed;
  String? get coverUrl => imageUrl ?? podcastImageUrl;

  factory PodcastEpisode.fromJson(Map<String, dynamic> j) => PodcastEpisode(
    id: j['id'],
    podcastId: j['podcast_id'],
    title: j['title'],
    podcastTitle: j['podcast_title'],
    description: j['description'],
    imageUrl: j['image_url'],
    podcastImageUrl: j['podcast_image_url'],
    publishedAt: DateTime.tryParse(j['published_at'] ?? ''),
    durationSeconds: (j['duration_seconds'] as num?)?.toDouble(),
    positionSeconds: (j['position_seconds'] as num?)?.toDouble() ?? 0,
    completed: j['completed'] ?? false,
  );
}

class PodcastSearchResult {
  const PodcastSearchResult({
    required this.feedUrl,
    required this.title,
    this.itunesId,
    this.author,
    this.imageUrl,
    this.source,
  });

  final String feedUrl;
  final String title;
  final int? itunesId;
  final String? author;
  final String? imageUrl;
  final String? source;

  factory PodcastSearchResult.fromJson(Map<String, dynamic> j) =>
      PodcastSearchResult(
        feedUrl: j['feed_url'],
        title: j['title'],
        itunesId: (j['itunes_id'] as num?)?.toInt(),
        author: j['author'],
        imageUrl: j['image_url'],
        source: j['source'],
      );
}

class PodcastGenre {
  const PodcastGenre({required this.id, required this.name});

  final int id;
  final String name;

  factory PodcastGenre.fromJson(Map<String, dynamic> j) => PodcastGenre(id: j['id'], name: j['name']);
}

class PodcastSection {
  const PodcastSection({required this.id, required this.title, required this.items});

  final String id;
  final String title;
  final List<PodcastSearchResult> items;

  factory PodcastSection.fromJson(Map<String, dynamic> j) => PodcastSection(
    id: j['id'],
    title: j['title'],
    items: [for (final item in j['items'] ?? const []) PodcastSearchResult.fromJson(item)],
  );
}

class PodcastDiscover {
  const PodcastDiscover({required this.genres, required this.sections});

  final List<PodcastGenre> genres;
  final List<PodcastSection> sections;

  factory PodcastDiscover.fromJson(Map<String, dynamic> j) => PodcastDiscover(
    genres: [for (final genre in j['genres'] ?? const []) PodcastGenre.fromJson(genre)],
    sections: [for (final section in j['sections'] ?? const []) PodcastSection.fromJson(section)],
  );
}

final podcastsVisibleProvider = Provider<bool>(
  (ref) => !ref.watch(hiddenMediaSectionsProvider).contains(MediaSection.podcasts),
);
final podcastSubscriptionsProvider = FutureProvider.autoDispose<List<Podcast>>(
  (ref) => ref.watch(apiProvider).podcastSubscriptions(),
);
final podcastContinueProvider = FutureProvider.autoDispose<List<PodcastEpisode>>(
  (ref) => ref.watch(apiProvider).podcastContinue(),
);
final podcastLatestProvider = FutureProvider.autoDispose<List<PodcastEpisode>>(
  (ref) => ref.watch(apiProvider).podcastLatest(),
);
final podcastDiscoverProvider = FutureProvider.autoDispose<PodcastDiscover>(
  (ref) => ref.watch(apiProvider).podcastDiscover(),
);
final podcastGenreProvider = FutureProvider.autoDispose.family<List<PodcastSearchResult>, int>(
  (ref, id) => ref.watch(apiProvider).podcastGenre(id),
);
final podcastProvider = FutureProvider.autoDispose.family<Podcast, String>(
  (ref, id) => ref.watch(apiProvider).podcast(id),
);
final podcastSearchProvider = FutureProvider.autoDispose.family<List<PodcastSearchResult>, String>(
  (ref, query) => ref.watch(apiProvider).podcastSearch(query),
);
