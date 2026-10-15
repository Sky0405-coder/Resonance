import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/offline/offline_store.dart';

Map<String, dynamic> _user([String displayName = 'User']) => {
  'id': 'u',
  'username': 'user',
  'display_name': displayName,
  'role': 'user',
  'accent_color': '#00ff00',
  'is_disabled': false,
  'created_at': '2026-01-01T00:00:00Z',
  'last_seen_at': '2026-10-15T00:00:00Z',
};
Map<String, dynamic> _album(String title) => {
  'id': 'a',
  'title': title,
  'artist': {'id': 'artist', 'name': 'Artist'},
  'duration': 0,
  'tracks': [],
};

Future<void> _until(bool Function() predicate, {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out waiting for session restoration');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HttpServer server;
  late String url;
  late int status;
  late String title;
  late List<Uri> requests;
  late ProviderContainer container;
  late SharedPreferences prefs;

  final httpOverrides = HttpOverrides.current;
  setUp(() async {
    HttpOverrides.global = null;
    directory = await (await Directory('build').create()).createTemp('session-test-');
    status = 200;
    title = 'Updated';
    requests = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    url = 'http://${server.address.address}:${server.port}';
    server.listen((request) async {
      requests.add(request.uri);
      expect(request.headers.value(HttpHeaders.authorizationHeader), 'Bearer token');
      if (request.uri.path == '/api/me') {
        request.response.statusCode = status;
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(status == 200 ? _user('Restored') : {'detail': 'unavailable'}));
      } else if (request.uri.path == '/api/albums/a') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(_album(title)));
      } else {
        request.response.headers.contentType = ContentType('audio', 'mpeg');
        request.response.add([1, 2, 3, 4, 5]);
      }
      await request.response.close();
    });
  });

  Future<void> start({bool cached = true, bool token = true}) async {
    SharedPreferences.setMockInitialValues({
      'server_url': url,
      if (token) 'token': 'token',
      if (cached) 'session.user': jsonEncode(_user()),
    });
    prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(
      retry: (_, _) => null,
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        offlineDirectoryProvider.overrideWithValue(Future.value(directory)),
      ],
    );
    await container.read(offlineProvider.notifier).load();
    await _until(() => !container.read(sessionProvider).loading);
  }

  tearDown(() async {
    container.dispose();
    await server.close(force: true);
    await directory.delete(recursive: true);
    HttpOverrides.global = httpOverrides;
  });

  test('User JSON round-trips every cached field', () async {
    await start();
    final user = User.fromJson(_user());
    final restored = User.fromJson(user.toJson());
    expect(restored.id, user.id);
    expect(restored.username, user.username);
    expect(restored.displayName, user.displayName);
    expect(restored.role, user.role);
    expect(restored.accentColor, user.accentColor);
    expect(restored.isDisabled, user.isDisabled);
    expect(restored.createdAt, user.createdAt);
    expect(restored.lastSeenAt, user.lastSeenAt);
    expect(jsonDecode(prefs.getString('session.user')!)['display_name'], 'Restored');
  });

  test('cached user restores offline and a 30-second retry recovers and syncs saved collections', () async {
    await File('${directory.path}/index.json').writeAsString(
      jsonEncode({
        'version': 1,
        'collections': {
          'album:a': {
            'kind': 'album',
            'id': 'a',
            'name': 'Cached',
            'added_at': '2026-01-01T00:00:00Z',
            'synced_at': null,
            'data': _album('Cached'),
          },
        },
        'tracks': {},
      }),
    );
    status = 503;
    await start();
    expect(container.read(sessionProvider).offline, true);
    expect(container.read(sessionProvider).loggedIn, true);
    expect(container.read(sessionProvider).user!.displayName, 'User');
    expect(container.read(offlineProvider).collections['album:a']!.name, 'Cached');
    status = 200;
    await _until(() => !container.read(sessionProvider).offline, timeout: const Duration(seconds: 33));
    await _until(() => container.read(offlineProvider).collections['album:a']!.name == 'Updated');
    expect(jsonDecode(prefs.getString('session.user')!)['display_name'], 'Restored');
    expect(requests.where((uri) => uri.path == '/api/me').length, 2);
  }, timeout: const Timeout(Duration(seconds: 40)));

  test('401 invalidates cached credentials, while an error without a cached user stays signed out', () async {
    status = 401;
    await start();
    expect(container.read(sessionProvider).loggedIn, false);
    expect(container.read(sessionProvider).offline, false);
    expect(prefs.getString('token'), isNull);
    expect(prefs.getString('session.user'), isNull);
    container.dispose();
    status = 503;
    await start(cached: false);
    expect(container.read(sessionProvider).loggedIn, false);
    expect(container.read(sessionProvider).loading, false);
    expect(container.read(sessionProvider).offline, false);
  });

  test('sign-in persists the user and raw API/download methods use the authenticated Dio client', () async {
    await start(cached: false, token: false);
    await container.read(sessionProvider.notifier).signedIn('token', User.fromJson(_user()));
    expect(jsonDecode(prefs.getString('session.user')!)['id'], 'u');
    final api = container.read(apiProvider);
    expect((await api.offlineCollection('album', 'a'))['title'], 'Updated');
    final part = '${directory.path}/sample.mp3.part';
    String? contentType;
    await api.downloadMedia(api.streamUrl('track', format: 'auto'), (type) {
      contentType = type;
      return part;
    });
    expect(contentType, 'audio/mpeg');
    expect(await File(part).readAsBytes(), [1, 2, 3, 4, 5]);
    expect(requests.last.queryParameters, containsPair('token', 'token'));
    expect(requests.last.queryParameters, containsPair('format', 'auto'));
  });
}
