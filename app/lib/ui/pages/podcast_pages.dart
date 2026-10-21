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

class PodcastActions extends ConsumerWidget {
  const PodcastActions({super.key, this.search = true});
  final bool search;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (search)
        IconButton(
          tooltip: context.l10n.podcastsSearch,
          icon: const Icon(Icons.search),
          onPressed: () => context.push('/podcasts/search'),
        ),
      IconButton(
        tooltip: context.l10n.podcastsAddRss,
        icon: const Icon(Icons.add_link),
        onPressed: () async {
          final url = await promptText(context, context.l10n.podcastsAddRss, context.l10n.podcastsRssUrl);
          if (url == null || url.trim().isEmpty || !context.mounted) return;
          final podcast = await _subscribe(context, ref, url.trim());
          if (podcast != null && context.mounted) context.push('/podcasts/${podcast.id}');
        },
      ),
    ],
  );
}

class PodcastsPage extends ConsumerWidget {
  const PodcastsPage({super.key, this.embedded = false});
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final subscriptions = ref.watch(podcastSubscriptionsProvider);
    final continued = ref.watch(podcastContinueProvider);
    final body = RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(podcastSubscriptionsProvider);
        ref.invalidate(podcastContinueProvider);
        await Future.wait([ref.read(podcastSubscriptionsProvider.future), ref.read(podcastContinueProvider.future)]);
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 140),
        children: [
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
                      SizedBox(
                        height: 270,
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
                                    _EpisodeProgress(episode: episode),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 24),
                    ],
                  ),
          ),
          Text(context.l10n.podcastsSubscriptions, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 16),
          AsyncBody(
            value: subscriptions,
            onRetry: () => ref.invalidate(podcastSubscriptionsProvider),
            builder: (podcasts) => podcasts.isEmpty
                ? Padding(padding: const EdgeInsets.all(24), child: Text(context.l10n.podcastsEmpty))
                : GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 210,
                      mainAxisExtent: 280,
                      crossAxisSpacing: 16,
                      mainAxisSpacing: 16,
                    ),
                    itemCount: podcasts.length,
                    itemBuilder: (_, i) {
                      final podcast = podcasts[i];
                      return InkWell(
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
                      );
                    },
                  ),
          ),
        ],
      ),
    );
    if (embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.navPodcasts), actions: const [PodcastActions()]),
      body: body,
    );
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

  Future<void> _open(PodcastSearchResult result) async {
    if (_busy.contains(result.feedUrl)) return;
    setState(() => _busy.add(result.feedUrl));
    try {
      final podcast = await ref.read(apiProvider).openPodcast(result.feedUrl);
      if (mounted) context.push('/podcasts/${podcast.id}');
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy.remove(result.feedUrl));
    }
  }

  @override
  Widget build(BuildContext context) {
    final subscriptions = ref.watch(podcastSubscriptionsProvider).value ?? const <Podcast>[];
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.podcastsSearch), actions: const [PodcastActions(search: false)]),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(labelText: context.l10n.podcastsSearch, prefixIcon: const Icon(Icons.search)),
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
              child: AsyncBody(
                value: ref.watch(podcastSearchProvider(_query)),
                onRetry: () => ref.invalidate(podcastSearchProvider(_query)),
                builder: (results) => results.isEmpty
                    ? Center(child: Text(context.l10n.booksNoResults))
                    : ListView.builder(
                        padding: const EdgeInsets.only(bottom: 140),
                        itemCount: results.length,
                        itemBuilder: (_, i) {
                          final result = results[i];
                          final subscribed = subscriptions.any((p) => p.feedUrl == result.feedUrl);
                          return ListTile(
                            leading: SizedBox(
                              width: 56,
                              child: NetworkCover(url: result.imageUrl, icon: Icons.podcasts),
                            ),
                            title: Text(result.title),
                            subtitle: Text(result.author ?? ''),
                            onTap: () => _open(result),
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
