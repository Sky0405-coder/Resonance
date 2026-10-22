import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/podcasts.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../widgets/catalog.dart';
import '../widgets/track_list.dart';
import '../widgets/common.dart';

void _changed(WidgetRef ref, String id) {
  ref.invalidate(podcastSubscriptionsProvider);
  ref.invalidate(podcastDiscoverProvider);
  ref.invalidate(podcastLatestProvider);
  ref.invalidate(podcastProvider(id));
}

Future<Podcast?> _subscribe(BuildContext context, WidgetRef ref, String feedUrl) async {
  try {
    final podcast = await ref.read(apiProvider).subscribePodcast(feedUrl);
    _changed(ref, podcast.id);
    return podcast;
  } catch (e) {
    if (context.mounted) showError(context, e);
    return null;
  }
}

Future<void> _playEpisode(BuildContext context, WidgetRef ref, PodcastEpisode episode) async {
  try {
    await ref.read(playerProvider.notifier).playEpisode(episode);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> _addRss(BuildContext context, WidgetRef ref) async {
  final url = await promptText(context, context.l10n.podcastsAddRss, context.l10n.podcastsRssUrl);
  if (url == null || url.trim().isEmpty || !context.mounted) return;
  final podcast = await _subscribe(context, ref, url.trim());
  if (podcast != null && context.mounted) context.push('/podcasts/${podcast.id}');
}

Future<void> _openResult(BuildContext context, WidgetRef ref, PodcastSearchResult result) async {
  try {
    final podcast = await ref.read(apiProvider).openPodcast(result.feedUrl);
    if (context.mounted) context.push('/podcasts/${podcast.id}');
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

bool _isFeedUrl(String value) {
  final lower = value.toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

Widget _episodeShelf(BuildContext context, WidgetRef ref, List<PodcastEpisode> episodes, {required bool progress}) =>
    SizedBox(
      height: progress ? 270 : 248,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: episodes.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (_, i) {
          final episode = episodes[i];
          return SizedBox(
            width: 160,
            child: InkWell(
              onTap: () => _playEpisode(context, ref, episode),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NetworkCover(url: episode.coverUrl, icon: Icons.podcasts),
                  const SizedBox(height: 8),
                  Text(episode.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    episode.podcastTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Palette.textMuted),
                  ),
                  if (progress) _EpisodeProgress(episode: episode),
                ],
              ),
            ),
          );
        },
      ),
    );

Widget _resultShelf(BuildContext context, WidgetRef ref, PodcastSection section) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(section.title, style: Theme.of(context).textTheme.titleLarge),
    const SizedBox(height: 12),
    SizedBox(
      height: 220,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: section.items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 16),
        itemBuilder: (_, i) {
          final result = section.items[i];
          return SizedBox(
            width: 140,
            child: InkWell(
              onTap: () => _openResult(context, ref, result),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NetworkCover(url: result.imageUrl, icon: Icons.podcasts),
                  const SizedBox(height: 8),
                  Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(
                    result.author ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Palette.textMuted),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ),
    const SizedBox(height: 24),
  ],
);

Widget _subscriptionShelf(BuildContext context, List<Podcast> podcasts) => SizedBox(
  height: 196,
  child: ListView.separated(
    scrollDirection: Axis.horizontal,
    itemCount: podcasts.length,
    separatorBuilder: (_, _) => const SizedBox(width: 16),
    itemBuilder: (_, i) {
      final podcast = podcasts[i];
      return SizedBox(
        width: 140,
        child: Builder(
          builder: (context) => InkWell(
            onTap: () => context.push('/podcasts/${podcast.id}'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Badge(
                  label: Text('${podcast.unplayedCount}'),
                  isLabelVisible: podcast.unplayedCount > 0,
                  child: NetworkCover(url: podcast.imageUrl, icon: Icons.podcasts),
                ),
                const SizedBox(height: 8),
                Text(podcast.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ),
      );
    },
  ),
);

class PodcastsPage extends ConsumerWidget {
  const PodcastsPage({super.key, this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscriptions = ref.watch(podcastSubscriptionsProvider);
    final continued = ref.watch(podcastContinueProvider);
    final latest = ref.watch(podcastLatestProvider).value ?? const <PodcastEpisode>[];
    final discoverState = ref.watch(podcastDiscoverProvider);
    final discover = discoverState.isLoading ? null : discoverState.value;
    final body = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(podcastSubscriptionsProvider);
        ref.invalidate(podcastContinueProvider);
        ref.invalidate(podcastLatestProvider);
        ref.invalidate(podcastDiscoverProvider);
        await Future.wait<Object?>([
          ref.read(podcastSubscriptionsProvider.future),
          ref.read(podcastContinueProvider.future),
          ref.read(podcastLatestProvider.future),
          ref.read(podcastDiscoverProvider.future),
        ]).catchError((_) => <Object?>[]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 140),
        children: [
          TextField(
            readOnly: true,
            // Only opens the search page; never shows a focus outline when coming back.
            canRequestFocus: false,
            onTap: () => context.push('/podcasts/search'),
            decoration: searchDecoration(context.l10n.podcastsSearchHint),
          ),
          const SizedBox(height: 24),
          AsyncBody(
            value: continued,
            onRetry: () => ref.invalidate(podcastContinueProvider),
            builder: (episodes) => episodes.isEmpty
                ? const SizedBox.shrink()
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(context.l10n.podcastsContinue, style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 12),
                      _episodeShelf(context, ref, episodes, progress: true),
                      const SizedBox(height: 24),
                    ],
                  ),
          ),
          if (latest.isNotEmpty) ...[
            Text(context.l10n.podcastsNewEpisodes, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            _episodeShelf(context, ref, latest, progress: false),
            const SizedBox(height: 24),
          ],
          if ((subscriptions.value ?? const <Podcast>[]).isNotEmpty) ...[
            Text(context.l10n.podcastsYourPodcasts, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            _subscriptionShelf(context, subscriptions.value!),
            const SizedBox(height: 24),
          ],
          if (discover != null) ...[
            Text(context.l10n.podcastsCategories, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final genre in discover.genres)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        label: Text(genre.name),
                        onPressed: () => context.push('/podcasts/genre/${genre.id}', extra: genre.name),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            for (final section in discover.sections)
              if (section.items.isNotEmpty) _resultShelf(context, ref, section),
          ],
        ],
      ),
    );
    if (embedded) return body;
    return Scaffold(appBar: AppBar(title: Text(context.l10n.navPodcasts)), body: body);
  }
}

class PodcastSearchPage extends ConsumerStatefulWidget {
  const PodcastSearchPage({super.key});
  @override
  ConsumerState<PodcastSearchPage> createState() => _PodcastSearchPageState();
}

class _PodcastSearchPageState extends ConsumerState<PodcastSearchPage> {
  final _controller = TextEditingController();
  final _busy = <String>{};
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _addFeed(String feedUrl) async {
    if (_busy.contains(feedUrl)) return;
    setState(() => _busy.add(feedUrl));
    final podcast = await _subscribe(context, ref, feedUrl);
    if (mounted) {
      setState(() => _busy.remove(feedUrl));
      if (podcast != null) context.push('/podcasts/${podcast.id}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final subscriptions = ref.watch(podcastSubscriptionsProvider).value ?? const <Podcast>[];
    final feedQuery = _isFeedUrl(_query);
    final results = _query.isNotEmpty && !feedQuery ? ref.watch(podcastSearchProvider(_query)) : null;
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.podcastsSearch),
        actions: [
          IconButton(
            tooltip: context.l10n.podcastsAddRss,
            icon: const Icon(Icons.add_link),
            onPressed: () => _addRss(context, ref),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: searchDecoration(context.l10n.podcastsSearchHint),
              onChanged: (value) {
                _debounce?.cancel();
                _debounce = Timer(const Duration(milliseconds: 350), () {
                  if (mounted) setState(() => _query = value.trim());
                });
              },
            ),
          ),
          if (_query.isNotEmpty)
            Expanded(
              child: feedQuery
                  ? ListView(
                      padding: const EdgeInsets.only(bottom: 140),
                      children: [
                        ListTile(
                          leading: const Icon(Icons.rss_feed),
                          title: Text(context.l10n.podcastsAddFeedByUrl),
                          subtitle: Text(_query),
                          onTap: () => _addFeed(_query),
                        ),
                      ],
                    )
                  : AsyncBody(
                      value: results!,
                      onRetry: () => ref.invalidate(podcastSearchProvider(_query)),
                      builder: (items) => items.isEmpty
                          ? Center(
                              child: Padding(
                                padding: const EdgeInsets.all(24),
                                child: Text(context.l10n.podcastsNoResults, textAlign: TextAlign.center),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(bottom: 140),
                              itemCount: items.length,
                              itemBuilder: (_, i) {
                                final result = items[i];
                                final subscribed = subscriptions.any((p) => p.feedUrl == result.feedUrl);
                                return ListTile(
                                  leading: SizedBox(
                                    width: 56,
                                    child: NetworkCover(url: result.imageUrl, icon: Icons.podcasts),
                                  ),
                                  title: Text(result.title),
                                  subtitle: Text(result.author ?? ''),
                                  onTap: () => _openResult(context, ref, result),
                                  trailing: TextButton(
                                    onPressed: subscribed || _busy.contains(result.feedUrl)
                                        ? null
                                        : () async {
                                            setState(() => _busy.add(result.feedUrl));
                                            await _subscribe(context, ref, result.feedUrl);
                                            if (mounted) setState(() => _busy.remove(result.feedUrl));
                                          },
                                    child: Text(
                                      subscribed ? context.l10n.podcastsSubscribed : context.l10n.podcastsSubscribe,
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
            ),
        ],
      ),
    );
  }
}

class PodcastGenrePage extends ConsumerWidget {
  const PodcastGenrePage({super.key, required this.id, required this.name});

  final int id;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
    appBar: AppBar(title: Text(name)),
    body: AsyncBody(
      value: ref.watch(podcastGenreProvider(id)),
      onRetry: () => ref.invalidate(podcastGenreProvider(id)),
      builder: (items) => GridView.builder(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 140),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 210,
          mainAxisExtent: 280,
          crossAxisSpacing: 16,
          mainAxisSpacing: 16,
        ),
        itemCount: items.length,
        itemBuilder: (_, i) {
          final result = items[i];
          return InkWell(
            onTap: () => _openResult(context, ref, result),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NetworkCover(url: result.imageUrl, icon: Icons.podcasts),
                const SizedBox(height: 8),
                Text(result.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                Text(
                  result.author ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Palette.textMuted),
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}
class PodcastPage extends ConsumerStatefulWidget {
  const PodcastPage({super.key, required this.id});
  final String id;
  @override
  ConsumerState<PodcastPage> createState() => _PodcastPageState();
}

class _PodcastPageState extends ConsumerState<PodcastPage> {
  final _more = <PodcastEpisode>[];
  bool _busy = false;
  bool _loading = false;
  bool _hasMore = true;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(context.l10n.navPodcasts)),
    body: AsyncBody(
      value: ref.watch(podcastProvider(widget.id)),
      onRetry: () => ref.invalidate(podcastProvider(widget.id)),
      builder: (podcast) {
        final episodes = [...podcast.episodes, ..._more];
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 140),
          children: [
            Center(
              child: SizedBox(
                width: 220,
                child: NetworkCover(url: podcast.imageUrl, icon: Icons.podcasts),
              ),
            ),
            const SizedBox(height: 16),
            Text(podcast.title, style: Theme.of(context).textTheme.headlineMedium),
            if (podcast.author != null) Text(podcast.author!, style: const TextStyle(color: Palette.textMuted)),
            Align(
              alignment: Alignment.centerLeft,
              child: FilledButton(
                onPressed: _busy
                    ? null
                    : () async {
                        setState(() => _busy = true);
                        try {
                          final api = ref.read(apiProvider);
                          if (podcast.subscribed) {
                            await api.unsubscribePodcast(podcast.id);
                          } else {
                            await api.subscribePodcast(podcast.feedUrl);
                          }
                          _changed(ref, podcast.id);
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        } finally {
                          if (mounted) setState(() => _busy = false);
                        }
                      },
                child: Text(podcast.subscribed ? context.l10n.podcastsUnsubscribe : context.l10n.podcastsSubscribe),
              ),
            ),
            if (podcast.description?.isNotEmpty ?? false)
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(context.l10n.podcastsDescription),
                children: [Align(alignment: Alignment.centerLeft, child: Text(podcast.description!))],
              ),
            const SizedBox(height: 16),
            Text(context.l10n.podcastsEpisodes, style: Theme.of(context).textTheme.titleLarge),
            for (final episode in episodes) PodcastEpisodeTile(episode: episode),
            if (podcast.episodes.length == 50 && _hasMore)
              TextButton(
                onPressed: _loading
                    ? null
                    : () async {
                        setState(() => _loading = true);
                        try {
                          final next = await ref.read(apiProvider).podcast(widget.id, offset: episodes.length);
                          if (mounted) {
                            setState(() {
                              _more.addAll(next.episodes);
                              _hasMore = next.episodes.length == 50;
                            });
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        } finally {
                          if (mounted) setState(() => _loading = false);
                        }
                      },
                child: Text(context.l10n.podcastsLoadMore),
              ),
          ],
        );
      },
    ),
  );
}

class PodcastEpisodeTile extends ConsumerWidget {
  const PodcastEpisodeTile({super.key, required this.episode});
  final PodcastEpisode episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = episode.publishedAt;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      title: Text(episode.title),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            [
              if (date != null) MaterialLocalizations.of(context).formatMediumDate(date.toLocal()),
              if (episode.durationSeconds != null) formatLongDuration(context.l10n, episode.durationSeconds!),
            ].join(' • '),
          ),
          _EpisodeProgress(episode: episode),
        ],
      ),
      trailing: episode.completed
          ? Tooltip(message: context.l10n.podcastsCompleted, child: const Icon(Icons.check))
          : const Icon(Icons.play_arrow),
      onTap: () => _playEpisode(context, ref, episode),
    );
  }
}

class _EpisodeProgress extends StatelessWidget {
  const _EpisodeProgress({required this.episode});
  final PodcastEpisode episode;

  @override
  Widget build(BuildContext context) {
    final duration = episode.durationSeconds;
    if (episode.positionSeconds <= 0 || duration == null || duration <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: LinearProgressIndicator(value: (episode.positionSeconds / duration).clamp(0, 1)),
    );
  }
}
