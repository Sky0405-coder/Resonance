import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models.dart';
import '../../core/theme.dart';
import '../../core/session.dart';
import '../../core/tv_mode.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
import '../../player/spectrum.dart';
import 'common.dart';

const _channel = MethodChannel('resonance/ringtone');

/// Ringtones come from the server, are saved through Android's MediaStore and need a phone.
bool ringtonesAvailable(WidgetRef ref) =>
    !kIsWeb &&
    defaultTargetPlatform == TargetPlatform.android &&
    !ref.read(tvModeProvider) &&
    !ref.read(sessionProvider).offline;

Future<void> showRingtoneSheet(BuildContext context, WidgetRef ref, Track track) async {
  if (await _channel.invokeMethod<bool>('supported') != true) {
    if (context.mounted) showInfo(context, context.l10n.ringtoneUnsupported);
    return;
  }
  if (!context.mounted) return;
  await showModalBottomSheet(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: const Color(0xFF202020),
    clipBehavior: Clip.antiAlias,
    builder: (_) => RingtoneSheet(track: track),
  );
}

class RingtoneSheet extends ConsumerStatefulWidget {
  const RingtoneSheet({super.key, required this.track});
  final Track track;

  @override
  ConsumerState<RingtoneSheet> createState() => _RingtoneSheetState();
}

class _RingtoneSheetState extends ConsumerState<RingtoneSheet> {
  static const _lengths = [20, 30, 40];

  int _length = 30;
  double _start = 0;
  late double _duration = widget.track.duration;
  double _suggested = 0;
  List<double> _levels = const [];
  bool _loading = true;
  String _type = 'ringtone';
  bool _busy = false;
  AudioPlayer? _preview;
  bool _previewing = false;
  // The paused music, resumed when the sheet closes (dispose may no longer use ref).
  PlayerController? _pausedMusic;

  @override
  void initState() {
    super.initState();
    _suggest();
  }

  Future<void> _suggest() async {
    try {
      final suggestion = await ref.read(apiProvider).ringtoneSuggestion(widget.track.id, _length);
      if (!mounted) return;
      setState(() {
        _duration = suggestion.duration;
        _levels = suggestion.levels;
        _start = _suggested = suggestion.start.clamp(0, _maxStart);
      });
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  double get _maxStart => (_duration - _length).clamp(0, double.infinity);

  Future<void> _togglePreview() async {
    if (_previewing) return _stopPreview();
    if (_pausedMusic == null && ref.read(playerProvider).playing) {
      _pausedMusic = ref.read(playerProvider.notifier);
      await _pausedMusic!.pause();
    }
    final preview = _preview ??= AudioPlayer();
    setState(() => _previewing = true);
    try {
      await preview.setUrl(ref.read(apiProvider).ringtoneUrl(widget.track.id, _start, _length));
      unawaited(
        preview.play().then((_) {
          if (mounted && preview.processingState == ProcessingState.completed) setState(() => _previewing = false);
        }),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _previewing = false);
        showError(context, e);
      }
    }
  }

  Future<void> _stopPreview() async {
    await _preview?.stop();
    if (mounted) setState(() => _previewing = false);
  }

  @override
  void dispose() {
    _preview?.dispose();
    _pausedMusic?.play();
    super.dispose();
  }

  /// Waits until the user comes back from the system settings.
  Future<void> _resumed() {
    final done = Completer<void>();
    late final AppLifecycleListener listener;
    listener = AppLifecycleListener(
      onResume: () {
        listener.dispose();
        done.complete();
      },
    );
    return done.future;
  }

  Future<void> _apply() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final title = '${widget.track.artistCredit} - ${widget.track.title}';
    setState(() => _busy = true);
    await _stopPreview();
    try {
      final file = '${(await getTemporaryDirectory()).path}/ringtone.mp3';
      await ref
          .read(apiProvider)
          .downloadMedia(ref.read(apiProvider).ringtoneUrl(widget.track.id, _start, _length), (_) => file);
      final uri = await _channel.invokeMethod<String>('save', {
        'path': file,
        'title': title,
        'artist': widget.track.artistCredit,
        'type': _type,
      });
      var allowed = await _channel.invokeMethod<bool>('canWriteSettings') ?? false;
      if (!allowed && mounted) {
        final allow = await showDialog<bool>(
          context: context,
          builder: (dialog) => AlertDialog(
            title: Text(l10n.ringtonePermissionTitle),
            content: Text(l10n.ringtonePermissionText),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialog, false), child: Text(l10n.ringtonePermissionManual)),
              FilledButton(onPressed: () => Navigator.pop(dialog, true), child: Text(l10n.ringtonePermissionAllow)),
            ],
          ),
        );
        if (allow == true) {
          final back = _resumed();
          await _channel.invokeMethod<void>('openWriteSettings');
          await back;
          allowed = await _channel.invokeMethod<bool>('canWriteSettings') ?? false;
        }
      }
      if (allowed) {
        await _channel.invokeMethod<void>('setDefault', {'uri': uri, 'type': _type});
        messenger.showSnackBar(SnackBar(content: Text(l10n.ringtoneDone(widget.track.title, _type))));
      } else {
        await _channel.invokeMethod<void>('openSoundSettings');
        messenger.showSnackBar(SnackBar(content: Text(l10n.ringtoneSaved(title))));
      }
      if (navigator.mounted) navigator.pop();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _time(double seconds) => formatDuration(Duration(milliseconds: (seconds * 1000).round()));

  void _moveTo(double start) {
    final value = start.clamp(0.0, _maxStart).roundToDouble();
    if (value == _start) return;
    if (_previewing) _stopPreview();
    setState(() => _start = value);
  }

  void _setLength(int length) {
    _stopPreview();
    setState(() {
      _length = length;
      _start = _start.clamp(0, _maxStart);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final tint = ref.watch(coverColorProvider(coverImageProvider(ref, widget.track.album.id, size: 300))).value;
    final end = (_start + _length).clamp(0.0, _duration);
    final atSuggestion = (_start - _suggested.clamp(0, _maxStart)).abs() < 1;
    final idle = _loading || _busy;
    return DecoratedBox(
      // The cover's color glows in from the top, so every song's sheet looks a bit different.
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.center,
          colors: [(tint ?? accent).withValues(alpha: 0.22), Colors.transparent],
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 6))],
                    ),
                    child: CoverImage(albumId: widget.track.album.id, size: 150, radius: 8),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.ringtoneMenu.toUpperCase(),
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Palette.textMuted,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Text(
                          widget.track.artistCredit,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(color: Palette.textMuted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  for (final (i, (value, icon, label)) in [
                    ('ringtone', Icons.ring_volume_rounded, l10n.ringtoneTypeRingtone),
                    ('notification', Icons.notifications_active_rounded, l10n.ringtoneTypeNotification),
                    ('alarm', Icons.alarm_rounded, l10n.ringtoneTypeAlarm),
                  ].indexed) ...[
                    if (i > 0) const SizedBox(width: 10),
                    Expanded(
                      child: _TypeTile(
                        icon: icon,
                        label: label,
                        selected: _type == value,
                        onTap: _busy ? null : () => setState(() => _type = value),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _loading
                              ? const SizedBox.shrink()
                              : FittedBox(
                                  fit: BoxFit.scaleDown,
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    l10n.ringtoneRange(_time(_start), _time(end)),
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                    ),
                                  ),
                                ),
                        ),
                        Semantics(
                          label: l10n.ringtoneLength,
                          child: _LengthPicker(
                            lengths: _lengths,
                            selected: _length,
                            label: l10n.ringtoneSeconds,
                            onSelected: _busy ? null : _setLength,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 76,
                      child: _loading
                          ? Center(child: CircularProgressIndicator(strokeWidth: 2.5, color: accent))
                          : StreamBuilder<Duration>(
                              stream: _preview?.positionStream,
                              builder: (context, position) => _CutPicker(
                                key: const ValueKey('ringtone-start'),
                                levels: _levels,
                                duration: _duration,
                                start: _start,
                                length: _length.toDouble(),
                                played: _previewing ? (position.data?.inMilliseconds ?? 0) / 1000 : null,
                                color: accent,
                                enabled: !_busy && _maxStart > 0,
                                describe: (start) =>
                                    l10n.ringtoneRange(_time(start), _time((start + _length).clamp(0.0, _duration))),
                                onChangeStart: _stopPreview,
                                onChanged: _moveTo,
                              ),
                            ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text('0:00', style: theme.textTheme.labelSmall?.copyWith(color: Palette.textMuted)),
                        const Spacer(),
                        Text(_time(_duration), style: theme.textTheme.labelSmall?.copyWith(color: Palette.textMuted)),
                      ],
                    ),
                    if (!_loading) ...[
                      const SizedBox(height: 6),
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        child: atSuggestion
                            ? Row(
                                key: const ValueKey('suggested'),
                                children: [
                                  Icon(Icons.auto_awesome_rounded, size: 16, color: accent),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      l10n.ringtoneSuggested,
                                      style: theme.textTheme.bodySmall?.copyWith(color: Palette.textMuted),
                                    ),
                                  ),
                                ],
                              )
                            : Align(
                                key: const ValueKey('moved'),
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(horizontal: 8),
                                  ),
                                  onPressed: _busy ? null : () => _moveTo(_suggested),
                                  icon: const Icon(Icons.auto_awesome_rounded, size: 16),
                                  label: Text(l10n.ringtoneBackToSuggestion),
                                ),
                              ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              Row(
                children: [
                  _PreviewButton(
                    playing: _previewing,
                    tooltip: _previewing ? l10n.ringtoneStopPreview : l10n.ringtonePreview,
                    color: accent,
                    onPressed: idle ? null : _togglePreview,
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: SizedBox(
                      height: 54,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          shape: const StadiumBorder(),
                          textStyle: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        onPressed: idle ? null : _apply,
                        child: _busy
                            ? SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(strokeWidth: 2.5, color: theme.colorScheme.onPrimary),
                              )
                            : Text(l10n.ringtoneApply),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One of the sound types: a rounded tile with its icon, lit in the accent color when chosen.
class _TypeTile extends StatelessWidget {
  const _TypeTile({required this.icon, required this.label, required this.selected, required this.onTap});
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 6),
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.16) : Colors.white.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: selected ? accent : Colors.transparent, width: 1.5),
            ),
            child: Column(
              children: [
                Icon(icon, size: 24, color: selected ? accent : Palette.textMuted),
                const SizedBox(height: 6),
                // "Benachrichtigung" is long: shrunk to one line rather than broken.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    label,
                    maxLines: 1,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: selected ? Colors.white : Palette.textMuted,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The cut's length as a small pill switch.
class _LengthPicker extends StatelessWidget {
  const _LengthPicker({required this.lengths, required this.selected, required this.label, required this.onSelected});
  final List<int> lengths;
  final int selected;
  final String Function(int seconds) label;
  final ValueChanged<int>? onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.3), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final length in lengths)
            Semantics(
              button: true,
              selected: length == selected,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: onSelected == null ? null : () => onSelected!(length),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: length == selected ? accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Text(
                    label(length),
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: length == selected ? theme.colorScheme.onPrimary : Palette.textMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The song as loudness bars with the cut as a window over it; drag the window or tap where it should go.
class _CutPicker extends StatelessWidget {
  const _CutPicker({
    super.key,
    required this.levels,
    required this.duration,
    required this.start,
    required this.length,
    required this.played,
    required this.color,
    required this.enabled,
    required this.describe,
    required this.onChangeStart,
    required this.onChanged,
  });
  final List<double> levels;
  final double duration;
  final double start;
  final double length;

  /// Seconds of the preview played so far, null when it is not playing.
  final double? played;
  final Color color;
  final bool enabled;

  /// The window starting at the given second, read out by screen readers.
  final String Function(double start) describe;
  final VoidCallback onChangeStart;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final perPixel = duration / math.max(1.0, width);
        // Grabbed somewhere inside the window, it keeps that offset under the finger.
        var grab = length / 2;
        return Semantics(
          slider: true,
          value: describe(start),
          increasedValue: describe(math.min(start + 5, math.max(0.0, duration - length))),
          decreasedValue: describe(math.max(0.0, start - 5)),
          onIncrease: enabled ? () => onChanged(start + 5) : null,
          onDecrease: enabled ? () => onChanged(start - 5) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: enabled ? (d) => onChanged(d.localPosition.dx * perPixel - length / 2) : null,
            onHorizontalDragStart: enabled
                ? (d) {
                    onChangeStart();
                    final at = d.localPosition.dx * perPixel;
                    grab = at >= start && at <= start + length ? at - start : length / 2;
                    onChanged(at - grab);
                  }
                : null,
            onHorizontalDragUpdate: enabled ? (d) => onChanged(d.localPosition.dx * perPixel - grab) : null,
            child: CustomPaint(
              size: Size.infinite,
              painter: _CutPainter(
                levels: levels,
                duration: duration,
                start: start,
                length: length,
                played: played,
                color: color,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CutPainter extends CustomPainter {
  _CutPainter({
    required this.levels,
    required this.duration,
    required this.start,
    required this.length,
    required this.played,
    required this.color,
  });
  final List<double> levels;
  final double duration;
  final double start;
  final double length;
  final double? played;
  final Color color;

  static const _bar = 3.0;
  static const _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0 || size.width <= 0) return;
    final from = start / duration * size.width;
    final to = math.min(size.width, (start + length) / duration * size.width);
    final window = RRect.fromLTRBR(from, 0, to, size.height, const Radius.circular(10));
    canvas.drawRRect(window, Paint()..color = color.withValues(alpha: 0.14));

    final count = (size.width / (_bar + _gap)).floor();
    final playedTo = played == null ? null : (start + played!) / duration * size.width;
    final inside = Paint()..color = color;
    final outside = Paint()..color = Colors.white.withValues(alpha: 0.18);
    final heard = Paint()..color = Colors.white;
    final middle = size.height / 2;
    for (var i = 0; i < count; i++) {
      final x = i * (_bar + _gap) + _gap / 2;
      // Each bar shows the loudest second it covers; without levels (older server) a gentle wave stands in.
      double level;
      if (levels.isEmpty) {
        level = 0.35 + 0.15 * math.sin(i / 3);
      } else {
        final a = (i / count * levels.length).floor();
        final b = math.max(a + 1, ((i + 1) / count * levels.length).floor());
        level = levels.sublist(a, math.min(b, levels.length)).fold(0.0, math.max);
      }
      final half = math.max(1.5, level * (size.height / 2 - 8));
      final centre = x + _bar / 2;
      final paint = centre < from || centre > to
          ? outside
          : playedTo != null && centre <= playedTo
          ? heard
          : inside;
      canvas.drawRRect(
        RRect.fromLTRBR(x, middle - half, x + _bar, middle + half, const Radius.circular(_bar / 2)),
        paint,
      );
    }
    canvas.drawRRect(
      window,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = color,
    );
    // Grips on both edges hint that the window moves.
    final grip = Paint()..color = color;
    for (final x in [from, to]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(x, middle), width: 6, height: 28),
          const Radius.circular(3),
        ),
        grip,
      );
    }
  }

  @override
  bool shouldRepaint(_CutPainter old) =>
      old.start != start ||
      old.length != length ||
      old.played != played ||
      old.color != color ||
      old.duration != duration ||
      !identical(old.levels, levels);
}

/// A round play/stop button for the preview.
class _PreviewButton extends StatelessWidget {
  const _PreviewButton({required this.playing, required this.tooltip, required this.color, required this.onPressed});
  final bool playing;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        shape: CircleBorder(side: BorderSide(color: onPressed == null ? Palette.divider : color, width: 2)),
        color: playing ? color.withValues(alpha: 0.16) : Colors.transparent,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          child: SizedBox(
            width: 54,
            height: 54,
            child: Icon(
              playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
              size: 30,
              color: onPressed == null ? Palette.textMuted : color,
            ),
          ),
        ),
      ),
    );
  }
}
