import '../../../l10n/l10n.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models.dart';
import '../../../core/session.dart';
import '../../../core/theme.dart';
import '../../widgets/collection.dart';
import '../../widgets/common.dart';

final _infoProvider = FutureProvider.autoDispose<ImportInfo>((ref) => ref.watch(apiProvider).importInfo());

final _filesProvider = FutureProvider.autoDispose.family<List<ImportFile>, (String, String)>(
  (ref, key) => ref.watch(apiProvider).importFiles(key.$1, status: key.$2),
);

final _batchesProvider = FutureProvider.autoDispose<List<ImportBatch>>((ref) async {
  final list = await ref.watch(apiProvider).importBatches();
  if (list.any((b) => b.isRunning)) {
    final timer = Timer(const Duration(seconds: 3), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return list;
});

/// Import folder + library cleanup (AcoustID / MusicBrainz identification).
class ImportTab extends ConsumerWidget {
  const ImportTab({super.key});

  Future<void> _start(BuildContext context, WidgetRef ref, String kind) async {
    if (kind == 'cleanup') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(context.l10n.adminImportCleanupTitle),
          content: Text(context.l10n.adminImportCleanupHint),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.l10n.commonCancel)),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.adminImportCleanupConfirm)),
          ],
        ),
      );
      if (ok != true) return;
    }
    try {
      await ref.read(apiProvider).startImport(kind);
      ref.invalidate(_batchesProvider);
      ref.invalidate(_infoProvider);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final info = ref.watch(_infoProvider);
    final batches = ref.watch(_batchesProvider);
    final running = batches.value?.any((b) => b.isRunning) ?? false;
    final accent = Theme.of(context).colorScheme.primary;

    return RefreshIndicator(
      onRefresh: () async {
        ref.invalidate(_infoProvider);
        ref.invalidate(_batchesProvider);
      },
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, kBottomInset),
        children: [
          info.when(
            loading: () => const LinearProgressIndicator(),
            error: (e, _) => Text('$e'),
            data: (i) => Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(context.l10n.adminImportFolder, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    SelectableText(i.importDir, style: const TextStyle(color: Palette.textMuted)),
                    const SizedBox(height: 8),
                    Text(
                      context.l10n.adminImportPendingFiles(
                        i.pendingFiles,
                        (i.importMode == 'copy' ? context.l10n.adminImportCopyHint : context.l10n.adminImportMove)
                            .toString(),
                      ),
                    ),
                    if (!i.acoustidConfigured) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error, size: 20),
                          const SizedBox(width: 8),
                          Expanded(child: Text(context.l10n.adminImportAcoustIdHint)),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        FilledButton.icon(
                          onPressed: running || i.pendingFiles == 0 ? null : () => _start(context, ref, 'import'),
                          icon: const Icon(Icons.move_to_inbox),
                          label: Text(context.l10n.adminImportStart),
                        ),
                        OutlinedButton.icon(
                          onPressed: running ? null : () => _start(context, ref, 'cleanup'),
                          icon: const Icon(Icons.auto_fix_high),
                          label: Text(context.l10n.adminImportCleanup),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            context.l10n.adminImportHistory,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(color: accent),
          ),
          const SizedBox(height: 8),
          AsyncBody(
            value: batches,
            builder: (list) => list.isEmpty
                ? Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(context.l10n.adminImportEmptyHistory, style: TextStyle(color: Palette.textMuted)),
                  )
                : Column(children: [for (final b in list) _BatchCard(batch: b)]),
          ),
        ],
      ),
    );
  }
}

String _statusLabel(AppLocalizations l10n, String s) => switch (s) {
  'queued' => l10n.adminImportWaiting,
  'running' => l10n.downloadsStatusRunning,
  'done' => l10n.commonDone,
  'failed' => l10n.downloadsStatusFailed,
  'cancelled' => l10n.downloadsStatusCancelled,
  _ => s,
};

class _BatchCard extends ConsumerWidget {
  const _BatchCard({required this.batch});
  final ImportBatch batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = batch;
    final title = b.kind == 'cleanup'
        ? context.l10n.adminImportCleanup
        : context.l10n.adminImportBatchTitle(
            (b.mode == 'copy' ? context.l10n.adminImportCopyMode : context.l10n.adminImportMoveMode).toString(),
          );
    final started = MaterialLocalizations.of(context).formatShortDate(b.createdAt.toLocal());
    final time = TimeOfDay.fromDateTime(b.createdAt.toLocal()).format(context);
    Widget stat(String label, int value, String? filter) => ActionChip(
      label: Text('$label: $value'),
      onPressed: filter == null || value == 0 ? null : () => _showFiles(context, b, filter, label),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
                Text(
                  '${_statusLabel(context.l10n, b.status)} • $started $time',
                  style: const TextStyle(color: Palette.textMuted),
                ),
                if (b.isRunning)
                  IconButton(
                    tooltip: context.l10n.commonCancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                    onPressed: () async {
                      try {
                        await ref.read(apiProvider).cancelImport(b.id);
                        ref.invalidate(_batchesProvider);
                      } catch (e) {
                        if (context.mounted) showError(context, e);
                      }
                    },
                  ),
              ],
            ),
            if (b.isRunning) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: b.total == 0 ? null : b.progress, borderRadius: BorderRadius.circular(2)),
              const SizedBox(height: 4),
              Text(
                context.l10n.adminImportFileProgress(b.processed, b.total),
                style: const TextStyle(color: Palette.textMuted),
              ),
            ],
            if (b.message != null) ...[
              const SizedBox(height: 8),
              Text(b.message!, style: const TextStyle(color: Palette.textMuted)),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                stat(context.l10n.adminImportIdentified, b.identified, 'identified'),
                stat(context.l10n.adminImportImported, b.imported, 'imported'),
                stat(context.l10n.adminImportDuplicates, b.duplicates, 'duplicate'),
                stat(context.l10n.adminImportUnidentified, b.unidentified, 'unidentified'),
                stat(context.l10n.adminImportErrors, b.failed, 'failed'),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showFiles(BuildContext context, ImportBatch batch, String status, String label) => showDialog<void>(
  context: context,
  builder: (_) => Dialog(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900, maxHeight: 640),
      child: _FilesView(batch: batch, status: status, label: label),
    ),
  ),
);

class _FilesView extends ConsumerWidget {
  const _FilesView({required this.batch, required this.status, required this.label});
  final ImportBatch batch;
  final String status;
  final String label;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final files = ref.watch(_filesProvider((batch.id, status)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
          child: Row(
            children: [
              Expanded(child: Text(label, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ],
          ),
        ),
        Expanded(
          child: AsyncBody(
            value: files,
            builder: (files) {
              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                itemCount: files.length,
                itemBuilder: (_, i) {
                  final f = files[i];
                  final meta = [f.artist, f.album, f.title].whereType<String>().join(' – ');
                  return ListTile(
                    dense: true,
                    title: Text(f.path, maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        if (meta.isNotEmpty) meta,
                        if (f.target != null) '→ ${f.target}',
                        if (f.method != null) _methodLabel(context.l10n, f.method!),
                        if (f.error != null) f.error!,
                      ].join('\n'),
                      style: const TextStyle(color: Palette.textMuted),
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

String _methodLabel(AppLocalizations l10n, String m) => switch (m) {
  'release' => l10n.adminImportMethodAlbumFingerprint,
  'recording' => l10n.adminImportMethodTrackFingerprint,
  'deezer' => l10n.adminImportMethodTags,
  'tags' => l10n.adminImportMethodUnidentified,
  _ => m,
};
