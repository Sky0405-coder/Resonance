import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/tv_mode.dart';
import '../../l10n/l10n.dart';
import '../../player/player.dart';
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
        _start = suggestion.start.clamp(0, _maxStart);
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final end = (_start + _length).clamp(0.0, _duration);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.ringtoneMenu, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${widget.track.title} · ${widget.track.artistCredit}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            SegmentedButton<String>(
              // Text only, shrunk if needed: with icons "Benachrichtigung" broke over two lines on phones.
              segments: [
                for (final (value, label) in [
                  ('ringtone', l10n.ringtoneTypeRingtone),
                  ('notification', l10n.ringtoneTypeNotification),
                  ('alarm', l10n.ringtoneTypeAlarm),
                ])
                  ButtonSegment(
                    value: value,
                    label: FittedBox(fit: BoxFit.scaleDown, child: Text(label, maxLines: 1)),
                  ),
              ],
              showSelectedIcon: false,
              selected: {_type},
              onSelectionChanged: _busy ? null : (value) => setState(() => _type = value.first),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text(l10n.ringtoneLength, style: theme.textTheme.titleSmall),
                const Spacer(),
                for (final length in _lengths)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: ChoiceChip(
                      label: Text(l10n.ringtoneSeconds(length)),
                      selected: _length == length,
                      onSelected: _busy
                          ? null
                          : (_) {
                              _stopPreview();
                              setState(() {
                                _length = length;
                                _start = _start.clamp(0, _maxStart);
                              });
                            },
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...[
              Text(
                l10n.ringtoneRange(_time(_start), _time(end)),
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              Slider(
                key: const ValueKey('ringtone-start'),
                value: _start.clamp(0, _maxStart),
                max: _maxStart > 0 ? _maxStart : 1,
                onChanged: _busy || _maxStart <= 0 ? null : (value) => setState(() => _start = value.roundToDouble()),
                onChangeStart: (_) => _stopPreview(),
              ),
              Text(
                l10n.ringtoneSuggested,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 16),
            if (_busy) const Padding(padding: EdgeInsets.only(bottom: 12), child: LinearProgressIndicator()),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _loading || _busy ? null : _togglePreview,
                    icon: Icon(_previewing ? Icons.stop : Icons.play_arrow),
                    label: Text(_previewing ? l10n.ringtoneStopPreview : l10n.ringtonePreview),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _loading || _busy ? null : _apply,
                    icon: const Icon(Icons.check),
                    label: Text(l10n.ringtoneApply),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
