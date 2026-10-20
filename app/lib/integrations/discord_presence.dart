import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/session.dart';
import '../l10n/l10n.dart';
import '../l10n/locale.dart';
import '../player/player.dart';
import 'discord_rpc.dart';

bool get isDiscordDesktop =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows);

final discordClientIdProvider = FutureProvider<String>((ref) async {
  if (!isDiscordDesktop) return '';
  final session = ref.watch(sessionProvider.select((s) => (s.loggedIn, s.serverUrl, s.token, s.offline)));
  if (!session.$1) return '';
  var id = '';
  try {
    id = await ref.read(apiProvider).discordClientId();
  } catch (e) {
    debugPrint('Discord client configuration failed: $e');
  }
  // The admin may enter the application ID while the app runs (or the server was unreachable): ask again later.
  if (id.isEmpty) {
    final retry = Timer(const Duration(minutes: 2), ref.invalidateSelf);
    ref.onDispose(retry.cancel);
  }
  return id;
});

class DiscordPresenceSetting extends Notifier<bool> {
  @override
  bool build() => ref.read(prefsProvider).getBool('discord_presence') ?? true;

  void setEnabled(bool enabled) {
    state = enabled;
    ref.read(prefsProvider).setBool('discord_presence', enabled);
  }
}

final discordPresenceSettingProvider = NotifierProvider<DiscordPresenceSetting, bool>(DiscordPresenceSetting.new);

final discordPresenceProvider = Provider<void>((ref) {
  if (!isDiscordDesktop) return;
  final session = ref.watch(sessionProvider.select((s) => (s.loggedIn, s.serverUrl, s.token)));
  final clientId = ref.watch(discordClientIdProvider).asData?.value ?? '';
  final enabled = ref.watch(discordPresenceSettingProvider);
  if (!session.$1 || !enabled || clientId.isEmpty) return;
  final rpc = DiscordRpc(clientId: clientId);
  final player = ref.watch(playerProvider.notifier);
  final presence = DiscordPresenceController(
    rpc: rpc,
    serverUrl: session.$2!,
    localizations: () => lookupAppLocalizations(ref.read(appLocaleProvider)),
  );
  Duration position() => ref.read(playerProvider).book == null
      ? player.engine.position
      : Duration(milliseconds: (player.bookPosition * 1000).round());
  void update() => presence.update(
    ref.read(playerProvider),
    position(),
    stopped:
        player.engine.processingState == ProcessingState.completed ||
        player.engine.processingState == ProcessingState.idle,
  );
  ref.listen(
    playerProvider.select((p) => (p.current, p.book, p.station, p.stationNow, p.index, p.playing, p.speed)),
    (_, _) => update(),
  );
  ref.listen(appLocaleProvider, (_, _) => update());
  final positions = player.engine.positionStream.listen((_) => presence.onPosition(position()));
  final states = player.engine.playerStateStream.listen((_) => update());
  ref.onDispose(() {
    positions.cancel();
    states.cancel();
    rpc.stop();
  });
  update();
  rpc.start();
});

String _discordText(String value) {
  final text = String.fromCharCodes(value.runes.take(128));
  final length = text.runes.length;
  return length < 2 ? '$text${' ' * (2 - length)}' : text;
}

Map<String, dynamic>? buildDiscordActivity({
  required PlayerView player,
  required Duration position,
  required String serverUrl,
  required AppLocalizations l10n,
  required DateTime now,
}) {
  final track = player.current;
  final book = player.book;
  final station = player.station;
  final stationNow = player.stationNow;
  if (!player.playing || (track == null && book == null && (station == null || stationNow?.title == null))) {
    return null;
  }
  // Build public artwork from the origin/path only; credentials and query tokens never reach Discord.
  final server = Uri.parse(serverUrl);
  final image = Uri(
    scheme: server.scheme,
    host: server.host,
    port: server.hasPort ? server.port : null,
    path: '${server.path.replaceFirst(RegExp(r'/+$'), '')}/icons/Icon-512.png',
  ).toString();
  if (station != null) {
    return {
      'type': 2,
      'details': _discordText(stationNow!.title!),
      'state': _discordText([
        if (stationNow.artist?.isNotEmpty ?? false) l10n.discordPresenceArtist(stationNow.artist!),
        station.name,
      ].join(' · ')),
      'assets': {
        'large_image': image,
        if (stationNow.album != null) 'large_text': _discordText(stationNow.album!),
      },
    };
  }
  final duration = book == null ? track!.length.inMilliseconds : (book.duration * 1000).round();
  final start = now.millisecondsSinceEpoch - position.inMilliseconds;
  final chapter = book?.chapterAt(position.inMilliseconds / 1000)?.title;
  return {
    'type': 2,
    'details': _discordText(book?.title ?? track!.title),
    'state': _discordText(book == null ? l10n.discordPresenceArtist(track!.artistCredit) : book.author ?? ''),
    'assets': {
      'large_image': image,
      if (book == null || chapter != null) 'large_text': _discordText(book == null ? track!.album.name : chapter!),
    },
    'timestamps': {'start': start, if (player.speed == 1) 'end': start + duration},
  };
}

class DiscordPresenceController {
  DiscordPresenceController({
    required this.rpc,
    required this.serverUrl,
    required this.localizations,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final DiscordRpc rpc;
  final String serverUrl;
  final AppLocalizations Function() localizations;
  final DateTime Function() _now;
  PlayerView _player = const PlayerView();
  bool _stopped = false;
  Duration _position = Duration.zero;
  DateTime? _observedAt;
  String? _chapter;

  void update(PlayerView player, Duration position, {bool stopped = false}) {
    _player = player;
    _stopped = stopped;
    _send(position);
  }

  void onPosition(Duration position) {
    if (!_player.playing || _stopped) return;
    final now = _now();
    final expected =
        _position.inMilliseconds +
        (_observedAt == null ? 0 : now.difference(_observedAt!).inMilliseconds * _player.speed);
    final chapter = _player.book?.chapterAt(position.inMilliseconds / 1000)?.title;
    if ((position.inMilliseconds - expected).abs() > 2000 || chapter != _chapter) _send(position);
  }

  void _send(Duration position) {
    _position = position;
    _observedAt = _now();
    _chapter = _player.book?.chapterAt(position.inMilliseconds / 1000)?.title;
    rpc.setActivity(
      _stopped
          ? null
          : buildDiscordActivity(
              player: _player,
              position: position,
              serverUrl: serverUrl,
              l10n: localizations(),
              now: _observedAt!,
            ),
    );
  }
}
