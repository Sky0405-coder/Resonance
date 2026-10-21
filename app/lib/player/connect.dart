import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/session.dart';
import '../core/tv_mode.dart';
import '../l10n/l10n.dart';
import '../l10n/locale.dart';
import 'jam.dart';
import 'player.dart';

class ConnectDevice {
  const ConnectDevice({required this.id, required this.name, required this.kind, this.active = false});
  final String id;
  final String name;
  final String kind;
  final bool active;

  factory ConnectDevice.fromJson(Map<String, dynamic> j) =>
      ConnectDevice(id: j['id'], name: j['name'], kind: j['kind'], active: j['active'] == true);
}

class ConnectPlayback {
  ConnectPlayback(Map<String, dynamic> json, {DateTime? receivedAt})
    : json = Map.unmodifiable(json),
      receivedAt = receivedAt ?? DateTime.now();
  final Map<String, dynamic> json;
  final DateTime receivedAt;
  bool get playing => json['playing'] == true;
  int get index => (json['index'] as num?)?.toInt() ?? 0;
  List<String> get queue => List<String>.from(json['queue'] ?? const <String>[]);
  double get volume => ((json['volume'] as num?)?.toDouble() ?? 1).clamp(0, 1);
  Track? get track {
    final value = json['track'];
    if (value is! Map) return null;
    final data = Map<String, dynamic>.from(value);
    data['artist'] ??= {'id': '', 'name': data['artist_credit'] ?? ''};
    return Track.fromJson(data);
  }

  Duration positionAt(DateTime now) {
    final base = (json['position_ms'] as num?)?.toInt() ?? 0;
    final elapsed = playing ? max(0, now.difference(receivedAt).inMilliseconds) : 0;
    final duration = track?.length.inMilliseconds;
    return Duration(milliseconds: (base + elapsed).clamp(0, duration ?? (1 << 40)));
  }

  Map<String, dynamic> transfer() => {
    'type': 'transfer',
    'queue': queue,
    'index': index,
    'position_ms': positionAt(DateTime.now()).inMilliseconds,
    'playing': playing,
    'shuffle': json['shuffle'] == true,
    'repeat': json['repeat'] ?? 'off',
  };
}

class ConnectView {
  const ConnectView({
    required this.deviceId,
    required this.name,
    required this.kind,
    this.connected = false,
    this.devices = const [],
    this.states = const {},
  });
  final String deviceId;
  final String name;
  final String kind;
  final bool connected;
  final List<ConnectDevice> devices;
  final Map<String, ConnectPlayback> states;
  ConnectDevice? get active => devices.where((d) => d.active).firstOrNull;

  ConnectView copyWith({
    String? name,
    String? kind,
    bool? connected,
    List<ConnectDevice>? devices,
    Map<String, ConnectPlayback>? states,
  }) => ConnectView(
    deviceId: deviceId,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    connected: connected ?? this.connected,
    devices: devices ?? this.devices,
    states: states ?? this.states,
  );
}

String get defaultConnectName => kIsWeb
    ? 'Browser'
    : switch (defaultTargetPlatform) {
        TargetPlatform.android => 'Android',
        TargetPlatform.iOS => 'iPhone',
        TargetPlatform.linux => 'Linux-PC',
        TargetPlatform.windows => 'Windows-PC',
        TargetPlatform.macOS => 'Mac',
        TargetPlatform.fuchsia => 'Fuchsia',
      };

final connectSocketProvider = Provider<WebSocketChannel Function(Uri)>((ref) => WebSocketChannel.connect);

class ConnectController extends Notifier<ConnectView> implements ConnectRouter {
  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  StreamSubscription? _positions;
  Timer? _reconnect;
  Timer? _ticker;
  Timer? _publishTimer;
  Timer? _transferTimeout;
  int _attempt = 0;
  int _generation = 0;
  bool _executing = false;
  String? _pendingTarget;
  DateTime? _lastSent;
  Duration? _lastPosition;
  DateTime? _positionTime;
  Future<void> _commands = Future.value();
  final _tracks = <String, Track>{};
  final messages = StreamController<String>.broadcast();

  PlayerController get _player => ref.read(playerProvider.notifier);
  ApiClient get _api => ref.read(apiProvider);
  AppLocalizations get _l10n => lookupAppLocalizations(ref.read(appLocaleProvider));
  bool get _online {
    final s = ref.read(sessionProvider);
    return s.loggedIn && !s.offline;
  }

  bool get _inJam => ref.read(jamProvider) != null;
  String get _kind => ref.read(tvModeProvider)
      ? 'tv'
      : kIsWeb
      ? 'web'
      : switch (defaultTargetPlatform) {
          TargetPlatform.android || TargetPlatform.iOS => 'phone',
          _ => 'desktop',
        };

  @override
  ConnectView build() {
    final prefs = ref.read(prefsProvider);
    final id =
        prefs.getString('connect_device_id') ??
        List.generate(16, (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    prefs.setString('connect_device_id', id).ignore();
    ref.listen(sessionProvider.select((s) => (s.serverUrl, s.token, s.user?.id, s.offline)), (_, next) {
      _disconnect();
      _tracks.clear();
      state = state.copyWith(connected: false, devices: [], states: {});
      _player.clearConnectRemote();
      if (_online) _open();
    });
    ref.listen(tvModeProvider, (_, next) {
      state = state.copyWith(kind: _kind);
      if (_online) _open();
    });
    ref.listen(jamProvider, (previous, next) {
      if (next != null) {
        final remote = state.active;
        if (remote != null && remote.id != state.deviceId) _sendCommand(remote.id, {'type': 'pause'});
        _pendingTarget = null;
        _transferTimeout?.cancel();
        _player.clearConnectRemote();
      } else {
        _applyRemote();
      }
    });
    ref.listen(playerProvider, (_, next) {
      if (!_online || _executing || _inJam || next.connectRemote) return;
      if (state.active != null && state.active!.id != state.deviceId && _pendingTarget == null) {
        _applyRemote();
        return;
      }
      if (_pendingTarget != null) {
        if (next.playing) _player.engine.pause().ignore();
        return;
      }
      if (next.playing && next.current != null && state.active?.id != state.deviceId) _send({'type': 'activate'});
      _scheduleState();
    });
    _positions = _player.engine.positionStream.listen((position) {
      final now = DateTime.now();
      final elapsed = _positionTime == null ? Duration.zero : now.difference(_positionTime!);
      final expected = (_lastPosition ?? position) + (_player.engine.playing ? elapsed : Duration.zero);
      if ((position - expected).abs() > const Duration(milliseconds: 750)) _scheduleState();
      _lastPosition = position;
      _positionTime = now;
    });
    final player = _player;
    player.userVolume.addListener(_scheduleState);
    _ticker = Timer.periodic(const Duration(seconds: 2), (_) {
      if (ref.read(playerProvider).playing) _scheduleState();
    });
    ref.onDispose(() {
      _disconnect();
      _ticker?.cancel();
      _positions?.cancel();
      player.userVolume.removeListener(_scheduleState);
      messages.close();
    });
    Future.microtask(() {
      if (ref.mounted && _online) _open();
    });
    return ConnectView(deviceId: id, name: prefs.getString('connect_device_name') ?? defaultConnectName, kind: _kind);
  }

  Future<void> rename(String name) async {
    final value = name.trim();
    if (value.isEmpty || value.length > 100) return;
    await ref.read(prefsProvider).setString('connect_device_name', value);
    if (!ref.mounted) return;
    state = state.copyWith(name: value);
    if (_online) _open();
  }

  void _open() {
    _disconnect();
    if (!_online) return;
    final generation = _generation;
    state = state.copyWith(connected: false);
    final channel = ref.read(connectSocketProvider)(_api.devicesSocketUri(state.deviceId, state.name, state.kind));
    _channel = channel;
    _subscription = channel.stream.listen(
      (raw) {
        if (generation == _generation) _onMessage(raw);
      },
      onDone: () {
        if (generation == _generation) _closed(channel.closeCode);
      },
      onError: (_) {
        if (generation == _generation) _closed(null);
      },
      cancelOnError: true,
    );
    channel.ready.catchError((Object _) {
      if (generation == _generation) _closed(null);
    });
  }

  void _closed(int? code) {
    _disconnect();
    state = state.copyWith(connected: false, devices: [], states: {});
    _player.clearConnectRemote();
    if (!_online || code == 4401 || code == 4000) return;
    const delays = [1, 2, 5, 10];
    _reconnect = Timer(Duration(seconds: delays[(_attempt++).clamp(0, delays.length - 1)]), _open);
  }

  void _disconnect() {
    _generation++;
    _reconnect?.cancel();
    _publishTimer?.cancel();
    _publishTimer = null;
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _pendingTarget = null;
    _transferTimeout?.cancel();
  }

  void _send(Map<String, dynamic> message) => _channel?.sink.add(jsonEncode(message));
  void _sendCommand(String target, Map<String, dynamic> command) =>
      _send({'type': 'command', 'target': target, 'command': command});

  void _onMessage(dynamic raw) {
    try {
      final message = Map<String, dynamic>.from(jsonDecode(raw as String));
      switch (message['type']) {
        case 'devices':
          _attempt = 0;
          final devices = [for (final d in message['devices']) ConnectDevice.fromJson(Map<String, dynamic>.from(d))];
          state = state.copyWith(
            connected: true,
            devices: devices,
            states: {
              for (final d in devices)
                if (state.states[d.id] != null) d.id: state.states[d.id]!,
            },
          );
          if (state.active?.id == _pendingTarget) {
            _pendingTarget = null;
            _transferTimeout?.cancel();
          }
          _applyRemote();
          final local = ref.read(playerProvider);
          if (!_inJam && !local.connectRemote && local.playing && local.current != null && state.active == null) {
            _send({'type': 'activate'});
          }
          if (state.active?.id == state.deviceId) _scheduleState();
        case 'state':
          final id = message['device'] as String;
          final playback = ConnectPlayback(Map<String, dynamic>.from(message['state']));
          state = state.copyWith(states: {...state.states, id: playback});
          _applyRemote();
        case 'command':
          final command = Map<String, dynamic>.from(message['command']);
          final generation = _generation;
          _commands = _commands
              .then((_) async {
                if (ref.mounted && generation == _generation && _online) await execute(command);
              })
              .catchError((Object e) {
                if (ref.mounted) messages.add(e.toString());
              });
        case 'error':
          _transferTimeout?.cancel();
          _pendingTarget = null;
          messages.add(_l10n.connectUnavailable);
      }
    } catch (_) {
      // Ignore malformed messages, just like the Jam socket.
    }
  }

  void _applyRemote() {
    if (_inJam || _executing) return;
    final active = state.active;
    if (active == null || active.id == state.deviceId) {
      _player.clearConnectRemote();
      return;
    }
    final playback = state.states[active.id];
    // Mirror the remote view before pausing, so engine events cannot reactivate local playback.
    final current = playback?.track;
    if (playback == null || current == null) {
      _player.showConnectRemote(const PlayerView(connectRemote: true), this, () => Duration.zero);
      return;
    }
    final ids = playback.queue.isEmpty ? [current.id] : playback.queue;
    final queue = [
      for (final id in ids)
        id == current.id
            ? current
            : _tracks[id] ??
                  Track(
                    id: id,
                    title: '',
                    artist: const NamedRef('', ''),
                    artistCredit: '',
                    album: const NamedRef('', ''),
                    duration: 0,
                  ),
    ];
    _player.showConnectRemote(
      PlayerView(
        queue: queue,
        index: playback.index.clamp(0, queue.length - 1),
        playing: playback.playing,
        shuffle: playback.json['shuffle'] == true,
        loop: _loop(playback.json['repeat']),
        connectRemote: true,
      ),
      this,
      () => state.states[active.id]?.positionAt(DateTime.now()) ?? Duration.zero,
    );
  }

  static LoopMode _loop(dynamic name) => LoopMode.values.where((v) => v.name == name).firstOrNull ?? LoopMode.off;

  /// Commands run serially so play/seek cannot overtake an in-flight transfer.
  Future<void> execute(Map<String, dynamic> command) async {
    if (_inJam) {
      messages.add(_l10n.connectJamHint);
      return;
    }
    if (command['type'] != 'transfer' && _player.connect != null) return;
    _executing = true;
    try {
      switch (command['type']) {
        case 'transfer':
          final ids = List<String>.from(command['queue']);
          if (ids.isEmpty) return;
          final generation = _generation;
          final tracks = <Track>[];
          for (var i = 0; i < ids.length; i += 8) {
            tracks.addAll(await Future.wait(ids.skip(i).take(8).map((id) => _api.track(id))));
          }
          if (!ref.mounted || generation != _generation || _inJam) return;
          _tracks.addEntries(tracks.map((t) => MapEntry(t.id, t)));
          await _player.loadConnect(
            tracks,
            (command['index'] as num?)?.toInt() ?? 0,
            Duration(milliseconds: max(0, (command['position_ms'] as num?)?.toInt() ?? 0)),
            command['playing'] == true,
            command['shuffle'] == true,
            _loop(command['repeat']),
          );
          if (!_inJam) _send({'type': 'activate'});
        case 'play':
          _player.play().ignore();
        case 'pause':
          await _player.pause();
        case 'next':
          await _player.next();
        case 'previous':
          await _player.previous();
        case 'seek':
          await _player.seek(Duration(milliseconds: max(0, (command['position_ms'] as num).toInt())));
        case 'volume':
          _player.setUserVolume((command['value'] as num).toDouble().clamp(0, 1));
        case 'jump':
          final index = (command['index'] as num).toInt();
          if (index >= 0 && index < ref.read(playerProvider).queue.length) await _player.jumpTo(index);
        case 'shuffle':
          await _player.setShuffle(command['shuffle'] == true);
        case 'repeat':
          await _player.setLoop(_loop(command['repeat']));
      }
    } finally {
      _executing = false;
      _scheduleState();
    }
  }

  Map<String, dynamic> _localState() {
    final p = ref.read(playerProvider);
    final t = p.current;
    _tracks.addEntries(p.queue.map((t) => MapEntry(t.id, t)));
    return {
      'track': t == null
          ? null
          : {
              'id': t.id,
              'title': t.title,
              'artist_credit': t.artistCredit,
              'artist': {'id': t.artist.id, 'name': t.artist.name},
              'album': {'id': t.album.id, 'title': t.album.name, 'cover_key': coverKeys[t.album.id]},
              'duration': t.duration,
            },
      'queue': [for (final t in p.queue) t.id],
      'index': p.index ?? 0,
      'queue_length': p.queue.length,
      'position_ms': _player.engine.position.inMilliseconds,
      'playing': p.playing,
      'shuffle': p.shuffle,
      'repeat': p.loop.name,
      'volume': _player.userVolume.value,
    };
  }

  void _scheduleState() {
    if (!ref.mounted || _publishTimer != null) return;
    final elapsed = _lastSent == null ? 300 : DateTime.now().difference(_lastSent!).inMilliseconds;
    _publishTimer = Timer(Duration(milliseconds: max(0, 280 - elapsed)), () {
      _publishTimer = null;
      final p = ref.read(playerProvider);
      if (!state.connected || state.active?.id != state.deviceId || _inJam || _executing || p.connectRemote) return;
      _lastSent = DateTime.now();
      _send({'type': 'state', 'state': _localState()});
    });
  }

  Future<void> transferTo(String target) async {
    if (_inJam) {
      messages.add(_l10n.connectJamHint);
      return;
    }
    if (!state.connected) {
      messages.add(_l10n.connectUnavailable);
      return;
    }
    final active = state.active;
    final remote = active != null && active.id != state.deviceId;
    if (target == state.deviceId && !remote) return;
    if (target == active?.id) return;
    final local = ref.read(playerProvider);
    if (!remote && (local.book != null || local.station != null || local.current == null)) {
      messages.add(_l10n.connectMusicOnly);
      return;
    }
    final snapshot = remote ? state.states[active.id] : ConnectPlayback(_localState());
    if (snapshot == null || snapshot.queue.isEmpty) {
      messages.add(_l10n.connectUnavailable);
      return;
    }
    final transfer = snapshot.transfer();
    if (target == state.deviceId) {
      if (remote) _sendCommand(active.id, {'type': 'pause'});
      await execute(transfer);
    } else {
      if (remote) _sendCommand(active.id, {'type': 'pause'});
      _pendingTarget = target;
      _transferTimeout?.cancel();
      _transferTimeout = Timer(const Duration(seconds: 30), () {
        _pendingTarget = null;
        messages.add(_l10n.connectUnavailable);
      });
      _sendCommand(target, transfer);
      await _player.engine.pause();
    }
  }

  @override
  Future<void> command(String name, [Map<String, dynamic> args = const {}]) async {
    final target = state.active;
    if (_inJam || target == null || target.id == state.deviceId || !state.connected) return;
    _sendCommand(target.id, {'type': name, ...args});
  }

  @override
  Future<void> playTracks(List<Track> tracks, int index) async {
    if (tracks.isEmpty) return;
    _tracks.addEntries(tracks.map((t) => MapEntry(t.id, t)));
    await command('transfer', {
      'queue': [for (final t in tracks) t.id],
      'index': index,
      'position_ms': 0,
      'playing': true,
      'shuffle': false,
      'repeat': 'off',
    });
  }
}

final connectProvider = NotifierProvider<ConnectController, ConnectView>(ConnectController.new);
final remoteDeviceProvider = Provider<ConnectDevice?>((ref) {
  if (ref.watch(jamProvider) != null) return null;
  final view = ref.watch(connectProvider);
  return view.active?.id == view.deviceId ? null : view.active;
});
final connectMessagesProvider = StreamProvider<String>((ref) => ref.watch(connectProvider.notifier).messages.stream);
