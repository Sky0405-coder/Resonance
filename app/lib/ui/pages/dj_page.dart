import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/band_waveform.dart';
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

/// Song seconds from [seconds] to the next bar (four beats counted from [downbeat]), at least [minimum] away.
double untilNextBar(double seconds, double downbeat, double beat, {double minimum = 0}) {
  final bar = 4 * beat;
  var next = downbeat + ((seconds - downbeat) / bar).ceil() * bar;
  while (next - seconds < minimum) {
    next += bar;
  }
  return next - seconds;
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
  String get label => id.toUpperCase();

  /// The tempo it plays at (the song's own times the speed).
  double? get bpm => points?.bpm == null ? null : points!.bpm! * speed;
  double get beat => 60 / (points?.bpm ?? 120);
  double get downbeat => points?.downbeat ?? points?.mixIn ?? 0;
  double get seconds => player.position.inMicroseconds / 1e6;
  bool get playing => player.playing;

  /// Something on the deck changed outside its own methods (a cue set or cleared, the channel fader).
  void changed() => notifyListeners();

  /// Loads [track], ready at [at] (else at its mix-in point, where a transition brings it in).
  Future<void> load(String url, Track track, MixPoints? points, {Duration? at}) async {
    this.track = track;
    this.points = points;
    cue = Duration(microseconds: ((points?.mixIn ?? 0) * 1e6).round());
    hotCues.fillRange(0, 4, null);
    if (loopBeats != 0) setLoop(loopBeats);
    low = mid = high = filter = 0;
    notifyListeners();
    await player.pause();
    await player.setAudioSource(AudioSource.uri(Uri.parse('$url&$key')));
    await player.seek(at ?? cue);
    await setSpeed(1);
    applyEffects();
  }

  void play() => player.play().ignore();

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

  /// Loops the last [beats] beats from now (0 or the same length again ends the loop).
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

  /// Sync to [other]: the same tempo, then (when both play) the same place in the beat.
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

/// A running transition: the crossfader moves from [start] to [target] over [seconds], the bass swaps halfway.
class _Fade {
  _Fade(this.from, this.to, this.start, this.target, this.seconds);
  final DjDeck from;
  final DjDeck to;
  final double start;
  final double target;
  final double seconds;
  final watch = Stopwatch()..start();
  bool swapped = false;

  double get progress => (watch.elapsedMicroseconds / 1e6 / seconds).clamp(0.0, 1.0);
}

/// PC: mixing by hand with two decks. Deck A takes over the playing song, deck B gets the next one from the queue;
/// "transition" matches the tempo, starts the other deck on the next bar and fades over, and the deck that ended
/// gets the following song. Tempo, EQ, cues and loops sit under "more". Leaving hands the song back to the player.
class DjPage extends ConsumerStatefulWidget {
  const DjPage({super.key});

  @override
  ConsumerState<DjPage> createState() => _DjPageState();
}

class _DjPageState extends ConsumerState<DjPage> {
  final _a = DjDeck('a'), _b = DjDeck('b');
  late final PlayerController _controller = ref.read(playerProvider.notifier);
  double _crossfader = -1;
  int _beats = 16;
  List<Track> _queue = const [];
  int _next = 0;
  _Fade? _fade;
  Timer? _fadeTimer;
  Timer? _startTimer;

  @override
  void initState() {
    super.initState();
    // The decks need the mix filter chain; AutoMix already puts it on every player.
    if (!_controller.engine.automix) {
      for (final deck in [_a, _b]) {
        JustAudioMediaKit.setSourceFilter(deck.key, mixMpvFilter);
      }
    }
    _applyVolumes();
    // After the first frame: pausing changes the player's state.
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeOver());
  }

  /// Deck A continues the playing song where it is, deck B gets the next one.
  Future<void> _takeOver() async {
    final view = ref.read(playerProvider);
    final playing = view.playing;
    final position = _controller.engine.position;
    await _controller.pause();
    if (view.book != null || view.station != null || view.connectRemote) return;
    _queue = view.queue;
    final index = view.index ?? -1;
    final current = view.current;
    _next = index + 1;
    if (current != null) {
      await _loadTrack(_a, current, at: position);
      if (playing && mounted) _a.play();
    }
    if (mounted) await _loadNext(_b);
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    _startTimer?.cancel();
    _handBack();
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  /// The song playing on a deck continues in the player, when it is in the queue.
  void _handBack() {
    final deck = [_a, _b].where((d) => d.playing && d.track != null).firstOrNull;
    if (deck == null) return;
    final index = _queue.indexWhere((t) => t.id == deck.track!.id);
    if (index < 0) return;
    final position = deck.player.position;
    final controller = _controller;
    () async {
      await controller.jumpTo(index);
      await controller.seek(position);
      await controller.play();
    }().ignore();
  }

  DjDeck _otherDeck(DjDeck deck) => identical(deck, _a) ? _b : _a;

  /// The deck the crowd hears: the one the crossfader leans to, unless only the other one plays.
  DjDeck get _live {
    final leaning = _crossfader <= 0 ? _a : _b;
    final other = _otherDeck(leaning);
    return !leaning.playing && other.playing ? other : leaning;
  }

  void _applyVolumes() {
    final (a, b) = crossfaderGains(_crossfader);
    _a.player.setVolume(a * _a.channel).ignore();
    _b.player.setVolume(b * _b.channel).ignore();
  }

  void _setCrossfader(double value, {bool byHand = true}) {
    if (byHand) _cancelTransition();
    setState(() => _crossfader = value.clamp(-1.0, 1.0));
    _applyVolumes();
  }

  Future<void> _loadTrack(DjDeck deck, Track track, {Duration? at}) async {
    final api = ref.read(apiProvider);
    try {
      final points = (await api.mixPoints([track.id]))[track.id];
      await deck.load(api.streamUrl(track.id), track, points, at: at);
      _applyVolumes();
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  /// The next song of the queue onto [deck] (it stays as it is at the end of the queue).
  Future<void> _loadNext(DjDeck deck) async {
    if (_next < 0 || _next >= _queue.length) return;
    final track = _queue[_next++];
    await _loadTrack(deck, track);
    if (mounted) setState(() {});
  }

  Future<void> _pick(DjDeck deck) async {
    final track = await showDialog<Track>(context: context, builder: (_) => const _TrackPicker());
    if (track == null || !mounted) return;
    if (_fade != null && (identical(_fade!.to, deck) || identical(_fade!.from, deck))) _cancelTransition();
    await _loadTrack(deck, track);
  }

  bool get _transitioning => _fade != null || _startTimer != null;

  Future<void> _toggleTransition() async {
    if (_transitioning) {
      _cancelTransition();
      return;
    }
    final from = _live, to = _otherDeck(from);
    if (from.track == null || to.track == null) {
      showInfo(context, context.l10n.djNeedsTwo);
      return;
    }
    if (!from.playing) {
      // Nothing playing yet: this starts the deck being heard.
      from.play();
      return;
    }
    await to.syncTo(from);
    // The bass of the coming song stays out until the swap halfway.
    to.low = mixCutDb;
    to.applyEffects();
    await to.player.seek(to.cue);
    final delay = untilNextBar(from.seconds, from.downbeat, from.beat, minimum: 0.3) / from.speed;
    if (!mounted) return;
    setState(() {
      _startTimer = Timer(Duration(microseconds: (delay * 1e6).round()), () {
        _startTimer = null;
        if (!mounted) return;
        to.play();
        final seconds = _beats * from.beat / from.speed;
        _fade = _Fade(from, to, _crossfader, identical(to, _b) ? 1 : -1, seconds);
        // Once both run, line up their beats exactly.
        Timer(const Duration(milliseconds: 400), () {
          if (mounted && identical(_fade?.to, to)) to.syncTo(from).ignore();
        });
        _fadeTimer = Timer.periodic(const Duration(milliseconds: 40), (_) => _stepFade());
        setState(() {});
      });
    });
  }

  void _stepFade() {
    final fade = _fade;
    if (fade == null || !mounted) return;
    final progress = fade.progress;
    _setCrossfader(fade.start + (fade.target - fade.start) * progress, byHand: false);
    if (!fade.swapped && progress >= 0.5) {
      fade.swapped = true;
      fade.from.low = mixCutDb;
      fade.from.applyEffects();
      fade.to.low = 0;
      fade.to.applyEffects();
    }
    if (progress >= 1) {
      _fadeTimer?.cancel();
      _fadeTimer = null;
      _fade = null;
      fade.from.player.pause();
      fade.from.low = 0;
      fade.from.applyEffects();
      _loadNext(fade.from);
      setState(() {});
    }
  }

  /// Stops the automatic transition where it is (the crossfader stays, both basses come back).
  void _cancelTransition() {
    final fade = _fade;
    if (!_transitioning) return;
    _startTimer?.cancel();
    _startTimer = null;
    _fadeTimer?.cancel();
    _fadeTimer = null;
    _fade = null;
    for (final deck in [_a, _b]) {
      if (deck.low == mixCutDb) {
        deck.low = 0;
        deck.applyEffects();
      }
    }
    if (fade == null) setState(() {});
  }

  void _togglePlay(DjDeck deck) {
    if (deck.track == null) return;
    deck.playing ? deck.player.pause() : deck.play();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    const nudge = 0.1;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.djTitle)),
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyQ): () => _togglePlay(_a),
          const SingleActivator(LogicalKeyboardKey.keyP): () => _togglePlay(_b),
          const SingleActivator(LogicalKeyboardKey.keyT): _toggleTransition,
          const SingleActivator(LogicalKeyboardKey.keyS): () {
            final incoming = _otherDeck(_live);
            if (incoming.track != null) incoming.syncTo(_live).ignore();
          },
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _setCrossfader(_crossfader - nudge),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _setCrossfader(_crossfader + nudge),
        },
        child: Focus(
          autofocus: true,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 900;
              final center = _CenterPanel(
                crossfader: _crossfader,
                beats: _beats,
                from: _live,
                to: _otherDeck(_live),
                fade: _fade,
                starting: _startTimer != null,
                nextUp: _next >= 0 && _next < _queue.length ? _queue[_next] : null,
                onCrossfader: _setCrossfader,
                onBeats: (beats) => setState(() => _beats = beats),
                onTransition: _toggleTransition,
              );
              Widget controls(DjDeck deck) => _DeckControls(
                deck: deck,
                other: _otherDeck(deck),
                onLoad: () => _pick(deck),
                onChannel: _applyVolumes,
              );
              return ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  _DeckStrip(deck: _a, gain: crossfaderGains(_crossfader).$1),
                  const SizedBox(height: 8),
                  _DeckStrip(deck: _b, gain: crossfaderGains(_crossfader).$2),
                  const SizedBox(height: 16),
                  if (wide)
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: controls(_a)),
                        const SizedBox(width: 16),
                        SizedBox(width: 340, child: center),
                        const SizedBox(width: 16),
                        Expanded(child: controls(_b)),
                      ],
                    )
                  else ...[
                    center,
                    const SizedBox(height: 16),
                    controls(_a),
                    const SizedBox(height: 16),
                    controls(_b),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    l10n.djShortcuts,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A deck's song across the full width: title, tempo and key, time left, and its waveform under the playhead.
/// Both decks' strips line up, so their beats can be compared at a glance; the one being heard is outlined.
class _DeckStrip extends StatelessWidget {
  const _DeckStrip({required this.deck, required this.gain});
  final DjDeck deck;
  final double gain;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final accent = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      listenable: deck,
      builder: (context, _) {
        final track = deck.track;
        final heard = deck.playing && gain > 0.05;
        final duration = deck.player.duration ?? Duration.zero;
        final left = duration - deck.player.position;
        final base = deck.points?.bpm;
        return Container(
          decoration: BoxDecoration(
            color: Palette.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: heard ? accent.withValues(alpha: 0.4 + 0.6 * gain) : Colors.transparent,
              width: 2,
            ),
          ),
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _DeckBadge(label: deck.label, active: heard),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 40,
                    height: 40,
                    child: track == null
                        ? const Icon(Icons.album, size: 32)
                        : CoverImage(albumId: track.album.id, size: 96),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          track?.title ?? l10n.djEmptyDeck(deck.label),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        if (track != null)
                          Text(
                            track.artistCredit,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Palette.textMuted, fontSize: 13),
                          ),
                      ],
                    ),
                  ),
                  if (track != null) ...[
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          deck.bpm == null ? '– BPM' : '${deck.bpm!.toStringAsFixed(1)} BPM',
                          style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
                        ),
                        if (base != null && (deck.speed - 1).abs() > 0.0005)
                          Text(
                            l10n.djOriginalBpm(
                              base.toStringAsFixed(1),
                              '${deck.speed > 1 ? '+' : '−'}${((deck.speed - 1).abs() * 100).toStringAsFixed(1)} %',
                            ),
                            style: const TextStyle(color: Palette.textMuted, fontSize: 11),
                          ),
                      ],
                    ),
                    const SizedBox(width: 14),
                    if (deck.points?.key case final key?)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(color: Colors.white10, borderRadius: BorderRadius.circular(6)),
                        child: Text(key, style: const TextStyle(fontWeight: FontWeight.w700)),
                      ),
                    const SizedBox(width: 14),
                    SizedBox(
                      width: 52,
                      child: Text(
                        '−${formatDuration(left.isNegative ? Duration.zero : left)}',
                        textAlign: TextAlign.end,
                        style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(height: 120, child: _DeckWave(deck: deck)),
            ],
          ),
        );
      },
    );
  }
}

class _DeckBadge extends StatelessWidget {
  const _DeckBadge({required this.label, required this.active});
  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      width: 30,
      height: 30,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: active ? accent : Colors.white12, borderRadius: BorderRadius.circular(8)),
      child: Text(
        label,
        style: TextStyle(fontWeight: FontWeight.w900, color: active ? onColor(accent) : Colors.white),
      ),
    );
  }
}

/// Play, sync, load, filter and volume of one deck; tempo, EQ, cues and loops folded away under "more".
class _DeckControls extends StatelessWidget {
  const _DeckControls({required this.deck, required this.other, required this.onLoad, required this.onChannel});
  final DjDeck deck;
  final DjDeck other;
  final VoidCallback onLoad;
  final VoidCallback onChannel;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return ListenableBuilder(
      listenable: deck,
      builder: (context, _) {
        final loaded = deck.track != null;
        return Material(
          color: Palette.surface,
          borderRadius: BorderRadius.circular(12),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    _DeckBadge(label: deck.label, active: false),
                    const Spacer(),
                    IconButton(tooltip: l10n.djLoad, onPressed: onLoad, icon: const Icon(Icons.library_music_outlined)),
                    const SizedBox(width: 4),
                    OutlinedButton(
                      onPressed: loaded && other.track != null ? () => deck.syncTo(other) : null,
                      child: const Text('SYNC'),
                    ),
                    const SizedBox(width: 8),
                    IconButton.filled(
                      iconSize: 32,
                      tooltip: deck.playing ? l10n.djPause : l10n.djPlay,
                      onPressed: loaded ? () => deck.playing ? deck.player.pause() : deck.play() : null,
                      icon: Icon(deck.playing ? Icons.pause : Icons.play_arrow),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _LabeledSlider(
                  label: l10n.djFilter,
                  value: deck.filter,
                  min: -1,
                  max: 1,
                  start: 'LP',
                  end: 'HP',
                  onChanged: loaded
                      ? (v) {
                          // A little dead zone around the middle, so it is easy to open fully.
                          deck.filter = v.abs() < 0.04 ? 0 : v;
                          deck.applyEffects();
                        }
                      : null,
                ),
                _LabeledSlider(
                  label: l10n.djVolume,
                  value: deck.channel,
                  min: 0,
                  max: 1,
                  reset: 1,
                  valueText: '${(deck.channel * 100).round()} %',
                  onChanged: (v) {
                    deck.channel = v;
                    deck.changed();
                    onChannel();
                  },
                ),
                Theme(
                  data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                  child: ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    childrenPadding: const EdgeInsets.only(bottom: 8),
                    title: Text(l10n.djMore, style: const TextStyle(fontSize: 13, color: Palette.textMuted)),
                    children: [
                      _LabeledSlider(
                        label: l10n.djTempo,
                        value: deck.speed,
                        min: 0.84,
                        max: 1.16,
                        reset: 1,
                        valueText:
                            '${deck.speed >= 1 ? '+' : '−'}${((deck.speed - 1).abs() * 100).toStringAsFixed(1)} %',
                        onChanged: loaded ? (v) => deck.setSpeed(v) : null,
                      ),
                      for (final (label, value, set) in [
                        (l10n.djHigh, deck.high, (double v) => deck.high = v),
                        (l10n.djMid, deck.mid, (double v) => deck.mid = v),
                        (l10n.djLow, deck.low, (double v) => deck.low = v),
                      ])
                        _LabeledSlider(
                          label: label,
                          value: value,
                          min: mixCutDb,
                          max: 6,
                          valueText: '${value > 0 ? '+' : ''}${value.toStringAsFixed(0)} dB',
                          onChanged: loaded
                              ? (v) {
                                  set(v);
                                  deck.applyEffects();
                                }
                              : null,
                        ),
                      const SizedBox(height: 6),
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
                                      backgroundColor: deck.hotCues[i] == null
                                          ? null
                                          : _cueColors[i].withValues(alpha: 0.7),
                                    ),
                                    onPressed: loaded
                                        ? () {
                                            final cue = deck.hotCues[i];
                                            if (cue == null) {
                                              deck.hotCues[i] = deck.player.position;
                                              deck.changed();
                                            } else {
                                              deck.player.seek(cue);
                                            }
                                          }
                                        : null,
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
                      Wrap(
                        spacing: 6,
                        children: [
                          for (final beats in const [1, 2, 4, 8, 16])
                            ChoiceChip(
                              label: Text('$beats'),
                              selected: deck.loopBeats == beats,
                              onSelected: loaded ? (_) => deck.setLoop(beats) : null,
                            ),
                        ],
                      ),
                    ],
                  ),
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

/// A slider with its name on the left and its value (or end labels) on the right; double-tap resets it.
class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.reset = 0,
    this.valueText,
    this.start,
    this.end,
  });
  final String label;
  final double value;
  final double min;
  final double max;
  final double reset;
  final String? valueText;
  final String? start;
  final String? end;
  final ValueChanged<double>? onChanged;

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: Palette.textMuted, fontSize: 12);
    return GestureDetector(
      onDoubleTap: onChanged == null ? null : () => onChanged!(reset),
      child: Row(
        children: [
          SizedBox(width: 84, child: Text(label, style: const TextStyle(fontSize: 13))),
          SizedBox(width: 22, child: Text(start ?? '', style: muted)),
          Expanded(
            child: Slider(min: min, max: max, value: value.clamp(min, max), onChanged: onChanged),
          ),
          SizedBox(
            width: 64,
            child: Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(valueText ?? end ?? '', style: muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// The transition button with its length, the crossfader and what comes next.
class _CenterPanel extends StatelessWidget {
  const _CenterPanel({
    required this.crossfader,
    required this.beats,
    required this.from,
    required this.to,
    required this.fade,
    required this.starting,
    required this.nextUp,
    required this.onCrossfader,
    required this.onBeats,
    required this.onTransition,
  });
  final double crossfader;
  final int beats;
  final DjDeck from;
  final DjDeck to;
  final _Fade? fade;
  final bool starting;
  final Track? nextUp;
  final ValueChanged<double> onCrossfader;
  final ValueChanged<int> onBeats;
  final VoidCallback onTransition;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final running = fade != null || starting;
    final source = fade?.from ?? from, target = fade?.to ?? to;
    return Material(
      color: Palette.surface,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: FilledButton.icon(
                style: running ? FilledButton.styleFrom(backgroundColor: Colors.white24) : null,
                onPressed: onTransition,
                icon: Icon(running ? Icons.close : Icons.swap_horiz),
                label: Text(
                  running ? l10n.djTransitionCancel : l10n.djTransition(source.label, target.label),
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 8),
            if (running)
              LinearProgressIndicator(value: fade?.progress)
            else
              Text(
                l10n.djTransitionHint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.textMuted, fontSize: 11),
              ),
            const SizedBox(height: 10),
            SegmentedButton<int>(
              showSelectedIcon: false,
              segments: [
                for (final b in const [8, 16, 32]) ButtonSegment(value: b, label: Text(l10n.djBeats(b))),
              ],
              selected: {beats},
              onSelectionChanged: running ? null : (s) => onBeats(s.first),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Text('A', style: TextStyle(fontWeight: FontWeight.w900)),
                Expanded(
                  child: GestureDetector(
                    onDoubleTap: () => onCrossfader(0),
                    child: SliderTheme(
                      data: SliderTheme.of(context)
                          .copyWith(trackHeight: 6, thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 11)),
                      child: Slider(min: -1, max: 1, value: crossfader, onChanged: onCrossfader),
                    ),
                  ),
                ),
                const Text('B', style: TextStyle(fontWeight: FontWeight.w900)),
              ],
            ),
            Text(
              l10n.djCrossfader,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Palette.textMuted, fontSize: 11),
            ),
            const Divider(height: 24),
            if (nextUp case final track?)
              Row(
                children: [
                  SizedBox(width: 32, height: 32, child: CoverImage(albumId: track.album.id, size: 64)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      l10n.djNextUp('${track.title} – ${track.artistCredit}'),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              )
            else
              Text(
                l10n.djQueueEnd,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.textMuted, fontSize: 12),
              ),
          ],
        ),
      ),
    );
  }
}

/// A deck's song as a three-band waveform around the playhead (±8 s), with its beat grid; a tap seeks there.
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
      paintBandWaveform(
        canvas,
        Offset.zero & size,
        spectrum,
        songTime: (px) => start + px / size.width * _span,
        opacity: (px) => px < size.width / 2 ? 0.55 : 1,
      );
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
