import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'player.dart';

/// Karaoke mode: the lyrics sing along line by line, and songs play without their voice once the server has
/// separated them (only while karaoke is on, the current and the next song; until then the original plays).
class KaraokeState {
  const KaraokeState({this.on = false, this.songs = const {}});
  final bool on;

  /// Per song: ready | pending | failed | unavailable (karaoke is off on the server, or the song is too long).
  final Map<String, String> songs;

  bool ready(String trackId) => on && songs[trackId] == 'ready';
}

class KaraokeController extends Notifier<KaraokeState> {
  static const _retry = Duration(seconds: 10);
  final _asking = <String>{};

  @override
  KaraokeState build() {
    ref.listen(playerProvider.select(_wanted), (_, ids) {
      if (state.on) ids.forEach(_ask);
    });
    // Another server or account: its songs are separated there.
    ref.listen(sessionProvider.select((s) => (s.serverUrl, s.user?.id)), (_, _) {
      if (state.songs.isNotEmpty) state = KaraokeState(on: state.on);
    });
    return const KaraokeState();
  }

  /// The current song and the next one.
  static List<String> _wanted(PlayerView player) {
    final index = player.index;
    if (index == null || player.book != null || player.station != null) return const [];
    return [for (var i = index; i < player.queue.length && i <= index + 1; i++) player.queue[i].id];
  }

  void toggle() {
    state = KaraokeState(on: !state.on, songs: state.songs);
    if (state.on) _wanted(ref.read(playerProvider)).forEach(_ask);
    ref.read(playerProvider.notifier).applyKaraoke().ignore();
  }

  Future<void> _ask(String trackId) async {
    final known = state.songs[trackId];
    if (known == 'ready' || known == 'unavailable' || known == 'failed' || !_asking.add(trackId)) return;
    try {
      while (state.on && _wanted(ref.read(playerProvider)).contains(trackId)) {
        final result = await ref.read(apiProvider).prepareKaraoke(trackId);
        if (!ref.mounted) return;
        state = KaraokeState(on: state.on, songs: {...state.songs, trackId: result});
        if (result == 'ready') {
          await ref.read(playerProvider.notifier).applyKaraoke();
          return;
        }
        if (result != 'pending') return;
        await Future<void>.delayed(_retry);
      }
    } catch (_) {
      // Offline or an older server: the song plays with its voice.
    } finally {
      _asking.remove(trackId);
    }
  }
}

final karaokeProvider = NotifierProvider<KaraokeController, KaraokeState>(KaraokeController.new);
