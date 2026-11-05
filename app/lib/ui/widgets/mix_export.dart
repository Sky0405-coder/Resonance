import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../../offline/export.dart';
import 'common.dart';

/// Playlist menu → export the mix: the server renders the playlist with AutoMix's transitions as one MP3 (a chapter
/// per song), the app saves it to Music/Resonance/Mixes (Android) or where the user picks (desktop).
Future<void> exportMix(BuildContext context, WidgetRef ref, Playlist playlist) async {
  final api = ref.read(apiProvider);
  final l10n = context.l10n;
  final name = '${safeFileName(playlist.name)} (Mix).mp3';
  String? target;
  if (!kIsWeb && !Platform.isAndroid) {
    final folder = await FilePicker.getDirectoryPath(dialogTitle: l10n.mixExport);
    if (folder == null || !context.mounted) return;
    target = '$folder${Platform.pathSeparator}$name';
  }
  final ready = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (_) => _RenderDialog(playlistId: playlist.id, start: () => api.renderMix(playlist.id)),
  );
  if (ready != true || !context.mounted) return;
  try {
    final url = api.renderedMixUrl(playlist.id);
    if (kIsWeb) {
      await launchUrl(Uri.parse('$url?token=${api.token}'));
      return;
    }
    showInfo(context, l10n.mixExportSaving);
    if (Platform.isAndroid) {
      final temp = File('${(await getTemporaryDirectory()).path}/${DateTime.now().microsecondsSinceEpoch}.mp3');
      try {
        await api.downloadMedia(url, (_) => temp.path);
        await exportFile(temp.path, 'Mixes', name);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
      target = 'Music/Resonance/Mixes';
    } else {
      final file = target!;
      await api.downloadMedia(url, (_) => file);
    }
    if (context.mounted) showInfo(context, l10n.mixExportSaved(target));
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

class _RenderDialog extends ConsumerStatefulWidget {
  const _RenderDialog({required this.playlistId, required this.start});
  final String playlistId;
  final Future<({String state, double progress})> Function() start;

  @override
  ConsumerState<_RenderDialog> createState() => _RenderDialogState();
}

class _RenderDialogState extends ConsumerState<_RenderDialog> {
  Timer? _poll;
  double _progress = 0;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    try {
      _update(await widget.start());
      _poll = Timer.periodic(const Duration(milliseconds: 1500), (_) async {
        try {
          _update(await ref.read(apiProvider).renderMixStatus(widget.playlistId));
        } catch (e) {
          if (mounted) setState(() => _error = e);
        }
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _update(({String state, double progress}) status) {
    if (!mounted) return;
    if (status.state == 'done') {
      _poll?.cancel();
      Navigator.pop(context, true);
    } else if (status.state == 'failed') {
      _poll?.cancel();
      setState(() => _error = context.l10n.mixExportFailed);
    } else {
      setState(() => _progress = status.progress);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      title: Text(l10n.mixExport),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_error != null)
            Text(_error is String ? _error as String : ApiException.from(_error!, l10n).message)
          else ...[
            LinearProgressIndicator(value: _progress > 0 ? _progress : null),
            const SizedBox(height: 12),
            Text(l10n.mixExportRendering((_progress * 100).round())),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(_error == null ? l10n.mixExportBackground : l10n.commonClose),
        ),
      ],
    );
  }
}
