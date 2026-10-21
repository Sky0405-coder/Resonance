import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/player/connect.dart';
import 'package:resonance/player/jam.dart';
import 'package:resonance/player/player.dart';
import 'package:resonance/ui/widgets/devices_sheet.dart';

import 'support/connect_engine.dart';

Track makeTrack(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: const NamedRef('a', 'Artist'),
  artistCredit: 'Artist',
  album: const NamedRef('b', 'Album'),
  duration: 200,
);

Map<String, dynamic> playback({bool playing = true, int position = 10000, int index = 1}) => {
  'track': {
    'id': 'two',
    'title': 'Remote song',
    'artist_credit': 'Remote artist',
    'album': {'id': 'album', 'title': 'Album', 'cover_key': 'cover'},
    'duration': 200,
  },
  'queue': ['one', 'two', 'one'],
  'index': index,
  'queue_length': 3,
  'position_ms': position,
  'playing': playing,
  'shuffle': true,
  'repeat': 'all',
  'volume': 0.4,
};

class _Api extends ApiClient {
  _Api() : super('https://example.test', 'token');
  final fetched = <String>[];
  Completer<Track>? pendingTrack;
  @override
  Future<Track> track(String id) async {
    fetched.add(id);
    return pendingTrack == null ? trackFor(id) : await pendingTrack!.future;
  }

  Track trackFor(String id) => makeTrack(id);
  @override
  Future<StationNowPlaying?> stationNowPlaying(String id) async => null;
  @override
  Future<void> reportPlay(String id, double seconds, {String? context}) async {}
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    serverUrl: 'https://example.test',
    token: 'token',
    user: User(
      id: 'u',
      username: 'user',
      displayName: 'User',
      role: 'user',
      accentColor: '#123456',
      isDisabled: false,
      createdAt: DateTime(2026),
    ),
  );
  void offline(bool value) => state = state.copyWith(offline: value);
}

class _Jam extends JamController {
  @override
  JamView? build() => null;
  void enter() => state = JamView(
    state: JamState.fromJson({
      'code': 'ABC123',
      'host': {'id': 'u'},
      'members': [],
      'queue': [],
    }),
    listenHere: true,
    connected: true,
    myId: 'u',
  );
}

class _Sink implements WebSocketSink {
  final sent = <Map<String, dynamic>>[];
  bool closed = false;
  @override
  void add(dynamic value) => sent.add(Map<String, dynamic>.from(jsonDecode(value as String)));
  @override
  Future<void> close([int? closeCode, String? closeReason]) async {
    closed = true;
  }

  @override
  Future<void> get done => Future.value();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Socket implements WebSocketChannel {
  final incoming = StreamController<dynamic>();
  @override
  final _Sink sink = _Sink();
  @override
  Stream<dynamic> get stream => incoming.stream;
  @override
  Future<void> get ready => Future.value();
  @override
  int? closeCode;
  @override
  String? get closeReason => null;
  @override
  String? get protocol => null;
  void receive(Map<String, dynamic> message) => incoming.add(jsonEncode(message));
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ProviderContainer container;
  late SharedPreferences prefs;
  late ConnectTestEngine engine;
  late _Api api;
  late ConnectController connect;
  late PlayerController player;
  late _Socket socket;
  late List<Uri> uris;

  setUp(() async {
    SharedPreferences.setMockInitialValues({'connect_device_id': 'local', 'connect_device_name': 'My PC'});
    prefs = await SharedPreferences.getInstance();
    engine = ConnectTestEngine();
    api = _Api();
    uris = [];
    container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
        jamProvider.overrideWith(_Jam.new),
        downloadSummaryProvider.overrideWith((ref) async => const DownloadSummary()),
        playerProvider.overrideWith(() => PlayerController(engine: engine)),
        connectSocketProvider.overrideWithValue((uri) {
          uris.add(uri);
          socket = _Socket();
          return socket;
        }),
      ],
    );
    player = container.read(playerProvider.notifier);
    player.autoplay = false;
    connect = container.read(connectProvider.notifier);
    await settle();
    socket.receive({
      'type': 'devices',
      'devices': [
        {'id': 'local', 'name': 'My PC', 'kind': 'desktop', 'active': false},
        {'id': 'remote', 'name': 'Living room', 'kind': 'tv', 'active': false},
      ],
    });
    await settle();
  });
  tearDown(() => container.dispose());

  Future<void> remote({bool playing = true}) async {
    socket.receive({'type': 'state', 'device': 'remote', 'state': playback(playing: playing)});
    socket.receive({
      'type': 'devices',
      'devices': [
        {'id': 'local', 'name': 'My PC', 'kind': 'desktop', 'active': false},
        {'id': 'remote', 'name': 'Living room', 'kind': 'tv', 'active': true},
      ],
    });
    await settle();
  }

  test('uses persisted identity and reconnects with the edited device name', () async {
    expect(uris.single.path, '/api/devices/ws');
    expect(uris.single.queryParameters, containsPair('device_id', 'local'));
    expect(uris.single.queryParameters, containsPair('token', 'token'));
    final old = socket;
    await connect.rename('  Office  ');
    expect(old.sink.closed, isTrue);
    expect(prefs.getString('connect_device_name'), 'Office');
    expect(uris.last.queryParameters['name'], 'Office');
    expect(prefs.getString('connect_device_id'), 'local');
  });

  test('a new installation generates and persists a stable random device ID', () async {
    await prefs.remove('connect_device_id');
    container.invalidate(connectProvider);
    final id = container.read(connectProvider).deviceId;
    await settle();
    expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(prefs.getString('connect_device_id'), id);
    container.invalidate(connectProvider);
    expect(container.read(connectProvider).deviceId, id);
    await settle();
    expect(uris.last.queryParameters['device_id'], id);
  });

  test('transfer fetches the ordered queue, loads, seeks, plays and activates', () async {
    await connect.execute({
      'type': 'transfer',
      'queue': ['two', 'one', 'two'],
      'index': 1,
      'position_ms': 12345,
      'playing': true,
      'shuffle': true,
      'repeat': 'all',
    });
    expect(api.fetched, ['two', 'one', 'two']);
    expect(container.read(playerProvider).queue.map((t) => t.id), ['two', 'one', 'two']);
    expect(engine.currentIndex, 1);
    expect(engine.position, const Duration(milliseconds: 12345));
    expect(engine.playing, isTrue);
    expect(engine.loopMode, LoopMode.all);
    expect(container.read(playerProvider).shuffle, isTrue);
    expect(socket.sink.sent, contains(equals({'type': 'activate'})));
    await connect.execute({'type': 'next'});
    expect(engine.currentIndex, 2);
    await connect.execute({'type': 'pause'});
    expect(engine.playing, isFalse);
    await connect.execute({'type': 'jump', 'index': 0});
    expect(engine.currentIndex, 0);
    await connect.execute({'type': 'seek', 'position_ms': 4500});
    expect(engine.position.inMilliseconds, 4500);
    await connect.execute({'type': 'volume', 'value': 4});
    expect(player.userVolume.value, 1);
  });

  test('paused transfer never starts the engine', () async {
    await connect.execute({
      'type': 'transfer',
      'queue': ['one'],
      'index': 0,
      'position_ms': 2000,
      'playing': false,
      'shuffle': false,
      'repeat': 'off',
    });
    expect(engine.playing, isFalse);
    expect(engine.position.inMilliseconds, 2000);
  });

  test('remote progress extrapolates only while playing and clamps to duration', () {
    final received = DateTime(2026);
    final state = ConnectPlayback(playback(), receivedAt: received);
    expect(state.positionAt(received.add(const Duration(seconds: 3))).inMilliseconds, 13000);
    expect(state.positionAt(received.subtract(const Duration(seconds: 3))).inMilliseconds, 10000);
    expect(state.positionAt(received.add(const Duration(hours: 1))).inMilliseconds, 200000);
    final paused = ConnectPlayback(playback(playing: false), receivedAt: received);
    expect(paused.positionAt(received.add(const Duration(seconds: 3))).inMilliseconds, 10000);
    expect(state.track!.artistCredit, 'Remote artist');
    expect(state.track!.album.id, 'album');
  });

  test('remote mode mirrors metadata and routes controls while local engine stays paused', () async {
    await player.loadConnect([makeTrack('one')], 0, Duration.zero, true, false, LoopMode.off);
    await remote(playing: false);
    expect(engine.playing, isFalse);
    expect(container.read(remoteDeviceProvider)!.name, 'Living room');
    expect(container.read(playerProvider).current!.title, 'Remote song');
    expect(container.read(playerProvider).connectRemote, isTrue);
    player.togglePlay();
    await player.next();
    await player.seek(const Duration(seconds: 20));
    player.setUserVolume(0.3);
    expect(engine.playing, isFalse);
    final commands = socket.sink.sent.where((m) => m['type'] == 'command').toList();
    expect(commands.map((m) => m['command']['type']), ['play', 'next', 'seek', 'volume']);
    expect(commands.every((m) => m['target'] == 'remote'), isTrue);
    await engine.play();
    expect(engine.playing, isFalse);
    expect(container.read(playerProvider).current!.title, 'Remote song');
  });

  test('transfer away pauses locally and carries the music queue and position', () async {
    await player.loadConnect(
      [makeTrack('one'), makeTrack('two')],
      1,
      const Duration(seconds: 8),
      true,
      true,
      LoopMode.one,
    );
    await connect.transferTo('remote');
    expect(engine.playing, isFalse);
    final transfer = socket.sink.sent.lastWhere((m) => m['type'] == 'command')['command'];
    expect(transfer['queue'], ['one', 'two']);
    expect(transfer['index'], 1);
    expect(transfer['position_ms'], greaterThanOrEqualTo(8000));
    expect(transfer['playing'], isTrue);
    expect(transfer['shuffle'], isTrue);
    expect(transfer['repeat'], 'one');
  });

  test('picking this device pauses the remote target and resumes its last queue here', () async {
    await remote();
    await connect.transferTo('local');
    expect(
      socket.sink.sent,
      contains(
        equals({
          'type': 'command',
          'target': 'remote',
          'command': {'type': 'pause'},
        }),
      ),
    );
    expect(container.read(playerProvider).queue.map((t) => t.id), ['one', 'two', 'one']);
    expect(engine.currentIndex, 1);
    expect(engine.position.inMilliseconds, greaterThanOrEqualTo(10000));
    expect(engine.playing, isTrue);
    expect(container.read(playerProvider).connectRemote, isFalse);
  });

  test('disconnecting or going offline clears remote mode without resuming local audio', () async {
    await remote();
    final old = socket;
    (container.read(sessionProvider.notifier) as _Session).offline(true);
    await settle();
    expect(old.sink.closed, isTrue);
    expect(container.read(connectProvider).connected, isFalse);
    expect(container.read(remoteDeviceProvider), isNull);
    expect(container.read(playerProvider).connectRemote, isFalse);
    expect(engine.playing, isFalse);
    expect(uris, hasLength(1));
  });

  test('radio playback cannot be transferred and shows a music-only hint', () async {
    final messages = <String>[];
    final subscription = connect.messages.stream.listen(messages.add);
    await player.playStation(
      const Station(id: 'radio', name: 'Radio', country: 'Germany', countryCode: 'DE', tags: [], codec: 'mp3'),
    );
    await connect.transferTo('remote');
    await settle();
    expect(socket.sink.sent.where((m) => m['type'] == 'command'), isEmpty);
    expect(messages.single, contains('music'));
    expect(engine.playing, isTrue);
    await subscription.cancel();
  });

  test('active target publishes music state on change and every two seconds', () async {
    await player.loadConnect(
      [makeTrack('one'), makeTrack('two')],
      1,
      const Duration(seconds: 7),
      true,
      true,
      LoopMode.all,
    );
    socket.receive({
      'type': 'devices',
      'devices': [
        {'id': 'local', 'name': 'My PC', 'kind': 'desktop', 'active': true},
      ],
    });
    await settle();
    final states = socket.sink.sent.where((m) => m['type'] == 'state').toList();
    expect(states, hasLength(1));
    expect(states.single['state']['queue'], ['one', 'two']);
    expect(states.single['state']['track']['id'], 'two');
    expect(states.single['state']['position_ms'], 7000);
    expect(states.single['state']['queue_length'], 2);
    await Future<void>.delayed(const Duration(milliseconds: 2100));
    expect(socket.sink.sent.where((m) => m['type'] == 'state').length, greaterThanOrEqualTo(2));
    await connect.execute({'type': 'pause'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(socket.sink.sent.lastWhere((m) => m['type'] == 'state')['state']['playing'], isFalse);
  });

  test('incoming commands execute in order without waiting for playback to end', () async {
    final lifetime = Completer<void>();
    engine.playbackLifetime = lifetime.future;
    socket.receive({
      'type': 'command',
      'from': 'controller',
      'command': {
        'type': 'transfer',
        'queue': ['one', 'two'],
        'index': 0,
        'playing': false,
      },
    });
    socket.receive({
      'type': 'command',
      'from': 'controller',
      'command': {'type': 'play'},
    });
    socket.receive({
      'type': 'command',
      'from': 'controller',
      'command': {'type': 'next'},
    });
    socket.receive({
      'type': 'command',
      'from': 'controller',
      'command': {'type': 'pause'},
    });
    await settle();
    expect(engine.currentIndex, 1);
    expect(engine.playing, isFalse);
    lifetime.complete();
  });

  test('disconnect cancels queued commands from the previous socket session', () async {
    final pending = Completer<Track>();
    api.pendingTrack = pending;
    socket.receive({
      'type': 'command',
      'from': 'controller',
      'command': {
        'type': 'transfer',
        'queue': ['one'],
        'playing': true,
      },
    });
    socket.receive({
      'type': 'command',
      'from': 'controller',
      'command': {'type': 'play'},
    });
    await settle();
    (container.read(sessionProvider.notifier) as _Session).offline(true);
    pending.complete(makeTrack('one'));
    await settle();
    expect(engine.playing, isFalse);
    expect(container.read(playerProvider).queue, isEmpty);
  });

  test('closed socket reconnects with backoff and one stable device identity', () async {
    final old = socket;
    await old.incoming.close();
    await settle();
    expect(container.read(connectProvider).connected, isFalse);
    expect(uris, hasLength(1));
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(uris, hasLength(2));
    expect(uris.last.queryParameters['device_id'], 'local');
    expect(old.sink.closed, isTrue);
  });

  test('Jam blocks transfers and incoming commands', () async {
    final messages = <String>[];
    final subscription = connect.messages.stream.listen(messages.add);
    (container.read(jamProvider.notifier) as _Jam).enter();
    await connect.transferTo('remote');
    await connect.execute({
      'type': 'transfer',
      'queue': ['one'],
      'playing': true,
    });
    await settle();
    expect(api.fetched, isEmpty);
    expect(socket.sink.sent.where((m) => m['type'] == 'command'), isEmpty);
    expect(messages, hasLength(2));
    await subscription.cancel();
  });

  testWidgets('picker shows this device first, platform icons and active target', (tester) async {
    await tester.runAsync(() => remote());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: DevicesSheet()),
        ),
      ),
    );
    expect(find.text('Play on…'), findsOneWidget);
    expect(find.text('This device'), findsOneWidget);
    expect(find.text('My PC'), findsOneWidget);
    expect(find.text('Living room'), findsOneWidget);
    expect(tester.getTopLeft(find.text('This device')).dy, lessThan(tester.getTopLeft(find.text('Living room')).dy));
    expect(find.byIcon(deviceKindIcon(container.read(connectProvider).kind)), findsOneWidget);
    expect(find.byIcon(Icons.tv), findsOneWidget);
    expect(find.byIcon(Icons.equalizer), findsOneWidget);
    final selected = tester.widgetList<ListTile>(find.byType(ListTile)).where((tile) => tile.selected);
    expect(selected, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });
  testWidgets('German picker explains Jam precedence and disables transfers', (tester) async {
    (container.read(jamProvider.notifier) as _Jam).enter();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(body: DevicesSheet()),
        ),
      ),
    );
    expect(find.text('Wiedergabe auf…'), findsOneWidget);
    expect(find.text('Dieses Gerät'), findsOneWidget);
    expect(find.text('Während eines Jams ist kein Gerätewechsel möglich.'), findsOneWidget);
    expect(tester.widgetList<ListTile>(find.byType(ListTile)).every((tile) => !tile.enabled), isTrue);
    expect(deviceKindIcon('phone'), Icons.phone_android);
    expect(deviceKindIcon('desktop'), Icons.computer);
    expect(deviceKindIcon('web'), Icons.language);
    expect(deviceKindIcon('tv'), Icons.tv);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
