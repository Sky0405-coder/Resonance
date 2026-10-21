import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'media_sections.dart';
import 'session.dart';

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
  const PodcastSearchResult({required this.feedUrl, required this.title, this.author, this.imageUrl});
  final String feedUrl;
  final String title;
  final String? author;
  final String? imageUrl;

  factory PodcastSearchResult.fromJson(Map<String, dynamic> j) =>
      PodcastSearchResult(feedUrl: j['feed_url'], title: j['title'], author: j['author'], imageUrl: j['image_url']);
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
final podcastProvider = FutureProvider.autoDispose.family<Podcast, String>(
  (ref, id) => ref.watch(apiProvider).podcast(id),
);
final podcastSearchProvider = FutureProvider.autoDispose.family<List<PodcastSearchResult>, String>(
  (ref, query) => ref.watch(apiProvider).podcastSearch(query),
);
