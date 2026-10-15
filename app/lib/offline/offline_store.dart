import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/session.dart';

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

class OfflineState {
  const OfflineState({
    this.collections = const {},
    this.tracks = const {},
    this.queued = 0,
    this.currentTrackId,
    this.waitingForWifi = false,
    this.loaded = false,
    this.directory,
  });
  final Map<String, OfflineCollection> collections;
  final Map<String, OfflineTrack> tracks;
  final int queued;
  final String? currentTrackId;
  final bool waitingForWifi;
  final bool loaded;
  final String? directory;

  bool isDownloaded(String trackId) => filePath(trackId) != null;

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

  @override
  OfflineState build() {
    if (!kIsWeb) {
      final timer = Timer.periodic(const Duration(minutes: 30), (_) {
        if (ref.read(sessionProvider).loggedIn && !ref.read(sessionProvider).offline) sync().ignore();
      });
      ref.listen(offlineSettingsProvider, (_, _) => _signal());
      ref.listen(sessionProvider.select((s) => (s.loggedIn, s.offline)), (previous, next) {
        if (!next.$1) {
          _cancel?.cancel();
          _queue.clear();
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
    state = OfflineState(
      collections: Map.unmodifiable(collections),
      tracks: Map.unmodifiable(tracks),
      directory: directory.path,
      loaded: true,
    );
    await _persist();
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
    String? currentTrackId,
    bool? waitingForWifi,
    bool clearCurrent = false,
  }) {
    if (!ref.mounted) return;
    state = OfflineState(
      collections: collections == null ? state.collections : Map.unmodifiable(collections),
      tracks: tracks == null ? state.tracks : Map.unmodifiable(tracks),
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
          (state.coverPath(track.album.id) == null && !_coverAttempts.contains(track.album.id))) {
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
      if (state.currentTrackId == id) _cancel?.cancel();
      _signal(interruptRetry: state.currentTrackId == id);
      if (track.file != null) await _deleteFile('${state.directory}/${track.file}');
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
    await _serialize(() async {
      _queue.clear();
      _coverAttempts.clear();
      final directory = Directory(state.directory!);
      if (await directory.exists()) await directory.delete(recursive: true);
      await Directory('${directory.path}/tracks').create(recursive: true);
      await Directory('${directory.path}/covers').create(recursive: true);
      _publish(collections: {}, tracks: {}, clearCurrent: true, waitingForWifi: false);
      await _persist();
    });
  }

  void _startWorker() {
    if (_worker != null || _clearing != null || _queue.isEmpty || !ref.mounted) return;
    _worker = _runWorker().whenComplete(() {
      _worker = null;
      if (ref.mounted) {
        _publish(clearCurrent: true, waitingForWifi: false);
        if (_queue.isNotEmpty) _startWorker();
      }
    });
    _worker!.ignore();
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

  Future<void> _downloadCover(ApiClient api, String albumId, int generation, CancelToken cancel) async {
    if (state.coverPath(albumId) != null || !_coverAttempts.add(albumId)) return;
    final path = '${state.directory}/covers/$albumId.jpg';
    try {
      await api.downloadMedia(api.coverUrl(albumId, size: 600), (_) => '$path.part', cancelToken: cancel);
      await _serialize(() async {
        if (generation != _generation || !state.tracks.values.any((t) => t.albumId == albumId)) return;
        await File('$path.part').rename(path);
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
