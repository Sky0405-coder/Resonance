import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/equalizer.dart';

class ConnectTestEngine implements PlaybackEngine {
  final states = StreamController<PlayerState>.broadcast(sync: true);
  final indices = StreamController<int?>.broadcast(sync: true);
  final loops = StreamController<LoopMode>.broadcast(sync: true);
  @override
  Stream<PlayerState> get playerStateStream => states.stream;
  @override
  Stream<int?> get currentIndexStream => indices.stream;
  @override
  Stream<LoopMode> get loopModeStream => loops.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<Object> get errorStream => const Stream.empty();
  @override
  int crossfadeSeconds = 0;
  @override
  bool automix = false;
  @override
  MixPoints? Function(int)? mixPointsForIndex;
  @override
  String? Function(int index)? sourceKeyForIndex;
  @override
  Future<void> setEqualizer(EqualizerSettings settings) async {}
  @override
  double Function(int)? targetVolumeForIndex;
  @override
  bool isBook = false;
  @override
  bool playing = false;
  @override
  ProcessingState processingState = ProcessingState.ready;
  @override
  int? currentIndex;
  @override
  Duration position = Duration.zero;
  @override
  LoopMode loopMode = LoopMode.off;
  @override
  double speed = 1;
  @override
  List<SourceFactory> audioSources = [];
  final removed = <int>[];
  bool? preservedCurrent;

  @override
  Future<void> setSources(
    List<SourceFactory> sources, {
    required int initialIndex,
    Duration initialPosition = Duration.zero,
    bool preserveCurrent = false,
  }) async {
    audioSources = [...sources];
    preservedCurrent = preserveCurrent;
    currentIndex = initialIndex;
    if (!preserveCurrent) position = initialPosition;
  }

  @override
  Future<void> insert(int index, SourceFactory source) async => audioSources.insert(index, source);
  @override
  Future<void> removeAt(int index) async {
    removed.add(index);
    audioSources.removeAt(index);
  }

  Future<void>? playbackLifetime;

  @override
  Future<void> play() async {
    playing = true;
    states.add(PlayerState(true, processingState));
    if (playbackLifetime != null) await playbackLifetime;
  }

  @override
  Future<void> pause() async {
    playing = false;
    states.add(PlayerState(false, processingState));
  }

  @override
  Future<void> stop() => pause();
  @override
  Future<void> finishFade() async {}
  @override
  Future<void> setLoopMode(LoopMode mode) async {
    loopMode = mode;
    loops.add(mode);
  }

  @override
  Future<void> setSpeed(double value) async => speed = value;
  @override
  Future<void> setVolume(double value) async => volume = value;
  double volume = 1;
  @override
  Future<void> seek(Duration value, {int? index}) async {
    position = value;
    currentIndex = index ?? currentIndex;
    indices.add(currentIndex);
  }

  @override
  bool get hasPrevious => (currentIndex ?? 0) > 0;
  @override
  Future<void> seekToNext() => seek(Duration.zero, index: (currentIndex ?? 0) + 1);
  @override
  Future<void> seekToPrevious() => seek(Duration.zero, index: (currentIndex ?? 0) - 1);

  @override
  Future<void> dispose() async {
    await states.close();
    await indices.close();
    await loops.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
