import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'session.dart';

// Ebook library, catalog and requests (/api/books).

const _kHideBooks = 'books.hide_tab';

class BooksStatus {
  const BooksStatus({required this.enabled, required this.requestsEnabled, required this.defaultLanguage});
  final bool enabled;
  final bool requestsEnabled;
  final String defaultLanguage;

  factory BooksStatus.fromJson(Map<String, dynamic> j) => BooksStatus(
    enabled: j['enabled'] ?? false,
    requestsEnabled: j['requests_enabled'] ?? false,
    defaultLanguage: j['default_language'] ?? 'de',
  );
}

String? _str(Object? v) => v is String && v.isNotEmpty ? v : null;

class Book {
  const Book({
    required this.id,
    required this.title,
    required this.authors,
    required this.format,
    required this.size,
    required this.hasCover,
    required this.filename,
    this.subtitle,
    this.series,
    this.seriesIndex,
    this.language,
    this.isbn,
    this.publisher,
    this.year,
    this.description,
  });

  final String id;
  final String title;
  final String? subtitle;
  final List<String> authors;
  final String? series;
  final double? seriesIndex;
  final String? language;
  final String? isbn;
  final String? publisher;
  final int? year;
  final String? description;
  final String format;
  final int size;
  final bool hasCover;
  final String filename;

  String get authorText => authors.join(', ');

  factory Book.fromJson(Map<String, dynamic> j) => Book(
    id: j['id'],
    title: j['title'] ?? '',
    subtitle: _str(j['subtitle']),
    authors: List<String>.from(j['authors'] ?? const []),
    series: _str(j['series']),
    seriesIndex: (j['series_index'] as num?)?.toDouble(),
    language: _str(j['language']),
    isbn: _str(j['isbn']),
    publisher: _str(j['publisher']),
    year: j['year'],
    description: _str(j['description']),
    format: j['format'] ?? '',
    size: j['size'] ?? 0,
    hasCover: j['has_cover'] ?? false,
    filename: j['filename'] ?? '',
  );
}

/// A search hit from the metadata catalog (Audible, Google Books) – sent back unchanged to request it.
class CatalogBook {
  const CatalogBook(this.json);
  final Map<String, dynamic> json;

  String get title => json['title'] ?? '';
  List<String> get authors => List<String>.from(json['authors'] ?? const []);
  String get authorText => authors.join(', ');
  String? get series => _str(json['series']);
  double? get seriesIndex => (json['series_index'] as num?)?.toDouble();
  String? get description => _str(json['description']);
  String? get coverUrl => _str(json['cover_url']);
  int? get year => json['year'];
  String? get language => _str(json['language']);
  String? get bookId => _str(json['book_id']);
  String? get requestId => _str(json['request_id']);
  String? get requestStatus => _str(json['request_status']);

  /// The request body: the catalog fields without the library/request annotations.
  Map<String, dynamic> requestBody(String? language) => {
    for (final key in const [
      'ref',
      'title',
      'subtitle',
      'authors',
      'series',
      'series_index',
      'isbn',
      'publisher',
      'year',
      'description',
      'cover_url',
    ])
      if (json[key] != null) key: json[key],
    'language': language,
  };
}

class BookRequest {
  const BookRequest({
    required this.id,
    required this.title,
    required this.authors,
    required this.status,
    required this.language,
    required this.progress,
    required this.userName,
    this.coverUrl,
    this.torrentName,
    this.error,
    this.book,
  });

  final String id;
  final String title;
  final List<String> authors;
  final String status;
  final String language;
  final double progress;
  final String userName;
  final String? coverUrl;
  final String? torrentName;
  final String? error;
  final Book? book;

  bool get active => !const {'done', 'failed', 'cancelled', 'rejected'}.contains(status);

  factory BookRequest.fromJson(Map<String, dynamic> j) => BookRequest(
    id: j['id'],
    title: j['title'] ?? '',
    authors: List<String>.from(j['authors'] ?? const []),
    status: j['status'] ?? '',
    language: j['language'] ?? 'any',
    progress: (j['progress'] as num?)?.toDouble() ?? 0,
    userName: (j['user'] as Map?)?['display_name'] ?? (j['user'] as Map?)?['username'] ?? '',
    coverUrl: _str(j['cover_url']),
    torrentName: _str(j['torrent_name']),
    error: _str(j['error']),
    book: j['book'] is Map ? Book.fromJson(Map<String, dynamic>.from(j['book'])) : null,
  );
}

class BookGroup {
  const BookGroup({required this.name, required this.count, this.author});
  final String name;
  final int count;
  final String? author;
}

/// Filter of a library list: free text, author or series (sorted to match).
typedef LibraryQuery = ({String? q, String? author, String? series, String sort});

final booksStatusProvider = FutureProvider<BooksStatus>(
  (ref) async => BooksStatus.fromJson(Map<String, dynamic>.from(await ref.watch(apiProvider).booksGet('/status'))),
);

/// Users can hide the books tab; it only shows when the module is enabled anyway.
final booksTabHiddenProvider = NotifierProvider<BooksTabHidden, bool>(BooksTabHidden.new);

class BooksTabHidden extends Notifier<bool> {
  @override
  bool build() => ref.read(prefsProvider).getBool(_kHideBooks) ?? false;

  void set(bool hidden) {
    ref.read(prefsProvider).setBool(_kHideBooks, hidden);
    state = hidden;
  }
}

final ebooksVisibleProvider = Provider<bool>(
  (ref) => (ref.watch(booksStatusProvider).value?.enabled ?? false) && !ref.watch(booksTabHiddenProvider),
);

final bookLibraryProvider = FutureProvider.autoDispose.family<List<Book>, LibraryQuery>((ref, query) async {
  final j = await ref.watch(apiProvider).booksGet('/library', {
    'q': ?query.q,
    'author': ?query.author,
    'series': ?query.series,
    'sort': query.sort,
    'limit': 200,
  });
  return [for (final b in j['items']) Book.fromJson(b)];
});

final bookProvider = FutureProvider.autoDispose.family<Book, String>(
  (ref, id) async => Book.fromJson(await ref.watch(apiProvider).booksGet('/library/$id')),
);

final bookAuthorsProvider = FutureProvider.autoDispose<List<BookGroup>>((ref) async {
  final j = await ref.watch(apiProvider).booksGet('/library/authors');
  return [for (final a in j) BookGroup(name: a['name'], count: a['count'])];
});

final bookSeriesProvider = FutureProvider.autoDispose<List<BookGroup>>((ref) async {
  final j = await ref.watch(apiProvider).booksGet('/library/series');
  return [for (final s in j) BookGroup(name: s['name'], count: s['count'], author: _str(s['author']))];
});

final bookCatalogProvider = FutureProvider.autoDispose.family<List<CatalogBook>, String>((ref, q) async {
  final j = await ref.watch(apiProvider).booksGet('/catalog/search', {'q': q});
  return [for (final b in j) CatalogBook(Map<String, dynamic>.from(b))];
});

/// The user's requests, or everyone's for admins with `all`.
final bookRequestsProvider = FutureProvider.autoDispose.family<List<BookRequest>, bool>((ref, all) async {
  final j = await ref.watch(apiProvider).booksGet('/requests', {'scope': all ? 'all' : 'mine', 'limit': 200});
  final requests = [for (final r in j['items']) BookRequest.fromJson(r)];
  // Running requests refresh themselves.
  if (requests.any((r) => r.active)) {
    final timer = Timer(const Duration(seconds: 5), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return requests;
});
