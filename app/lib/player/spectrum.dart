import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'player.dart';
import 'visualizer_themes.dart';

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

/// Spectra of the current and the next song, loaded as soon as a song starts (the first analysis of a song takes
/// the server a second or two) and retried when a request fails.
final spectrumProvider = FutureProvider.family<Spectrum?, String>((ref, trackId) async {
  final link = ref.keepAlive();
  // Keep a handful of songs; older ones are dropped a while after nobody uses them.
  Timer? release;
  ref.onCancel(() => release = Timer(const Duration(minutes: 5), link.close));
  ref.onResume(() => release?.cancel());
  ref.onDispose(() => release?.cancel());
  for (var attempt = 0; attempt < 3; attempt++) {
    try {
      final bytes = await ref.read(apiProvider).spectrum(trackId);
      return bytes == null ? null : Spectrum.parse(bytes);
    } catch (_) {
      await Future<void>.delayed(Duration(seconds: 2 * (attempt + 1)));
    }
  }
  link.close();
  return null;
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
    this.theme,
    this.mirrored = false,
    this.gap = 0.3,
    this.minHeight = 0.02,
    this.boost,
    this.reflection = 0,
  });
  final String trackId;
  final Color color;
  final VisualizerTheme? theme;
  final bool mirrored;

  /// Gap between bars as a fraction of the bar slot.
  final double gap;
  final double minHeight;

  /// Height of the faded reflection below the spectrum, separated by a three-pixel gap.
  final double reflection;

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
  final _peaks = <PeakDots>[];
  bool _peaksEnabled = true;
  List<double> _target = [];
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

  @override
  void didUpdateWidget(SpectrumVisualizer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trackId != widget.trackId || oldWidget.theme != widget.theme) {
      _peaks.fillRange(0, _peaks.length, const PeakDots());
    }
  }

  void _tick(Duration elapsed) {
    final spectrum = ref.read(spectrumProvider(widget.trackId)).value;
    final engine = ref.read(playerProvider.notifier).engine;
    final elapsedSeconds = math.max(0.0, (elapsed - _lastTick).inMicroseconds / 1e6);
    final dt = elapsedSeconds.clamp(0.0, 0.1);
    _lastTick = elapsed;
    final bands = spectrum?.bands ?? 0;
    final peaksEnabled = (widget.theme?.peaks ?? false) && ref.read(visualizerPeaksProvider);
    if (_peaksEnabled != peaksEnabled) {
      _peaksEnabled = peaksEnabled;
      _peaks.fillRange(0, _peaks.length, const PeakDots());
    }
    if (_target.length != bands) {
      _target = List.filled(bands, 0);
      _peaks.clear();
      for (var i = 0; i < bands; i++) {
        _peaks.add(const PeakDots());
      }
    }
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
    final hadBubbles = _peaks.any((dots) => dots.bubbles.isNotEmpty);
    final previous = _levels.value;
    final next = List<double>.generate(bands, (i) {
      final from = i < previous.length ? previous[i] : 0.0;
      final to = _target[i];
      // Fast attack, slower release, like a VU meter.
      final rate = to > from ? 30.0 : 6.0;
      final level = from + (to - from) * (1 - math.exp(-rate * dt));
      if (peaksEnabled) _peaks[i] = _peaks[i].advance(level < 0.005 ? 0 : level, elapsedSeconds);
      return level;
    });
    if (!playing &&
        next.every((v) => v < 0.005) &&
        previous.every((v) => v < 0.005) &&
        !hadBubbles &&
        (!peaksEnabled || _peaks.every((v) => v.bubbles.isEmpty))) {
      return;
    }
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
    final peaksEnabled = ref.watch(visualizerPeaksProvider);
    return LayoutBuilder(
      builder: (context, constraints) => OverflowBox(
        alignment: Alignment.topCenter,
        minHeight: constraints.maxHeight + (widget.reflection > 0 ? widget.reflection + 3 : 0),
        maxHeight: constraints.maxHeight + (widget.reflection > 0 ? widget.reflection + 3 : 0),
        child: RepaintBoundary(
          child: CustomPaint(
            size: Size.infinite,
            painter: _BarsPainter(
              _levels,
              color: widget.color,
              theme: widget.theme,
              peaks: peaksEnabled ? _peaks : const [],
              mirrored: widget.mirrored,
              gap: widget.gap,
              minHeight: widget.minHeight,
              reflection: widget.reflection,
            ),
          ),
        ),
      ),
    );
  }
}

/// A fixed sample painted exactly like the playing spectrum, without starting the player.
class SpectrumPreview extends StatefulWidget {
  const SpectrumPreview({super.key, required this.theme, required this.color, this.mirrored = true});
  final VisualizerTheme theme;
  final Color color;
  final bool mirrored;

  @override
  State<SpectrumPreview> createState() => _SpectrumPreviewState();
}

class _SpectrumPreviewState extends State<SpectrumPreview> {
  static const _sample = <double>[0.9, 0.75, 0.85, 0.6, 0.7, 0.5, 0.55, 0.4, 0.45, 0.35, 0.3, 0.25];
  final _levels = ValueNotifier<List<double>>(_sample);

  @override
  void dispose() {
    _levels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 72,
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: ColoredBox(
        color: const Color(0xFF121212),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: CustomPaint(
            size: Size.infinite,
            painter: _BarsPainter(
              _levels,
              color: widget.color,
              theme: widget.theme.id == 'auto' ? null : widget.theme,
              peaks: [for (final level in _sample) PeakDots(level: level)],
              mirrored: widget.mirrored,
              gap: 0.35,
              minHeight: 0.015,
            ),
          ),
        ),
      ),
    ),
  );
}

class _BarsPainter extends CustomPainter {
  _BarsPainter(
    this.levels, {
    required this.color,
    required this.mirrored,
    required this.gap,
    required this.minHeight,
    this.theme,
    this.peaks = const [],
    this.reflection = 0,
  }) : super(repaint: levels) {
    final colors = theme?.colors;
    _gradient = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: colors != null && colors.length > 1 ? colors : [color, color.withValues(alpha: color.a * 0.25)],
    );
    _paint.color = colors != null && colors.length == 1 ? colors.first : Colors.white;
    if (theme?.id == 'ocean') _paint.color = Colors.white.withValues(alpha: 0.85);
    if (theme?.id == 'aurora') _paint.color = Colors.white.withValues(alpha: 0.7);
    if (theme?.glow ?? false) {
      final (blur, opacity) = switch (theme!.id) {
        'neon' => (10.0, 0.8),
        'fire' => (6.0, 0.5),
        'aurora' => (12.0, 0.5),
        _ => (8.0, 0.6),
      };
      _glowPaint
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur)
        ..color = _paint.color.withValues(alpha: _paint.color.a * opacity);
    }
    _linePaint
      ..style = PaintingStyle.stroke
      ..strokeWidth = theme?.id == 'ocean' ? 2 : 1
      ..color = theme?.id == 'ocean' ? const Color(0xFFA6FFF6) : const Color(0xFFFF2BD6).withValues(alpha: 0.15);
    if (theme?.style == VisualizerStyle.segments) {
      _litSegments = [for (final color in theme!.colors) Paint()..color = color];
      _unlitSegments = [for (final color in theme!.colors) Paint()..color = color.withValues(alpha: 0.08)];
    }
  }
  final ValueNotifier<List<double>> levels;
  final Color color;
  final VisualizerTheme? theme;
  final List<PeakDots> peaks;
  final bool mirrored;
  final double gap;
  final double minHeight;
  final double reflection;
  final _paint = Paint();
  final _glowPaint = Paint();
  final _linePaint = Paint();
  final _reflectionMask = Paint()..blendMode = BlendMode.dstIn;
  final _bars = Path();
  final _area = Path();
  final _top = Path();
  late final LinearGradient _gradient;
  List<Paint> _litSegments = const [];
  List<Paint> _unlitSegments = const [];
  List<Paint> _rainbowPaints = const [];
  Size? _shaderSize;
  static const _reflectionFade = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color.from(alpha: 0.35, red: 1, green: 1, blue: 1), Color(0x00FFFFFF)],
  );

  int _band(int bar, int bands) => mirrored ? (bar < bands ? bands - 1 - bar : bar - bands) : bar;

  double _height(List<double> values, int bar, double height) =>
      height * math.max(minHeight, values[_band(bar, values.length)]);

  void _prepare(Size size, int bars) {
    if (_shaderSize != size) {
      _shaderSize = size;
      if (!(theme?.rainbow ?? false) && (theme?.colors.length ?? 0) != 1) {
        final shader = _gradient.createShader(Offset.zero & size);
        _paint.shader = shader;
        _glowPaint.shader = shader;
      }
      if (reflection > 0) {
        _reflectionMask.shader = _reflectionFade.createShader(
          Rect.fromLTWH(0, size.height + 3, size.width, reflection),
        );
      }
    }
    if ((theme?.rainbow ?? false) && _rainbowPaints.length != bars) {
      _rainbowPaints = List.generate(bars, (i) => Paint()..color = rainbowColor(i, bars));
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final values = levels.value;
    if (reflection > 0) size = Size(size.width, math.max(0.0, size.height - reflection - 3));
    if (values.isEmpty || size.isEmpty) return;
    final bars = values.length * (mirrored ? 2 : 1);
    _prepare(size, bars);
    final slot = size.width / bars;
    final width = slot * (1 - (theme?.id == 'mono' ? 0.6 : gap));
    if (theme?.id == 'synthwave') {
      for (var i = 1; i <= 3; i++) {
        final y = size.height * i / 4;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), _linePaint);
      }
    }
    _drawSpectrum(canvas, size, values, bars, slot, width);
    if (reflection > 0) {
      final bounds = Rect.fromLTWH(0, size.height + 3, size.width, reflection);
      canvas.save();
      canvas.clipRect(bounds);
      canvas.saveLayer(bounds, Paint());
      canvas.save();
      canvas.translate(0, size.height + 3);
      canvas.scale(1, -0.6);
      canvas.translate(0, -size.height);
      _drawSpectrum(canvas, size, values, bars, slot, width, reflected: true);
      canvas.restore();
      canvas.drawRect(bounds, _reflectionMask);
      canvas.restore();
      canvas.restore();
    }
  }

  void _drawSpectrum(
    Canvas canvas,
    Size size,
    List<double> values,
    int bars,
    double slot,
    double width, {
    bool reflected = false,
  }) {
    switch (theme?.style ?? VisualizerStyle.bars) {
      case VisualizerStyle.bars:
        _drawBars(canvas, size, values, bars, slot, width, reflected: reflected);
      case VisualizerStyle.segments:
        _drawSegments(canvas, size, values, bars, slot, width);
      case VisualizerStyle.area:
        _drawArea(canvas, size, values, bars, slot, reflected: reflected);
    }
  }

  void _drawBars(
    Canvas canvas,
    Size size,
    List<double> values,
    int bars,
    double slot,
    double width, {
    bool reflected = false,
  }) {
    final radius = Radius.circular(theme?.id == 'neon' ? width / 2 : math.min(width / 2, 4));
    RRect bar(int i) {
      final height = _height(values, i, size.height);
      final left = i * slot + (slot - width) / 2;
      return RRect.fromLTRBAndCorners(
        left,
        size.height - height,
        left + width,
        size.height,
        topLeft: radius,
        topRight: radius,
        bottomLeft: theme?.id == 'neon' ? radius : Radius.zero,
        bottomRight: theme?.id == 'neon' ? radius : Radius.zero,
      );
    }

    if (!reflected) {
      _bars.reset();
      for (var i = 0; i < bars; i++) {
        _bars.addRRect(bar(i));
      }
      if (theme?.glow ?? false) canvas.drawPath(_bars, _glowPaint);
    }
    if (theme?.rainbow ?? false) {
      for (var i = 0; i < bars; i++) {
        canvas.drawRRect(bar(i), _rainbowPaints[i]);
      }
    } else {
      canvas.drawPath(_bars, _paint);
    }
  }

  int _segmentColor(double height) => theme?.id == 'retro' ? (height < 0.6 ? 0 : (height < 0.85 ? 1 : 2)) : 0;

  void _drawSegments(Canvas canvas, Size size, List<double> values, int bars, double slot, double width) {
    for (var i = 0; i < bars; i++) {
      final height = _height(values, i, size.height);
      final left = i * slot + (slot - width) / 2;
      for (var bottom = 0.0; bottom < size.height; bottom += 8) {
        final segmentHeight = math.min(6.0, size.height - bottom);
        final color = _segmentColor((bottom + segmentHeight / 2) / size.height);
        canvas.drawRect(
          Rect.fromLTWH(left, size.height - bottom - segmentHeight, width, segmentHeight),
          bottom < height ? _litSegments[color] : _unlitSegments[color],
        );
      }
      final band = _band(i, values.length);
      if ((theme?.peaks ?? false) && band < peaks.length) {
        final dots = peaks[band];
        if (dots.level > 0.005) _drawPeak(canvas, size, left, width, math.max(minHeight, dots.level), 1);
        for (final bubble in dots.bubbles) {
          _drawPeak(canvas, size, left, width, bubble.height, bubble.opacity);
        }
      }
    }
  }

  void _drawPeak(Canvas canvas, Size size, double left, double width, double height, double opacity) {
    final color = _litSegments[_segmentColor(height)].color;
    final paint = Paint()..color = color.withValues(alpha: color.a * opacity);
    canvas.drawRect(Rect.fromLTWH(left, size.height * (1 - height), width, 3), paint);
  }

  void _drawArea(Canvas canvas, Size size, List<double> values, int bars, double slot, {bool reflected = false}) {
    if (reflected) {
      canvas.drawPath(_area, _paint);
      if (theme?.id == 'ocean') canvas.drawPath(_top, _linePaint);
      return;
    }
    var previousY = size.height - _height(values, 0, size.height);
    _top
      ..reset()
      ..moveTo(0, previousY)
      ..lineTo(slot / 2, previousY);
    for (var i = 1; i < bars; i++) {
      final y = size.height - _height(values, i, size.height);
      final middle = i * slot;
      _top.cubicTo(middle, previousY, middle, y, (i + 0.5) * slot, y);
      previousY = y;
    }
    _top.lineTo(size.width, previousY);
    _area
      ..reset()
      ..addPath(_top, Offset.zero)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    if (theme?.glow ?? false) canvas.drawPath(_area, _glowPaint);
    canvas.drawPath(_area, _paint);
    if (theme?.id == 'ocean') canvas.drawPath(_top, _linePaint);
  }

  @override
  bool shouldRepaint(_BarsPainter old) =>
      old.color != color ||
      old.theme != theme ||
      old.peaks != peaks ||
      old.levels != levels ||
      old.mirrored != mirrored ||
      old.gap != gap ||
      old.minHeight != minHeight ||
      old.reflection != reflection;
}

/// Loads the spectra of the current and the next song while the visualizer is on, so the bars are there as soon
/// as the player opens. Watched by the mini player.
final spectrumPrefetchProvider = Provider<void>((ref) {
  if (!ref.watch(visualizerEnabledProvider)) return;
  final (current, next) = ref.watch(
    playerProvider.select((p) {
      final index = p.index;
      final queue = p.queue;
      final ok = index != null && p.book == null && p.station == null;
      return (
        ok && index < queue.length ? queue[index].id : null,
        ok && index + 1 < queue.length ? queue[index + 1].id : null,
      );
    }),
  );
  for (final id in [current, next]) {
    if (id != null) ref.watch(spectrumProvider(id));
  }
});

/// The most colorful bright tone of an image (for bars that match the cover), or null if it cannot be read.
final coverColorProvider = FutureProvider.family<Color?, ImageProvider>((ref, image) async {
  final completer = Completer<ImageInfo>();
  final stream = ResizeImage(image, width: 32, height: 32).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, _) => completer.isCompleted ? null : completer.complete(info),
    onError: (error, _) => completer.isCompleted ? null : completer.completeError(error),
  );
  stream.addListener(listener);
  try {
    final info = await completer.future.timeout(const Duration(seconds: 10));
    final data = await info.image.toByteData();
    if (data == null) return null;
    HSVColor? best;
    var bestScore = -1.0;
    for (var i = 0; i + 3 < data.lengthInBytes; i += 4) {
      final color = HSVColor.fromColor(
        Color.fromARGB(255, data.getUint8(i), data.getUint8(i + 1), data.getUint8(i + 2)),
      );
      // Saturated and not too dark; greys score low.
      final score = color.saturation * (0.3 + color.value);
      if (score > bestScore) {
        bestScore = score;
        best = color;
      }
    }
    if (best == null || best.saturation < 0.15) return Colors.white;
    return best.withSaturation(math.min(best.saturation, 0.75)).withValue(0.95).toColor();
  } catch (_) {
    return null;
  } finally {
    stream.removeListener(listener);
  }
});
