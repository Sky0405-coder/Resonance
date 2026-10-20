import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models.dart';
import '../../../core/session.dart';
import '../../../core/theme.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/common.dart';
import 'admin_page.dart' show formatBytes;

final _duplicatesProvider = FutureProvider.autoDispose<List<DuplicateGroup>>(
  (ref) => ref.watch(apiProvider).duplicates(),
);

class DuplicatesPage extends ConsumerStatefulWidget {
  const DuplicatesPage({super.key});

  @override
  ConsumerState<DuplicatesPage> createState() => _DuplicatesPageState();
}

class _DuplicatesPageState extends ConsumerState<DuplicatesPage> {
  Set<String>? _selected;
  bool _merging = false;

  Future<void> _merge(List<DuplicateGroup> groups) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.l10n.adminDuplicatesConfirmTitle),
        content: Text(context.l10n.adminDuplicatesConfirmHint),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.commonDelete)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _merging = true);
    try {
      final result = await ref.read(apiProvider).mergeDuplicates([for (final group in groups) group.tracks.first.id]);
      if (!mounted) return;
      showInfo(
        context,
        context.l10n.adminDuplicatesMerged(
          result.deletedTracks,
          formatBytes(result.freedBytes, locale: context.l10n.localeName),
        ),
      );
      _selected = null;
      ref.invalidate(_duplicatesProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _merging = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(_duplicatesProvider);
    final list = groups.value ?? <DuplicateGroup>[];
    final selected = _selected ?? {for (final group in list) group.tracks.first.id};
    final checked = [
      for (final group in list)
        if (selected.contains(group.tracks.first.id)) group,
    ];
    final count = checked.fold(0, (sum, group) => sum + group.tracks.length - 1);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.adminDuplicates)),
      body: AsyncBody(
        value: groups,
        onRetry: () => ref.invalidate(_duplicatesProvider),
        builder: (data) => data.isEmpty
            ? Center(child: Text(context.l10n.adminDuplicatesEmpty))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(context.l10n.adminDuplicatesHint(data.length)),
                  const SizedBox(height: 16),
                  for (final group in data)
                    CheckboxListTile(
                      value: selected.contains(group.tracks.first.id),
                      onChanged: _merging
                          ? null
                          : (value) => setState(() {
                              _selected = {...selected};
                              if (value == true) {
                                _selected!.add(group.tracks.first.id);
                              } else {
                                _selected!.remove(group.tracks.first.id);
                              }
                            }),
                      title: Text(
                        context.l10n.adminDuplicatesGroupTitle(
                          group.artistName,
                          group.albumTitle,
                          group.tracks.first.title,
                        ),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (group.kind == 'cross_album')
                            Text(
                              context.l10n.adminDuplicatesDifferentAlbums,
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          for (final track in group.tracks)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  context.l10n.adminDuplicatesFile(
                                    track.keep ? '✓' : '✗',
                                    (track.codec ?? context.l10n.commonUnknown).toUpperCase(),
                                    track.bitrate ?? 0,
                                    formatBytes(track.size, locale: context.l10n.localeName, megabytes: true),
                                  ),
                                  style: TextStyle(
                                    color: track.keep ? Theme.of(context).colorScheme.primary : Palette.textMuted,
                                  ),
                                ),
                                if (track.album.isNotEmpty)
                                  Text(track.album, style: Theme.of(context).textTheme.bodySmall),
                              ],
                            ),
                        ],
                      ),
                    ),
                ],
              ),
      ),
      bottomNavigationBar: list.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: count == 0 || _merging ? null : () => _merge(checked),
                  child: Text(context.l10n.adminDuplicatesDelete(count)),
                ),
              ),
            ),
    );
  }
}
