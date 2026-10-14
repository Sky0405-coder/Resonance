import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ota_update/ota_update.dart';

import '../../core/session.dart';
import '../../core/updates.dart';
import 'common.dart';

/// Downloads the APK from the server with progress and hands it to the Android installer.
Future<void> installAppUpdate(BuildContext context, WidgetRef ref) async {
  final url = ref.read(apiProvider).androidApkUrl;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _UpdateDialog(url: url),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog({required this.url});
  final String url;

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  double? _progress;
  String? _error;

  @override
  void initState() {
    super.initState();
    OtaUpdate()
        .execute(widget.url, destinationFilename: 'Resonance.apk')
        .listen(
          (event) {
            if (!mounted) return;
            switch (event.status) {
              case OtaStatus.DOWNLOADING:
                setState(() => _progress = (double.tryParse(event.value ?? '') ?? 0) / 100);
              case OtaStatus.INSTALLING || OtaStatus.INSTALLATION_DONE:
                // The system installer takes over from here.
                Navigator.pop(context);
              case OtaStatus.PERMISSION_NOT_GRANTED_ERROR:
                setState(() => _error = 'Bitte erlaube Resonance in den Android-Einstellungen, Apps zu installieren.');
              case OtaStatus.CANCELED:
                Navigator.pop(context);
              default:
                setState(() => _error = 'Update fehlgeschlagen (${event.status.name}). Bitte erneut versuchen.');
            }
          },
          onError: (Object e) {
            if (mounted) setState(() => _error = 'Update fehlgeschlagen: $e');
          },
        );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('App wird aktualisiert'),
    content: _error != null
        ? Text(_error!)
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(_progress == null ? 'Download startet …' : 'Download ${(_progress! * 100).round()} %'),
            ],
          ),
    actions: [if (_error != null) TextButton(onPressed: () => Navigator.pop(context), child: const Text('Schließen'))],
  );
}

/// Shows a one-time hint per app start when the server has a newer APK.
class UpdateNotifier extends ConsumerStatefulWidget {
  const UpdateNotifier({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<UpdateNotifier> createState() => _UpdateNotifierState();
}

class _UpdateNotifierState extends ConsumerState<UpdateNotifier> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    ref.listen(appUpdateProvider, (_, next) {
      final update = next.value;
      if (_shown || update == null || !update.available) return;
      _shown = true;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 10),
          content: Text('Neue App-Version ${update.availableName} verfügbar'),
          action: SnackBarAction(label: 'Installieren', onPressed: () => installAppUpdate(context, ref)),
        ),
      );
    });
    return widget.child;
  }
}

/// Settings tile: installed version and update button.
class AppVersionTile extends ConsumerWidget {
  const AppVersionTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(appUpdateProvider);
    final u = update.value;
    if (u == null) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.system_update),
      title: Text('App-Version ${u.installed} (${u.installedCode})'),
      subtitle: Text(u.available ? 'Version ${u.availableName} ist verfügbar' : 'Aktuell'),
      trailing: u.available
          ? FilledButton(onPressed: () => installAppUpdate(context, ref), child: const Text('Aktualisieren'))
          : IconButton(
              tooltip: 'Nach Updates suchen',
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                ref.invalidate(appUpdateProvider);
                try {
                  final next = await ref.read(appUpdateProvider.future);
                  if (context.mounted && !(next?.available ?? false)) showInfo(context, 'Die App ist aktuell');
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
            ),
    );
  }
}
