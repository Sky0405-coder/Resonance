import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/audiobooks.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/integrations/discord_presence.dart';
import 'package:resonance/integrations/discord_rpc.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/player/player.dart';

class _Transport implements DiscordTransport {
  final input = StreamController<List<int>>(sync: true);
  final sent = <DiscordFrame>[];
  bool closed = false;

  @override
  Stream<List<int>> get bytes => input.stream;

  @override
  Future<void> send(Uint8List bytes) async => sent.addAll(DiscordFrameDecoder().add(bytes));

  void receive(int opcode, Map<String, dynamic> payload) => input.add(DiscordFrame(opcode, payload).encode());

  void ready() => receive(1, {'cmd': 'DISPATCH', 'evt': 'READY'});

  List<Map<String, dynamic>?> get activities => [
    for (final frame in sent.where((f) => f.payload['cmd'] == 'SET_ACTIVITY'))
      frame.payload['args']['activity'] as Map<String, dynamic>?,
  ];

  @override
  Future<void> close() async {
    closed = true;
  }
}

class _FakeTimer implements Timer {
  _FakeTimer(this.due, this.callback);
  final DateTime due;
  final void Function() callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;
  @override
  int get tick => _tick;
  @override
  void cancel() => _active = false;

  void fire() {
    _active = false;
    _tick++;
    callback();
  }
}

class _Clock {
  DateTime now = DateTime.utc(2026, 10, 16);
  final timers = <_FakeTimer>[];

  Timer schedule(Duration duration, void Function() callback) {
    final timer = _FakeTimer(now.add(duration), callback);
    timers.add(timer);
    return timer;
  }

  void elapse(Duration duration) {
    final end = now.add(duration);
    while (true) {
      final due = timers.where((t) => t.isActive && !t.due.isAfter(end)).toList()
        ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      now = due.first.due;
      due.first.fire();
    }
    now = end;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

const _track = Track(
  id: 'track',
  title: 'Song title',
  artist: NamedRef('artist', 'Artist'),
  artistCredit: 'Artist feat. Guest',
  album: NamedRef('album', 'Album title'),
  duration: 180,
);

const _book = BookPlayback(
  itemId: 'book',
  sessionId: 'session',
  title: 'Book title',
  author: 'Author',
  coverUrl: 'https://server/api/abs/cover?token=secret',
  duration: 3600,
  parts: [],
  chapters: [
    AbsChapter(start: 0, end: 60, title: 'First chapter'),
    AbsChapter(start: 60, end: 120, title: 'Second chapter'),
  ],
);

class _RecordingRpc extends DiscordRpc {
  _RecordingRpc() : super(clientId: '123');
  final activities = <Map<String, dynamic>?>[];

  @override
  void setActivity(Map<String, dynamic>? activity) => activities.add(activity);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Discord frames', () {
    test('encodes opcode and UTF-8 byte length in little endian, decodes split and combined frames', () {
      final payload = {'text': 'ä🎵' * 100};
      final encoded = DiscordFrame(3, payload).encode();
      final length = utf8.encode(jsonEncode(payload)).length;
      expect(encoded.take(4), [3, 0, 0, 0]);
      expect(encoded.sublist(4, 8), [length & 255, length >> 8, 0, 0]);
      final decoder = DiscordFrameDecoder();
      expect(decoder.add(encoded.sublist(0, 5)), isEmpty);
      expect(decoder.add(encoded.sublist(5, 12)), isEmpty);
      final frames = decoder.add([...encoded.sublist(12), ...const DiscordFrame(2, {}).encode()]);
      expect(frames.map((f) => f.opcode), [3, 2]);
      expect(frames.first.payload, payload);
      expect(frames.last.payload, isEmpty);
    });

    test('rejects negative or excessive lengths and invalid JSON', () {
      for (final length in [-1, 1024 * 1024 + 1]) {
        final header = Uint8List(8);
        ByteData.sublistView(header).setInt32(4, length, Endian.little);
        expect(() => DiscordFrameDecoder().add(header), throwsFormatException);
      }
      expect(() => DiscordFrameDecoder().add([1, 0, 0, 0, 1, 0, 0, 0, 0xff]), throwsFormatException);
    });
  });

  group('RPC with fake transport and clock', () {
    late _Clock clock;
    late _Transport transport;
    late DiscordRpc rpc;

    setUp(() {
      clock = _Clock();
      transport = _Transport();
      rpc = DiscordRpc(
        clientId: '123456',
        connect: () async => transport,
        now: () => clock.now,
        schedule: clock.schedule,
      );
    });

    tearDown(() async {
      rpc.stop();
      await _settle();
      await transport.input.close();
    });

    test('waits for READY, sends pid/UUID and responds to PING', () async {
      rpc.setActivity({'details': 'latest'});
      rpc.start();
      await _settle();
      expect(transport.sent.single.opcode, 0);
      expect(transport.sent.single.payload, {'v': 1, 'client_id': '123456'});
      transport.receive(1, {'cmd': 'SET_ACTIVITY', 'evt': null});
      expect(transport.activities, isEmpty);
      transport.receive(3, {'ping': 42});
      await _settle();
      expect(transport.sent.last.opcode, 4);
      expect(transport.sent.last.payload, {'ping': 42});
      transport.ready();
      await _settle();
      final payload = transport.sent.last.payload;
      expect(payload['args'], {
        'pid': pid,
        'activity': {'details': 'latest'},
      });
      expect(
        payload['nonce'],
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')),
      );
    });

    test('coalesces to the latest activity including null, at most once every four seconds', () async {
      rpc.start();
      await _settle();
      transport.ready();
      rpc.setActivity({'details': 'first'});
      await _settle();
      rpc.setActivity({'details': 'obsolete'});
      clock.elapse(const Duration(seconds: 1));
      rpc.setActivity({'details': 'latest'});
      clock.elapse(const Duration(milliseconds: 2999));
      expect(transport.activities.length, 1);
      clock.elapse(const Duration(milliseconds: 1));
      await _settle();
      expect(transport.activities, [
        {'details': 'first'},
        {'details': 'latest'},
      ]);
      rpc.setActivity({'details': 'obsolete again'});
      rpc.setActivity(null);
      clock.elapse(const Duration(seconds: 4));
      await _settle();
      expect(transport.activities.last, isNull);
      expect(transport.activities.length, 3);
      final nonces = transport.sent.where((f) => f.opcode == 1).map((f) => f.payload['nonce']).toSet();
      expect(nonces.length, 3);
    });

    test('retries connection failures, CLOSE and socket errors after 30 seconds; stop cancels retries', () async {
      var attempts = 0;
      var current = transport;
      rpc = DiscordRpc(
        clientId: '123',
        connect: () async {
          attempts++;
          if (attempts == 1) throw const SocketException('not running');
          return current;
        },
        now: () => clock.now,
        schedule: clock.schedule,
      );
      rpc.setActivity({'details': 'playing'});
      rpc.start();
      await _settle();
      clock.elapse(const Duration(seconds: 29));
      expect(attempts, 1);
      clock.elapse(const Duration(seconds: 1));
      await _settle();
      transport.ready();
      await _settle();
      expect(transport.activities.single, {'details': 'playing'});
      transport.receive(2, {'message': 'closed'});
      expect(transport.closed, true);
      current = _Transport();
      clock.elapse(const Duration(seconds: 30));
      await _settle();
      expect(attempts, 3);
      current.ready();
      await _settle();
      expect(current.activities.single, {'details': 'playing'});
      current.input.addError(const SocketException('disconnected'));
      expect(current.closed, true);
      rpc.stop();
      clock.elapse(const Duration(minutes: 2));
      await _settle();
      expect(attempts, 3);
      await current.input.close();
    });

    test('handshake timeout reconnects and late connections are closed after stop', () async {
      rpc.start();
      await _settle();
      clock.elapse(const Duration(seconds: 10));
      expect(transport.closed, true);
      rpc.stop();
      final pending = Completer<DiscordTransport>();
      final lateTransport = _Transport();
      rpc = DiscordRpc(clientId: '123', connect: () => pending.future, schedule: clock.schedule);
      rpc.start();
      rpc.stop();
      pending.complete(lateTransport);
      await _settle();
      expect(lateTransport.closed, true);
      expect(lateTransport.sent, isEmpty);
      unawaited(lateTransport.input.close());
    });
  });

  group('activity building', () {
    final now = DateTime.utc(2026, 10, 16);
    final en = lookupAppLocalizations(const Locale('en'));
    final de = lookupAppLocalizations(const Locale('de'));

    Map<String, dynamic>? build(PlayerView player, {AppLocalizations? l10n, int seconds = 30}) => buildDiscordActivity(
      player: player,
      position: Duration(seconds: seconds),
      serverUrl: 'https://user:secret@server:8443/resonance/?token=secret#secret',
      l10n: l10n ?? en,
      now: now,
    );

    test('music uses localized artist, album, public token-free image and timestamps', () {
      const player = PlayerView(queue: [_track], index: 0, playing: true);
      final activity = build(player)!;
      expect(activity['type'], 2);
      expect(activity['details'], 'Song title');
      expect(activity['state'], 'by Artist feat. Guest');
      expect(build(player, l10n: de)!['state'], 'von Artist feat. Guest');
      expect(activity['assets'], {
        'large_image': 'https://server:8443/resonance/icons/Icon-512.png',
        'large_text': 'Album title',
      });
      expect(activity['timestamps'], {
        'start': now.millisecondsSinceEpoch - 30000,
        'end': now.millisecondsSinceEpoch + 150000,
      });
    });

    test('audiobook uses book title, author and the current chapter; no chapter is omitted', () {
      const player = PlayerView(book: _book, playing: true);
      expect(build(player)!['details'], 'Book title');
      expect(build(player)!['state'], 'Author');
      expect(build(player)!['assets']['large_text'], 'First chapter');
      expect(build(player, seconds: 90)!['assets']['large_text'], 'Second chapter');
      expect(build(player, seconds: 180)!['assets'].containsKey('large_text'), false);
      expect(build(player)!['timestamps']['end'], now.millisecondsSinceEpoch + 3570000);
    });

    test('truncates Unicode labels to 128 characters and pads labels to at least two', () {
      final track = Track(
        id: 'long',
        title: '🎵' * 200,
        artist: const NamedRef('artist', ''),
        artistCredit: 'x' * 200,
        album: const NamedRef('album', 'A'),
        duration: 1,
      );
      final activity = build(PlayerView(queue: [track], index: 0, playing: true))!;
      expect((activity['details'] as String).runes.length, 128);
      expect((activity['state'] as String).length, 128);
      expect(activity['assets']['large_text'], 'A ');
      final book = BookPlayback(
        itemId: 'short',
        sessionId: 'session',
        title: '',
        author: 'A',
        coverUrl: '',
        duration: 1,
        parts: [],
        chapters: const [AbsChapter(start: 0, end: 60, title: '')],
      );
      final short = build(PlayerView(book: book, playing: true))!;
      expect(short['details'], '  ');
      expect(short['state'], 'A ');
      expect(short['assets']['large_text'], '  ');
      final emojiBook = BookPlayback(
        itemId: 'emoji',
        sessionId: 'session',
        title: '🎵',
        author: '🎵',
        coverUrl: '',
        duration: 1,
        parts: [],
        chapters: const [AbsChapter(start: 0, end: 60, title: '🎵')],
      );
      final emoji = build(PlayerView(book: emojiBook, playing: true))!;
      expect(emoji['details'], '🎵 ');
      expect(emoji['state'], '🎵 ');
      expect(emoji['assets']['large_text'], '🎵 ');
    });

    test('speed other than one omits end, pause and empty playback clear activity', () {
      for (final speed in [0.75, 1.25, 2.0]) {
        final activity = build(PlayerView(book: _book, playing: true, speed: speed))!;
        expect(activity['timestamps'].containsKey('start'), true);
        expect(activity['timestamps'].containsKey('end'), false);
      }
      expect(build(const PlayerView(book: _book)), isNull);
      expect(build(const PlayerView(queue: [_track], index: 0)), isNull);
      expect(build(const PlayerView(playing: true)), isNull);
    });
  });

  test('presence sends on changes and seeks over two seconds, not normal position ticks', () {
    final clock = _Clock();
    final rpc = _RecordingRpc();
    final presence = DiscordPresenceController(
      rpc: rpc,
      serverUrl: 'https://server',
      localizations: () => lookupAppLocalizations(const Locale('en')),
      now: () => clock.now,
    );
    const playing = PlayerView(queue: [_track], index: 0, playing: true);
    presence.update(playing, Duration.zero);
    for (var second = 1; second <= 10; second++) {
      clock.elapse(const Duration(seconds: 1));
      presence.onPosition(Duration(seconds: second));
    }
    expect(rpc.activities.length, 1);
    presence.onPosition(const Duration(seconds: 12));
    expect(rpc.activities.length, 1);
    presence.onPosition(const Duration(milliseconds: 12001));
    expect(rpc.activities.length, 2);
    presence.onPosition(const Duration(seconds: 1));
    expect(rpc.activities.length, 3);
    presence.update(const PlayerView(queue: [_track], index: 0), const Duration(seconds: 1));
    expect(rpc.activities.last, isNull);
    presence.update(const PlayerView(book: _book, playing: true, speed: 2), const Duration(seconds: 10));
    expect(rpc.activities.last!['timestamps'].containsKey('end'), false);
    clock.elapse(const Duration(seconds: 1));
    presence.onPosition(const Duration(seconds: 12));
    expect(rpc.activities.length, 5);
    presence.update(playing, const Duration(seconds: 1), stopped: true);
    expect(rpc.activities.last, isNull);
    presence.update(const PlayerView(), Duration.zero);
    expect(rpc.activities.last, isNull);
  });

  test('presence setting defaults on and persists; mobile never requests client config', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [prefsProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    expect(container.read(discordPresenceSettingProvider), true);
    container.read(discordPresenceSettingProvider.notifier).setEnabled(false);
    expect(container.read(discordPresenceSettingProvider), false);
    expect(prefs.getBool('discord_presence'), false);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    expect(isDiscordDesktop, false);
    expect(await container.read(discordClientIdProvider.future), '');
    container.read(discordPresenceProvider);
  });

  test('real Unix IPC transport sends handshake and SET_ACTIVITY to an injectable directory', () async {
    final directory = await Directory.systemTemp.createTemp('resonance-discord-');
    final server = await ServerSocket.bind(
      InternetAddress('${directory.path}/discord-ipc-0', type: InternetAddressType.unix),
      0,
    );
    final handshake = Completer<DiscordFrame>();
    final activity = Completer<DiscordFrame>();
    Socket? peer;
    final accepted = server.listen((socket) {
      peer = socket;
      final decoder = DiscordFrameDecoder();
      socket.listen((bytes) {
        for (final frame in decoder.add(bytes)) {
          if (frame.opcode == 0) {
            handshake.complete(frame);
            socket.add(const DiscordFrame(1, {'cmd': 'DISPATCH', 'evt': 'READY'}).encode());
          } else if (!activity.isCompleted) {
            activity.complete(frame);
          }
        }
      });
    });
    final rpc = DiscordRpc(
      clientId: '123456',
      connect: () => connectDiscord(directories: [directory.path]),
    );
    addTearDown(() async {
      rpc.stop();
      peer?.destroy();
      await accepted.cancel();
      await server.close();
      await directory.delete(recursive: true);
    });
    rpc.setActivity({'type': 2, 'details': 'A song'});
    rpc.start();
    expect((await handshake.future.timeout(const Duration(seconds: 5))).payload, {'v': 1, 'client_id': '123456'});
    final frame = await activity.future.timeout(const Duration(seconds: 5));
    expect(frame.opcode, 1);
    expect(frame.payload['cmd'], 'SET_ACTIVITY');
    expect(frame.payload['args'], {
      'pid': pid,
      'activity': {'type': 2, 'details': 'A song'},
    });
  }, skip: !Platform.isLinux);
}
