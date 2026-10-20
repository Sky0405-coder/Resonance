import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'player.dart';

/// Frequency bands per frame, precomputed by the server (`backend/app/services/spectrum.py`), values 0–1.
class Spectrum {
  Spectrum._(this.bands, this.fps, this.frameCount, this._data);
  final int bands;
  final double fps;
  final int frameCount;
  final Uint8List _data;

  static const _headerSize = 13;

  /// The server maps this many dB onto 0–1, with bands spaced logarithmically from 40 Hz to 10 kHz.
  static const rangeDb = 48.0;

  static double bandFrequency(int band, int bands) => 40 * math.pow(10000 / 40, (band + 0.5) / bands).toDouble();

  static Spectrum? parse(Uint8List bytes) {
    if (bytes.length < _headerSize || String.fromCharCodes(bytes.sublist(0, 4)) != 'RSP1') return null;
    final header = ByteData.sublistView(bytes, 0, _headerSize);
    final bands = header.getUint8(4);
    final fps = header.getFloat32(5, Endian.little);
    final frames = header.getUint32(9, Endian.little);
    if (bands == 0 || fps <= 0 || bytes.length < _headerSize + bands * frames) return null;
    return Spectrum._(bands, fps, frames, Uint8List.sublistView(bytes, _headerSize));
  }

  /// Band levels at [position], interpolated between the two nearest frames.
  void levelsAt(Duration position, List<double> out) {
    if (frameCount == 0) {
      out.fillRange(0, out.length, 0);
      return;
    }
    final t = (position.inMicroseconds / 1e6 * fps).clamp(0.0, frameCount - 1.0);
    final a = t.floor();
    final b = math.min(a + 1, frameCount - 1);
    final f = t - a;
    for (var i = 0; i < bands && i < out.length; i++) {
      out[i] = (_data[a * bands + i] * (1 - f) + _data[b * bands + i] * f) / 255;
    }
  }
}

final spectrumProvider = FutureProvider.autoDispose.family<Spectrum?, String>((ref, trackId) async {
  try {
    final bytes = await ref.read(apiProvider).spectrum(trackId);
    return bytes == null ? null : Spectrum.parse(bytes);
  } catch (_) {
    return null;
  }
});

/// Whether the visualizer is shown (Settings); on by default.
final visualizerEnabledProvider = NotifierProvider<VisualizerEnabled, bool>(VisualizerEnabled.new);

class VisualizerEnabled extends Notifier<bool> {
  @override
  bool build() => ref.read(prefsProvider).getBool('visualizer') ?? true;

  void set(bool enabled) {
    ref.read(prefsProvider).setBool('visualizer', enabled);
    state = enabled;
  }
}

/// Animated spectrum bars of the playing song. [mirrored] draws the bass in the middle and the highs at both edges.
class SpectrumVisualizer extends ConsumerStatefulWidget {
  const SpectrumVisualizer({
    super.key,
    required this.trackId,
    required this.color,
    this.mirrored = false,
    this.gap = 0.3,
    this.minHeight = 0.02,
    this.boost,
  });
  final String trackId;
  final Color color;
  final bool mirrored;

  /// Gap between bars as a fraction of the bar slot.
  final double gap;
  final double minHeight;

  /// Extra dB per frequency (Hz), e.g. the equalizer's curve, so the bars show its effect.
  final double Function(double frequency)? boost;

  @override
  ConsumerState<SpectrumVisualizer> createState() => _SpectrumVisualizerState();
}

class _SpectrumVisualizerState extends ConsumerState<SpectrumVisualizer> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_tick);
  StreamSubscription<Duration>? _positions;
  Duration _position = Duration.zero;
  final _sincePosition = Stopwatch();
  final _levels = ValueNotifier<List<double>>(const []);
  List<double> _target = const [];
  Duration _lastTick = Duration.zero;

  @override
  void initState() {
    super.initState();
    final engine = ref.read(playerProvider.notifier).engine;
    _position = engine.position;
    _sincePosition.start();
    // The engine reports about five times a second; between reports the position is extrapolated.
    _positions = engine.positionStream.listen((position) {
      _position = position;
      _sincePosition
        ..reset()
        ..start();
    });
    _ticker.start();
  }

  void _tick(Duration elapsed) {
    final spectrum = ref.read(spectrumProvider(widget.trackId)).value;
    final engine = ref.read(playerProvider.notifier).engine;
    final dt = ((elapsed - _lastTick).inMicroseconds / 1e6).clamp(0.0, 0.1);
    _lastTick = elapsed;
    final bands = spectrum?.bands ?? 0;
    if (_target.length != bands) _target = List.filled(bands, 0);
    final playing = engine.playing;
    if (spectrum != null && playing) {
      final position = _position + _sincePosition.elapsed * engine.speed;
      spectrum.levelsAt(position, _target);
      final boost = widget.boost;
      if (boost != null) {
        for (var i = 0; i < bands; i++) {
          _target[i] = (_target[i] + boost(Spectrum.bandFrequency(i, bands)) / Spectrum.rangeDb).clamp(0.0, 1.0);
        }
      }
    } else {
      _target.fillRange(0, _target.length, 0);
    }
    final previous = _levels.value;
    final next = List<double>.generate(bands, (i) {
      final from = i < previous.length ? previous[i] : 0.0;
      final to = _target[i];
      // Fast attack, slower release, like a VU meter.
      final rate = to > from ? 30.0 : 6.0;
      return from + (to - from) * (1 - math.exp(-rate * dt));
    });
    if (!playing && next.every((v) => v < 0.005) && previous.every((v) => v < 0.005)) return;
    _levels.value = next;
  }

  @override
  void dispose() {
    _ticker.dispose();
    _positions?.cancel();
    _levels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(spectrumProvider(widget.trackId));
    return RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _BarsPainter(
          _levels,
          color: widget.color,
          mirrored: widget.mirrored,
          gap: widget.gap,
          minHeight: widget.minHeight,
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(this.levels, {required this.color, required this.mirrored, required this.gap, required this.minHeight})
    : super(repaint: levels);
  final ValueNotifier<List<double>> levels;
  final Color color;
  final bool mirrored;
  final double gap;
  final double minHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final values = levels.value;
    if (values.isEmpty || size.isEmpty) return;
    final bars = mirrored ? [...values.reversed, ...values] : values;
    final slot = size.width / bars.length;
    final width = slot * (1 - gap);
    final radius = Radius.circular(math.min(width / 2, 4));
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          color,
          color.withValues(alpha: color.a * 0.25),
        ],
      ).createShader(Offset.zero & size);
    for (var i = 0; i < bars.length; i++) {
      final height = size.height * math.max(minHeight, bars[i]);
      final left = i * slot + (slot - width) / 2;
      canvas.drawRRect(
        RRect.fromLTRBAndCorners(
          left,
          size.height - height,
          left + width,
          size.height,
          topLeft: radius,
          topRight: radius,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.color != color || old.mirrored != mirrored || old.gap != gap || old.minHeight != minHeight;
}
