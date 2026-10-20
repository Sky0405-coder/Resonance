import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/session.dart';
import '../l10n/l10n.dart';
import '../l10n/locale.dart';
import 'offline_transfer.dart';

class OfflineSettings {
  const OfflineSettings({this.quality = 'normal', this.wifiOnly = true});
  final String quality;
  final bool wifiOnly;
}

final offlineSettingsProvider = NotifierProvider<OfflineSettingsController, OfflineSettings>(
  OfflineSettingsController.new,
);

class OfflineSettingsController extends Notifier<OfflineSettings> {
  @override
  OfflineSettings build() {
    final prefs = ref.read(prefsProvider);
    return OfflineSettings(
      quality: prefs.getString('offline.quality') ?? 'normal',
      wifiOnly: prefs.getBool('offline.wifiOnly') ?? true,
    );
  }

  Future<void> setQuality(String quality) async {
    await ref.read(prefsProvider).setString('offline.quality', quality);
    state = OfflineSettings(quality: quality, wifiOnly: state.wifiOnly);
  }

  Future<void> setWifiOnly(bool value) async {
    await ref.read(prefsProvider).setBool('offline.wifiOnly', value);
    state = OfflineSettings(quality: state.quality, wifiOnly: value);
  }
}

class OfflineCollection {
  const OfflineCollection({
    required this.kind,
    required this.id,
    required this.name,
    required this.addedAt,
    required this.data,
    this.syncedAt,
  });
  final String kind;
  final String id;
  final String name;
  final DateTime addedAt;
  final DateTime? syncedAt;
  final dynamic data;

  String get key => kind == 'liked' ? 'liked' : '$kind:$id';
  List<Track> get orderedTracks => switch (kind) {
    'album' => AlbumDetail.fromJson(data).tracks,
    'playlist' => [for (final entry in PlaylistDetail.fromJson(data).entries) entry.track],
    'liked' => [for (final track in data) Track.fromJson(track)],
    _ => const [],
  };

  factory OfflineCollection.fromJson(Map<String, dynamic> json) => OfflineCollection(
    kind: json['kind'],
    id: json['id'],
    name: json['name'],
    addedAt: DateTime.parse(json['added_at']),
    syncedAt: json['synced_at'] == null ? null : DateTime.parse(json['synced_at']),
    data: json['data'],
  );

  Map<String, dynamic> toJson() => {
    'kind': kind,
    'id': id,
    'name': name,
    'added_at': addedAt.toIso8601String(),
    'synced_at': syncedAt?.toIso8601String(),
    'data': data,
  };
}

class OfflineTrack {
  const OfflineTrack({required this.albumId, required this.collections, this.file, this.size = 0});
  final String? file;
  final int size;
  final String albumId;
  final List<String> collections;

  factory OfflineTrack.fromJson(Map<String, dynamic> json) => OfflineTrack(
    file: json['file'],
    size: json['size'] ?? 0,
    albumId: json['album_id'],
    collections: List<String>.from(json['collections']),
  );

  Map<String, dynamic> toJson() => {
    if (file != null) 'file': file,
    'size': size,
    'album_id': albumId,
    'collections': collections,
  };
}

enum CollectionPhase { none, downloading, downloaded }

class CollectionStatus {
  const CollectionStatus.none() : phase = CollectionPhase.none, done = 0, total = 0;
  const CollectionStatus.downloading(this.done, this.total) : phase = CollectionPhase.downloading;
  const CollectionStatus.downloaded(this.total) : phase = CollectionPhase.downloaded, done = total;
  final CollectionPhase phase;
  final int done;
  final int total;
}

/// Cover version files read so far (`<directory>/<albumId>` → key).
final _storedCoverKeys = <String, String?>{};

class OfflineState {
  const OfflineState({
    this.collections = const {},
    this.tracks = const {},
    this.trackLyrics = const {},
    this.queued = 0,
    this.currentTrackId,
    this.waitingForWifi = false,
    this.loaded = false,
    this.directory,
  });
  final Map<String, OfflineCollection> collections;
  final Map<String, OfflineTrack> tracks;
  final Map<String, Lyrics> trackLyrics;
  final int queued;
  final String? currentTrackId;
  final bool waitingForWifi;
  final bool loaded;
  final String? directory;

  bool isDownloaded(String trackId) => filePath(trackId) != null;

  Lyrics? lyrics(String trackId) => trackLyrics[trackId];

  String? filePath(String trackId) {
    final file = tracks[trackId]?.file;
    if (kIsWeb || directory == null || file == null) return null;
    final path = '$directory/$file';
    return File(path).existsSync() ? path : null;
  }

  String? coverPath(String albumId) {
    if (kIsWeb || directory == null) return null;
    final path = '$directory/covers/$albumId.jpg';
    return File(path).existsSync() ? path : null;
  }

  /// Whether the downloaded cover is the server's current one (false after a cover was replaced on the server).
  bool coverCurrent(String albumId) {
    final expected = coverKeys[albumId];
    if (expected == null || kIsWeb || directory == null) return true;
    return _storedCoverKeys.putIfAbsent('$directory/$albumId', () {
          final file = File('$directory/covers/$albumId.key');
          return file.existsSync() ? file.readAsStringSync().trim() : null;
        }) ==
        expected;
  }

  CollectionStatus status(String key) {
    final collection = collections[key];
    if (collection == null) return const CollectionStatus.none();
    final ids = collection.orderedTracks.map((t) => t.id).toSet();
    final done = ids.where(isDownloaded).length;
    return done == ids.length
        ? CollectionStatus.downloaded(ids.length)
        : CollectionStatus.downloading(done, ids.length);
  }

  int get totalBytes => tracks.values.fold(0, (total, track) => total + track.size);
}

// Providers also let store tests use isolated directories and connectivity.
final offlineDirectoryProvider = Provider<Future<Directory>>(
  (ref) async => Directory('${(await getApplicationSupportDirectory()).path}/offline'),
);
final offlineConnectivityProvider = Provider<Connectivity>((ref) => Connectivity());
final offlineProvider = NotifierProvider<OfflineController, OfflineState>(OfflineController.new);

class OfflineController extends Notifier<OfflineState> {
  // A new ticket prevents a cancelled job from consuming a re-added track.
  final _queue = <String, int>{};
  int _nextTicket = 0;
  final _coverAttempts = <String>{};
  Future<void>? _loading;
  Future<void>? _worker;
  Future<void>? _syncing;
  Future<void>? _clearing;
  Future<void> _pending = Future.value();
  CancelToken? _cancel;
  Completer<void>? _wake;
  Completer<void>? _retryWake;
  int _generation = 0;
  OfflineTransfer? _transfer;
  final _transfers = <String, DownloadTask>{};
  final _bufferedUpdates = <TaskStatusUpdate>[];
  Future<void> _transferUpdates = Future.value();
  Future<void> _transferSettings = Future.value();
  bool _transfersReady = false;
  bool _changingWifi = false;

  @override
  OfflineState build() {
    if (!kIsWeb) {
      _transfer = ref.read(offlineTransferProvider);
      final transferSubscription = _transfer?.updates.listen((update) {
        if (!_transfersReady) {
          _bufferedUpdates.add(update);
        } else {
          _transferUpdates = _transferUpdates.then((_) => _handleTransferUpdate(update)).catchError((Object _) {});
        }
      });
      final lifecycle = AppLifecycleListener(
        onResume: () {
          _signal(interruptRetry: true);
          _recoverQueue();
        },
      );
      final connectivitySubscription = ref.read(offlineConnectivityProvider).onConnectivityChanged.listen((results) {
        if (results.any((result) => result != ConnectivityResult.none)) {
          _signal(interruptRetry: true);
          _recoverQueue();
        }
      });
      final timer = Timer.periodic(const Duration(minutes: 30), (_) {
        if (ref.read(sessionProvider).loggedIn && !ref.read(sessionProvider).offline) sync().ignore();
      });
      ref.listen(offlineSettingsProvider, (previous, next) {
        _signal();
        if (_transfer != null && previous?.wifiOnly != next.wifiOnly) {
          _changingWifi = true;
          _transferSettings = _transferSettings.then((_) => _requeueTransfers());
          _transferSettings.ignore();
        }
      });
      ref.listen(appLocaleProvider, (_, _) => _configureNotifications());
      ref.listen(sessionProvider.select((s) => (s.loggedIn, s.offline)), (previous, next) {
        if (!next.$1) {
          _cancel?.cancel();
          _queue.clear();
          _cancelTransfers(_transfers.keys.toList()).ignore();
          _signal(interruptRetry: true);
          _publish();
        } else if (!next.$2 && (previous?.$1 != true || previous?.$2 == true)) {
          // The store observes restoration; the session provider must not depend on the store.
          Future.microtask(() {
            if (ref.mounted) sync().ignore();
          });
        }
      });
      ref.onDispose(() {
        timer.cancel();
        lifecycle.dispose();
        connectivitySubscription.cancel();
        transferSubscription?.cancel();
        _cancel?.cancel();
        _signal(interruptRetry: true);
      });
    }
    return const OfflineState();
  }

  /// Awaited in main before building the app, so no consumer sees an unloaded index.
  Future<void> load() => kIsWeb ? Future.value() : _loading ??= _load();

  Future<void> _load() async {
    final directory = await ref.read(offlineDirectoryProvider);
    await Directory('${directory.path}/tracks').create(recursive: true);
    await Directory('${directory.path}/covers').create(recursive: true);
    await Directory('${directory.path}/lyrics').create(recursive: true);
    final index = File('${directory.path}/index.json');
    var collections = <String, OfflineCollection>{};
    var tracks = <String, OfflineTrack>{};
    if (await index.exists()) {
      final json = jsonDecode(await index.readAsString()) as Map<String, dynamic>;
      if (json['version'] == 1) {
        collections = {
          for (final entry in (json['collections'] as Map).entries)
            entry.key as String: OfflineCollection.fromJson(Map<String, dynamic>.from(entry.value)),
        };
        tracks = {
          for (final entry in (json['tracks'] as Map).entries)
            entry.key as String: OfflineTrack.fromJson(Map<String, dynamic>.from(entry.value)),
        };
      }
    }
    // Files removed by the OS must be eligible for downloading again.
    tracks = {
      for (final entry in tracks.entries)
        entry.key: entry.value.file != null && !File('${directory.path}/${entry.value.file}').existsSync()
            ? OfflineTrack(albumId: entry.value.albumId, collections: entry.value.collections)
            : entry.value,
    };
    final trackLyrics = <String, Lyrics>{};
    for (final id in tracks.keys) {
      try {
        final file = File('${directory.path}/lyrics/$id.json');
        if (await file.exists()) trackLyrics[id] = Lyrics.fromJson(jsonDecode(await file.readAsString()));
      } catch (_) {
        // A missing or damaged lyrics cache must not prevent loading downloaded music.
      }
    }
    state = OfflineState(
      collections: Map.unmodifiable(collections),
      tracks: Map.unmodifiable(tracks),
      trackLyrics: Map.unmodifiable(trackLyrics),
      directory: directory.path,
      loaded: true,
    );
    await _persist();
    if (_transfer != null) {
      _configureNotifications();
      final restored = await _transfer!.restore();
      _bufferedUpdates.insertAll(0, restored);
      while (_bufferedUpdates.isNotEmpty && ref.mounted) {
        final update = _bufferedUpdates.removeAt(0);
        final task = update.task;
        if (task is! DownloadTask || task.group != 'offline' || !task.taskId.startsWith('offline:')) continue;
        final id = task.taskId.substring('offline:'.length);
        if (state.tracks.containsKey(id) && !state.isDownloaded(id)) {
          _queue.putIfAbsent(id, () => _nextTicket++);
          _transfers.putIfAbsent(id, () => task);
        }
        await _handleTransferUpdate(update);
      }
      _transfersReady = true;
    }
    _recoverQueue();
  }

  void _recoverQueue() {
    if (!ref.mounted || !state.loaded || _clearing != null) return;
    final session = ref.read(sessionProvider);
    if (!session.loggedIn || session.offline) return;
    for (final id in [
      for (final collection in state.collections.values)
        for (final track in collection.orderedTracks) track.id,
      ...state.tracks.keys,
    ]) {
      if (state.tracks[id]?.file == null && state.tracks.containsKey(id)) {
        _queue.putIfAbsent(id, () => _nextTicket++);
      }
    }
    _publish();
    _startWorker();
  }

  void _configureNotifications() {
    final l10n = lookupAppLocalizations(ref.read(appLocaleProvider));
    _transfer?.configureNotifications(
      l10n.offlineNotificationRunning('{numFinished}', '{numTotal}'),
      l10n.offlineNotificationComplete,
    );
  }

  int get totalBytes => state.totalBytes;

  Future<void> _serialize(Future<void> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.catchError((Object _) {});
    return result;
  }

  void _publish({
    Map<String, OfflineCollection>? collections,
    Map<String, OfflineTrack>? tracks,
    Map<String, Lyrics>? trackLyrics,
    String? currentTrackId,
    bool? waitingForWifi,
    bool clearCurrent = false,
  }) {
    if (!ref.mounted) return;
    state = OfflineState(
      collections: collections == null ? state.collections : Map.unmodifiable(collections),
      tracks: tracks == null ? state.tracks : Map.unmodifiable(tracks),
      trackLyrics: trackLyrics == null ? state.trackLyrics : Map.unmodifiable(trackLyrics),
      directory: state.directory,
      loaded: state.loaded,
      queued: _queue.length,
      currentTrackId: clearCurrent ? null : currentTrackId ?? state.currentTrackId,
      waitingForWifi: waitingForWifi ?? state.waitingForWifi,
    );
  }

  Future<void> _persist() async {
    final directory = state.directory!;
    final temp = File('$directory/index.json.tmp');
    await temp.writeAsString(
      jsonEncode({
        'version': 1,
        'collections': {for (final entry in state.collections.entries) entry.key: entry.value.toJson()},
        'tracks': {for (final entry in state.tracks.entries) entry.key: entry.value.toJson()},
      }),
      flush: true,
    );
    await temp.rename('$directory/index.json');
  }

  Future<void> add(String kind, String id) async {
    if (kIsWeb) return;
    await load();
    await _clearing;
    final generation = _generation;
    final data = await ref.read(apiProvider).offlineCollection(kind, id);
    if (!ref.mounted || generation != _generation) return;
    final key = kind == 'liked' ? 'liked' : '$kind:$id';
    await _serialize(() async {
      if (generation != _generation) return;
      await _replace(kind, id, data, addedAt: state.collections[key]?.addedAt);
    });
    _startWorker();
  }

  Future<void> _replace(String kind, String id, dynamic data, {DateTime? addedAt}) async {
    final collection = OfflineCollection(
      kind: kind,
      id: kind == 'liked' ? 'liked' : id,
      name: switch (kind) {
        'album' => data['title'] as String,
        'playlist' => data['name'] as String,
        _ => 'Liked',
      },
      addedAt: addedAt ?? DateTime.now(),
      syncedAt: DateTime.now(),
      data: data,
    );
    final key = collection.key;
    final ordered = collection.orderedTracks;
    final ids = ordered.map((t) => t.id).toSet();
    final tracks = Map<String, OfflineTrack>.of(state.tracks);
    for (final entry in tracks.entries.toList()) {
      if (entry.value.collections.contains(key) && !ids.contains(entry.key)) {
        await _unlink(tracks, entry.key, key);
      }
    }
    for (final track in ordered) {
      final previous = tracks[track.id];
      tracks[track.id] = OfflineTrack(
        file: previous?.file,
        size: previous?.size ?? 0,
        albumId: track.album.id,
        collections: List.unmodifiable({...?previous?.collections, key}),
      );
    }
    _publish(collections: {...state.collections, key: collection}, tracks: tracks);
    await _deleteOrphanCovers();
    for (final track in ordered) {
      if (!state.isDownloaded(track.id) ||
          ((state.coverPath(track.album.id) == null || !state.coverCurrent(track.album.id)) &&
              !_coverAttempts.contains(track.album.id))) {
        _queue.putIfAbsent(track.id, () => _nextTicket++);
      }
    }
    _publish();
    await _persist();
  }

  Future<void> _unlink(Map<String, OfflineTrack> tracks, String id, String key) async {
    final track = tracks[id]!;
    final collections = track.collections.where((c) => c != key).toList();
    if (collections.isEmpty) {
      tracks.remove(id);
      _queue.remove(id);
      await _cancelTransfers([id]);
      if (state.currentTrackId == id) _cancel?.cancel();
      _signal(interruptRetry: state.currentTrackId == id);
      if (track.file != null) await _deleteFile('${state.directory}/${track.file}');
      await _deleteFile('${state.directory}/lyrics/$id.json');
      _publish(trackLyrics: {...state.trackLyrics}..remove(id));
    } else {
      tracks[id] = OfflineTrack(file: track.file, size: track.size, albumId: track.albumId, collections: collections);
    }
  }

  Future<void> remove(String key) async {
    if (kIsWeb) return;
    await load();
    await _clearing;
    await _serialize(() => _remove(key));
  }

  Future<void> _remove(String key) async {
    final tracks = Map<String, OfflineTrack>.of(state.tracks);
    for (final id in tracks.keys.toList()) {
      if (tracks[id]!.collections.contains(key)) await _unlink(tracks, id, key);
    }
    _publish(collections: {...state.collections}..remove(key), tracks: tracks);
    await _deleteOrphanCovers();
    await _persist();
    _startWorker();
  }

  Future<void> _deleteOrphanCovers() async {
    final albums = state.tracks.values.map((t) => t.albumId).toSet();
    _coverAttempts.removeWhere((id) => !albums.contains(id));
    await for (final file in Directory('${state.directory}/covers').list()) {
      final name = file.uri.pathSegments.last;
      if (name.endsWith('.jpg') && !albums.contains(name.substring(0, name.length - 4))) await file.delete();
    }
  }

  Future<void> sync() => kIsWeb ? Future.value() : _syncing ??= _sync().whenComplete(() => _syncing = null);

  Future<void> _sync() async {
    await load();
    await _clearing;
    final session = ref.read(sessionProvider);
    if (!session.loggedIn || session.offline) return;
    _coverAttempts.clear();
    final generation = _generation;
    for (final collection in state.collections.values.toList()) {
      try {
        final data = await ref.read(apiProvider).offlineCollection(collection.kind, collection.id);
        if (!ref.mounted || generation != _generation) return;
        await _serialize(() async {
          if (generation != _generation || !identical(state.collections[collection.key], collection)) return;
          await _replace(collection.kind, collection.id, data, addedAt: collection.addedAt);
        });
      } on ApiException catch (e) {
        if (!ref.mounted || generation != _generation) return;
        if (e.statusCode == 404 && collection.kind != 'liked') {
          await _serialize(() async {
            if (generation == _generation && identical(state.collections[collection.key], collection)) {
              await _remove(collection.key);
            }
          });
        } else if (e.statusCode != null) {
          rethrow;
        }
      }
    }
    _startWorker();
  }

  Future<void> clearAll() => kIsWeb ? Future.value() : _clearing ??= _clearAll().whenComplete(() => _clearing = null);

  Future<void> _clearAll() async {
    await load();
    _generation++;
    _coverAttempts.clear();
    _queue.clear();
    _cancel?.cancel();
    _signal(interruptRetry: true);
    await _worker;
    await _transferSettings;
    await _cancelTransfers({...state.tracks.keys, ..._transfers.keys});
    await _serialize(() async {
      _queue.clear();
      _coverAttempts.clear();
      final directory = Directory(state.directory!);
      if (await directory.exists()) await directory.delete(recursive: true);
      await Directory('${directory.path}/tracks').create(recursive: true);
      await Directory('${directory.path}/covers').create(recursive: true);
      await Directory('${directory.path}/lyrics').create(recursive: true);
      _publish(collections: {}, tracks: {}, trackLyrics: {}, clearCurrent: true, waitingForWifi: false);
      await _persist();
    });
  }

  void _startWorker() {
    if (_worker != null || _clearing != null || _queue.isEmpty || !ref.mounted) return;
    if (_transfer != null &&
        (!_transfersReady || _changingWifi || _transfers.length >= 3 || _queue.keys.every(_transfers.containsKey))) {
      return;
    }
    _worker = (_transfer == null ? _runWorker() : _runTransferWorker()).whenComplete(() {
      _worker = null;
      if (ref.mounted) {
        _publish(currentTrackId: _transfers.keys.firstOrNull, clearCurrent: _transfers.isEmpty, waitingForWifi: false);
        if (_queue.isNotEmpty) _startWorker();
      }
    });
    _worker!.ignore();
  }

  Future<void> _cancelTransfers(Iterable<String> ids) async {
    if (_transfer == null) return;
    final removed = ids.toList();
    for (final id in removed) {
      _transfers.remove(id);
    }
    if (removed.isNotEmpty) await _transfer!.cancel(removed.map((id) => 'offline:$id'));
    for (final id in removed) {
      await _deleteFile('${state.directory}/tracks/$id.download');
    }
  }

  Future<void> _requeueTransfers() async {
    try {
      await _worker;
      await _serialize(() => _cancelTransfers(_transfers.keys.toList()));
    } finally {
      _changingWifi = false;
      if (ref.mounted) _startWorker();
    }
  }

  Future<void> _runTransferWorker() async {
    final generation = _generation;
    while (ref.mounted && generation == _generation && !_changingWifi && _transfers.length < 3) {
      final id = _queue.keys.where((id) => !_transfers.containsKey(id)).firstOrNull;
      if (id == null) break;
      final ticket = _queue[id]!;
      try {
        final api = ref.read(apiProvider);
        if (state.isDownloaded(id)) {
          await _downloadLyrics(api, id, generation, ticket);
          if (_active(id, generation, ticket)) {
            await _downloadCover(api, state.tracks[id]!.albumId, generation, CancelToken());
          }
          if (_queue[id] == ticket) _queue.remove(id);
          continue;
        }
        final settings = ref.read(offlineSettingsProvider);
        final format = settings.quality == 'original' ? 'auto' : 'opus';
        final bitrate = format == 'auto' ? null : (settings.quality == 'high' ? 256 : 160);
        final task = await _transfer!.createTask(
          id: id,
          url: api.streamUrl(id, format: format, bitrate: bitrate),
          headers: api.mediaHeaders,
          directory: state.directory!,
          wifiOnly: settings.wifiOnly,
          token: '${DateTime.now().microsecondsSinceEpoch}:$ticket',
        );
        if (!_active(id, generation, ticket)) continue;
        _transfers[id] = task;
        _publish(currentTrackId: _transfers.keys.first);
        if (!await _transfer!.enqueue(task)) {
          await _handleTransferUpdate(TaskStatusUpdate(task, TaskStatus.failed));
        }
      } catch (_) {
        if (_queue[id] == ticket) {
          _transfers.remove(id);
          _queue.remove(id);
          await _deleteFile('${state.directory}/tracks/$id.download');
        }
      }
    }
  }

  Future<void> _handleTransferUpdate(TaskStatusUpdate update) async {
    final task = update.task;
    if (!ref.mounted || task.group != 'offline' || !task.taskId.startsWith('offline:')) return;
    final id = task.taskId.substring('offline:'.length);
    if (!state.tracks.containsKey(id)) {
      if (!update.status.isFinalState) await _transfer!.cancel([task.taskId]);
      await _deleteFile(await task.filePath());
      return;
    }
    // A cancellation may report late, after the same track was re-enqueued.
    if (_transfers[id]?.metaData != task.metaData || !_transfers.containsKey(id)) return;
    if (!update.status.isFinalState) return;
    final generation = _generation;
    final ticket = _queue[id]!;
    final path = '${state.directory}/tracks/$id.download';
    try {
      if (update.status == TaskStatus.complete) {
        await _serialize(() async {
          if (!_active(id, generation, ticket)) return;
          final source = File(path);
          if (!await source.exists()) return; // A replay of an already processed completion.
          final relative = 'tracks/$id.${await _sniffExtension(source)}';
          final file = await source.rename('${state.directory}/$relative');
          final previous = state.tracks[id]!;
          _publish(
            tracks: {
              ...state.tracks,
              id: OfflineTrack(
                file: relative,
                size: await file.length(),
                albumId: previous.albumId,
                collections: previous.collections,
              ),
            },
          );
          await _persist();
        });
        final api = ref.read(apiProvider);
        if (_active(id, generation, ticket)) await _downloadLyrics(api, id, generation, ticket);
        if (_active(id, generation, ticket) && state.isDownloaded(id)) {
          await _downloadCover(api, state.tracks[id]!.albumId, generation, CancelToken());
        }
      } else if (update.status == TaskStatus.failed || update.status == TaskStatus.notFound) {
        await _deleteFile(path);
      }
    } finally {
      if (_transfers[id]?.metaData == task.metaData) {
        _transfers.remove(id);
        if (_queue[id] == ticket) _queue.remove(id);
      }
      if (ref.mounted) {
        _publish(currentTrackId: _transfers.keys.firstOrNull, clearCurrent: _transfers.isEmpty);
        _startWorker();
      }
    }
  }

  static Future<String> _sniffExtension(File file) async {
    final input = await file.open();
    late List<int> bytes;
    try {
      bytes = await input.read(12);
    } finally {
      await input.close();
    }
    bool startsWith(List<int> signature) =>
        bytes.length >= signature.length && listEquals(bytes.sublist(0, signature.length), signature);
    if (startsWith([0x66, 0x4c, 0x61, 0x43])) return 'flac';
    if (startsWith([0x4f, 0x67, 0x67, 0x53])) return 'ogg';
    if (startsWith([0x49, 0x44, 0x33]) ||
        (bytes.length >= 2 && bytes[0] == 0xff && ((bytes[1] & 0xf0) == 0xe0 || bytes[1] == 0xfb))) {
      return 'mp3';
    }
    if (bytes.length >= 8 && listEquals(bytes.sublist(4, 8), [0x66, 0x74, 0x79, 0x70])) return 'm4a';
    return 'audio';
  }

  void _signal({bool interruptRetry = false}) {
    if (interruptRetry && _retryWake != null && !_retryWake!.isCompleted) _retryWake!.complete();
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  bool _active(String id, int generation, int ticket) =>
      ref.mounted && generation == _generation && _queue[id] == ticket;

  Future<bool> _waitForWifi(String id, int generation, int ticket) async {
    if (!ref.read(offlineSettingsProvider).wifiOnly) return true;
    final connectivity = ref.read(offlineConnectivityProvider);
    final subscription = connectivity.onConnectivityChanged.listen((_) => _signal());
    try {
      while (_active(id, generation, ticket)) {
        _wake = Completer<void>();
        if (!ref.read(offlineSettingsProvider).wifiOnly) return true;
        final results = await connectivity.checkConnectivity();
        if (results.contains(ConnectivityResult.wifi) || results.contains(ConnectivityResult.ethernet)) return true;
        if (!_active(id, generation, ticket)) return false;
        _publish(waitingForWifi: true);
        await _wake!.future;
      }
      return false;
    } finally {
      await subscription.cancel();
      _wake = null;
      if (ref.mounted) _publish(waitingForWifi: false);
    }
  }

  Future<void> _runWorker() async {
    final generation = _generation;
    while (ref.mounted && _queue.isNotEmpty && generation == _generation) {
      final id = _queue.keys.first;
      final ticket = _queue[id]!;
      _publish(currentTrackId: id);
      // An initial attempt followed by at most three retries.
      for (var attempt = 0; attempt <= 3 && _active(id, generation, ticket); attempt++) {
        String? part;
        try {
          if (!await _waitForWifi(id, generation, ticket) || !_active(id, generation, ticket)) break;
          final quality = ref.read(offlineSettingsProvider).quality;
          final format = quality == 'original' ? 'auto' : 'opus';
          final bitrate = format == 'auto'
              ? null
              : quality == 'high'
              ? 256
              : 160;
          final api = ref.read(apiProvider);
          final cancel = _cancel = CancelToken();
          if (state.isDownloaded(id)) {
            await _downloadLyrics(api, id, generation, ticket);
            await _downloadCover(api, state.tracks[id]!.albumId, generation, cancel);
            break;
          }
          String? relative;
          await api.downloadMedia(api.streamUrl(id, format: format, bitrate: bitrate), (contentType) {
            final ext = format == 'opus' ? 'ogg' : _extension(contentType);
            relative = 'tracks/$id.$ext';
            return part = '${state.directory}/$relative.part';
          }, cancelToken: cancel);
          if (!_active(id, generation, ticket)) break;
          final albumId = state.tracks[id]!.albumId;
          await _serialize(() async {
            if (!_active(id, generation, ticket)) return;
            final file = await File(part!).rename('${state.directory}/$relative');
            final previous = state.tracks[id]!;
            _publish(
              tracks: {
                ...state.tracks,
                id: OfflineTrack(
                  file: relative,
                  size: await file.length(),
                  albumId: previous.albumId,
                  collections: previous.collections,
                ),
              },
            );
            await _persist();
          });
          if (_active(id, generation, ticket)) await _downloadLyrics(api, id, generation, ticket);
          if (_active(id, generation, ticket)) await _downloadCover(api, albumId, generation, cancel);
          break;
        } catch (_) {
          if (!_active(id, generation, ticket) || _cancel?.isCancelled == true) break;
          if (attempt < 3) {
            final retry = _retryWake = Completer<void>();
            final timer = Timer(const Duration(seconds: 10), () {
              if (!retry.isCompleted) retry.complete();
            });
            try {
              await retry.future;
            } finally {
              timer.cancel();
              _retryWake = null;
            }
          }
        } finally {
          if (part != null) await _deleteFile(part!);
        }
      }
      if (_queue[id] == ticket) _queue.remove(id);
      if (ref.mounted) _publish(clearCurrent: true);
    }
  }

  Future<void> _downloadLyrics(ApiClient api, String id, int generation, int ticket) async {
    if (state.lyrics(id) != null) return;
    try {
      final lyrics = await api.lyrics(id);
      await _serialize(() async {
        if (!_active(id, generation, ticket) || !state.isDownloaded(id)) return;
        await File('${state.directory}/lyrics/$id.json').writeAsString(jsonEncode(lyrics.toJson()));
        _publish(trackLyrics: {...state.trackLyrics, id: lyrics});
      });
    } catch (_) {
      // Lyrics are optional; a failed lookup must not fail the track download.
    }
  }

  Future<void> _downloadCover(ApiClient api, String albumId, int generation, CancelToken cancel) async {
    if ((state.coverPath(albumId) != null && state.coverCurrent(albumId)) || !_coverAttempts.add(albumId)) return;
    final path = '${state.directory}/covers/$albumId.jpg';
    final key = coverKeys[albumId];
    try {
      await api.downloadMedia(api.coverUrl(albumId, size: 600), (_) => '$path.part', cancelToken: cancel);
      await _serialize(() async {
        if (generation != _generation || !state.tracks.values.any((t) => t.albumId == albumId)) return;
        await File('$path.part').rename(path);
        if (key != null) {
          await File('${state.directory}/covers/$albumId.key').writeAsString(key);
          _storedCoverKeys['${state.directory}/$albumId'] = key;
        }
        _publish();
      });
    } on ApiException catch (e) {
      if (e.statusCode != 404) _coverAttempts.remove(albumId);
      // Artwork must never prevent playing a successfully downloaded song (including cover 404s).
    } finally {
      await _deleteFile('$path.part');
    }
  }

  static String _extension(String? contentType) => switch (contentType?.split(';').first.trim().toLowerCase()) {
    'audio/flac' => 'flac',
    'audio/mpeg' => 'mp3',
    'audio/mp4' || 'audio/x-m4a' || 'audio/aac' => 'm4a',
    'audio/ogg' => 'ogg',
    _ => 'audio',
  };

  Future<void> _deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
