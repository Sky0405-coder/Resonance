import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/podcasts.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/track_list.dart';
import '../widgets/common.dart';
import '../widgets/media_widgets.dart';

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
      height: progress ? 224 : 204,
      child: MouseDragScroll(
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: episodes.length,
          separatorBuilder: (_, _) => const SizedBox(width: 16),
          itemBuilder: (_, i) {
            final episode = episodes[i];
            return SizedBox(
              width: 124,
              child: InkWell(
                onTap: () => _playEpisode(context, ref, episode),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    NetworkCover(url: episode.coverUrl, icon: Icons.podcasts, radius: 8),
                    const SizedBox(height: 8),
                    Text(
                      episode.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                    ),
                    Text(
                      episode.podcastTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Palette.textMuted, fontSize: 12.5),
                    ),
                    if (progress) _EpisodeProgress(episode: episode),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

Widget _resultShelf(BuildContext context, WidgetRef ref, PodcastSection section) => Column(
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(section.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
    const SizedBox(height: 12),
    SizedBox(
      height: 220,
      child: MouseDragScroll(
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
    ),
    const SizedBox(height: 24),
  ],
);

Widget _subscriptionShelf(BuildContext context, List<Podcast> podcasts) => SizedBox(
  height: 196,
  child: MouseDragScroll(
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
                  Stack(
                    children: [
                      NetworkCover(url: podcast.imageUrl, icon: Icons.podcasts, radius: 10),
                      if (podcast.unplayedCount > 0)
                        Positioned(
                          top: 6,
                          right: 6,
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: Theme.of(context).colorScheme.primary,
                              borderRadius: BorderRadius.circular(10),
                              boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 6)],
                            ),
                            child: Text(
                              '${podcast.unplayedCount}',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: onColor(Theme.of(context).colorScheme.primary),
                              ),
                            ),
                          ),
                        ),
                    ],
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
        padding: const EdgeInsets.fromLTRB(0, 16, 0, 140),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              readOnly: true,
              // Only opens the search page; never shows a focus outline when coming back.
              canRequestFocus: false,
              onTap: () => context.push('/podcasts/search'),
              decoration: searchDecoration(context.l10n.podcastsSearchHint),
            ),
          ),
          AsyncBody(
            value: continued,
            onRetry: () => ref.invalidate(podcastContinueProvider),
            builder: (episodes) {
              if (episodes.isEmpty) return const SizedBox.shrink();
              final first = episodes.first;
              final duration = first.durationSeconds;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionTitle(context.l10n.podcastsContinue),
                  ContinueCard(
                    cover: NetworkCover(url: first.coverUrl, icon: Icons.podcasts, radius: 0),
                    kicker: first.podcastTitle,
                    title: first.title,
                    progress: duration == null || duration <= 0 ? 0 : first.positionSeconds / duration,
                    remaining: duration == null
                        ? null
                        : context.l10n.podcastsTimeLeft(
                            formatRemaining(context.l10n, duration - first.positionSeconds),
                          ),
                    onPlay: () => _playEpisode(context, ref, first),
                    onTap: () => showEpisodeSheet(context, ref, first),
                  ),
                  if (episodes.length > 1) ...[
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.only(left: 16),
                      child: _episodeShelf(context, ref, episodes.skip(1).toList(), progress: true),
                    ),
                  ],
                ],
              );
            },
          ),
          if (latest.isNotEmpty) ...[
            SectionTitle(context.l10n.podcastsNewEpisodes, padding: const EdgeInsets.fromLTRB(16, 28, 8, 4)),
            for (final (i, episode) in latest.take(6).indexed) ...[
              if (i > 0) const Divider(height: 1, indent: 84, endIndent: 16, color: Palette.divider),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: PodcastEpisodeTile(episode: episode, showPodcast: true),
              ),
            ],
          ],
          if ((subscriptions.value ?? const <Podcast>[]).isNotEmpty) ...[
            SectionTitle(context.l10n.podcastsYourPodcasts),
            Padding(padding: const EdgeInsets.only(left: 16), child: _subscriptionShelf(context, subscriptions.value!)),
          ],
          if (discover != null) ...[
            SectionTitle(context.l10n.podcastsCategories),
            MouseDragScroll(
              child: PillTabs(
                dense: true,
                items: [for (final genre in discover.genres) (icon: null, label: genre.name)],
                selected: -1,
                onSelected: (i) =>
                    context.push('/podcasts/genre/${discover.genres[i].id}', extra: discover.genres[i].name),
              ),
            ),
            const SizedBox(height: 24),
            for (final section in discover.sections)
              if (section.items.isNotEmpty)
                Padding(padding: const EdgeInsets.only(left: 16), child: _resultShelf(context, ref, section)),
          ],
        ],
      ),
    );
    if (embedded) return body;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.navPodcasts)),
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
  bool _descriptionOpen = false;

  Future<void> _toggleSubscription(Podcast podcast) async {
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
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _markAll(Podcast podcast, bool completed) async {
    try {
      await ref.read(apiProvider).markPodcastPlayed(podcast.id, completed: completed);
      _more.clear();
      _changed(ref, podcast.id);
      ref.invalidate(podcastContinueProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> _setRemoveAds(Podcast podcast, bool enabled) async {
    try {
      await ref.read(apiProvider).setPodcastRemoveAds(podcast.id, enabled: enabled);
      _more.clear();
      _changed(ref, podcast.id);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  void _setOrder(bool oldestFirst) {
    setState(() {
      _more.clear();
      _hasMore = true;
    });
    ref.read(podcastOldestFirstProvider(widget.id).notifier).set(oldestFirst);
  }

  Future<void> _loadMore(int loaded) async {
    setState(() => _loading = true);
    try {
      final next = await ref
          .read(apiProvider)
          .podcast(widget.id, offset: loaded, oldestFirst: ref.read(podcastOldestFirstProvider(widget.id)));
      if (mounted) {
        setState(() {
          _more.addAll(next.episodes);
          _hasMore = next.episodes.length == 50;
        });
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final oldestFirst = ref.watch(podcastOldestFirstProvider(widget.id));
    final value = ref.watch(podcastProvider(widget.id));
    final url = value.value?.imageUrl;
    final tint = url == null ? null : ref.watch(coverColorProvider(CachedNetworkImageProvider(url))).value;
    final accent = Theme.of(context).colorScheme.primary;
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(backgroundColor: Colors.transparent),
      body: TweenAnimationBuilder<Color?>(
        duration: const Duration(milliseconds: 500),
        tween: ColorTween(end: darkTint(tint ?? accent)),
        builder: (context, color, child) => DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [color!, Palette.background],
              stops: const [0, 0.45],
            ),
          ),
          child: child,
        ),
        child: AsyncBody(
          value: value,
          onRetry: () => ref.invalidate(podcastProvider(widget.id)),
          builder: (podcast) {
            final episodes = [...podcast.episodes, ..._more];
            final next = episodes.where((e) => !e.completed).firstOrNull;
            return ListView(
              padding: EdgeInsets.fromLTRB(20, MediaQuery.paddingOf(context).top + kToolbarHeight, 20, kBottomInset),
              children: [
                Center(
                  child: Container(
                    width: 200,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: const [BoxShadow(color: Color(0x80000000), blurRadius: 30, offset: Offset(0, 12))],
                    ),
                    child: NetworkCover(url: podcast.imageUrl, icon: Icons.podcasts, radius: 12),
                  ),
                ),
                const SizedBox(height: 20),
                Text(
                  podcast.title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                ),
                if (podcast.author != null) ...[
                  const SizedBox(height: 2),
                  Text(podcast.author!, style: const TextStyle(color: Palette.textMuted, fontSize: 15)),
                ],
                if (podcast.episodeCount > 0) ...[
                  const SizedBox(height: 6),
                  Text(
                    context.l10n.podcastsEpisodeStats(podcast.episodeCount, podcast.completedCount),
                    style: const TextStyle(color: Palette.textMuted, fontSize: 13),
                  ),
                ],
                const SizedBox(height: 14),
                Row(
                  children: [
                    podcast.subscribed
                        ? OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
                            onPressed: _busy ? null : () => _toggleSubscription(podcast),
                            icon: const Icon(Icons.check, size: 18),
                            label: Text(context.l10n.podcastsSubscribed),
                          )
                        : FilledButton.icon(
                            style: FilledButton.styleFrom(shape: const StadiumBorder()),
                            onPressed: _busy ? null : () => _toggleSubscription(podcast),
                            icon: const Icon(Icons.add, size: 18),
                            label: Text(context.l10n.podcastsSubscribe),
                          ),
                    const SizedBox(width: 4),
                    PopupMenuButton<String>(
                      tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                      icon: const Icon(Icons.more_vert),
                      onSelected: (action) => switch (action) {
                        'played' => _markAll(podcast, true),
                        'unplayed' => _markAll(podcast, false),
                        _ => null,
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: 'played',
                          child: _MenuRow(
                            icon: const Icon(Icons.done_all),
                            label: Text(context.l10n.podcastsMarkAllPlayed),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'unplayed',
                          child: _MenuRow(
                            icon: const Icon(Icons.remove_done),
                            label: Text(context.l10n.podcastsMarkAllUnplayed),
                          ),
                        ),
                      ],
                    ),
                    const Spacer(),
                    if (next != null)
                      Tooltip(
                        message: context.l10n.podcastsPlayFirstUnplayed,
                        child: Material(
                          color: accent,
                          shape: const CircleBorder(),
                          child: InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _playEpisode(context, ref, next),
                            child: SizedBox(
                              width: 56,
                              height: 56,
                              child: Icon(Icons.play_arrow_rounded, size: 34, color: onColor(accent)),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                if (podcast.description?.isNotEmpty ?? false) ...[
                  const SizedBox(height: 12),
                  GestureDetector(
                    onTap: () => setState(() => _descriptionOpen = !_descriptionOpen),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 200),
                      alignment: Alignment.topCenter,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            podcast.description!,
                            maxLines: _descriptionOpen ? null : 3,
                            overflow: _descriptionOpen ? null : TextOverflow.ellipsis,
                            style: const TextStyle(color: Palette.textMuted, height: 1.4),
                          ),
                          Text(
                            _descriptionOpen ? context.l10n.podcastsLess : context.l10n.podcastsMore,
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (podcast.subscribed) ...[
                  const SizedBox(height: 16),
                  _RemoveAdsCard(value: podcast.removeAds, onChanged: (value) => _setRemoveAds(podcast, value)),
                ],
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.podcastsEpisodes,
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                      ),
                    ),
                    PopupMenuButton<bool>(
                      tooltip: context.l10n.podcastsSort,
                      initialValue: oldestFirst,
                      onSelected: _setOrder,
                      itemBuilder: (_) => [
                        PopupMenuItem(value: false, child: Text(context.l10n.podcastsNewestFirst)),
                        PopupMenuItem(value: true, child: Text(context.l10n.podcastsOldestFirst)),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.swap_vert, size: 18, color: Palette.textMuted),
                            const SizedBox(width: 6),
                            Text(
                              oldestFirst ? context.l10n.podcastsOldestFirst : context.l10n.podcastsNewestFirst,
                              style: const TextStyle(color: Palette.textMuted, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                for (final (i, episode) in episodes.indexed) ...[
                  if (i > 0) const Divider(height: 1, color: Palette.divider),
                  PodcastEpisodeTile(episode: episode),
                ],
                if (podcast.episodes.length == 50 && _hasMore)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Center(
                      child: OutlinedButton(
                        style: OutlinedButton.styleFrom(shape: const StadiumBorder()),
                        onPressed: _loading ? null : () => _loadMore(episodes.length),
                        child: Text(context.l10n.podcastsLoadMore),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A dark, still colorful version of a cover's color for page backgrounds.
Color darkTint(Color color) {
  final hsl = HSLColor.fromColor(color);
  return hsl.withLightness(math.min(hsl.lightness, 0.24)).withSaturation(math.min(hsl.saturation, 0.6)).toColor();
}

Future<void> setEpisodePlayed(BuildContext context, WidgetRef ref, PodcastEpisode episode, bool played) async {
  try {
    await ref
        .read(apiProvider)
        .saveEpisodeProgress(
          episode.id,
          played ? episode.durationSeconds ?? episode.positionSeconds : 0,
          completed: played,
        );
    _changed(ref, episode.podcastId);
    ref.invalidate(podcastContinueProvider);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Show notes of an episode with play and played/unplayed actions.
Future<void> showEpisodeSheet(BuildContext context, WidgetRef ref, PodcastEpisode episode) => showModalBottomSheet(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  showDragHandle: true,
  backgroundColor: const Color(0xFF202020),
  builder: (sheet) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    maxChildSize: 0.92,
    builder: (_, controller) => ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        Row(
          children: [
            SizedBox(
              width: 64,
              child: NetworkCover(url: episode.coverUrl, icon: Icons.podcasts, radius: 8),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    episode.podcastTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Palette.textMuted, fontSize: 13),
                  ),
                  Text(
                    episode.title,
                    style: Theme.of(sheet).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _EpisodeMeta(episode: episode),
        if ((episode.adsRemovedSeconds ?? 0) >= 1) ...[
          const SizedBox(height: 4),
          Text(
            context.l10n.podcastsAdsRemoved(formatRemaining(context.l10n, episode.adsRemovedSeconds!)),
            style: const TextStyle(color: Palette.textMuted, fontSize: 12.5),
          ),
        ],
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(shape: const StadiumBorder(), minimumSize: const Size(0, 48)),
                onPressed: () {
                  Navigator.pop(sheet);
                  _playEpisode(context, ref, episode);
                },
                icon: const Icon(Icons.play_arrow_rounded),
                label: Text(context.l10n.podcastsPlayEpisode),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(shape: const StadiumBorder(), minimumSize: const Size(0, 48)),
              onPressed: () {
                Navigator.pop(sheet);
                setEpisodePlayed(context, ref, episode, !episode.completed);
              },
              icon: Icon(episode.completed ? Icons.remove_done : Icons.done),
              label: Text(episode.completed ? context.l10n.podcastsMarkUnplayed : context.l10n.podcastsMarkPlayed),
            ),
          ],
        ),
        if (episode.description?.isNotEmpty ?? false) ...[
          const SizedBox(height: 20),
          Text(
            context.l10n.podcastsShowNotes,
            style: Theme.of(sheet).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          SelectableText(episode.description!, style: const TextStyle(color: Palette.textMuted, height: 1.45)),
        ],
      ],
    ),
  ),
);

/// Date and length of an episode; for started ones how much is left, for finished ones a check.
class _RemoveAdsCard extends StatelessWidget {
  const _RemoveAdsCard({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Material(
      color: value ? accent.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
          child: Row(
            children: [
              Icon(Icons.content_cut, size: 20, color: value ? accent : Palette.textMuted),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.podcastsRemoveAds, style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      context.l10n.podcastsRemoveAdsHint,
                      style: const TextStyle(color: Palette.textMuted, fontSize: 12.5, height: 1.3),
                    ),
                  ],
                ),
              ),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _EpisodeMeta extends StatelessWidget {
  const _EpisodeMeta({required this.episode});
  final PodcastEpisode episode;

  @override
  Widget build(BuildContext context) {
    final date = episode.publishedAt;
    final duration = episode.durationSeconds;
    final started = episode.positionSeconds > 0 && !episode.completed && duration != null && duration > 0;
    final accent = Theme.of(context).colorScheme.primary;
    const style = TextStyle(color: Palette.textMuted, fontSize: 12.5);
    return Row(
      children: [
        Flexible(
          child: Text(
            [
              if (date != null) formatEpisodeDate(date.toLocal(), Localizations.localeOf(context).toString()),
              if (duration != null && !started) formatLongDuration(context.l10n, duration),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        if (started) ...[
          const SizedBox(width: 10),
          SizedBox(
            width: 48,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: (episode.positionSeconds / duration).clamp(0, 1),
                minHeight: 3,
                backgroundColor: Colors.white12,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            context.l10n.podcastsTimeLeft(formatRemaining(context.l10n, duration - episode.positionSeconds)),
            style: style.copyWith(color: accent, fontWeight: FontWeight.w600),
          ),
        ],
        if ((episode.adsRemovedSeconds ?? 0) >= 1) ...[
          const SizedBox(width: 8),
          Tooltip(
            message: context.l10n.podcastsAdsRemoved(formatRemaining(context.l10n, episode.adsRemovedSeconds!)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.content_cut, size: 13, color: Palette.textMuted),
                const SizedBox(width: 3),
                Text('−${formatRemaining(context.l10n, episode.adsRemovedSeconds!)}', style: style),
              ],
            ),
          ),
        ],
        if (episode.completed) ...[
          const SizedBox(width: 8),
          Icon(Icons.check_circle, size: 14, color: accent),
          const SizedBox(width: 4),
          Text(
            context.l10n.podcastsPlayed,
            style: style.copyWith(color: accent, fontWeight: FontWeight.w600),
          ),
        ],
      ],
    );
  }
}

class PodcastEpisodeTile extends ConsumerWidget {
  const PodcastEpisodeTile({super.key, required this.episode, this.showPodcast = false});
  final PodcastEpisode episode;

  /// With the cover and podcast name, for lists mixing podcasts.
  final bool showPodcast;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accent = Theme.of(context).colorScheme.primary;
    final playing = ref.watch(playerProvider.select((p) => p.book?.episode?.id == episode.id));
    final duration = episode.durationSeconds;
    final progress = episode.completed
        ? 1.0
        : duration == null || duration <= 0
        ? 0.0
        : (episode.positionSeconds / duration).clamp(0.0, 1.0);
    return InkWell(
      onTap: () => showEpisodeSheet(context, ref, episode),
      onLongPress: () => setEpisodePlayed(context, ref, episode, !episode.completed),
      child: Opacity(
        opacity: episode.completed && !playing ? 0.55 : 1,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              if (showPodcast) ...[
                SizedBox(
                  width: 56,
                  child: NetworkCover(url: episode.coverUrl, icon: Icons.podcasts, radius: 8),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (showPodcast)
                      Text(
                        episode.podcastTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Palette.textMuted, fontSize: 12.5, fontWeight: FontWeight.w600),
                      ),
                    _EpisodeMeta(episode: episode),
                    const SizedBox(height: 4),
                    Text(
                      episode.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        color: playing ? accent : Colors.white,
                      ),
                    ),
                    if (!showPodcast && (episode.description?.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 4),
                      Text(
                        episode.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Palette.textMuted, fontSize: 13, height: 1.35),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Play button with the listened share as a ring around it.
              Tooltip(
                message: context.l10n.podcastsPlayEpisode,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _playEpisode(context, ref, episode),
                  child: SizedBox(
                    width: 44,
                    height: 44,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Positioned.fill(
                          child: CircularProgressIndicator(
                            value: progress,
                            strokeWidth: 2.5,
                            color: accent,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                        Icon(
                          playing ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
                          size: 26,
                          color: playing ? accent : Colors.white,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              PopupMenuButton<String>(
                tooltip: MaterialLocalizations.of(context).showMenuTooltip,
                icon: const Icon(Icons.more_vert, color: Palette.textMuted),
                onSelected: (action) => switch (action) {
                  'played' => setEpisodePlayed(context, ref, episode, !episode.completed),
                  'notes' => showEpisodeSheet(context, ref, episode),
                  _ => null,
                },
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'played',
                    child: _MenuRow(
                      icon: Icon(episode.completed ? Icons.remove_done : Icons.done),
                      label: Text(
                        episode.completed ? context.l10n.podcastsMarkUnplayed : context.l10n.podcastsMarkPlayed,
                      ),
                    ),
                  ),
                  PopupMenuItem(
                    value: 'notes',
                    child: _MenuRow(icon: const Icon(Icons.notes), label: Text(context.l10n.podcastsShowNotes)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: (episode.positionSeconds / duration).clamp(0, 1),
          minHeight: 3,
          backgroundColor: Colors.white12,
        ),
      ),
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});
  final Widget icon;
  final Widget label;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconTheme.merge(data: const IconThemeData(size: 20), child: icon),
      const SizedBox(width: 14),
      Flexible(child: label),
    ],
  );
}
