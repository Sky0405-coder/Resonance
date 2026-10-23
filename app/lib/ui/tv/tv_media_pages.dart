import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audiobooks.dart';
import '../../core/books.dart';
import '../../core/podcasts.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../pages/audiobook_pages.dart';
import '../pages/book_pages.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import 'tv_focusable.dart';
import 'tv_shelves.dart';

enum TvMediaSection { audiobooks, podcasts }

class TvMediaPage extends ConsumerWidget {
  const TvMediaPage({super.key, this.section});

  final TvMediaSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ebooks = section == null && ref.watch(ebooksVisibleProvider);
    final audiobooks =
        (section == null || section == TvMediaSection.audiobooks) && ref.watch(audiobooksVisibleProvider);
    final podcasts = (section == null || section == TvMediaSection.podcasts) && ref.watch(podcastsVisibleProvider);
    final sections = [ebooks, audiobooks, podcasts].where((enabled) => enabled).length;
    final title = sections > 1
        ? context.l10n.navMedia
        : sections == 1
        ? audiobooks
              ? context.l10n.navAudiobooks
              : podcasts
              ? context.l10n.navPodcasts
              : context.l10n.navBooks
        : section == TvMediaSection.audiobooks
        ? context.l10n.navAudiobooks
        : section == TvMediaSection.podcasts
        ? context.l10n.navPodcasts
        : context.l10n.navMedia;

    final libraryState = audiobooks ? ref.watch(absLibrariesProvider) : null;
    final library = libraryState?.value?.where((item) => item.mediaType == 'book').firstOrNull;
    final audiobookItems = library == null ? null : ref.watch(absItemsProvider(library.id));
    final audiobookShelves = library == null ? null : ref.watch(absShelvesProvider(library.id));
    final progress = audiobooks
        ? ref.watch(absProgressProvider).value ?? const <String, AbsProgress>{}
        : const <String, AbsProgress>{};
    final subscriptions = podcasts ? ref.watch(podcastSubscriptionsProvider) : null;
    final continuedEpisodes = podcasts ? ref.watch(podcastContinueProvider) : null;
    final latestEpisodes = podcasts ? ref.watch(podcastLatestProvider) : null;
    final discover = podcasts ? ref.watch(podcastDiscoverProvider) : null;
    final books = ebooks ? ref.watch(bookLibraryProvider((q: null, author: null, series: null, sort: 'title'))) : null;

    final shelves = <TvShelfData>[];
    if (audiobooks || podcasts) {
      final continueCards = <TvCardData>[
        if (audiobooks && audiobookItems?.value != null)
          for (final item in audiobookItems!.value!)
            if ((progress[item.id] ?? item.progress) case final p? when p.progress > 0 && !p.isFinished)
              _audiobookCard(context, ref, item, p),
        if (podcasts)
          for (final episode in continuedEpisodes?.value ?? const <PodcastEpisode>[])
            _episodeCard(context, ref, episode),
      ];
      if (continueCards.isNotEmpty) {
        shelves.add(TvShelfData(context.l10n.podcastsContinue, continueCards.take(20).toList()));
      }
    }

    if (audiobooks && audiobookItems?.value != null) {
      final personalized = audiobookShelves?.value ?? const <AbsShelf>[];
      if (personalized.isNotEmpty) {
        for (final shelf in personalized.take(4)) {
          shelves.add(
            TvShelfData(shelf.label, [
              for (final item in shelf.items) _audiobookCard(context, ref, item, progress[item.id] ?? item.progress),
            ]),
          );
        }
      } else {
        shelves.add(
          TvShelfData(context.l10n.navAudiobooks, [
            for (final item in audiobookItems!.value!)
              _audiobookCard(context, ref, item, progress[item.id] ?? item.progress),
          ]),
        );
      }
    }

    if (podcasts) {
      final subscribed = subscriptions?.value ?? const <Podcast>[];
      if (subscribed.isNotEmpty) {
        shelves.add(
          TvShelfData(context.l10n.podcastsYourPodcasts, [
            for (final podcast in subscribed) _podcastCard(context, podcast),
          ]),
        );
      }
      final latest = latestEpisodes?.value ?? const <PodcastEpisode>[];
      if (latest.isNotEmpty) {
        shelves.add(
          TvShelfData(context.l10n.podcastsNewEpisodes, [
            for (final episode in latest) _episodeCard(context, ref, episode),
          ]),
        );
      }
      for (final discoverShelf in discover?.value?.sections ?? const <PodcastSection>[]) {
        if (discoverShelf.items.isEmpty) continue;
        shelves.add(
          TvShelfData(discoverShelf.title, [
            for (final result in discoverShelf.items) _discoverCard(context, ref, result),
          ]),
        );
      }
    }

    if (ebooks) {
      final libraryBooks = books?.value ?? const <Book>[];
      if (libraryBooks.isNotEmpty) {
        shelves.add(
          TvShelfData(context.l10n.booksEbooks, [
            for (final book in libraryBooks.take(40))
              TvCardData(
                title: book.title,
                subtitle: book.authorText,
                image: BookCover(bookId: book.id),
                onActivate: () => context.push('/books/item/${book.id}'),
              ),
          ]),
        );
      }
    }

    return TvShelves(
      title: title,
      leading: podcasts
          ? FittedBox(
              alignment: Alignment.centerLeft,
              fit: BoxFit.scaleDown,
              child: TvButton(
                icon: Icons.search,
                label: context.l10n.podcastsSearch,
                autofocus: true,
                onPressed: () => context.push('/podcasts/search'),
              ),
            )
          : null,
      shelves: shelves,
    );
  }
}

TvCardData _audiobookCard(BuildContext context, WidgetRef ref, AbsItem item, AbsProgress? progress) => TvCardData(
  title: item.title,
  subtitle: item.author,
  image: Stack(
    fit: StackFit.expand,
    children: [
      NetworkCover(
        url: ref.watch(apiProvider).absUrl('items/${item.id}/cover', {'width': '400'}),
        icon: Icons.headphones,
      ),
      if (progress != null && progress.progress > 0 && !progress.isFinished)
        Align(
          alignment: Alignment.bottomCenter,
          child: LinearProgressIndicator(value: progress.progress, minHeight: 5),
        ),
    ],
  ),
  onActivate: () => context.push('/audiobooks/item/${item.id}'),
);

TvCardData _podcastCard(BuildContext context, Podcast podcast) => TvCardData(
  title: podcast.title,
  subtitle: podcast.author,
  image: NetworkCover(url: podcast.imageUrl, icon: Icons.podcasts),
  onActivate: () => context.push('/podcasts/${podcast.id}'),
);

TvCardData _episodeCard(BuildContext context, WidgetRef ref, PodcastEpisode episode) => TvCardData(
  title: episode.title,
  subtitle: episode.podcastTitle,
  image: NetworkCover(url: episode.podcastImageUrl, icon: Icons.podcasts),
  onActivate: () => _playEpisode(context, ref, episode),
);

TvCardData _discoverCard(BuildContext context, WidgetRef ref, PodcastSearchResult result) => TvCardData(
  title: result.title,
  subtitle: result.author,
  image: NetworkCover(url: result.imageUrl, icon: Icons.podcasts),
  onActivate: () async {
    try {
      final podcast = await ref.read(apiProvider).openPodcast(result.feedUrl);
      if (context.mounted) context.push('/podcasts/${podcast.id}');
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  },
);

Future<void> _playEpisode(BuildContext context, WidgetRef ref, PodcastEpisode episode) async {
  try {
    await ref.read(playerProvider.notifier).playEpisode(episode);
    if (context.mounted) context.push('/now-playing');
  } catch (error) {
    if (context.mounted) showError(context, error);
  }
}

String _bookProgressText(BuildContext context, AbsItem item) {
  final progress = item.progress;
  if (progress == null) return formatBookDuration(context.l10n, item.duration);
  if (progress.isFinished) return context.l10n.audiobooksFinished;
  if (progress.currentTime <= 0) return formatBookDuration(context.l10n, item.duration);
  final remaining = (item.duration - progress.currentTime).clamp(0, double.infinity).toDouble();
  return context.l10n.audiobooksTimeRemaining(formatBookDuration(context.l10n, remaining));
}

class TvAudiobookPage extends ConsumerWidget {
  const TvAudiobookPage({super.key, required this.id});

  final String id;

  Future<void> _play(BuildContext context, WidgetRef ref, AbsItem item, {double? startAt}) async {
    try {
      await ref.read(playerProvider.notifier).playBook(item, startAt: startAt);
      if (context.mounted) context.push('/now-playing');
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) => TvAsync(
    value: ref.watch(absItemProvider(id)),
    onRetry: () => ref.invalidate(absItemProvider(id)),
    builder: (item) {
      final progress = item.progress;
      final canResume = (progress?.currentTime ?? 0) > 0 && !(progress?.isFinished ?? false);
      return SingleChildScrollView(
        padding: const EdgeInsets.all(36),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 220,
                  height: 220,
                  child: NetworkCover(
                    url: ref.watch(apiProvider).absUrl('items/${item.id}/cover', {'width': '600'}),
                    icon: Icons.headphones,
                  ),
                ),
                const SizedBox(width: 32),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.title, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 14),
                      if (item.author != null) Text(item.author!, style: const TextStyle(fontSize: 22)),
                      if (item.narrator != null)
                        Text(context.l10n.audiobooksNarrator(item.narrator!), style: const TextStyle(fontSize: 20)),
                      const SizedBox(height: 8),
                      Text(formatBookDuration(context.l10n, item.duration)),
                      if (progress != null && (progress.currentTime > 0 || progress.isFinished))
                        Text(_bookProgressText(context, item), style: const TextStyle(color: Palette.textMuted)),
                      const SizedBox(height: 20),
                      Wrap(
                        spacing: 16,
                        children: [
                          TvButton(
                            icon: Icons.play_arrow,
                            label: canResume ? context.l10n.audiobooksResume : context.l10n.tvPlay,
                            autofocus: true,
                            onPressed: () => _play(context, ref, item),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (item.description != null && item.description!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 28),
                child: Text(
                  item.description!
                      .replaceAll(RegExp(r'<br\s*/?>|</p>'), '\n')
                      .replaceAll(RegExp(r'<[^>]+>'), '')
                      .trim(),
                  style: const TextStyle(color: Palette.textMuted),
                ),
              ),
            if (item.chapters.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 32, bottom: 12),
                child: Text(context.l10n.audiobooksChapters, style: const TextStyle(fontSize: 26)),
              ),
              for (final (index, chapter) in item.chapters.indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TvFocusable(
                    focusScale: 1.015,
                    onActivate: () => _play(context, ref, item, startAt: chapter.start),
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 48,
                            child: Text('${index + 1}', style: const TextStyle(color: Palette.textMuted)),
                          ),
                          Expanded(child: Text(chapter.title)),
                          Text(formatBookDuration(context.l10n, chapter.end - chapter.start)),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ],
        ),
      );
    },
  );
}

class TvPodcastPage extends ConsumerStatefulWidget {
  const TvPodcastPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<TvPodcastPage> createState() => _TvPodcastPageState();
}

class _TvPodcastPageState extends ConsumerState<TvPodcastPage> {
  bool _busy = false;

  Future<void> _toggle(Podcast podcast) async {
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (podcast.subscribed) {
        await api.unsubscribePodcast(podcast.id);
      } else {
        await api.subscribePodcast(podcast.feedUrl);
      }
      ref.invalidate(podcastSubscriptionsProvider);
      ref.invalidate(podcastDiscoverProvider);
      ref.invalidate(podcastLatestProvider);
      ref.invalidate(podcastProvider(podcast.id));
    } catch (error) {
      if (mounted) showError(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => TvAsync(
    value: ref.watch(podcastProvider(widget.id)),
    onRetry: () => ref.invalidate(podcastProvider(widget.id)),
    builder: (podcast) => SingleChildScrollView(
      padding: const EdgeInsets.all(36),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 220,
                height: 220,
                child: NetworkCover(url: podcast.imageUrl, icon: Icons.podcasts),
              ),
              const SizedBox(width: 32),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(podcast.title, style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800)),
                    if (podcast.author != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(podcast.author!, style: const TextStyle(color: Palette.textMuted, fontSize: 22)),
                      ),
                    const SizedBox(height: 20),
                    TvButton(
                      icon: podcast.subscribed ? Icons.notifications_off_outlined : Icons.add,
                      label: podcast.subscribed ? context.l10n.podcastsUnsubscribe : context.l10n.podcastsSubscribe,
                      autofocus: true,
                      onPressed: _busy ? null : () => _toggle(podcast),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 32, bottom: 12),
            child: Text(context.l10n.podcastsEpisodes, style: const TextStyle(fontSize: 26)),
          ),
          for (final (index, episode) in podcast.episodes.indexed) _TvEpisodeRow(index: index, episode: episode),
        ],
      ),
    ),
  );
}

class _TvEpisodeRow extends ConsumerWidget {
  const _TvEpisodeRow({required this.index, required this.episode});

  final int index;
  final PodcastEpisode episode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = episode.publishedAt;
    final duration = episode.durationSeconds;
    final partiallyPlayed =
        !episode.completed &&
        duration != null &&
        duration > 0 &&
        episode.positionSeconds > 0 &&
        episode.positionSeconds < duration;
    final metadata = [
      if (date != null) formatEpisodeDate(date.toLocal(), Localizations.localeOf(context).toString()),
      if (duration != null) formatLongDuration(context.l10n, duration),
    ].join(' • ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TvFocusable(
        focusScale: 1.015,
        onActivate: () => _playEpisode(context, ref, episode),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Text('${index + 1}', style: const TextStyle(color: Palette.textMuted)),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(episode.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    if (metadata.isNotEmpty)
                      Text(metadata, style: const TextStyle(color: Palette.textMuted, fontSize: 18)),
                    if (partiallyPlayed)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: LinearProgressIndicator(value: episode.positionSeconds / duration),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Icon(episode.completed ? Icons.check : Icons.play_arrow),
            ],
          ),
        ),
      ),
    );
  }
}

class TvPodcastSearchPage extends ConsumerStatefulWidget {
  const TvPodcastSearchPage({super.key});

  @override
  ConsumerState<TvPodcastSearchPage> createState() => _TvPodcastSearchPageState();
}

class _TvPodcastSearchPageState extends ConsumerState<TvPodcastSearchPage> {
  final _text = TextEditingController();
  final _field = FocusNode();
  Timer? _debounce;
  String _query = '';

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (_field.hasFocus && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _field.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _debounce?.cancel();
    _text.dispose();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(32),
        child: TvFocusable(
          focusScale: 1.015,
          skipTraversal: true,
          descendantsAreFocusable: true,
          onActivate: () {
            _field.requestFocus();
            SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          },
          child: TextField(
            controller: _text,
            focusNode: _field,
            autofocus: true,
            style: const TextStyle(fontSize: 28),
            decoration: searchDecoration(context.l10n.podcastsSearchHint),
            textInputAction: TextInputAction.search,
            onChanged: (value) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () {
                if (mounted) setState(() => _query = value.trim());
              });
            },
          ),
        ),
      ),
      Expanded(
        child: _query.isEmpty
            ? const SizedBox.shrink()
            : TvAsync(
                value: ref.watch(podcastSearchProvider(_query)),
                onRetry: () => ref.invalidate(podcastSearchProvider(_query)),
                builder: (results) => TvShelves(
                  title: context.l10n.podcastsSearch,
                  shelves: [
                    TvShelfData(context.l10n.navPodcasts, [
                      for (final result in results)
                        TvCardData(
                          title: result.title,
                          subtitle: result.author,
                          image: NetworkCover(url: result.imageUrl, icon: Icons.podcasts),
                          onActivate: () async {
                            try {
                              final podcast = await ref.read(apiProvider).openPodcast(result.feedUrl);
                              if (context.mounted) context.push('/podcasts/${podcast.id}');
                            } catch (error) {
                              if (context.mounted) showError(context, error);
                            }
                          },
                        ),
                    ]),
                  ],
                ),
              ),
      ),
    ],
  );
}
