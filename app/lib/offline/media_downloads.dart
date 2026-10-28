import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';
import '../core/audiobooks.dart';
import '../core/books.dart';
import '../core/podcasts.dart';
import '../core/session.dart';
import '../l10n/l10n.dart';
import '../l10n/locale.dart';
import 'offline_store.dart';

// Podcast episodes, audiobooks and ebooks saved on the device, apart from the music downloads: each is one item
// with its own folder (`<kind>/<id>/`), downloaded in full, one after the other.

class MediaFile {
  const MediaFile({required this.name, this.source = '', this.start = 0, this.duration = 0});

  /// File name within the item's folder.
  final String name;

  /// Server path of an audiobook file (`items/<id>/file/<ino>`); episodes and ebooks have one known URL.
  final String source;
  final double start;
  final double duration;

  factory MediaFile.fromJson(Map<String, dynamic> j) => MediaFile(
    name: j['name'],
    source: j['source'] ?? '',
    start: (j['start'] as num?)?.toDouble() ?? 0,
    duration: (j['duration'] as num?)?.toDouble() ?? 0,
  );

  Map<String, dynamic> toJson() => {'name': name, 'source': source, 'start': start, 'duration': duration};
}

class MediaDownload {
  const MediaDownload({
    required this.kind,
    required this.id,
    required this.title,
    required this.data,
    required this.files,
    required this.addedAt,
    this.subtitle,
    this.coverUrl,
    this.size = 0,
    this.done = false,
    this.position,
    this.completed = false,
    this.pending = false,
  });

  /// `episode`, `audiobook` or `ebook`.
  final String kind;
  final String id;
  final String title;
  final String? subtitle;
  final String? coverUrl;

  /// The server's data at download time, to play or open the item without the server.
  final Map<String, dynamic> data;
  final List<MediaFile> files;
  final DateTime addedAt;
  final int size;
  final bool done;

  /// Where listening stopped on this device, and whether the server still has to learn it.
  final double? position;
  final bool completed;
  final bool pending;

  String get key => '$kind:$id';
  PodcastEpisode get episode => PodcastEpisode.fromJson(data);
  Book get book => Book.fromJson(data);
  double get duration =>
      (data['duration_seconds'] as num?)?.toDouble() ?? ((data['media'] as Map?)?['duration'] as num?)?.toDouble() ?? 0;

  MediaDownload copyWith({int? size, bool? done, double? position, bool? completed, bool? pending}) => MediaDownload(
    kind: kind,
    id: id,
    title: title,
    subtitle: subtitle,
    coverUrl: coverUrl,
    data: data,
    files: files,
    addedAt: addedAt,
    size: size ?? this.size,
    done: done ?? this.done,
    position: position ?? this.position,
    completed: completed ?? this.completed,
    pending: pending ?? this.pending,
  );

  factory MediaDownload.fromJson(Map<String, dynamic> j) => MediaDownload(
    kind: j['kind'],
    id: j['id'],
    title: j['title'],
    subtitle: j['subtitle'],
    coverUrl: j['cover_url'],
    data: Map<String, dynamic>.from(j['data']),
    files: [for (final f in j['files']) MediaFile.fromJson(Map<String, dynamic>.from(f))],
    addedAt: DateTime.parse(j['added_at']),
    size: j['size'] ?? 0,
    done: j['done'] ?? false,
    position: (j['position'] as num?)?.toDouble(),
    completed: j['completed'] ?? false,
    pending: j['pending'] ?? false,
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'title': title,
    'subtitle': subtitle,
    'cover_url': coverUrl,
    'data': data,
    'files': [for (final f in files) f.toJson()],
    'added_at': addedAt.toIso8601String(),
    'size': size,
    'done': done,
    'position': position,
    'completed': completed,
    'pending': pending,
  };
}

enum MediaDownloadPhase { none, downloading, done, failed }

class MediaDownloadsState {
  const MediaDownloadsState({this.items = const {}, this.progress = const {}, this.failed = const {}, this.directory});

  /// In the order they were added.
  final Map<String, MediaDownload> items;

  /// Share of the running download (0..1) by key.
  final Map<String, double> progress;
  final Set<String> failed;
  final String? directory;

  MediaDownload? item(String kind, String id) => items['$kind:$id'];

  /// The item if it is completely on the device.
  MediaDownload? ready(String kind, String id) {
    final item = items['$kind:$id'];
    return item != null && item.done ? item : null;
  }

  MediaDownloadPhase phase(String kind, String id) {
    final item = items['$kind:$id'];
    if (item == null) return MediaDownloadPhase.none;
    if (item.done) return MediaDownloadPhase.done;
    return failed.contains(item.key) ? MediaDownloadPhase.failed : MediaDownloadPhase.downloading;
  }

  String folder(MediaDownload item) => '$directory/${item.kind}/${item.id}';
  String filePath(MediaDownload item, int index) => '${folder(item)}/${item.files[index].name}';

  String? coverPath(MediaDownload item) {
    if (directory == null) return null;
    final path = '${folder(item)}/cover';
    return File(path).existsSync() ? path : null;
  }

  int get totalBytes => items.values.fold(0, (total, item) => total + item.size);
}

/// Fetches one file to [path], reporting its progress (0..1).
abstract class MediaFetcher {
  Future<void> fetch({
    required String taskId,
    required String url,
    required Map<String, String> headers,
    required String path,
    required String name,
    required bool wifiOnly,
    required void Function(double) onProgress,
    required CancelToken cancel,
  });

  /// Stops transfers left over from an earlier run.
  Future<void> cancelAll();
}

/// Android and iOS: the system downloads, also while the app is in the background, with a notification.
class BackgroundMediaFetcher extends MediaFetcher {
  final _downloader = FileDownloader();
  bool _configured = false;

  @override
  Future<void> fetch({
    required String taskId,
    required String url,
    required Map<String, String> headers,
    required String path,
    required String name,
    required bool wifiOnly,
    required void Function(double) onProgress,
    required CancelToken cancel,
  }) async {
    if (!_configured) {
      _configured = true;
      _downloader.configureNotificationForGroup(
        'media',
        running: const TaskNotification('{displayName}', '{progress}'),
        progressBar: true,
      );
    }
    final (baseDirectory, directory, filename) = await Task.split(filePath: path);
    final task = DownloadTask(
      taskId: taskId,
      group: 'media',
      url: url,
      headers: headers,
      baseDirectory: baseDirectory,
      directory: directory,
      filename: filename,
      displayName: name,
      retries: 3,
      requiresWiFi: wifiOnly,
      updates: Updates.statusAndProgress,
      allowPause: false,
    );
    cancel.whenCancel.then((_) => _downloader.cancelTaskWithId(taskId)).ignore();
    final result = await _downloader.download(task, onProgress: (p) => p >= 0 ? onProgress(p) : null);
    if (result.status != TaskStatus.complete) throw Exception('download ${result.status.name}');
  }

  @override
  Future<void> cancelAll() async {
    await _downloader.cancelTasksWithIds(await _downloader.allTaskIds(group: 'media'));
  }
}

/// Desktop: the app downloads itself while it runs.
class DioMediaFetcher extends MediaFetcher {
  DioMediaFetcher(this._api);
  final ApiClient Function() _api;

  @override
  Future<void> fetch({
    required String taskId,
    required String url,
    required Map<String, String> headers,
    required String path,
    required String name,
    required bool wifiOnly,
    required void Function(double) onProgress,
    required CancelToken cancel,
  }) => _api().downloadMedia(
    url,
    (_) => path,
    cancelToken: cancel,
    onProgress: (received, total) => total > 0 ? onProgress(received / total) : null,
  );

  @override
  Future<void> cancelAll() async {}
}

// Providers also let tests use isolated directories and fake transfers.
final mediaDirectoryProvider = Provider<Future<Directory>>(
  (ref) async => Directory('${(await getApplicationSupportDirectory()).path}/media'),
);
final mediaFetcherProvider = Provider<MediaFetcher>(
  (ref) => !kIsWeb && (Platform.isAndroid || Platform.isIOS)
      ? BackgroundMediaFetcher()
      : DioMediaFetcher(() => ref.read(apiProvider)),
);
final mediaDownloadsProvider = NotifierProvider<MediaDownloadsController, MediaDownloadsState>(
  MediaDownloadsController.new,
);

class MediaDownloadsController extends Notifier<MediaDownloadsState> {
  Future<void>? _loading;
  Future<void>? _worker;
  Future<void> _flushing = Future.value();
  Future<void> _writing = Future.value();
  CancelToken? _cancel;
  String? _current;

  @override
  MediaDownloadsState build() {
    if (!kIsWeb) {
      final lifecycle = AppLifecycleListener(onResume: _resume);
      ref.listen(sessionProvider.select((s) => (s.loggedIn, s.offline)), (previous, next) {
        if (!next.$1) {
          _cancel?.cancel();
        } else if (!next.$2 && previous?.$2 != false) {
          Future.microtask(_resume);
        }
      });
      ref.onDispose(() {
        lifecycle.dispose();
        _cancel?.cancel();
      });
    }
    return const MediaDownloadsState();
  }

  /// Awaited in main before building the app, like the music downloads.
  Future<void> load() => kIsWeb ? Future.value() : _loading ??= _load();

  Future<void> _load() async {
    final directory = await ref.read(mediaDirectoryProvider);
    await directory.create(recursive: true);
    final index = File('${directory.path}/index.json');
    var items = <String, MediaDownload>{};
    if (await index.exists()) {
      try {
        final json = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
        if (json['version'] == 1) {
          for (final entry in json['items'] as List) {
            final item = MediaDownload.fromJson(Map<String, dynamic>.from(entry));
            items[item.key] = item;
          }
        }
      } catch (_) {
        // A damaged index starts empty rather than keeping the app from starting.
      }
    }
    state = MediaDownloadsState(items: Map.unmodifiable(items), directory: directory.path);
    // Files removed by the OS are downloaded again.
    for (final item in items.values.where((i) => i.done)) {
      if (!Iterable.generate(item.files.length).every((i) => File(state.filePath(item, i)).existsSync())) {
        _put(item.copyWith(done: false));
      }
    }
    try {
      await ref.read(mediaFetcherProvider).cancelAll();
    } catch (_) {
      // Nothing left over to stop.
    }
    _resume();
  }

  void _resume() {
    if (!ref.mounted || state.directory == null) return;
    final session = ref.read(sessionProvider);
    if (!session.loggedIn || session.offline) return;
    if (state.failed.isNotEmpty) _publish(failed: const {});
    flush().ignore();
    _startWorker();
  }

  void _publish({Map<String, MediaDownload>? items, Map<String, double>? progress, Set<String>? failed}) {
    if (!ref.mounted) return;
    state = MediaDownloadsState(
      items: items == null ? state.items : Map.unmodifiable(items),
      progress: progress == null ? state.progress : Map.unmodifiable(progress),
      failed: failed == null ? state.failed : Set.unmodifiable(failed),
      directory: state.directory,
    );
  }

  Future<void> _put(MediaDownload item) {
    _publish(items: {...state.items, item.key: item});
    return _persist();
  }

  /// Waits for the running download and index writes (tests).
  @visibleForTesting
  Future<void> settled() async {
    await _worker;
    await _writing;
  }

  Future<void> _persist() {
    final directory = state.directory;
    if (directory == null) return Future.value();
    final json = jsonEncode({
      'version': 1,
      'items': [for (final item in state.items.values) item.toJson()],
    });
    return _writing = _writing
        .then((_) async {
          final temp = File('$directory/index.json.tmp');
          await temp.writeAsString(json, flush: true);
          await temp.rename('$directory/index.json');
        })
        .catchError((Object _) {});
  }

  Future<void> addEpisode(PodcastEpisode episode) async {
    await load();
    final current = await ref.read(apiProvider).podcastEpisode(episode.id);
    _add(
      MediaDownload(
        kind: 'episode',
        id: current.id,
        title: current.title,
        subtitle: current.podcastTitle,
        coverUrl: current.coverUrl,
        data: current.toJson(),
        files: const [MediaFile(name: 'episode.mp3')],
        addedAt: DateTime.now(),
      ),
    );
  }

  Future<void> addAudiobook(String id) async {
    await load();
    final api = ref.read(apiProvider);
    final j = Map<String, dynamic>.from(await api.absGet('items/$id', {'expanded': 1}));
    final l10n = lookupAppLocalizations(ref.read(appLocaleProvider));
    final item = AbsItem.fromJson(j, l10n);
    final media = Map<String, dynamic>.from(j['media'] as Map);
    final tracks = [for (final t in media['tracks'] as List? ?? const []) Map<String, dynamic>.from(t)];
    if (tracks.isEmpty) throw ApiException(l10n.playerAudiobookLoadError);
    final width = tracks.length.toString().length;
    _add(
      MediaDownload(
        kind: 'audiobook',
        id: id,
        title: item.title,
        subtitle: item.author,
        coverUrl: api.absUrl('items/$id/cover', {'width': '600'}),
        // Enough for AbsItem.fromJson.
        data: {
          'id': id,
          'media': {
            'metadata': media['metadata'],
            'duration': media['duration'],
            'chapters': media['chapters'] ?? const [],
          },
        },
        files: [
          for (final (i, t) in tracks.indexed)
            MediaFile(
              name: '${(i + 1).toString().padLeft(width, '0')}${(t['metadata'] as Map?)?['ext'] ?? '.audio'}',
              source: (t['contentUrl'] as String).replaceFirst(RegExp(r'^/api/'), ''),
              start: (t['startOffset'] as num?)?.toDouble() ?? 0,
              duration: (t['duration'] as num?)?.toDouble() ?? 0,
            ),
        ],
        addedAt: DateTime.now(),
      ),
    );
  }

  Future<void> addEbook(String id) async {
    await load();
    final api = ref.read(apiProvider);
    final j = Map<String, dynamic>.from(await api.booksGet('/library/$id'));
    final book = Book.fromJson(j);
    final dot = book.filename.lastIndexOf('.');
    final ext = dot >= 0 ? book.filename.substring(dot).toLowerCase() : '.${book.format.toLowerCase()}';
    _add(
      MediaDownload(
        kind: 'ebook',
        id: id,
        title: book.title,
        subtitle: book.authorText,
        coverUrl: book.hasCover ? api.bookCoverUrl(id) : null,
        data: j,
        files: [MediaFile(name: 'book$ext')],
        addedAt: DateTime.now(),
      ),
    );
  }

  void _add(MediaDownload item) {
    if (state.items.containsKey(item.key)) return;
    _put(item);
    _startWorker();
  }

  Future<void> remove(String key) async {
    final item = state.items[key];
    if (item == null) return;
    if (_current == key) _cancel?.cancel();
    _publish(
      items: {...state.items}..remove(key),
      progress: {...state.progress}..remove(key),
      failed: {...state.failed}..remove(key),
    );
    await _persist();
    await _worker;
    final folder = Directory(state.folder(item));
    if (await folder.exists()) await folder.delete(recursive: true);
  }

  Future<void> clearAll() async {
    await load();
    _cancel?.cancel();
    final items = state.items.values.toList();
    _publish(items: const {}, progress: const {}, failed: const {});
    await _persist();
    await _worker;
    for (final item in items) {
      final folder = Directory(state.folder(item));
      if (await folder.exists()) await folder.delete(recursive: true);
    }
  }

  /// Tries a failed download again.
  void retry(String key) {
    _publish(failed: {...state.failed}..remove(key));
    _startWorker();
  }

  void _startWorker() {
    if (_worker != null || !ref.mounted) return;
    _worker = _run().whenComplete(() => _worker = null);
    _worker!.ignore();
  }

  Future<void> _run() async {
    while (ref.mounted) {
      final session = ref.read(sessionProvider);
      if (!session.loggedIn || session.offline) return;
      final item = state.items.values.where((i) => !i.done && !state.failed.contains(i.key)).firstOrNull;
      if (item == null) return;
      final cancel = _cancel = CancelToken();
      _current = item.key;
      try {
        await _download(item, cancel);
      } catch (_) {
        if (!cancel.isCancelled && state.items.containsKey(item.key)) {
          _publish(failed: {...state.failed, item.key});
        }
      } finally {
        _current = null;
        _publish(progress: {...state.progress}..remove(item.key));
      }
    }
  }

  String _url(ApiClient api, MediaDownload item, MediaFile file) => switch (item.kind) {
    'episode' => api.episodeStreamUrl(item.id),
    'audiobook' => api.absUrl(file.source),
    _ => api.bookFileUrl(item.id),
  };

  Future<void> _download(MediaDownload item, CancelToken cancel) async {
    final api = ref.read(apiProvider);
    final fetcher = ref.read(mediaFetcherProvider);
    final folder = Directory(state.folder(item));
    await folder.create(recursive: true);
    final count = item.files.length;
    for (final (i, file) in item.files.indexed) {
      final path = state.filePath(item, i);
      if (await File(path).exists()) continue;
      final part = '$path.part';
      try {
        await fetcher.fetch(
          taskId: 'media:${item.key}:$i',
          url: _url(api, item, file),
          headers: api.mediaHeaders,
          path: part,
          name: item.title,
          wifiOnly: ref.read(offlineSettingsProvider).wifiOnly,
          onProgress: (p) {
            if (_current == item.key) _publish(progress: {...state.progress, item.key: (i + p) / count});
          },
          cancel: cancel,
        );
        if (cancel.isCancelled || !state.items.containsKey(item.key)) return;
        await File(part).rename(path);
      } finally {
        final leftover = File(part);
        if (await leftover.exists()) await leftover.delete();
      }
    }
    if (item.coverUrl != null) {
      // Plain client: episode covers are on other hosts, which must not get the token header.
      try {
        await Dio().download(item.coverUrl!, '${folder.path}/cover', cancelToken: cancel);
      } catch (_) {
        // The item works without its cover.
      }
    }
    var size = 0;
    for (var i = 0; i < count; i++) {
      size += await File(state.filePath(item, i)).length();
    }
    final current = state.items[item.key];
    if (current == null || cancel.isCancelled) return;
    _put(current.copyWith(size: size, done: true));
  }

  /// Remembers where listening stopped; [synced] says whether the server already has it.
  Future<void> savePosition(String kind, String id, double position, {required bool completed, required bool synced}) {
    final item = state.items['$kind:$id'];
    if (item == null) return Future.value();
    return _put(item.copyWith(position: position, completed: completed, pending: !synced));
  }

  /// Sends positions listened to offline to the server.
  Future<void> flush() {
    // One after the other: a flush asked for while one runs still sees the newest state.
    final next = _flushing.then((_) => _flush());
    _flushing = next.catchError((Object _) {});
    return next;
  }

  Future<void> _flush() async {
    final api = ref.read(apiProvider);
    for (final item in state.items.values.where((i) => i.pending && i.position != null).toList()) {
      try {
        final position = item.position!;
        if (item.kind == 'episode') {
          await api.saveEpisodeProgress(item.id, position, completed: item.completed);
        } else {
          final duration = item.duration;
          await api.absPatch('me/progress/${item.id}', {
            'currentTime': position,
            'duration': duration,
            'progress': duration > 0 ? (position / duration).clamp(0, 1) : 0,
            'isFinished': item.completed,
          });
        }
        final current = state.items[item.key];
        if (current != null && current.position == position) _put(current.copyWith(pending: false));
      } catch (_) {
        // Still offline; the next resume or reconnect tries again.
      }
    }
  }
}
