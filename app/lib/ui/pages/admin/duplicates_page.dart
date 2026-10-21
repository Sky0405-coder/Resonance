import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models.dart';
import '../../../core/session.dart';
import '../../../core/theme.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/collection.dart' show kBottomInset;
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

  String _selectionKey(DuplicateGroup group) => '${group.kind}:${group.tracks.first.id}';

  /// Groups merged so far while deleting; sent in small batches so no request runs into the timeout.
  int _done = 0;

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
    setState(() {
      _merging = true;
      _done = 0;
    });
    var deleted = 0;
    var freed = 0;
    try {
      for (final kind in ['same_album', 'cross_album']) {
        final matching = groups.where((group) => group.kind == kind).toList();
        for (var i = 0; i < matching.length; i += 25) {
          final batch = matching.skip(i).take(25).toList();
          final result = await ref.read(apiProvider).mergeDuplicates([
            for (final group in batch) group.tracks.first.id,
          ], kind: kind);
          deleted += result.deletedTracks;
          freed += result.freedBytes;
          if (!mounted) return;
          setState(() => _done += batch.length);
        }
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) {
        if (deleted > 0) {
          showInfo(
            context,
            context.l10n.adminDuplicatesMerged(deleted, formatBytes(freed, locale: context.l10n.localeName)),
          );
        }
        _selected = null;
        ref.invalidate(_duplicatesProvider);
        setState(() => _merging = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = ref.watch(_duplicatesProvider);
    final list = groups.value ?? <DuplicateGroup>[];
    final selectable = [
      for (final group in list)
        if (group.verified && !group.pending) group,
    ];
    final selected =
        _selected ??
        {
          for (final group in selectable)
            if (group.kind == 'same_album') _selectionKey(group),
        };
    final checked = [
      for (final group in selectable)
        if (selected.contains(_selectionKey(group))) group,
    ];
    final count = checked.fold(0, (sum, group) => sum + group.tracks.length - 1);

    final allSelected = selectable.isNotEmpty && checked.length == selectable.length;

    return Scaffold(
      appBar: AppBar(
        title: Text(context.l10n.adminDuplicates),
        actions: [
          if (list.isNotEmpty)
            TextButton(
              onPressed: _merging || selectable.isEmpty
                  ? null
                  : () => setState(
                      () =>
                          _selected = allSelected ? <String>{} : {for (final group in selectable) _selectionKey(group)},
                    ),
              child: Text(allSelected ? context.l10n.adminDuplicatesSelectNone : context.l10n.adminDuplicatesSelectAll),
            ),
        ],
      ),
      body: AsyncBody(
        value: groups,
        onRetry: () => ref.invalidate(_duplicatesProvider),
        builder: (data) => data.isEmpty
            ? Center(child: Text(context.l10n.adminDuplicatesEmpty))
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(context.l10n.adminDuplicatesHint(selectable.length)),
                  const SizedBox(height: 16),
                  for (final group in data)
                    CheckboxListTile(
                      value: group.verified && !group.pending && selected.contains(_selectionKey(group)),
                      onChanged: _merging || group.pending || !group.verified
                          ? null
                          : (value) => setState(() {
                              _selected = {...selected};
                              if (value == true) {
                                _selected!.add(_selectionKey(group));
                              } else {
                                _selected!.remove(_selectionKey(group));
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
                          if (group.pending)
                            Text(context.l10n.adminDuplicatesPending, style: Theme.of(context).textTheme.labelSmall)
                          else if (group.kind == 'cross_album')
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
              // On phones the mini player floats over the bottom of the page, so the button sits above it.
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, isWide(context) ? 16 : kBottomInset),
                child: FilledButton(
                  onPressed: count == 0 || _merging ? null : () => _merge(checked),
                  child: Text(
                    _merging
                        ? context.l10n.adminDuplicatesProgress(_done, checked.length)
                        : context.l10n.adminDuplicatesDelete(count),
                  ),
                ),
              ),
            ),
    );
  }
}
