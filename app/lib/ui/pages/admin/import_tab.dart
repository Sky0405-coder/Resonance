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
          title: const Text('Bibliothek aufräumen?'),
          content: const Text(
            'Alle Songs der Bibliothek werden per Audio-Fingerabdruck erkannt, neu getaggt, mit Cover versehen '
            'und nach „Künstler/Album (Jahr)/Nr - Titel“ umbenannt. Die Dateien werden dabei direkt verändert.\n\n'
            'Likes, Playlists und Verlauf bleiben erhalten. Bei großen Bibliotheken dauert das mehrere Stunden.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Aufräumen')),
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
                    Text('Import-Ordner', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 4),
                    SelectableText(i.importDir, style: const TextStyle(color: Palette.textMuted)),
                    const SizedBox(height: 8),
                    Text(
                      '${i.pendingFiles} Audiodateien warten • Modus: '
                      '${i.importMode == 'copy' ? 'Kopieren (Originale bleiben unverändert)' : 'Verschieben'}',
                    ),
                    if (!i.acoustidConfigured) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.warning_amber, color: Theme.of(context).colorScheme.error, size: 20),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              'Kein AcoustID-Schlüssel eingetragen – Songs werden nur über ihre vorhandenen Tags '
                              'erkannt. Einen kostenlosen Schlüssel gibt es auf acoustid.org/new-application; '
                              'eintragen unter „Server“.',
                            ),
                          ),
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
                          label: const Text('Import starten'),
                        ),
                        OutlinedButton.icon(
                          onPressed: running ? null : () => _start(context, ref, 'cleanup'),
                          icon: const Icon(Icons.auto_fix_high),
                          label: const Text('Bibliothek aufräumen'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('Verlauf', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: accent)),
          const SizedBox(height: 8),
          AsyncBody(
            value: batches,
            builder: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Noch kein Import gelaufen.', style: TextStyle(color: Palette.textMuted)),
                  )
                : Column(children: [for (final b in list) _BatchCard(batch: b)]),
          ),
        ],
      ),
    );
  }
}

String _statusLabel(String s) => switch (s) {
  'queued' => 'Wartet',
  'running' => 'Läuft',
  'done' => 'Fertig',
  'failed' => 'Fehlgeschlagen',
  'cancelled' => 'Abgebrochen',
  _ => s,
};

class _BatchCard extends ConsumerWidget {
  const _BatchCard({required this.batch});
  final ImportBatch batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = batch;
    final title = b.kind == 'cleanup'
        ? 'Bibliothek aufräumen'
        : 'Import (${b.mode == 'copy' ? 'kopieren' : 'verschieben'})';
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
                Text('${_statusLabel(b.status)} • $started $time', style: const TextStyle(color: Palette.textMuted)),
                if (b.isRunning)
                  IconButton(
                    tooltip: 'Abbrechen',
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
              Text('${b.processed} von ${b.total} Dateien', style: const TextStyle(color: Palette.textMuted)),
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
                stat('Erkannt', b.identified, 'identified'),
                stat('Importiert', b.imported, 'imported'),
                stat('Duplikate', b.duplicates, 'duplicate'),
                stat('Nicht erkannt', b.unidentified, 'unidentified'),
                stat('Fehler', b.failed, 'failed'),
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
                        if (f.method != null) _methodLabel(f.method!),
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

String _methodLabel(String m) => switch (m) {
  'release' => 'Erkannt per Fingerabdruck (komplettes Album)',
  'recording' => 'Erkannt per Fingerabdruck (einzelner Song)',
  'deezer' => 'Erkannt über vorhandene Tags (Katalog)',
  'tags' => 'Nicht erkannt – vorhandene Tags übernommen',
  _ => m,
};
