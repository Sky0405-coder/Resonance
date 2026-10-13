import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

import '../core/api.dart';
import '../core/models.dart';
import '../core/session.dart';

/// Snapshot of what the UI needs to render the player.
class PlayerView {
  const PlayerView({
    this.queue = const [],
    this.index,
    this.playing = false,
    this.buffering = false,
    this.shuffle = false,
    this.loop = LoopMode.off,
    this.context,
  });

  final List<Track> queue;
  final int? index;
  final bool playing;
  final bool buffering;
  final bool shuffle;
  final LoopMode loop;
  // Where playback was started from, e.g. "album:<id>".
  final String? context;

  Track? get current => index != null && index! < queue.length ? queue[index!] : null;
}

/// Owns the [AudioPlayer]; one instance for the whole app.
class PlayerController extends Notifier<PlayerView> {
  final AudioPlayer player = AudioPlayer();
  final List<StreamSubscription> _subs = [];

  // Play reporting: count listened time for the current track.
  String? _reportTrackId;
  double _listened = 0;
  Duration _lastPos = Duration.zero;

  bool normalize = true;
  // Volume chosen by the user; multiplied with the ReplayGain factor.
  final ValueNotifier<double> userVolume = ValueNotifier(1);
  double _gainFactor = 1;

  ApiClient get _api => ref.read(apiProvider);

  @override
  PlayerView build() {
    _subs.addAll([
      player.playerStateStream.listen((s) {
        state = _copy(
          playing: s.playing,
          buffering: s.processingState == ProcessingState.loading || s.processingState == ProcessingState.buffering,
        );
      }),
      player.currentIndexStream.listen((i) {
        _flushPlayReport();
        state = _copy(index: i);
        _applyGain();
        _reportTrackId = state.current?.id;
      }),
      player.shuffleModeEnabledStream.listen((v) => state = _copy(shuffle: v)),
      player.loopModeStream.listen((v) => state = _copy(loop: v)),
      player.positionStream.listen(_trackListening),
    ]);
    ref.onDispose(() {
      for (final s in _subs) {
        s.cancel();
      }
      player.dispose();
    });
    return const PlayerView();
  }

  PlayerView _copy({int? index, bool? playing, bool? buffering, bool? shuffle, LoopMode? loop}) => PlayerView(
    queue: state.queue,
    index: index ?? state.index,
    playing: playing ?? state.playing,
    buffering: buffering ?? state.buffering,
    shuffle: shuffle ?? state.shuffle,
    loop: loop ?? state.loop,
    context: state.context,
  );

  AudioSource _source(Track t) => AudioSource.uri(
    Uri.parse(_api.streamUrl(t.id)),
    tag: MediaItem(
      id: t.id,
      title: t.title,
      artist: t.artistCredit,
      album: t.album.name,
      duration: t.length,
      artUri: Uri.parse(_api.coverUrl(t.album.id, size: 600)),
    ),
  );

  /// Replace the queue and start playing at [index].
  Future<void> playTracks(List<Track> tracks, {int index = 0, String? context, bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    _flushPlayReport();
    state = PlayerView(
      queue: List.unmodifiable(tracks),
      index: index,
      shuffle: shuffle,
      loop: state.loop,
      context: context,
    );
    await player.setShuffleModeEnabled(shuffle);
    await player.setAudioSources(
      [for (final t in tracks) _source(t)],
      initialIndex: shuffle ? math.Random().nextInt(tracks.length) : index,
      preload: true,
    );
    if (shuffle) await player.shuffle();
    _reportTrackId = state.current?.id;
    player.play();
  }

  Future<void> playNext(Track t) async {
    final at = (state.index ?? -1) + 1;
    await _insert(at, t);
  }

  Future<void> addToQueue(Track t) => _insert(state.queue.length, t);

  Future<void> _insert(int at, Track t) async {
    if (state.queue.isEmpty) return playTracks([t]);
    state = PlayerView(
      queue: List.unmodifiable([...state.queue]..insert(at, t)),
      index: state.index,
      playing: state.playing,
      buffering: state.buffering,
      shuffle: state.shuffle,
      loop: state.loop,
      context: state.context,
    );
    await player.insertAudioSource(at, _source(t));
  }

  Future<void> removeAt(int i) async {
    state = PlayerView(
      queue: List.unmodifiable([...state.queue]..removeAt(i)),
      index: state.index,
      playing: state.playing,
      buffering: state.buffering,
      shuffle: state.shuffle,
      loop: state.loop,
      context: state.context,
    );
    await player.removeAudioSourceAt(i);
  }

  void togglePlay() => player.playing ? player.pause() : player.play();

  Future<void> next() => player.seekToNext();

  /// Like Spotify: restart the track unless we're in its first 3 seconds.
  Future<void> previous() async {
    if (player.position > const Duration(seconds: 3) || !player.hasPrevious) {
      await player.seek(Duration.zero);
    } else {
      await player.seekToPrevious();
    }
  }

  Future<void> jumpTo(int index) => player.seek(Duration.zero, index: index);

  Future<void> seek(Duration d) => player.seek(d);

  Future<void> toggleShuffle() async {
    final enable = !player.shuffleModeEnabled;
    if (enable) await player.shuffle();
    await player.setShuffleModeEnabled(enable);
  }

  Future<void> cycleLoop() => player.setLoopMode(switch (player.loopMode) {
    LoopMode.off => LoopMode.all,
    LoopMode.all => LoopMode.one,
    LoopMode.one => LoopMode.off,
  });

  void setLikedLocally(String trackId, bool liked) {
    state = PlayerView(
      queue: List.unmodifiable([for (final t in state.queue) t.id == trackId ? t.copyWith(liked: liked) : t]),
      index: state.index,
      playing: state.playing,
      buffering: state.buffering,
      shuffle: state.shuffle,
      loop: state.loop,
      context: state.context,
    );
  }

  /// ReplayGain: attenuate loud tracks towards a common level. We can only
  /// lower volume (max 1.0), so gains are offset by a fixed headroom.
  void _applyGain() {
    final t = state.current;
    if (!normalize || t == null) {
      _gainFactor = 1;
    } else {
      const headroomDb = -6.0;
      final gainDb = (t.replayGainTrack ?? 0) + headroomDb;
      _gainFactor = math.min(1.0, math.pow(10, gainDb / 20).toDouble());
    }
    player.setVolume(_gainFactor * userVolume.value);
  }

  void setUserVolume(double v) {
    userVolume.value = v.clamp(0, 1);
    player.setVolume(_gainFactor * userVolume.value);
  }

  void setNormalize(bool enabled) {
    normalize = enabled;
    _applyGain();
  }

  void _trackListening(Duration pos) {
    final delta = (pos - _lastPos).inMilliseconds / 1000;
    // Ignore seeks (big jumps or backwards).
    if (delta > 0 && delta < 2 && player.playing) _listened += delta;
    _lastPos = pos;
  }

  /// Report a play once at least 30 s or half of the track was listened to.
  void _flushPlayReport() {
    final id = _reportTrackId;
    final track = state.queue.where((t) => t.id == id).firstOrNull;
    if (id != null && track != null && (_listened >= 30 || _listened >= track.duration / 2)) {
      _api.reportPlay(id, _listened, context: state.context).ignore();
    }
    _reportTrackId = null;
    _listened = 0;
    _lastPos = Duration.zero;
  }
}

final playerProvider = NotifierProvider<PlayerController, PlayerView>(PlayerController.new);

final positionProvider = StreamProvider<Duration>((ref) => ref.read(playerProvider.notifier).player.positionStream);
final durationProvider = StreamProvider<Duration?>((ref) => ref.read(playerProvider.notifier).player.durationStream);
