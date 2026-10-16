import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;

class DiscordFrame {
  const DiscordFrame(this.opcode, this.payload);

  final int opcode;
  final Map<String, dynamic> payload;

  Uint8List encode() {
    final json = utf8.encode(jsonEncode(payload));
    final bytes = Uint8List(8 + json.length);
    final header = ByteData.sublistView(bytes);
    header.setInt32(0, opcode, Endian.little);
    header.setInt32(4, json.length, Endian.little);
    bytes.setRange(8, bytes.length, json);
    return bytes;
  }
}

class DiscordFrameDecoder {
  List<int> _buffer = [];

  List<DiscordFrame> add(List<int> bytes) {
    _buffer.addAll(bytes);
    final frames = <DiscordFrame>[];
    while (_buffer.length >= 8) {
      final header = ByteData.sublistView(Uint8List.fromList(_buffer.sublist(0, 8)));
      final length = header.getInt32(4, Endian.little);
      if (length < 0 || length > 1024 * 1024) throw const FormatException('Invalid Discord frame length');
      if (_buffer.length < 8 + length) break;
      frames.add(
        DiscordFrame(
          header.getInt32(0, Endian.little),
          Map<String, dynamic>.from(jsonDecode(utf8.decode(_buffer.sublist(8, 8 + length))) as Map),
        ),
      );
      _buffer = _buffer.sublist(8 + length);
    }
    return frames;
  }
}

abstract interface class DiscordTransport {
  Stream<List<int>> get bytes;
  Future<void> send(Uint8List bytes);
  Future<void> close();
}

class _SocketTransport implements DiscordTransport {
  _SocketTransport(this.socket);
  final Socket socket;

  @override
  Stream<List<int>> get bytes => socket;

  @override
  Future<void> send(Uint8List bytes) async {
    socket.add(bytes);
    await socket.flush();
  }

  @override
  Future<void> close() async => socket.destroy();
}

Future<DiscordTransport> connectDiscord({List<String>? directories}) async {
  if (Platform.isWindows) {
    // Dart's FileMode.append calls _lseeki64(SEEK_END), which fails on named pipes.
    // Socket has no Windows named-pipe API; no plugins, FFI or processes are used.
    debugPrint('Discord presence is unsupported on Windows: dart:io cannot open duplex named pipes.');
    throw const SocketException('Discord named pipes are unsupported by dart:io');
  }
  if (!Platform.isLinux) throw const SocketException('Discord IPC is only enabled on desktop');
  final runtime = Platform.environment['XDG_RUNTIME_DIR'];
  final dirs =
      directories ??
      [
        if (runtime != null && runtime.isNotEmpty) runtime,
        if (Platform.environment['TMPDIR'] case final String tmp when tmp.isNotEmpty) tmp,
        '/tmp',
        if (runtime != null && runtime.isNotEmpty) ...['$runtime/app/com.discordapp.Discord', '$runtime/snap.discord'],
      ];
  for (final dir in dirs.toSet()) {
    for (var n = 0; n < 10; n++) {
      try {
        final socket = await Socket.connect(
          InternetAddress('$dir/discord-ipc-$n', type: InternetAddressType.unix),
          0,
          timeout: const Duration(seconds: 1),
        );
        return _SocketTransport(socket);
      } on SocketException {
        // Discord may use another slot or installation directory.
      }
    }
  }
  throw const SocketException('Discord IPC socket not found');
}

class DiscordRpc {
  DiscordRpc({
    required this.clientId,
    Future<DiscordTransport> Function()? connect,
    DateTime Function()? now,
    Timer Function(Duration, void Function())? schedule,
  }) : _connectTransport = connect ?? connectDiscord,
       _now = now ?? DateTime.now,
       _schedule = schedule ?? Timer.new;

  final String clientId;
  final Future<DiscordTransport> Function() _connectTransport;
  final DateTime Function() _now;
  final Timer Function(Duration, void Function()) _schedule;
  DiscordTransport? _transport;
  StreamSubscription<List<int>>? _subscription;
  Timer? _retry;
  Timer? _handshake;
  Timer? _update;
  bool _enabled = false;
  bool _ready = false;
  bool _sending = false;
  bool _hasActivity = false;
  bool _pending = false;
  Map<String, dynamic>? _activity;
  DateTime? _lastSent;
  int _generation = 0;

  void start() {
    if (_enabled) return;
    _enabled = true;
    _connect();
  }

  Future<void> _connect() async {
    final generation = ++_generation;
    try {
      final transport = await _connectTransport();
      if (!_enabled || generation != _generation) {
        await transport.close();
        return;
      }
      _transport = transport;
      final decoder = DiscordFrameDecoder();
      _subscription = transport.bytes.listen(
        (bytes) {
          if (generation != _generation) return;
          try {
            for (final frame in decoder.add(bytes)) {
              switch (frame.opcode) {
                case 1:
                  if (frame.payload['cmd'] == 'DISPATCH' && frame.payload['evt'] == 'READY') {
                    _handshake?.cancel();
                    _ready = true;
                    _pending = _hasActivity;
                    _flush();
                  }
                case 2:
                  _disconnect(generation);
                  return;
                case 3:
                  _write(DiscordFrame(4, frame.payload), generation);
              }
            }
          } catch (e) {
            debugPrint('Discord IPC frame failed: $e');
            _disconnect(generation);
          }
        },
        onError: (Object error) => _disconnect(generation),
        onDone: () => _disconnect(generation),
      );
      _handshake = _schedule(const Duration(seconds: 10), () => _disconnect(generation));
      await _write(DiscordFrame(0, {'v': 1, 'client_id': clientId}), generation);
    } catch (e) {
      if (generation != _generation) return;
      debugPrint('Discord IPC connection failed: $e');
      _disconnect(generation);
    }
  }

  Future<void> _write(DiscordFrame frame, int generation) async {
    try {
      await _transport?.send(frame.encode());
    } catch (e) {
      debugPrint('Discord IPC write failed: $e');
      _disconnect(generation);
    }
  }

  void setActivity(Map<String, dynamic>? activity) {
    _activity = activity;
    _hasActivity = true;
    _pending = true;
    _flush();
  }

  Future<void> _flush() async {
    if (!_enabled || !_ready || !_pending || _sending || _update?.isActive == true) return;
    final elapsed = _lastSent == null ? const Duration(seconds: 4) : _now().difference(_lastSent!);
    final remaining = const Duration(seconds: 4) - elapsed;
    if (remaining > Duration.zero) {
      _update = _schedule(remaining, () {
        _update = null;
        _flush();
      });
      return;
    }
    _pending = false;
    _sending = true;
    _lastSent = _now();
    final generation = _generation;
    await _write(
      DiscordFrame(1, {
        'cmd': 'SET_ACTIVITY',
        'args': {'pid': pid, 'activity': _activity},
        'nonce': _nonce(),
      }),
      generation,
    );
    _sending = false;
    _flush();
  }

  void _disconnect(int generation) {
    if (generation != _generation) return;
    _generation++;
    _ready = false;
    _handshake?.cancel();
    _update?.cancel();
    _subscription?.cancel();
    _subscription = null;
    _transport?.close();
    _transport = null;
    if (_enabled) _retry = _schedule(const Duration(seconds: 30), _connect);
  }

  void stop() {
    setActivity(null);
    _enabled = false;
    _retry?.cancel();
    // Closing IPC also clears Discord's activity, including a rate-limited clear.
    _disconnect(_generation);
  }

  static String _nonce() {
    final random = Random.secure();
    final bytes = List.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
