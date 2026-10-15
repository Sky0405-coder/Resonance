import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/library.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/offline/offline_store.dart';

final _user = User(
  id: 'u',
  username: 'user',
  displayName: 'User',
  role: 'user',
  accentColor: '#00ff00',
  isDisabled: false,
  createdAt: DateTime.utc(2026),
);

Map<String, dynamic> _track(String id, {String album = 'a'}) => {
  'id': id,
  'title': id,
  'artist': {'id': 'artist', 'name': 'Artist'},
  'artist_credit': 'Artist',
  'album': {'id': album, 'name': album},
  'duration': 120,
};
Map<String, dynamic> _album(List<String> ids, {String name = 'Album'}) => {
  'id': 'a',
  'title': name,
  'artist': {'id': 'artist', 'name': 'Artist'},
  'duration': 120 * ids.length,
  'tracks': [for (final id in ids) _track(id)],
};
Map<String, dynamic> _playlist(List<String> ids) => {
  'id': 'p',
  'name': 'Playlist',
  'is_public': false,
  'owner': {'id': 'u', 'name': 'User'},
  'track_count': ids.length,
  'duration': 120 * ids.length,
  'cover_album_ids': ['a'],
  'entries': [
    for (final id in ids) {'entry_id': 'entry-$id', 'track': _track(id)},
  ],
};

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(serverUrl: 'http://test', token: 'token', user: _user);
}

class _Connectivity implements Connectivity {
  final changes = StreamController<List<ConnectivityResult>>.broadcast();
  List<ConnectivityResult> results = [ConnectivityResult.wifi];
  @override
  Future<List<ConnectivityResult>> checkConnectivity() async => results;
  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged => changes.stream;
  void change(ConnectivityResult result) {
    results = [result];
    changes.add(results);
  }
}

class _Api extends ApiClient {
  _Api() : super('http://test', 'token');
  final collections = <String, dynamic>{};
  final downloaded = <Uri>[];
  final contentTypes = <String, String>{};
  ApiException? failure;
  Completer<void>? hold;
  int failuresLeft = 0;
  int attempts = 0;

  @override
  Future<dynamic> offlineCollection(String kind, String id) async {
    if (failure != null) throw failure!;
    return collections[kind == 'liked' ? 'liked' : '$kind:$id'] ?? (throw ApiException('gone', 404));
  }

  @override
  Future<void> downloadMedia(String url, String Function(String?) destination, {CancelToken? cancelToken}) async {
    final uri = Uri.parse(url);
    downloaded.add(uri);
    final path = destination(contentTypes[uri.pathSegments[2]] ?? 'audio/flac');
    await File(path).writeAsBytes([1, 2, 3, 4]);
    if (uri.path.endsWith('/stream')) {
      attempts++;
      if (failuresLeft-- > 0) throw ApiException('unreachable');
      if (hold != null) {
        await Future.any([hold!.future, cancelToken!.whenCancel.then<void>((_) => throw ApiException('cancelled'))]);
      }
    }
  }

  @override
  Future<AlbumDetail> album(String id) async => AlbumDetail.fromJson(await offlineCollection('album', id));
  @override
  Future<PlaylistDetail> playlist(String id) async => PlaylistDetail.fromJson(await offlineCollection('playlist', id));
  @override
  Future<List<Track>> likedTracks() async => [
    for (final t in await offlineCollection('liked', 'liked')) Track.fromJson(t),
  ];
  @override
  Future<List<Playlist>> playlists() async {
    if (failure != null) throw failure!;
    return [
      for (final e in collections.entries)
        if (e.key.startsWith('playlist:')) Playlist.fromJson(e.value),
    ];
  }

  @override
  Future<Home> home() async => throw failure ?? ApiException('no home cache');
}

Future<void> _until(bool Function() predicate, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for offline state');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences prefs;
  late ProviderContainer container;
  late _Api api;
  late _Connectivity connectivity;
  late OfflineController controller;

  ProviderContainer makeContainer() => ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      apiProvider.overrideWithValue(api),
      offlineDirectoryProvider.overrideWithValue(Future.value(directory)),
      offlineConnectivityProvider.overrideWithValue(connectivity),
    ],
  );
  OfflineState offline() => container.read(offlineProvider);
  Future<void> idle() => _until(() => offline().queued == 0 && offline().currentTrackId == null);

  setUp(() async {
    final build = await Directory('build').create();
    directory = await build.createTemp('offline-test-');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    api = _Api();
    connectivity = _Connectivity();
    container = makeContainer();
    controller = container.read(offlineProvider.notifier);
    await controller.load();
  });
  tearDown(() async {
    await controller.clearAll();
    container.dispose();
    await connectivity.changes.close();
    await directory.delete(recursive: true);
  });

  test('downloads in order, persists raw metadata, and retains shared files until the last unlink', () async {
    api.collections['album:a'] = _album(['t2', 't1']);
    api.collections['playlist:p'] = _playlist(['t1']);
    await controller.add('album', 'a');
    await idle();
    expect(api.downloaded.where((u) => u.path.endsWith('stream')).map((u) => u.pathSegments[2]), ['t2', 't1']);
    expect(api.downloaded.first.queryParameters, containsPair('format', 'opus'));
    expect(api.downloaded.first.queryParameters, containsPair('bitrate', '160'));
    expect(offline().filePath('t1'), endsWith('/tracks/t1.ogg'));
    expect(offline().coverPath('a'), isNotNull);
    expect(controller.totalBytes, 8);
    expect(offline().status('album:a').phase, CollectionPhase.downloaded);
    expect(api.downloaded.where((u) => u.path.endsWith('/cover')).length, 1);
    await controller.add('playlist', 'p');
    await idle();
    expect(offline().tracks['t1']!.collections, ['album:a', 'playlist:p']);
    final json = jsonDecode(await File('${directory.path}/index.json').readAsString());
    expect(json['version'], 1);
    expect(json['collections']['playlist:p']['data'], api.collections['playlist:p']);
    expect(await File('${directory.path}/index.json.tmp').exists(), false);

    container.dispose();
    container = makeContainer();
    controller = container.read(offlineProvider.notifier);
    await controller.load();
    expect(offline().loaded, true);
    expect(offline().isDownloaded('t1'), true);
    await controller.remove('album:a');
    expect(offline().isDownloaded('t1'), true);
    expect(offline().tracks.containsKey('t2'), false);
    expect(await File('${directory.path}/tracks/t2.ogg').exists(), false);
    expect(offline().coverPath('a'), isNotNull);
    await controller.remove('playlist:p');
    expect(offline().tracks, isEmpty);
    expect(offline().coverPath('a'), isNull);
    expect(controller.totalBytes, 0);
  });

  test('sync updates membership and names, ignores network loss, and removes deleted collections', () async {
    api.collections['album:a'] = _album(['t1', 't2']);
    await controller.add('album', 'a');
    await idle();
    final added = offline().collections['album:a']!.addedAt;
    api.collections['album:a'] = _album(['t2', 't3'], name: 'Updated');
    await controller.sync();
    await idle();
    expect(offline().tracks.keys.toSet(), {'t2', 't3'});
    expect(await File('${directory.path}/tracks/t1.ogg').exists(), false);
    expect(offline().collections['album:a']!.name, 'Updated');
    expect(offline().collections['album:a']!.addedAt, added);
    expect(offline().collections['album:a']!.syncedAt, isNotNull);
    api.failure = ApiException('unreachable');
    await controller.sync();
    expect(offline().collections, hasLength(1));
    api.failure = ApiException('gone', 404);
    await controller.sync();
    expect(offline().collections, isEmpty);
    expect(offline().tracks, isEmpty);
    expect(offline().coverPath('a'), isNull);
  });

  test('waits on cellular, resumes on ethernet, and only applies changed quality to future files', () async {
    connectivity.change(ConnectivityResult.mobile);
    api.collections['album:a'] = _album(['t1']);
    await controller.add('album', 'a');
    await _until(() => offline().waitingForWifi);
    expect(api.downloaded, isEmpty);
    expect(offline().status('album:a').done, 0);
    expect(offline().queued, 1);
    connectivity.change(ConnectivityResult.ethernet);
    await idle();
    await container.read(offlineSettingsProvider.notifier).setQuality('high');
    api.collections['album:a'] = _album(['t1', 't2']);
    await controller.sync();
    await idle();
    expect(api.downloaded.where((u) => u.path.endsWith('stream')).last.queryParameters['bitrate'], '256');
    expect(api.downloaded.where((u) => u.path.contains('/t1/stream')).length, 1);
    await container.read(offlineSettingsProvider.notifier).setQuality('original');
    api.collections['album:a'] = _album(['t1', 't2', 't3']);
    api.contentTypes['t3'] = 'audio/mpeg; charset=binary';
    await controller.sync();
    await idle();
    expect(offline().filePath('t3'), endsWith('.mp3'));
    final last = api.downloaded.where((u) => u.path.endsWith('stream')).last;
    expect(last.queryParameters['format'], 'auto');
    expect(last.queryParameters.containsKey('bitrate'), false);
    expect(prefs.getString('offline.quality'), 'original');
  });

  test('disabling Wi-Fi-only wakes the worker and clear cancels a partial file', () async {
    connectivity.change(ConnectivityResult.mobile);
    api.collections['album:a'] = _album(['t1', 't2']);
    api.hold = Completer<void>();
    await controller.add('album', 'a');
    await _until(() => offline().waitingForWifi);
    await container.read(offlineSettingsProvider.notifier).setWifiOnly(false);
    await _until(() => File('${directory.path}/tracks/t1.ogg.part').existsSync());
    expect(offline().isDownloaded('t1'), false);
    await controller.clearAll();
    expect(offline().collections, isEmpty);
    expect(offline().tracks, isEmpty);
    expect(offline().queued, 0);
    expect(offline().currentTrackId, isNull);
    expect(offline().waitingForWifi, false);
    expect(await Directory('${directory.path}/tracks').list().isEmpty, true);
    expect(await Directory('${directory.path}/covers').list().isEmpty, true);
    expect(prefs.getBool('offline.wifiOnly'), false);
  });

  test('detail/list providers fall back only on unreachable-server errors and home still fails', () async {
    api.collections.addAll({
      'album:a': _album(['t1']),
      'playlist:p': _playlist(['t1']),
      'liked': [_track('t1')],
    });
    await controller.add('album', 'a');
    await controller.add('playlist', 'p');
    await controller.add('liked', 'liked');
    await idle();
    expect(offline().collections['liked']!.name, 'Liked');
    api.failure = ApiException('unreachable');
    expect((await container.read(albumProvider('a').future)).tracks.single.id, 't1');
    expect((await container.read(playlistDetailProvider('p').future)).entries.single.track.id, 't1');
    expect((await container.read(likedTracksProvider.future)).single.id, 't1');
    expect((await container.read(playlistsProvider.future)).single.id, 'p');
    await expectLater(container.read(homeProvider.future), throwsA(isA<ApiException>()));
    await expectLater(container.read(albumProvider('missing').future), throwsA(isA<ApiException>()));
    api.failure = ApiException('forbidden', 403);
    container.invalidate(albumProvider('a'));
    await expectLater(
      container.read(albumProvider('a').future),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 403)),
    );
  });

  test('a missing file is detected at startup and downloaded again at sync', () async {
    api.collections['album:a'] = _album(['t1']);
    await controller.add('album', 'a');
    await idle();
    await File(offline().filePath('t1')!).delete();
    container.dispose();
    container = makeContainer();
    controller = container.read(offlineProvider.notifier);
    await controller.load();
    expect(offline().isDownloaded('t1'), false);
    expect(controller.totalBytes, 0);
    await controller.sync();
    await idle();
    expect(offline().isDownloaded('t1'), true);
  });

  test('removing an active collection and re-adding it does not lose the new download job', () async {
    api.collections['album:a'] = _album(['t1']);
    api.hold = Completer<void>();
    await controller.add('album', 'a');
    await _until(() => api.attempts == 1);
    await controller.remove('album:a');
    api.hold!.complete();
    api.hold = null;
    await controller.add('album', 'a');
    await idle();
    expect(offline().isDownloaded('t1'), true);
    expect(offline().collections.keys, ['album:a']);
  });

  test('clearing while a collection is being added leaves an empty index and no queued work', () async {
    api.collections['album:a'] = _album(['t1', 't2']);
    api.hold = Completer<void>();
    final adding = controller.add('album', 'a');
    await _until(() => offline().collections.isNotEmpty);
    await controller.clearAll();
    await adding;
    expect(offline().collections, isEmpty);
    expect(offline().tracks, isEmpty);
    expect(offline().queued, 0);
    expect(offline().currentTrackId, isNull);
    expect(await Directory('${directory.path}/tracks').list().isEmpty, true);
    final index = jsonDecode(await File('${directory.path}/index.json').readAsString());
    expect(index['collections'], isEmpty);
    expect(index['tracks'], isEmpty);
  });

  test('rebuilds a missing cover without downloading existing audio again', () async {
    api.collections['album:a'] = _album(['t1']);
    await controller.add('album', 'a');
    await idle();
    await File(offline().coverPath('a')!).delete();
    await controller.sync();
    await idle();
    expect(offline().coverPath('a'), isNotNull);
    expect(api.attempts, 1);
  });

  test('original downloads select extensions for each supported response content type', () async {
    await container.read(offlineSettingsProvider.notifier).setQuality('original');
    api.contentTypes.addAll({
      'flac': 'audio/flac',
      'mp3': 'audio/mpeg',
      'mp4': 'audio/mp4',
      'm4a': 'audio/x-m4a',
      'aac': 'audio/aac',
      'ogg': 'audio/ogg',
      'unknown': 'application/octet-stream',
    });
    api.collections['album:a'] = _album(api.contentTypes.keys.toList());
    await controller.add('album', 'a');
    await idle();
    for (final entry in {
      'flac': 'flac',
      'mp3': 'mp3',
      'mp4': 'm4a',
      'm4a': 'm4a',
      'aac': 'm4a',
      'ogg': 'ogg',
      'unknown': 'audio',
    }.entries) {
      expect(offline().filePath(entry.key), endsWith('.${entry.value}'));
    }
  });

  test('retries three times then leaves a failed track for the next sync', () async {
    api.collections['album:a'] = _album(['t1']);
    api.failuresLeft = 4;
    await controller.add('album', 'a');
    await _until(() => offline().queued == 0 && offline().currentTrackId == null, timeout: const Duration(seconds: 35));
    expect(api.attempts, 4);
    expect(offline().isDownloaded('t1'), false);
    expect(await File('${directory.path}/tracks/t1.ogg.part').exists(), false);
    await controller.sync();
    await idle();
    expect(offline().isDownloaded('t1'), true);
  }, timeout: const Timeout(Duration(seconds: 45)));
}
