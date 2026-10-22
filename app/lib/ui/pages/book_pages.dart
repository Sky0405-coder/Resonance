import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/audiobooks.dart';
import '../../core/books.dart';
import '../../core/podcasts.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/track_list.dart';
import 'audiobook_pages.dart';
import 'podcast_pages.dart';

String _statusText(AppLocalizations l10n, String status) => switch (status) {
  'pending_approval' => l10n.booksStatusPending,
  'queued' => l10n.booksStatusQueued,
  'searching' => l10n.booksStatusSearching,
  'downloading' => l10n.booksStatusDownloading,
  'importing' => l10n.booksStatusImporting,
  'done' => l10n.booksStatusDone,
  'failed' => l10n.booksStatusFailed,
  'cancelled' => l10n.booksStatusCancelled,
  'rejected' => l10n.booksStatusRejected,
  _ => status,
};

String _languageText(AppLocalizations l10n, String code) => switch (code) {
  'de' => l10n.booksLanguageDe,
  'en' => l10n.booksLanguageEn,
  'any' => l10n.booksLanguageAny,
  _ => code,
};

String _seriesText(AppLocalizations l10n, String? series, double? index) {
  if (series == null) return '';
  if (index == null) return series;
  final number = index == index.roundToDouble() ? index.toInt().toString() : index.toString();
  return '$series · ${l10n.booksVolume(number)}';
}

void _refreshLibrary(WidgetRef ref) {
  ref.invalidate(bookLibraryProvider);
  ref.invalidate(bookAuthorsProvider);
  ref.invalidate(bookSeriesProvider);
}

/// Book cover (2:3) from the library or a catalog URL, with a placeholder.
class BookCover extends ConsumerWidget {
  const BookCover({super.key, this.bookId, this.url, this.radius = 4});
  final String? bookId;
  final String? url;
  final double radius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final placeholder = Container(
      color: const Color(0xFF282828),
      alignment: Alignment.center,
      child: LayoutBuilder(
        builder: (_, c) => Icon(Icons.menu_book, color: Palette.textMuted, size: (c.maxWidth * 0.4).clamp(12, 64)),
      ),
    );
    final src = bookId != null ? ref.watch(apiProvider).bookCoverUrl(bookId!) : url;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: AspectRatio(
        aspectRatio: 2 / 3,
        child: src == null
            ? placeholder
            : Image.network(
                src,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder,
                loadingBuilder: (_, child, progress) => progress == null ? child : placeholder,
              ),
      ),
    );
  }
}

/// Bottom tab "Bücher": ebooks and, if set up, audiobooks side by side.
class BooksHubPage extends ConsumerStatefulWidget {
  const BooksHubPage({super.key});

  @override
  ConsumerState<BooksHubPage> createState() => _BooksHubPageState();
}

class _BooksHubPageState extends ConsumerState<BooksHubPage> with TickerProviderStateMixin {
  TabController? _tabController;

  void _tabChanged() {
    if (mounted) setState(() {});
  }

  void _syncTabController(int? length) {
    if (_tabController?.length == length) return;
    _tabController?.removeListener(_tabChanged);
    _tabController?.dispose();
    _tabController = length == null ? null : TabController(length: length, vsync: this);
    _tabController?.addListener(_tabChanged);
  }

  @override
  void dispose() {
    _tabController?.removeListener(_tabChanged);
    _tabController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ref = this.ref;
    final ebooks = ref.watch(ebooksVisibleProvider);
    final audiobooks = ref.watch(audiobooksVisibleProvider);
    final podcasts =
        !isWide(context) &&
        ref.watch(podcastsVisibleProvider) &&
        ref.watch(sessionProvider.select((s) => s.user?.isAdmin ?? false));
    final tabs = <(String, Widget, bool)>[
      if (ebooks) (context.l10n.booksEbooks, const _EbooksView(), true),
      if (audiobooks) (context.l10n.navAudiobooks, const AudiobooksPage(embedded: true), false),
      if (podcasts) (context.l10n.navPodcasts, const PodcastsPage(embedded: true), false),
    ];
    if (tabs.isEmpty) {
      _syncTabController(null);
      return const PodcastsPage();
    }
    if (tabs.length == 1 && audiobooks) {
      _syncTabController(null);
      return const AudiobooksPage();
    }
    _syncTabController(tabs.length);
    final controller = _tabController!;
    final ebookIndex = tabs.indexWhere((tab) => tab.$3);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(context.l10n.navBooks, style: const TextStyle(fontWeight: FontWeight.w800)),
        actions: [if (controller.index == ebookIndex && ebookIndex >= 0) const _EbookActions()],
        bottom: tabs.length > 1
            ? TabBar(
                controller: controller,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                tabs: [for (final tab in tabs) Tab(text: tab.$1)],
              )
            : null,
      ),
      body: TabBarView(controller: controller, children: [for (final tab in tabs) tab.$2]),
    );
  }
}

/// Requests (with a badge for running ones) and import, like the downloads button in the library.
class _EbookActions extends ConsumerWidget {
  const _EbookActions();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(bookRequestsProvider(false)).value?.where((r) => r.active).length ?? 0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          tooltip: context.l10n.booksRequests,
          icon: Badge(isLabelVisible: active > 0, label: Text('$active'), child: const Icon(Icons.download_outlined)),
          onPressed: () => context.push('/books/requests'),
        ),
        IconButton(
          tooltip: context.l10n.booksImport,
          icon: const Icon(Icons.upload_file_outlined),
          onPressed: () => showBookImport(context, ref),
        ),
      ],
    );
  }
}

class _EbooksView extends ConsumerWidget {
  const _EbooksView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recent = ref.watch(bookLibraryProvider((q: null, author: null, series: null, sort: 'added')));
    final all = ref.watch(bookLibraryProvider((q: null, author: null, series: null, sort: 'title')));
    final requests = ref.watch(bookRequestsProvider(false));
    final active = requests.value?.where((r) => r.active).toList() ?? const <BookRequest>[];
    final heading = Theme.of(context).textTheme.titleLarge;
    final books = all.value ?? const <Book>[];
    return RefreshIndicator(
      onRefresh: () async {
        _refreshLibrary(ref);
        ref.invalidate(bookRequestsProvider);
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                textInputAction: TextInputAction.search,
                decoration: searchDecoration(context.l10n.booksSearchHint),
                onSubmitted: (q) {
                  if (q.trim().isNotEmpty) context.push('/books/search?q=${Uri.encodeQueryComponent(q.trim())}');
                },
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  for (final (icon, label, route) in [
                    (Icons.person_outline, context.l10n.booksAuthors, '/books/authors'),
                    (Icons.collections_bookmark_outlined, context.l10n.booksSeries, '/books/series'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ActionChip(
                        avatar: Icon(icon, size: 18),
                        label: Text(label),
                        onPressed: () => context.push(route),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (active.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.booksRequests, style: heading),
                    for (final r in active) _RequestTile(request: r, admin: false),
                  ],
                ),
              ),
            ),
          // With a small library the shelf would only repeat the grid below.
          if (books.length > 12)
            SliverToBoxAdapter(
              child: _BookShelf(title: context.l10n.booksRecent, books: (recent.value ?? const []).take(20).toList()),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(context.l10n.booksAll, style: heading),
            ),
          ),
          all.when(
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
            error: (e, _) => SliverToBoxAdapter(
              child: ListTile(leading: const Icon(Icons.error_outline), title: Text('$e')),
            ),
            data: (list) => list.isEmpty
                ? SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(32, 24, 32, 0),
                      child: Text(
                        context.l10n.booksEmptyLibrary,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Palette.textMuted),
                      ),
                    ),
                  )
                : SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    sliver: SliverGrid.builder(
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 170,
                        childAspectRatio: 0.5,
                      ),
                      itemCount: list.length,
                      itemBuilder: (_, i) => _BookCard(book: list[i]),
                    ),
                  ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
        ],
      ),
    );
  }
}

/// Horizontal row of book cards with a heading, like the music shelves on the home page.
class _BookShelf extends StatelessWidget {
  const _BookShelf({required this.title, required this.books});
  final String title;
  final List<Book> books;

  @override
  Widget build(BuildContext context) {
    if (books.isEmpty) return const SizedBox.shrink();
    const width = 140.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(title, style: Theme.of(context).textTheme.titleLarge),
        ),
        SizedBox(
          height: (width - 20) * 1.5 + 80,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            itemCount: books.length,
            itemBuilder: (_, i) => SizedBox(width: width, child: _BookCard(book: books[i])),
          ),
        ),
      ],
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({required this.book});
  final Book book;

  @override
  Widget build(BuildContext context) => MediaCard(
    image: BookCover(bookId: book.hasCover ? book.id : null),
    title: book.title,
    subtitle: book.authorText,
    onTap: () => context.push('/books/item/${book.id}'),
  );
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book});
  final Book book;

  @override
  Widget build(BuildContext context) {
    final series = _seriesText(context.l10n, book.series, book.seriesIndex);
    return ListTile(
      leading: SizedBox(width: 40, child: BookCover(bookId: book.hasCover ? book.id : null, radius: 2)),
      title: Text(book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [book.authorText, if (series.isNotEmpty) series].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: () => context.push('/books/item/${book.id}'),
    );
  }
}

/// Library list for a free-text search, an author or a series.
class BookListPage extends ConsumerWidget {
  const BookListPage({super.key, this.author, this.series});
  final String? author;
  final String? series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final query = (
      q: null,
      author: author,
      series: series,
      sort: series != null
          ? 'series'
          : author != null
          ? 'author'
          : 'title',
    );
    final books = ref.watch(bookLibraryProvider(query));
    return Scaffold(
      appBar: AppBar(title: Text(series ?? author ?? context.l10n.booksAll)),
      body: AsyncBody(
        value: books,
        onRetry: () => ref.invalidate(bookLibraryProvider(query)),
        builder: (list) => ListView(
          padding: const EdgeInsets.only(bottom: kBottomInset),
          children: [for (final b in list) _BookTile(book: b)],
        ),
      ),
    );
  }
}

class BookGroupsPage extends ConsumerWidget {
  const BookGroupsPage({super.key, required this.series});
  final bool series;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final provider = series ? bookSeriesProvider : bookAuthorsProvider;
    return Scaffold(
      appBar: AppBar(title: Text(series ? context.l10n.booksSeries : context.l10n.booksAuthors)),
      body: AsyncBody(
        value: ref.watch(provider),
        onRetry: () => ref.invalidate(provider),
        builder: (groups) => ListView(
          padding: const EdgeInsets.only(bottom: kBottomInset),
          children: [
            for (final g in groups)
              ListTile(
                leading: Icon(series ? Icons.collections_bookmark_outlined : Icons.person_outline),
                title: Text(g.name),
                subtitle: g.author == null ? null : Text(g.author!),
                trailing: Text('${g.count}', style: const TextStyle(color: Palette.textMuted)),
                onTap: () =>
                    context.push('/books/list?${series ? 'series' : 'author'}=${Uri.encodeQueryComponent(g.name)}'),
              ),
          ],
        ),
      ),
    );
  }
}

/// Search: matching library books first, then catalog hits to request.
class BookSearchPage extends ConsumerWidget {
  const BookSearchPage({super.key, required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(bookLibraryProvider((q: query, author: null, series: null, sort: 'title')));
    final catalog = ref.watch(bookCatalogProvider(query));
    final status = ref.watch(booksStatusProvider).value;
    final title = Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700);
    return Scaffold(
      appBar: AppBar(title: Text(query)),
      body: ListView(
        padding: const EdgeInsets.only(bottom: kBottomInset),
        children: [
          if (library.value?.isNotEmpty ?? false) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(context.l10n.booksInLibrary, style: title),
            ),
            for (final b in library.value!) _BookTile(book: b),
          ],
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(context.l10n.booksFromCatalog, style: title),
          ),
          if (status != null && !status.requestsEnabled)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(context.l10n.booksRequestsDisabled, style: const TextStyle(color: Palette.textMuted)),
            )
          else ...[
            catalog.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => ListTile(leading: const Icon(Icons.error_outline), title: Text('$e')),
              data: (hits) => Column(
                children: [
                  if (hits.isEmpty) ListTile(title: Text(context.l10n.booksNoResults)),
                  for (final hit in hits) _CatalogTile(hit: hit, query: query),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: Text(context.l10n.booksRequestFree),
              onTap: () => _freeRequest(context, ref, query),
            ),
          ],
        ],
      ),
    );
  }
}

class _CatalogTile extends ConsumerWidget {
  const _CatalogTile({required this.hit, required this.query});
  final CatalogBook hit;
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final series = _seriesText(context.l10n, hit.series, hit.seriesIndex);
    final Widget trailing;
    if (hit.bookId != null) {
      trailing = const Icon(Icons.check_circle, color: Palette.textMuted);
    } else if (hit.requestStatus != null) {
      trailing = Text(_statusText(context.l10n, hit.requestStatus!), style: const TextStyle(color: Palette.textMuted));
    } else {
      trailing = const Icon(Icons.add_circle_outline);
    }
    return ListTile(
      leading: SizedBox(width: 40, child: BookCover(url: hit.coverUrl, radius: 2)),
      title: Text(hit.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [hit.authorText, if (series.isNotEmpty) series, if (hit.year != null) '${hit.year}'].join(' · '),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
      onTap: () {
        if (hit.bookId != null) {
          context.push('/books/item/${hit.bookId}');
        } else {
          _showCatalogBook(context, ref, hit, query);
        }
      },
    );
  }
}

Future<void> _showCatalogBook(BuildContext context, WidgetRef ref, CatalogBook hit, String query) async {
  final status = ref.read(booksStatusProvider).value;
  var language = status?.defaultLanguage ?? 'de';
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheet) => StatefulBuilder(
      builder: (sheet, setState) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(sheet).height * 0.85),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(width: 90, child: BookCover(url: hit.coverUrl)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(hit.title, style: Theme.of(sheet).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(hit.authorText, style: const TextStyle(color: Palette.textMuted)),
                          if (hit.series != null)
                            Text(
                              _seriesText(context.l10n, hit.series, hit.seriesIndex),
                              style: const TextStyle(color: Palette.textMuted),
                            ),
                          if (hit.year != null) Text('${hit.year}', style: const TextStyle(color: Palette.textMuted)),
                        ],
                      ),
                    ),
                  ],
                ),
                if (hit.description != null) ...[const SizedBox(height: 16), Text(hit.description!)],
                const SizedBox(height: 16),
                if (hit.requestStatus != null)
                  Text(_statusText(context.l10n, hit.requestStatus!))
                else ...[
                  Text(context.l10n.booksLanguage, style: const TextStyle(color: Palette.textMuted)),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: [
                      for (final code in const ['de', 'en', 'any'])
                        ButtonSegment(value: code, label: Text(_languageText(context.l10n, code))),
                    ],
                    selected: {language},
                    onSelectionChanged: (v) => setState(() => language = v.first),
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.download),
                      label: Text(context.l10n.booksRequest),
                      onPressed: () async {
                        Navigator.pop(sheet);
                        await _createRequest(context, ref, hit.requestBody(language), query);
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _createRequest(BuildContext context, WidgetRef ref, Map<String, dynamic> body, String? query) async {
  try {
    final j = await ref.read(apiProvider).booksPost('/requests', body);
    if (query != null) ref.invalidate(bookCatalogProvider(query));
    ref.invalidate(bookRequestsProvider);
    if (context.mounted) showInfo(context, context.l10n.booksRequested(j['title'] ?? ''));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> _freeRequest(BuildContext context, WidgetRef ref, String query) async {
  final title = TextEditingController(text: query);
  final author = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(context.l10n.booksRequest),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: title,
            decoration: InputDecoration(labelText: context.l10n.booksTitle),
          ),
          TextField(
            controller: author,
            decoration: InputDecoration(labelText: context.l10n.booksAuthorsField),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(context.l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.booksRequest)),
      ],
    ),
  );
  if (ok != true || title.text.trim().isEmpty || !context.mounted) return;
  await _createRequest(context, ref, {
    'title': title.text.trim(),
    'authors': [
      for (final a in author.text.split(','))
        if (a.trim().isNotEmpty) a.trim(),
    ],
  }, query);
}

/// Detail page of a library book.
class BookPage extends ConsumerWidget {
  const BookPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final book = ref.watch(bookProvider(id));
    final isAdmin = ref.watch(sessionProvider.select((s) => s.user?.isAdmin ?? false));
    return Scaffold(
      appBar: AppBar(
        actions: [
          if (book.hasValue && isAdmin) ...[
            IconButton(
              tooltip: context.l10n.booksEdit,
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _editBook(context, ref, book.value!),
            ),
            IconButton(
              tooltip: context.l10n.booksDelete,
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _deleteBook(context, ref, book.value!),
            ),
          ],
        ],
      ),
      body: AsyncBody(
        value: book,
        onRetry: () => ref.invalidate(bookProvider(id)),
        builder: (b) {
          final details = [
            if (b.series != null) _seriesText(context.l10n, b.series, b.seriesIndex),
            if (b.year != null) '${b.year}',
            if (b.publisher != null) b.publisher!,
            if (b.language != null) _languageText(context.l10n, b.language!),
            '${b.format.toUpperCase()} · ${(b.size / 1024 / 1024).toStringAsFixed(1)} MB',
          ];
          return ListView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, kBottomInset),
            children: [
              Center(
                child: SizedBox(width: 180, child: BookCover(bookId: b.hasCover ? b.id : null, radius: 6)),
              ),
              const SizedBox(height: 20),
              Text(b.title, style: Theme.of(context).textTheme.headlineSmall, textAlign: TextAlign.center),
              if (b.subtitle != null) Text(b.subtitle!, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                b.authorText,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.textMuted),
              ),
              const SizedBox(height: 4),
              Text(
                details.join(' · '),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 20),
              Center(
                child: FilledButton.icon(
                  icon: const Icon(Icons.download),
                  label: Text(context.l10n.booksDownload),
                  onPressed: () => launchUrl(
                    Uri.parse(ref.read(apiProvider).bookFileUrl(b.id)),
                    mode: LaunchMode.externalApplication,
                  ),
                ),
              ),
              if (b.description != null) ...[const SizedBox(height: 24), Text(b.description!)],
            ],
          );
        },
      ),
    );
  }
}

Future<void> _editBook(BuildContext context, WidgetRef ref, Book book) async {
  final title = TextEditingController(text: book.title);
  final authors = TextEditingController(text: book.authors.join(', '));
  final series = TextEditingController(text: book.series ?? '');
  final index = TextEditingController(text: book.seriesIndex == null ? '' : _seriesNumber(book.seriesIndex!));
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(context.l10n.booksEdit),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: title,
              decoration: InputDecoration(labelText: context.l10n.booksTitle),
            ),
            TextField(
              controller: authors,
              decoration: InputDecoration(labelText: context.l10n.booksAuthorsField),
            ),
            TextField(
              controller: series,
              decoration: InputDecoration(labelText: context.l10n.booksSeriesField),
            ),
            TextField(
              controller: index,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: context.l10n.booksSeriesIndex),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(context.l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.commonSave)),
      ],
    ),
  );
  if (ok != true || title.text.trim().isEmpty) return;
  try {
    await ref.read(apiProvider).booksPatch('/library/${book.id}', {
      'title': title.text.trim(),
      'authors': [
        for (final a in authors.text.split(','))
          if (a.trim().isNotEmpty) a.trim(),
      ],
      'series': series.text.trim().isEmpty ? null : series.text.trim(),
      'series_index': double.tryParse(index.text.trim().replaceAll(',', '.')),
    });
    ref.invalidate(bookProvider(book.id));
    _refreshLibrary(ref);
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

String _seriesNumber(double index) => index == index.roundToDouble() ? index.toInt().toString() : index.toString();

Future<void> _deleteBook(BuildContext context, WidgetRef ref, Book book) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (d) => AlertDialog(
      content: Text(context.l10n.booksDeleteConfirm(book.title)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: Text(context.l10n.commonCancel)),
        FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.booksDelete)),
      ],
    ),
  );
  if (ok != true) return;
  try {
    await ref.read(apiProvider).booksDelete('/library/${book.id}');
    _refreshLibrary(ref);
    if (context.mounted) context.pop();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

/// Upload files or import from a link.
Future<void> showBookImport(BuildContext context, WidgetRef ref) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: Text(context.l10n.booksImportFiles),
            subtitle: Text(context.l10n.booksImportFilesHint),
            onTap: () => Navigator.pop(sheet, 'files'),
          ),
          ListTile(
            leading: const Icon(Icons.link),
            title: Text(context.l10n.booksImportUrl),
            onTap: () => Navigator.pop(sheet, 'url'),
          ),
        ],
      ),
    ),
  );
  if (!context.mounted || choice == null) return;
  final api = ref.read(apiProvider);
  try {
    List<dynamic> results;
    if (choice == 'files') {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['epub', 'azw3', 'mobi', 'pdf'],
      );
      if (picked.isEmpty) return;
      if (context.mounted) showInfo(context, context.l10n.booksImporting);
      results = await api.booksUpload([for (final f in picked) (name: f.name, bytes: await f.readAsBytes())]);
    } else {
      final url = await promptText(context, context.l10n.booksImportUrl, context.l10n.booksImportUrlLabel);
      if (url == null || url.trim().isEmpty) return;
      if (context.mounted) showInfo(context, context.l10n.booksImporting);
      results = [
        await api.booksPost('/import/url', {'url': url.trim()}),
      ];
    }
    _refreshLibrary(ref);
    if (!context.mounted) return;
    final ok = results.where((r) => r['ok'] == true).length;
    final errors = [
      for (final r in results)
        if (r['ok'] != true) context.l10n.booksImportFailed(r['filename'] ?? '', r['error'] ?? ''),
    ];
    showInfo(context, [context.l10n.booksImported(ok), ...errors].join('\n'));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.request, required this.admin});
  final BookRequest request;
  final bool admin;

  Future<void> _action(BuildContext context, WidgetRef ref, Future<void> Function() fn) async {
    try {
      await fn();
      ref.invalidate(bookRequestsProvider);
      _refreshLibrary(ref);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiProvider);
    final r = request;
    var status = _statusText(context.l10n, r.status);
    if (r.status == 'downloading') status = '$status ${(r.progress * 100).round()} %';
    final lines = [
      [r.authors.join(', '), status, if (admin) r.userName].where((s) => s.isNotEmpty).join(' · '),
      if (r.error != null) r.error!,
    ];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: SizedBox(
        width: 40,
        child: r.book != null
            ? BookCover(bookId: r.book!.hasCover ? r.book!.id : null, radius: 2)
            : BookCover(url: r.coverUrl, radius: 2),
      ),
      title: Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(lines.join('\n'), maxLines: 3, overflow: TextOverflow.ellipsis),
      onTap: r.book == null ? null : () => context.push('/books/item/${r.book!.id}'),
      trailing: PopupMenuButton<String>(
        onSelected: (v) => _action(context, ref, () async {
          switch (v) {
            case 'approve':
              await api.booksPost('/requests/${r.id}/approve');
            case 'reject':
              await api.booksPost('/requests/${r.id}/reject', {'reason': null});
            case 'retry':
              await api.booksPost('/requests/${r.id}/retry');
            case 'remove':
              await api.booksDelete('/requests/${r.id}');
          }
        }),
        itemBuilder: (_) => [
          if (admin && r.status == 'pending_approval') ...[
            PopupMenuItem(value: 'approve', child: Text(context.l10n.booksApprove)),
            PopupMenuItem(value: 'reject', child: Text(context.l10n.booksReject)),
          ],
          if (r.status == 'failed' || r.status == 'cancelled')
            PopupMenuItem(value: 'retry', child: Text(context.l10n.commonRetry)),
          PopupMenuItem(
            value: 'remove',
            child: Text(r.active ? context.l10n.booksCancelRequest : context.l10n.booksRemoveRequest),
          ),
        ],
      ),
    );
  }
}

class BookRequestsPage extends ConsumerStatefulWidget {
  const BookRequestsPage({super.key});

  @override
  ConsumerState<BookRequestsPage> createState() => _BookRequestsPageState();
}

class _BookRequestsPageState extends ConsumerState<BookRequestsPage> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(sessionProvider.select((s) => s.user?.isAdmin ?? false));
    final requests = ref.watch(bookRequestsProvider(_all && isAdmin));
    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.booksRequests),
        actions: [
          if (isAdmin)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(context.l10n.booksAllUsers),
                selected: _all,
                onSelected: (v) => setState(() => _all = v),
              ),
            ),
        ],
      ),
      body: AsyncBody(
        value: requests,
        onRetry: () => ref.invalidate(bookRequestsProvider),
        builder: (list) => list.isEmpty
            ? Center(
                child: Text(context.l10n.booksNoRequests, style: const TextStyle(color: Palette.textMuted)),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, kBottomInset),
                children: [for (final r in list) _RequestTile(request: r, admin: _all && isAdmin)],
              ),
      ),
    );
  }
}
