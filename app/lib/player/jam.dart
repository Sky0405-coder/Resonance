import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/session.dart';
import '../l10n/l10n.dart';
import '../l10n/locale.dart';
import 'player.dart';

class JamMember {
  const JamMember({required this.id, required this.name, required this.isHost, required this.online});
  final String id;
  final String name;
  final bool isHost;
  final bool online;

  factory JamMember.fromJson(Map<String, dynamic> j) =>
      JamMember(id: j['id'], name: j['name'] ?? '', isHost: j['is_host'] ?? false, online: j['online'] ?? false);
}

class JamEntry {
  const JamEntry({required this.entryId, required this.addedById, required this.addedByName, required this.track});
  final String entryId;
  final String addedById;
  final String addedByName;
  final Track track;

  factory JamEntry.fromJson(Map<String, dynamic> j) => JamEntry(
    entryId: j['entry_id'],
    addedById: j['added_by']['id'],
    addedByName: j['added_by']['name'] ?? '',
    track: Track.fromJson(Map<String, dynamic>.from(j['track'])),
  );
}

/// The server's view of a Jam (see backend `app/api/jam.py`).
class JamState {
  const JamState({
    required this.code,
    required this.hostId,
    required this.members,
    required this.membersControl,
    required this.playing,
    required this.positionMs,
    required this.serverTimeMs,
    required this.version,
    required this.index,
    required this.queue,
  });

  final String code;
  final String hostId;
  final List<JamMember> members;
  final bool membersControl;
  final bool playing;
  final int positionMs;
  final int serverTimeMs;
  final int version;
  final int index;
  final List<JamEntry> queue;

  JamEntry? get current => index >= 0 && index < queue.length ? queue[index] : null;

  factory JamState.fromJson(Map<String, dynamic> j) => JamState(
    code: j['code'],
    hostId: j['host']['id'],
    members: [for (final m in j['members']) JamMember.fromJson(Map<String, dynamic>.from(m))],
    membersControl: j['members_control'] ?? true,
    playing: j['playing'] ?? false,
    positionMs: j['position_ms'] ?? 0,
    serverTimeMs: j['server_time_ms'] ?? 0,
    version: j['version'] ?? 0,
    index: j['index'] ?? -1,
    queue: [for (final e in j['queue']) JamEntry.fromJson(Map<String, dynamic>.from(e))],
  );
}

/// Clock offset (server − local) from ping samples: the median is robust against one slow round trip.
int clockOffset(List<int> samples) {
  if (samples.isEmpty) return 0;
  final sorted = [...samples]..sort();
  return sorted[sorted.length ~/ 2];
}

/// One ping sample: the server time is taken to be in the middle of the round trip.
int offsetSample({required int sentMs, required int receivedMs, required int serverMs}) =>
    serverMs - (sentMs + (receivedMs - sentMs) ~/ 2);

/// Where the Jam's current song should be now (in server time).
int expectedPositionMs(JamState s, int serverNowMs) {
  if (!s.playing) return s.positionMs;
  final position = s.positionMs + (serverNowMs - s.serverTimeMs).clamp(0, 1 << 40);
  final duration = s.current == null ? null : (s.current!.track.duration * 1000).round();
  return duration == null ? position : position.clamp(0, duration);
}

/// Only correct audible drift; small differences come from buffering and network jitter.
bool needsSeek(int localMs, int expectedMs) => (localMs - expectedMs).abs() > 1000;

class JamView {
  const JamView({required this.state, required this.listenHere, required this.connected, required this.myId});
  final JamState state;
  final bool listenHere;
  final bool connected;
  final String? myId;

  bool get isHost => state.hostId == myId;
  bool get canControl => isHost || state.membersControl;

  JamView copyWith({JamState? state, bool? listenHere, bool? connected}) => JamView(
    state: state ?? this.state,
    listenHere: listenHere ?? this.listenHere,
    connected: connected ?? this.connected,
    myId: myId,
  );
}

/// Connection to the server's Jam hub; routes player actions to the Jam while one is active.
class JamController extends Notifier<JamView?> implements JamRouter {
  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _ping;
  Timer? _reconnect;
  int _attempt = 0;
  final List<int> _offsets = [];
  final messages = StreamController<String>.broadcast();

  PlayerController get _player => ref.read(playerProvider.notifier);
  ApiClient get _api => ref.read(apiProvider);
  AppLocalizations get _l10n => lookupAppLocalizations(ref.read(appLocaleProvider));

  int get serverNowMs => DateTime.now().millisecondsSinceEpoch + clockOffset(_offsets);

  @override
  JamView? build() {
    ref.listen(sessionProvider.select((s) => s.loggedIn && !s.offline), (previous, loggedIn) {
      if (loggedIn && previous != true) {
        restore().ignore();
      } else if (!loggedIn) {
        _clear();
      }
    });
    ref.onDispose(() {
      _close();
      messages.close();
    });
    if (ref.read(sessionProvider).loggedIn) Future.microtask(restore);
    return null;
  }

  Future<void> restore() async {
    try {
      _enter(JamState.fromJson(await _api.jamCurrent()));
    } catch (_) {
      // No Jam (404) or offline.
    }
  }

  Future<void> start() async {
    final p = ref.read(playerProvider);
    final music = p.book == null && p.station == null;
    final json = await _api.jamStart(
      trackIds: music ? [for (final t in p.queue) t.id] : const [],
      index: music ? p.index ?? 0 : 0,
      positionMs: music ? _player.engine.position.inMilliseconds : 0,
      playing: music && p.playing,
    );
    _enter(JamState.fromJson(json));
  }

  Future<void> join(String code) async {
    _enter(JamState.fromJson(await _api.jamJoin(code)));
  }

  Future<void> leave() async {
    await _api.jamLeave();
    _clear();
  }

  Future<void> kick(String userId) async {
    final s = state;
    if (s != null) await _api.jamKick(s.state.code, userId);
  }

  void setMembersControl(bool enabled) => _send('set_control', {'members_control': enabled});

  void setListenHere(bool listen) {
    final s = state;
    if (s == null || s.listenHere == listen) return;
    state = s.copyWith(listenHere: listen);
    _apply(s.state);
  }

  void _enter(JamState jam) {
    final myId = ref.read(currentUserIdProvider);
    state = JamView(state: jam, listenHere: state?.listenHere ?? true, connected: false, myId: myId);
    _player.jam = this;
    _apply(jam);
    _connect();
  }

  void _connect() {
    _close();
    if (state == null) return;
    final channel = WebSocketChannel.connect(_api.jamSocketUri());
    _channel = channel;
    _sub = channel.stream.listen(
      _onMessage,
      onDone: () => _onClosed(channel.closeCode),
      onError: (_) => _onClosed(null),
      cancelOnError: true,
    );
    _offsets.clear();
    _ping = Timer.periodic(const Duration(seconds: 15), (_) => _sendPing());
    _sendPing();
  }

  void _sendPing() {
    _channel?.sink.add(jsonEncode({'type': 'ping', 't': DateTime.now().millisecondsSinceEpoch}));
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> message;
    try {
      message = Map<String, dynamic>.from(jsonDecode(raw as String));
    } catch (_) {
      return;
    }
    switch (message['type']) {
      case 'state':
        _attempt = 0;
        final jam = JamState.fromJson(Map<String, dynamic>.from(message['state']));
        final s = state;
        if (s == null) return;
        state = s.copyWith(state: jam, connected: true);
        _apply(jam);
      case 'pong':
        final sent = message['t'];
        final server = message['server'];
        if (sent is int && server is int) {
          final now = DateTime.now().millisecondsSinceEpoch;
          // Drop absurd round trips (app was suspended).
          if (now - sent < 5000) {
            _offsets.add(offsetSample(sentMs: sent, receivedMs: now, serverMs: server));
            if (_offsets.length > 5) _offsets.removeAt(0);
          }
        }
      case 'error':
        messages.add(message['message'] ?? '');
      case 'kicked' || 'ended':
        _ended();
    }
  }

  void _onClosed(int? code) {
    if (state == null) return;
    if (code == 4404 || code == 4401) {
      _ended();
      return;
    }
    state = state!.copyWith(connected: false);
    _ping?.cancel();
    _reconnect?.cancel();
    const delays = [1, 2, 5, 10];
    final delay = delays[_attempt.clamp(0, delays.length - 1)];
    _attempt++;
    _reconnect = Timer(Duration(seconds: delay), () async {
      // The Jam may have ended while we were away.
      try {
        final current = JamState.fromJson(await _api.jamCurrent());
        if (state != null) {
          state = state!.copyWith(state: current);
          _connect();
        }
      } on ApiException catch (e) {
        if (e.statusCode == 404) {
          _ended();
        } else {
          _onClosed(null);
        }
      } catch (_) {
        _onClosed(null);
      }
    });
  }

  void _ended() {
    if (state == null) return;
    _clear();
    messages.add(_l10n.jamEnded);
  }

  void _clear() {
    _close();
    if (state != null) {
      state = null;
      _player.leaveJam().ignore();
    }
  }

  void _close() {
    _ping?.cancel();
    _ping = null;
    _reconnect?.cancel();
    _reconnect = null;
    _sub?.cancel();
    _sub = null;
    _channel?.sink.close();
    _channel = null;
  }

  void _apply(JamState jam) {
    final listen = state?.listenHere ?? true;
    _player
        .applyJam(
          [for (final e in jam.queue) e.track],
          jam.index,
          () => Duration(milliseconds: expectedPositionMs(jam, serverNowMs)),
          jam.playing,
          listen: listen,
          context: 'jam:${jam.code}',
        )
        .catchError((Object e) => debugPrint('Jam apply failed: $e'));
  }

  void _send(String cmd, [Map<String, dynamic> args = const {}]) {
    final channel = _channel;
    if (channel == null || state?.connected != true) {
      messages.add(_l10n.jamNotConnected);
      return;
    }
    channel.sink.add(jsonEncode({'type': 'cmd', 'cmd': cmd, ...args}));
  }

  String? _entryAt(int index) {
    final queue = state?.state.queue;
    return queue != null && index >= 0 && index < queue.length ? queue[index].entryId : null;
  }

  // --- JamRouter: player actions while in a Jam ------------------------------

  @override
  Future<void> playTracks(List<Track> tracks, int index) async {
    // Like tapping a song in an album: it plays now, the rest of the album follows (capped so one tap
    // cannot flood everybody's queue).
    final chosen = tracks.skip(index).take(100);
    if (chosen.isEmpty) return;
    _send('add', {
      'track_ids': [for (final t in chosen) t.id],
      'next': true,
      'play': true,
    });
  }

  @override
  Future<void> add(Track track, {required bool next}) async => _send('add', {
    'track_ids': [track.id],
    'next': next,
  });

  @override
  Future<void> removeAt(int index) async {
    final id = _entryAt(index);
    if (id != null) _send('remove', {'entry_id': id});
  }

  @override
  Future<void> jumpTo(int index) async {
    final id = _entryAt(index);
    if (id != null) _send('jump', {'entry_id': id});
  }

  @override
  Future<void> play() async => _send('play');

  @override
  Future<void> pause() async => _send('pause');

  @override
  Future<void> next() async => _send('next');

  @override
  Future<void> previous() async => _send('previous');

  @override
  Future<void> seek(Duration position) async => _send('seek', {'position_ms': position.inMilliseconds});

  @override
  bool get playing => state?.state.playing ?? false;
}

final jamProvider = NotifierProvider<JamController, JamView?>(JamController.new);

final jamMessagesProvider = StreamProvider<String>((ref) => ref.watch(jamProvider.notifier).messages.stream);
