import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/podcasts.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/offline/media_downloads.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _user = User(
  id: 'u',
  username: 'user',
  displayName: 'User',
  role: 'user',
  accentColor: '#00ff00',
  isDisabled: false,
  createdAt: DateTime.utc(2026),
);

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(serverUrl: 'http://test', token: 'token', user: _user);

  void setOffline(bool offline) => state = state.copyWith(offline: offline);
}

const _episode = PodcastEpisode(
  id: 'e1',
  podcastId: 'p1',
  title: 'Episode',
  podcastTitle: 'Podcast',
  durationSeconds: 3600,
  positionSeconds: 60,
);

class _Api extends ApiClient {
  _Api() : super('http://test', 'token');
  final progress = <String, Object>{};
  bool offline = false;

  @override
  Future<PodcastEpisode> podcastEpisode(String id) async => _episode;

  @override
  Future<dynamic> absGet(String path, [Map<String, dynamic>? query]) async => {
    'id': 'b1',
    'media': {
      'metadata': {'title': 'Book', 'authorName': 'Author'},
      'duration': 300.0,
      'chapters': [
        {'start': 0, 'end': 300, 'title': 'One'},
      ],
      'tracks': [
        {
          'contentUrl': '/api/items/b1/file/1',
          'startOffset': 0,
          'duration': 100.0,
          'metadata': {'ext': '.mp3'},
        },
        {
          'contentUrl': '/api/items/b1/file/2',
          'startOffset': 100,
          'duration': 200.0,
          'metadata': {'ext': '.m4b'},
        },
      ],
    },
  };

  @override
  Future<dynamic> booksGet(String path, [Map<String, dynamic>? query]) async => {
    'id': 'k1',
    'title': 'Ebook',
    'authors': ['Writer'],
    'format': 'epub',
    'size': 3,
    'has_cover': false,
    'filename': 'Writer - Ebook.EPUB',
  };

  @override
  Future<void> saveEpisodeProgress(String id, double position, {required bool completed}) async {
    if (offline) throw ApiException('offline');
    progress['episode:$id'] = position;
  }

  @override
  Future<dynamic> absPatch(String path, Object body) async {
    if (offline) throw ApiException('offline');
    progress[path] = body;
  }
}

class _Fetcher extends MediaFetcher {
  final urls = <String>[];
  final batches = <List<String>>[];
  final names = <String>[];
  Completer<void>? hold;
  bool fail = false;

  /// URLs that fail once while the other files of the batch arrive.
  final failOnce = <String>{};

  @override
  Future<void> fetch({
    required List<MediaTransfer> files,
    required Map<String, String> headers,
    required String name,
    required bool wifiOnly,
    required void Function(double) onProgress,
    required CancelToken cancel,
  }) async {
    batches.add([for (final file in files) file.taskId]);
    names.add(name);
    if (fail) throw ApiException('unreachable');
    var failed = 0;
    for (final file in files) {
      urls.add(file.url);
      if (failOnce.remove(file.url)) {
        failed++;
      } else {
        await File(file.path).writeAsBytes([1, 2, 3]);
      }
    }
    onProgress(0.5);
    if (hold != null) await hold!.future;
    if (failed > 0) throw ApiException('unreachable');
  }

  @override
  Future<void> cancelAll() async {}
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(done(), isTrue);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late SharedPreferences prefs;
  late _Api api;
  late _Fetcher fetcher;
  late ProviderContainer container;

  ProviderContainer make() => ProviderContainer(
    retry: (_, _) => null,
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      apiProvider.overrideWithValue(api),
      mediaDirectoryProvider.overrideWithValue(Future.value(directory)),
      mediaFetcherProvider.overrideWithValue(fetcher),
    ],
  );
  MediaDownloadsState downloads() => container.read(mediaDownloadsProvider);
  MediaDownloadsController controller() => container.read(mediaDownloadsProvider.notifier);

  setUp(() async {
    final build = await Directory('build').create();
    directory = await build.createTemp('media-test-');
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    api = _Api();
    fetcher = _Fetcher();
    container = make();
    await controller().load();
  });

  tearDown(() async {
    await controller().settled();
    container.dispose();
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('downloads an episode, an audiobook in parts and an ebook, and keeps them across restarts', () async {
    await controller().addEpisode(_episode);
    await controller().addAudiobook('b1');
    await controller().addEbook('k1');
    await _until(() => downloads().items.values.every((i) => i.done));

    expect(fetcher.urls, [
      'http://test/api/podcasts/episodes/e1/stream?token=token',
      'http://test/api/abs/api/items/b1/file/1?token=token',
      'http://test/api/abs/api/items/b1/file/2?token=token',
      'http://test/api/books/library/k1/file?token=token',
    ]);
    final book = downloads().ready('audiobook', 'b1')!;
    expect(book.files.map((f) => f.name), ['1.mp3', '2.m4b']);
    expect(book.files.map((f) => f.start), [0, 100]);
    expect(book.duration, 300);
    expect(book.size, 6);
    expect(downloads().ready('ebook', 'k1')!.files.single.name, 'book.epub');
    expect(downloads().ready('episode', 'e1')!.episode.title, 'Episode');
    expect(File(downloads().filePath(book, 1)).existsSync(), isTrue);
    expect(downloads().totalBytes, 12);

    await controller().settled();
    container.dispose();
    container = make();
    await controller().load();
    expect(downloads().items.keys, ['episode:e1', 'audiobook:b1', 'ebook:k1']);
    expect(downloads().ready('audiobook', 'b1'), isNotNull);

    // A file the system removed is downloaded again.
    await File(downloads().filePath(downloads().ready('ebook', 'k1')!, 0)).delete();
    await controller().settled();
    container.dispose();
    container = make();
    await controller().load();
    await _until(() => downloads().ready('ebook', 'k1') != null);
    expect(fetcher.urls.last, 'http://test/api/books/library/k1/file?token=token');

    await controller().remove('audiobook:b1');
    expect(downloads().items.containsKey('audiobook:b1'), isFalse);
    expect(Directory('${directory.path}/audiobook/b1').existsSync(), isFalse);
  });

  test('failed downloads wait for a retry, removal stops a running one', () async {
    fetcher.fail = true;
    await controller().addEbook('k1');
    await _until(() => downloads().phase('ebook', 'k1') == MediaDownloadPhase.failed);
    fetcher.fail = false;
    controller().retry('ebook:k1');
    await _until(() => downloads().phase('ebook', 'k1') == MediaDownloadPhase.done);

    fetcher.hold = Completer();
    await controller().addEpisode(_episode);
    await _until(() => downloads().progress['episode:e1'] == 0.5);
    expect(downloads().phase('episode', 'e1'), MediaDownloadPhase.downloading);
    final removing = controller().remove('episode:e1');
    fetcher.hold!.complete();
    await removing;
    expect(downloads().items.containsKey('episode:e1'), isFalse);
    expect(Directory('${directory.path}/episode/e1').existsSync(), isFalse);
  });

  test('an audiobook goes out as one batch, and a retry fetches only the missing files', () async {
    fetcher.failOnce.add('http://test/api/abs/api/items/b1/file/2?token=token');
    await controller().addAudiobook('b1');
    await _until(() => downloads().phase('audiobook', 'b1') == MediaDownloadPhase.failed);
    expect(fetcher.batches.single, ['media:audiobook:b1:0', 'media:audiobook:b1:1']);
    expect(fetcher.names.single, 'Book');
    final item = downloads().item('audiobook', 'b1')!;
    expect(File(downloads().filePath(item, 0)).existsSync(), isTrue);
    expect(File('${downloads().filePath(item, 1)}.part').existsSync(), isFalse);

    controller().retry('audiobook:b1');
    await _until(() => downloads().ready('audiobook', 'b1') != null);
    expect(fetcher.batches.last, ['media:audiobook:b1:1']);
    expect(downloads().ready('audiobook', 'b1')!.size, 6);
  });

  test('positions listened to offline reach the server later', () async {
    await controller().addEpisode(_episode);
    await controller().addAudiobook('b1');
    await _until(() => downloads().items.values.every((i) => i.done));

    await controller().savePosition('episode', 'e1', 120, completed: false, synced: false);
    await controller().savePosition('audiobook', 'b1', 150, completed: false, synced: false);
    api.offline = true;
    await controller().flush();
    expect(downloads().ready('episode', 'e1')!.pending, isTrue);

    // Kept on the device across restarts.
    await controller().settled();
    container.dispose();
    container = make();
    await controller().load();
    expect(downloads().ready('audiobook', 'b1')!.position, 150);

    api.offline = false;
    await controller().flush();
    expect(api.progress['episode:e1'], 120);
    expect(
      jsonEncode(api.progress['me/progress/b1']),
      jsonEncode({'currentTime': 150.0, 'duration': 300.0, 'progress': 0.5, 'isFinished': false}),
    );
    expect(downloads().items.values.any((i) => i.pending), isFalse);
  });

  test('nothing downloads while offline', () async {
    (container.read(sessionProvider.notifier) as _Session).setOffline(true);
    await controller().addEbook('k1');
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(fetcher.urls, isEmpty);
    (container.read(sessionProvider.notifier) as _Session).setOffline(false);
    await _until(() => downloads().ready('ebook', 'k1') != null);
  });
}
