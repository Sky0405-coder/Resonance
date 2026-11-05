import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../../player/engine.dart';
import '../../player/mix_fx.dart';
import '../../player/mix_lanes.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import '../widgets/common.dart';

/// The speed of a deck playing at [bpm] so it runs at [targetBpm] (double and half time count); null when that
/// would change it by more than 16 %.
double? syncSpeed(double bpm, double targetBpm) {
  if (bpm <= 0 || targetBpm <= 0) return null;
  var ratio = targetBpm / bpm;
  while (ratio > 1.5) {
    ratio /= 2;
  }
  while (ratio < 0.75) {
    ratio *= 2;
  }
  return (ratio - 1).abs() <= 0.16 ? ratio : null;
}

/// Where in its beat (0 to 1) a song is at [seconds], counting from its [downbeat].
double beatPhase(double seconds, double downbeat, double beat) {
  final phase = ((seconds - downbeat) / beat) % 1;
  return phase < 0 ? phase + 1 : phase;
}

/// The volumes of decks A and B for a crossfader at [position] (-1 = A only, 1 = B only), keeping the loudness
/// even in the middle.
(double, double) crossfaderGains(double position) {
  final x = ((position.clamp(-1.0, 1.0) + 1) / 2) * math.pi / 2;
  return (math.cos(x), math.sin(x));
}

/// One deck: its own player (with the desktop filter chain, addressed by `deck=<id>` in its stream URL), the song,
/// its analysis, tempo, EQ, cues and loop.
class DjDeck extends ChangeNotifier {
  DjDeck(this.id) {
    _subs.addAll([
      player.positionStream.listen((_) => notifyListeners()),
      player.playerStateStream.listen((_) => notifyListeners()),
    ]);
  }

  final String id;
  final player = AudioPlayer();
  final _subs = <StreamSubscription>[];
  Track? track;
  MixPoints? points;
  double speed = 1;
  double low = 0, mid = 0, high = 0;

  /// -1 (low-pass closed) … 0 (open) … 1 (high-pass closed).
  double filter = 0;
  double channel = 1;
  Duration cue = Duration.zero;
  final hotCues = List<Duration?>.filled(4, null);
  int loopBeats = 0;

  String get key => 'deck=$id';
  double? get bpm => points?.bpm == null ? null : points!.bpm! * speed;
  double get beat => 60 / (points?.bpm ?? 120);
  double get downbeat => points?.downbeat ?? points?.mixIn ?? 0;
  double get seconds => player.position.inMicroseconds / 1e6;

  /// Something on the deck changed outside its own methods (a cue set or cleared, the channel fader).
  void changed() => notifyListeners();

  Future<void> load(String url, Track track, MixPoints? points) async {
    this.track = track;
    this.points = points;
    cue = Duration(microseconds: ((points?.mixIn ?? 0) * 1e6).round());
    hotCues.fillRange(0, 4, null);
    loopBeats = 0;
    notifyListeners();
    await player.setAudioSource(AudioSource.uri(Uri.parse('$url&$key')));
    await player.seek(cue);
    await setSpeed(1);
    applyEffects();
  }

  Future<void> setSpeed(double value) async {
    speed = value;
    notifyListeners();
    await player.setSpeed(value);
  }

  /// The EQ and filter through the deck's filter chain.
  void applyEffects() {
    final state = FxState(
      low: low,
      mid: mid,
      high: high,
      highpass: filter > 0 ? mixHighpassOff * math.pow(2400 / mixHighpassOff, filter).toDouble() : mixHighpassOff,
      lowpass: filter < 0 ? mixLowpassOff * math.pow(250 / mixLowpassOff, -filter).toDouble() : mixLowpassOff,
    );
    for (final command in mpvFxCommands(state, null)) {
      JustAudioMediaKit.sourceCommand(key, command);
    }
    notifyListeners();
  }

  /// Loops the last [beats] beats from now (0 ends the loop).
  void setLoop(int beats) {
    loopBeats = beats == loopBeats ? 0 : beats;
    if (loopBeats == 0) {
      JustAudioMediaKit.sourceCommand(key, ['set', 'ab-loop-a', 'no']);
      JustAudioMediaKit.sourceCommand(key, ['set', 'ab-loop-b', 'no']);
    } else {
      // On the beat grid: the loop ends on the next beat.
      final end = downbeat + ((seconds - downbeat) / beat).ceil() * beat;
      JustAudioMediaKit.sourceCommand(key, ['set', 'ab-loop-a', (end - loopBeats * beat).toStringAsFixed(3)]);
      JustAudioMediaKit.sourceCommand(key, ['set', 'ab-loop-b', end.toStringAsFixed(3)]);
    }
    notifyListeners();
  }

  /// Sync to [other]: the same tempo, then the same place in the beat.
  Future<void> syncTo(DjDeck other) async {
    final ownBpm = points?.bpm, otherBpm = other.bpm;
    if (ownBpm == null || otherBpm == null) return;
    final target = syncSpeed(ownBpm, otherBpm);
    if (target == null) return;
    await setSpeed(target);
    if (!player.playing || !other.player.playing) return;
    final offset = beatPhase(other.seconds, other.downbeat, other.beat) - beatPhase(seconds, downbeat, beat);
    final shift = (offset > 0.5 ? offset - 1 : (offset < -0.5 ? offset + 1 : offset)) * beat;
    await player.seek(Duration(microseconds: ((seconds + shift) * 1e6).round()));
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    JustAudioMediaKit.setSourceFilter(key, null);
    player.dispose();
    super.dispose();
  }
}

/// PC: a live mixer with two decks (tempo sync, EQ, filter, cues, loops) and a crossfader, to mix by hand while
/// AutoMix rests.
class DjPage extends ConsumerStatefulWidget {
  const DjPage({super.key});

  @override
  ConsumerState<DjPage> createState() => _DjPageState();
}

class _DjPageState extends ConsumerState<DjPage> {
  final _a = DjDeck('a'), _b = DjDeck('b');
  double _crossfader = 0;

  @override
  void initState() {
    super.initState();
    final controller = ref.read(playerProvider.notifier);
    // AutoMix rests while mixing by hand (after the first frame: pausing changes the player's state).
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.pause().ignore());
    // The decks need the mix filter chain; AutoMix already puts it on every player.
    if (!controller.engine.automix) {
      for (final deck in [_a, _b]) {
        JustAudioMediaKit.setSourceFilter(deck.key, mixMpvFilter);
      }
    }
    _applyVolumes();
  }

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _applyVolumes() {
    final (a, b) = crossfaderGains(_crossfader);
    _a.player.setVolume(a * _a.channel).ignore();
    _b.player.setVolume(b * _b.channel).ignore();
  }

  Future<void> _load(DjDeck deck) async {
    final track = await showDialog<Track>(context: context, builder: (_) => const _TrackPicker());
    if (track == null || !mounted) return;
    final api = ref.read(apiProvider);
    try {
      final points = (await api.mixPoints([track.id]))[track.id];
      await deck.load(api.streamUrl(track.id), track, points);
      _applyVolumes();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.djTitle)),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: _DeckPanel(deck: _a, other: _b, onLoad: () => _load(_a)),
                  ),
                  const SizedBox(width: 12),
                  _MixerPanel(a: _a, b: _b, onChanged: _applyVolumes),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _DeckPanel(deck: _b, other: _a, onLoad: () => _load(_b)),
                  ),
                ],
              ),
            ),
            Row(
              children: [
                const Text('A', style: TextStyle(fontWeight: FontWeight.w800)),
                Expanded(
                  child: Slider(
                    min: -1,
                    max: 1,
                    value: _crossfader,
                    onChanged: (v) {
                      setState(() => _crossfader = v);
                      _applyVolumes();
                    },
                  ),
                ),
                const Text('B', style: TextStyle(fontWeight: FontWeight.w800)),
              ],
            ),
            Text(l10n.djCrossfader, style: const TextStyle(color: Palette.textMuted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _DeckPanel extends StatelessWidget {
  const _DeckPanel({required this.deck, required this.other, required this.onLoad});
  final DjDeck deck;
  final DjDeck other;
  final VoidCallback onLoad;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: deck,
      builder: (context, _) {
        final track = deck.track;
        final playing = deck.player.playing;
        return Material(
          color: Palette.surface,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 56,
                      height: 56,
                      child: track == null
                          ? const Icon(Icons.album, size: 40)
                          : CoverImage(albumId: track.album.id, size: 128),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            track?.title ?? l10n.djEmptyDeck(deck.id.toUpperCase()),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                          ),
                          if (track != null)
                            Text(
                              track.artistCredit,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(color: Palette.textMuted),
                            ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          deck.bpm == null ? '– BPM' : '${deck.bpm!.toStringAsFixed(1)} BPM',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
                        ),
                        Text(deck.points?.key ?? '', style: const TextStyle(color: Palette.textMuted)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(height: 90, child: _DeckWave(deck: deck)),
                const SizedBox(height: 4),
                Text(
                  '${formatDuration(deck.player.position)} / ${formatDuration(deck.player.duration ?? Duration.zero)}',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onLoad,
                      icon: const Icon(Icons.library_music),
                      label: Text(l10n.djLoad),
                    ),
                    // Cue: while stopped it sets the cue point; while playing it jumps back there and stops.
                    OutlinedButton(
                      onPressed: track == null
                          ? null
                          : () async {
                              if (deck.player.playing) {
                                await deck.player.pause();
                                await deck.player.seek(deck.cue);
                              } else {
                                deck.cue = deck.player.position;
                              }
                            },
                      child: const Text('CUE'),
                    ),
                    FilledButton.icon(
                      onPressed: track == null ? null : (playing ? deck.player.pause : deck.player.play),
                      icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                      label: Text(playing ? l10n.djPause : l10n.djPlay),
                    ),
                    OutlinedButton(
                      onPressed: track == null || other.track == null ? null : () => deck.syncTo(other),
                      child: const Text('SYNC'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(l10n.djTempo, style: const TextStyle(color: Palette.textMuted)),
                    Expanded(
                      child: Slider(
                        min: 0.84,
                        max: 1.16,
                        value: deck.speed.clamp(0.84, 1.16),
                        onChanged: track == null ? null : (v) => deck.setSpeed(v),
                      ),
                    ),
                    SizedBox(
                      width: 56,
                      child: Text(
                        '${deck.speed >= 1 ? '+' : ''}${((deck.speed - 1) * 100).toStringAsFixed(1)} %',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
                Text(l10n.djHotCues, style: const TextStyle(color: Palette.textMuted, fontSize: 12)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (var i = 0; i < 4; i++)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: GestureDetector(
                            onLongPress: () {
                              deck.hotCues[i] = null;
                              deck.changed();
                            },
                            child: FilledButton.tonal(
                              style: FilledButton.styleFrom(
                                backgroundColor: deck.hotCues[i] == null ? null : _cueColors[i].withValues(alpha: 0.7),
                              ),
                              onPressed: track == null
                                  ? null
                                  : () {
                                      final cue = deck.hotCues[i];
                                      if (cue == null) {
                                        deck.hotCues[i] = deck.player.position;
                                        deck.changed();
                                      } else {
                                        deck.player.seek(cue);
                                      }
                                    },
                              child: Text('${i + 1}'),
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(l10n.djLoop, style: const TextStyle(color: Palette.textMuted, fontSize: 12)),
                const SizedBox(height: 4),
                Row(
                  children: [
                    for (final beats in const [1, 2, 4, 8, 16])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: ChoiceChip(
                            label: Text('$beats'),
                            selected: deck.loopBeats == beats,
                            onSelected: track == null ? null : (_) => deck.setLoop(beats),
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

const _cueColors = [Colors.redAccent, Colors.orangeAccent, Colors.greenAccent, Colors.lightBlueAccent];

/// EQ, filter and channel volume of both decks, side by side like on a mixer.
class _MixerPanel extends StatelessWidget {
  const _MixerPanel({required this.a, required this.b, required this.onChanged});
  final DjDeck a;
  final DjDeck b;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    Widget column(DjDeck deck) => ListenableBuilder(
      listenable: deck,
      builder: (context, _) => Column(
        children: [
          Text(deck.id.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.w800)),
          for (final (label, value, set) in [
            (l10n.djHigh, deck.high, (double v) => deck.high = v),
            (l10n.djMid, deck.mid, (double v) => deck.mid = v),
            (l10n.djLow, deck.low, (double v) => deck.low = v),
          ])
            _Knob(
              label: label,
              value: value,
              min: mixCutDb,
              max: 6,
              onChanged: (v) {
                set(v);
                deck.applyEffects();
              },
            ),
          _Knob(
            label: l10n.djFilter,
            value: deck.filter,
            min: -1,
            max: 1,
            onChanged: (v) {
              deck.filter = v;
              deck.applyEffects();
            },
          ),
          SizedBox(
            height: 150,
            child: RotatedBox(
              quarterTurns: 3,
              child: Slider(
                value: deck.channel,
                onChanged: (v) {
                  deck.channel = v;
                  deck.changed();
                  onChanged();
                },
              ),
            ),
          ),
        ],
      ),
    );
    return Material(
      color: Palette.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: SizedBox(
          width: 220,
          child: SingleChildScrollView(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: column(a)),
                Expanded(child: column(b)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A small horizontal "knob": double-tap sets it back to the middle (0).
class _Knob extends StatelessWidget {
  const _Knob({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onDoubleTap: () => onChanged(0),
    child: Column(
      children: [
        Text(label, style: const TextStyle(color: Palette.textMuted, fontSize: 11)),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(trackHeight: 2),
          child: Slider(min: min, max: max, value: value.clamp(min, max), onChanged: onChanged),
        ),
      ],
    ),
  );
}

/// A deck's song as an RGB waveform around the playhead (±8 s), with its beat grid; a tap seeks there.
class _DeckWave extends ConsumerWidget {
  const _DeckWave({required this.deck});
  final DjDeck deck;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final track = deck.track;
    final spectrum = track == null ? null : ref.watch(spectrumProvider(track.id)).value;
    return LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        onTapUp: (details) {
          if (track == null) return;
          final seconds = deck.seconds + (details.localPosition.dx / constraints.maxWidth - 0.5) * 16;
          deck.player.seek(Duration(microseconds: (math.max(0, seconds) * 1e6).round()));
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: _DeckWavePainter(
            spectrum: spectrum,
            position: deck.seconds,
            beat: deck.beat,
            downbeat: deck.downbeat,
            hasGrid: deck.points?.bpm != null,
          ),
        ),
      ),
    );
  }
}

class _DeckWavePainter extends CustomPainter {
  _DeckWavePainter({
    required this.spectrum,
    required this.position,
    required this.beat,
    required this.downbeat,
    required this.hasGrid,
  });
  final Spectrum? spectrum;
  final double position;
  final double beat;
  final double downbeat;
  final bool hasGrid;

  static const _span = 16.0;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8)),
      Paint()..color = Colors.black26,
    );
    final start = position - _span / 2;
    double x(double seconds) => (seconds - start) / _span * size.width;
    if (hasGrid) {
      final grid = Paint()..strokeWidth = 1;
      for (var b = ((start - downbeat) / beat).ceil(); downbeat + b * beat <= start + _span; b++) {
        grid.color = Colors.white.withValues(alpha: b % 4 == 0 ? 0.3 : 0.08);
        final px = x(downbeat + b * beat);
        canvas.drawLine(Offset(px, 0), Offset(px, size.height), grid);
      }
    }
    final spectrum = this.spectrum;
    if (spectrum != null) {
      final levels = List<double>.filled(64, 0);
      final bands = math.min(spectrum.bands, levels.length);
      final line = Paint()..strokeWidth = 2;
      for (var px = 0.0; px < size.width; px += 2) {
        final t = start + px / size.width * _span;
        if (t < 0) continue;
        spectrum.levelsAt(Duration(microseconds: (t * 1e6).round()), levels);
        final rgb = [0.0, 0.0, 0.0], counts = [0, 0, 0];
        for (var i = 0; i < bands; i++) {
          final f = Spectrum.bandFrequency(i, bands);
          final g = f < 250 ? 0 : (f < 2500 ? 1 : 2);
          rgb[g] += levels[i];
          counts[g]++;
        }
        for (var g = 0; g < 3; g++) {
          rgb[g] = counts[g] == 0 ? 0 : rgb[g] / counts[g];
        }
        final peak = rgb.reduce(math.max);
        if (peak <= 0.01) continue;
        line.color = Color.fromRGBO(
          (255 * rgb[0] / peak).round(),
          (255 * rgb[1] / peak).round(),
          (255 * rgb[2] / peak).round(),
          px < size.width / 2 ? 0.55 : 1,
        );
        final h = peak * size.height * 0.45;
        canvas.drawLine(Offset(px, size.height / 2 - h), Offset(px, size.height / 2 + h), line);
      }
    }
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      Paint()
        ..color = Colors.white
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_DeckWavePainter old) =>
      old.position != position || old.spectrum != spectrum || old.beat != beat || old.downbeat != downbeat;
}

/// Picks a song for a deck: the current queue, or a search.
class _TrackPicker extends ConsumerStatefulWidget {
  const _TrackPicker();

  @override
  ConsumerState<_TrackPicker> createState() => _TrackPickerState();
}

class _TrackPickerState extends ConsumerState<_TrackPicker> {
  List<Track>? _results;
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _search(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      if (query.trim().isEmpty) {
        setState(() => _results = null);
        return;
      }
      try {
        final result = await ref.read(apiProvider).search(query.trim());
        if (mounted) setState(() => _results = result.tracks);
      } catch (e) {
        if (mounted) showError(context, e);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<Track> tracks = _results ?? ref.watch(playerProvider.select((p) => p.queue));
    return Dialog(
      child: SizedBox(
        width: 520,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                autofocus: true,
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: context.l10n.djSearch),
                onChanged: _search,
              ),
            ),
            Expanded(
              child: ListView(
                children: [
                  for (final track in tracks)
                    ListTile(
                      leading: SizedBox(width: 40, child: CoverImage(albumId: track.album.id, size: 64)),
                      title: Text(track.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text(track.artistCredit, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => Navigator.pop(context, track),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
