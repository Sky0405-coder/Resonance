import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audiobooks.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';

/// "1 Std. 23 Min." / "45 Min."
String formatBookDuration(AppLocalizations l10n, double seconds) {
  final d = Duration(seconds: seconds.round());
  final h = d.inHours;
  final m = d.inMinutes % 60;
  return h > 0 ? l10n.commonDurationHoursMinutes(h, m) : l10n.commonDurationMinutes(m);
}

String _remaining(AppLocalizations l10n, AbsItem item, AbsProgress? p) {
  if (p == null || p.currentTime <= 0) return formatBookDuration(l10n, item.duration);
  if (p.isFinished) return l10n.audiobooksFinished;
  return l10n.audiobooksTimeRemaining(
    (formatBookDuration(l10n, (item.duration - p.currentTime).clamp(0, double.infinity))).toString(),
  );
}

final _selectedLibraryProvider = NotifierProvider<_SelectedLibrary, String?>(_SelectedLibrary.new);

class _SelectedLibrary extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String id) => state = id;
}

Future<void> _play(BuildContext context, WidgetRef ref, AbsItem item, {double? startAt}) async {
  try {
    await ref.read(playerProvider.notifier).playBook(item, startAt: startAt);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Bottom tab "Hörbücher": Audiobookshelf libraries of the linked account.
class AudiobooksPage extends ConsumerWidget {
  const AudiobooksPage({super.key, this.embedded = false});

  /// Shown as a tab of the books page, which already has the heading.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(absStatusProvider);
    return AsyncBody(
      value: status,
      onRetry: () => ref.invalidate(absStatusProvider),
      builder: (s) {
        if (!s.enabled) {
          return Center(
            child: Text(context.l10n.audiobooksNotConfigured, style: TextStyle(color: Palette.textMuted)),
          );
        }
        if (!s.linked) return _LoginView(status: s);
        return _LibraryView(embedded: embedded);
      },
    );
  }
}

class _LoginView extends ConsumerStatefulWidget {
  const _LoginView({required this.status});
  final AbsStatus status;

  @override
  ConsumerState<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<_LoginView> {
  final _user = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    setState(() => _busy = true);
    try {
      await ref.read(apiProvider).absLogin(_user.text.trim(), _password.text);
      ref.invalidate(absStatusProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: AutofillGroup(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Icon(Icons.headphones, size: 56),
                const SizedBox(height: 16),
                Text(
                  context.l10n.audiobooksLoginTitle,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  context.l10n.audiobooksLoginHint(
                    (widget.status.url.isEmpty ? '' : ' (${widget.status.url})').toString(),
                  ),
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Palette.textMuted),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _user,
                  autofillHints: const [AutofillHints.username],
                  decoration: InputDecoration(labelText: context.l10n.authUsername),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _password,
                  obscureText: true,
                  autofillHints: const [AutofillHints.password],
                  onSubmitted: (_) => _login(),
                  decoration: InputDecoration(labelText: context.l10n.authPassword),
                ),
                const SizedBox(height: 20),
                FilledButton(onPressed: _busy ? null : _login, child: Text(context.l10n.authSignIn)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LibraryView extends ConsumerStatefulWidget {
  const _LibraryView({required this.embedded});
  final bool embedded;

  @override
  ConsumerState<_LibraryView> createState() => _LibraryViewState();
}

enum _BooksView { library, series, authors, narrators }

class _LibraryViewState extends ConsumerState<_LibraryView> {
  final _search = TextEditingController();
  String _query = '';
  _BooksView _view = _BooksView.library;
  // Opened series / author / narrator: (title, ABS item filter).
  (String, String)? _filter;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final libraries = ref.watch(absLibrariesProvider);
    return AsyncBody(
      value: libraries,
      onRetry: () => ref.invalidate(absLibrariesProvider),
      builder: (libs) {
        final books = libs.where((l) => l.mediaType == 'book').toList();
        if (books.isEmpty) {
          return Center(
            child: Text(context.l10n.audiobooksNoLibrary, style: TextStyle(color: Palette.textMuted)),
          );
        }
        final selected = ref.watch(_selectedLibraryProvider);
        final library = books.firstWhere((l) => l.id == selected, orElse: () => books.first);
        final progress = ref.watch(absProgressProvider).value ?? const {};
        return RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(absShelvesProvider(library.id));
            ref.invalidate(absItemsProvider(library.id));
            ref.invalidate(absProgressProvider);
            ref.invalidate(absSeriesProvider(library.id));
            ref.invalidate(absAuthorsProvider(library.id));
            ref.invalidate(absNarratorsProvider(library.id));
            if (_filter != null) ref.invalidate(absFilteredItemsProvider((library.id, _filter!.$2)));
          },
          child: CustomScrollView(
            slivers: [
              if (!widget.embedded)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(16, 24 + MediaQuery.paddingOf(context).top, 8, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(context.l10n.navAudiobooks, style: Theme.of(context).textTheme.headlineMedium),
                        ),
                        const _AccountMenu(),
                      ],
                    ),
                  ),
                ),
              if (books.length > 1)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        for (final l in books)
                          ChoiceChip(
                            label: Text(l.name),
                            selected: l.id == library.id,
                            onSelected: (_) {
                              setState(() => _filter = null);
                              ref.read(_selectedLibraryProvider.notifier).select(l.id);
                            },
                          ),
                      ],
                    ),
                  ),
                ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (v) => setState(() => _query = v.trim()),
                    onChanged: (v) {
                      if (v.isEmpty) setState(() => _query = '');
                    },
                    decoration: searchDecoration(context.l10n.audiobooksSearchHint),
                  ),
                ),
              ),
              if (_query.isNotEmpty)
                _BookGrid(value: ref.watch(absSearchProvider((library.id, _query))), progress: progress)
              else ...[
                SliverToBoxAdapter(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Row(
                      children: [
                        for (final (view, label) in [
                          (_BooksView.library, context.l10n.audiobooksViewLibrary),
                          (_BooksView.series, context.l10n.audiobooksViewSeries),
                          (_BooksView.authors, context.l10n.audiobooksViewAuthors),
                          (_BooksView.narrators, context.l10n.audiobooksViewNarrators),
                        ])
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ChoiceChip(
                              label: Text(label),
                              selected: _view == view,
                              onSelected: (_) => setState(() {
                                _view = view;
                                _filter = null;
                              }),
                            ),
                          ),
                        if (widget.embedded) const _AccountMenu(),
                      ],
                    ),
                  ),
                ),
                if (_filter case (final title, final filter)) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(4, 16, 16, 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: const Icon(Icons.arrow_back),
                            onPressed: () => setState(() => _filter = null),
                          ),
                          Expanded(
                            child: Text(
                              title,
                              style: Theme.of(context).textTheme.titleLarge,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _BookGrid(value: ref.watch(absFilteredItemsProvider((library.id, filter))), progress: progress),
                ] else if (_view == _BooksView.series)
                  _SeriesGrid(
                    value: ref.watch(absSeriesProvider(library.id)),
                    onOpen: (s) => setState(() => _filter = (s.name, absFilter('series', s.id))),
                  )
                else if (_view != _BooksView.library)
                  _PersonList(
                    value: ref.watch(
                      _view == _BooksView.authors
                          ? absAuthorsProvider(library.id)
                          : absNarratorsProvider(library.id),
                    ),
                    icon: _view == _BooksView.authors ? Icons.person : Icons.record_voice_over,
                    onOpen: (p) => setState(() => _filter = (p.name, p.filter)),
                  )
                else ...[
                SliverToBoxAdapter(
                  child: ref
                      .watch(absShelvesProvider(library.id))
                      .when(
                        loading: () => const SizedBox(),
                        error: (_, _) => const SizedBox(),
                        data: (shelves) => Column(
                          children: [
                            for (final s in shelves.where((s) => s.id == 'continue-listening'))
                              Shelf(
                                title: context.l10n.audiobooksContinueListening,
                                children: [for (final b in s.items) _BookCard(item: b, progress: progress[b.id])],
                              ),
                          ],
                        ),
                      ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                    child: Text(context.l10n.audiobooksAllBooks, style: Theme.of(context).textTheme.titleLarge),
                  ),
                ),
                _BookGrid(value: ref.watch(absItemsProvider(library.id)), progress: progress),
                ],
              ],
              const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
            ],
          ),
        );
      },
    );
  }
}

/// Sign out of the linked Audiobookshelf account.
class _AccountMenu extends ConsumerWidget {
  const _AccountMenu();

  @override
  Widget build(BuildContext context, WidgetRef ref) => PopupMenuButton<String>(
    useRootNavigator: true,
    icon: const Icon(Icons.more_vert),
    onSelected: (_) async {
      await ref.read(apiProvider).absLogout();
      ref.invalidate(absStatusProvider);
    },
    itemBuilder: (_) => [
      PopupMenuItem(
        value: 'logout',
        child: Text(context.l10n.audiobooksSignOutUser((ref.read(absStatusProvider).value?.username ?? '').toString())),
      ),
    ],
  );
}

class _BookGrid extends StatelessWidget {
  const _BookGrid({required this.value, required this.progress});
  final AsyncValue<List<AbsItem>> value;
  final Map<String, AbsProgress> progress;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SliverToBoxAdapter(child: Center(child: Text('$e'))),
      data: (items) => items.isEmpty
          ? SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(
                  child: Text(context.l10n.commonNothingFound, style: TextStyle(color: Palette.textMuted)),
                ),
              ),
            )
          : SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  childAspectRatio: 0.68,
                ),
                itemCount: items.length,
                itemBuilder: (_, i) => _BookCard(item: items[i], progress: progress[items[i].id]),
              ),
            ),
    );
  }
}

Widget _sliverLoading() => const SliverToBoxAdapter(
  child: Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
  ),
);

Widget _sliverEmpty(BuildContext context) => SliverToBoxAdapter(
  child: Padding(
    padding: const EdgeInsets.all(24),
    child: Center(child: Text(context.l10n.commonNothingFound, style: TextStyle(color: Palette.textMuted))),
  ),
);

class _SeriesGrid extends ConsumerWidget {
  const _SeriesGrid({required this.value, required this.onOpen});
  final AsyncValue<List<AbsSeries>> value;
  final ValueChanged<AbsSeries> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) => value.when(
    loading: _sliverLoading,
    error: (e, _) => SliverToBoxAdapter(child: Center(child: Text('$e'))),
    data: (series) => series.isEmpty
        ? _sliverEmpty(context)
        : SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 200,
                childAspectRatio: 0.68,
              ),
              itemCount: series.length,
              itemBuilder: (_, i) {
                final s = series[i];
                return MediaCard(
                  image: NetworkCover(
                    url: s.coverItemId == null
                        ? null
                        : ref.watch(apiProvider).absUrl('items/${s.coverItemId}/cover', {'width': '400'}),
                    icon: Icons.library_books,
                  ),
                  title: s.name,
                  subtitle: context.l10n.audiobooksBookCount(s.bookCount),
                  onTap: () => onOpen(s),
                );
              },
            ),
          ),
  );
}

class _PersonList extends StatelessWidget {
  const _PersonList({required this.value, required this.icon, required this.onOpen});
  final AsyncValue<List<AbsPerson>> value;
  final IconData icon;
  final ValueChanged<AbsPerson> onOpen;

  @override
  Widget build(BuildContext context) => value.when(
    loading: _sliverLoading,
    error: (e, _) => SliverToBoxAdapter(child: Center(child: Text('$e'))),
    data: (people) => people.isEmpty
        ? _sliverEmpty(context)
        : SliverPadding(
            padding: const EdgeInsets.only(top: 8),
            sliver: SliverList.builder(
              itemCount: people.length,
              itemBuilder: (_, i) {
                final p = people[i];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xFF282828),
                    child: Icon(icon, color: Palette.textMuted),
                  ),
                  title: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(context.l10n.audiobooksBookCount(p.bookCount)),
                  onTap: () => onOpen(p),
                );
              },
            ),
          ),
  );
}

class _BookCard extends ConsumerWidget {
  const _BookCard({required this.item, this.progress});
  final AbsItem item;
  final AbsProgress? progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final p = progress ?? item.progress;
    return MediaCard(
      image: Stack(
        children: [
          NetworkCover(
            url: ref.watch(apiProvider).absUrl('items/${item.id}/cover', {'width': '400'}),
            icon: Icons.headphones,
          ),
          if (p != null && p.progress > 0 && !p.isFinished)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(value: p.progress, minHeight: 4, backgroundColor: Colors.black54),
            ),
        ],
      ),
      title: item.title,
      subtitle: [?item.author, _remaining(context.l10n, item, p)].join(' • '),
      onTap: () => context.push('/audiobooks/item/${item.id}'),
      onPlay: () => _play(context, ref, item),
    );
  }
}

/// Book detail: cover, description, resume button and chapters.
class AudiobookPage extends ConsumerWidget {
  const AudiobookPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(absItemProvider(id));
    final book = ref.watch(playerProvider.select((p) => p.book));
    final isCurrent = book?.itemId == id;
    final playing = ref.watch(playerProvider.select((p) => p.playing)) && isCurrent;
    final position = isCurrent ? ref.watch(bookPositionProvider) : null;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AsyncBody(
        value: value,
        onRetry: () => ref.invalidate(absItemProvider(id)),
        builder: (item) {
          final p = item.progress;
          final started = (p?.currentTime ?? 0) > 0 && !(p?.isFinished ?? false);
          final current = position == null
              ? null
              : item.chapters.where((c) => position >= c.start && position < c.end).firstOrNull;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: CollectionHeader(
                  image: NetworkCover(
                    url: ref.watch(apiProvider).absUrl('items/$id/cover', {'width': '600'}),
                    icon: Icons.headphones,
                  ),
                  kind: context.l10n.audiobooksBook,
                  title: item.title,
                  description: item.series,
                  meta: Text(
                    [
                      ?item.author,
                      if (item.narrator != null) context.l10n.audiobooksNarrator((item.narrator).toString()),
                      ?item.year,
                      _remaining(context.l10n, item, p),
                    ].join(' • '),
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: ActionBar(
                  playing: playing,
                  onPlay: () => isCurrent ? ref.read(playerProvider.notifier).togglePlay() : _play(context, ref, item),
                  children: [
                    if (!isCurrent && started)
                      Text(
                        context.l10n.audiobooksContinueListening,
                        style: TextStyle(color: Theme.of(context).colorScheme.primary),
                      ),
                    PopupMenuButton<String>(
                      useRootNavigator: true,
                      icon: const Icon(Icons.more_horiz, color: Palette.textMuted),
                      onSelected: (action) async {
                        try {
                          if (action == 'restart') {
                            await _play(context, ref, item, startAt: 0);
                          } else {
                            await ref.read(apiProvider).absPatch('me/progress/$id', {
                              'isFinished': action == 'finished',
                            });
                            ref.invalidate(absItemProvider(id));
                            ref.invalidate(absProgressProvider);
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'restart', child: Text(context.l10n.audiobooksStartOver)),
                        if (p?.isFinished ?? false)
                          PopupMenuItem(value: 'unfinished', child: Text(context.l10n.audiobooksMarkUnfinished))
                        else
                          PopupMenuItem(value: 'finished', child: Text(context.l10n.audiobooksMarkFinished)),
                      ],
                    ),
                  ],
                ),
              ),
              if (item.description != null && item.description!.trim().isNotEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: Text(
                      // ABS stores descriptions as simple HTML.
                      item.description!
                          .replaceAll(RegExp(r'<br\s*/?>|</p>'), '\n')
                          .replaceAll(RegExp(r'<[^>]+>'), '')
                          .trim(),
                      style: const TextStyle(color: Palette.textMuted),
                    ),
                  ),
                ),
              if (item.chapters.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
                    child: Text(context.l10n.audiobooksChapters, style: Theme.of(context).textTheme.titleLarge),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  sliver: SliverList.builder(
                    itemCount: item.chapters.length,
                    itemBuilder: (_, i) {
                      final c = item.chapters[i];
                      final active = identical(c, current) || (current != null && c.start == current.start);
                      final accent = Theme.of(context).colorScheme.primary;
                      return ListTile(
                        leading: SizedBox(
                          width: 32,
                          child: Center(
                            child: Text('${i + 1}', style: TextStyle(color: active ? accent : Palette.textMuted)),
                          ),
                        ),
                        title: Text(c.title, style: TextStyle(color: active ? accent : null)),
                        trailing: Text(
                          formatBookDuration(context.l10n, c.end - c.start),
                          style: const TextStyle(color: Palette.textMuted),
                        ),
                        onTap: () => isCurrent
                            ? ref.read(playerProvider.notifier).seekBook(c.start)
                            : _play(context, ref, item, startAt: c.start),
                      );
                    },
                  ),
                ),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
            ],
          );
        },
      ),
    );
  }
}

/// Chapter list for the playing book (now playing screen).
Future<void> showChapterSheet(BuildContext context, WidgetRef ref, BookPlayback book) => showModalBottomSheet(
  context: context,
  useRootNavigator: true,
  backgroundColor: const Color(0xFF282828),
  showDragHandle: true,
  isScrollControlled: true,
  builder: (sheet) {
    final position = ref.read(bookPositionProvider);
    final accent = Theme.of(context).colorScheme.primary;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: book.chapters.length,
          itemBuilder: (_, i) {
            final c = book.chapters[i];
            final active = position >= c.start && position < c.end;
            return ListTile(
              title: Text(c.title, style: TextStyle(color: active ? accent : null)),
              trailing: Text(
                formatBookDuration(context.l10n, c.end - c.start),
                style: const TextStyle(color: Palette.textMuted),
              ),
              onTap: () {
                Navigator.pop(sheet);
                ref.read(playerProvider.notifier).seekBook(c.start);
              },
            );
          },
        ),
      ),
    );
  },
);
