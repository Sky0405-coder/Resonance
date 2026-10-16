import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/library.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';

final _statusProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.watch(apiProvider).spotifyStatus(),
);

final _playlistsProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.watch(apiProvider).spotifyPlaylists(),
);

final _importsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final list = await ref.watch(apiProvider).spotifyImports();
  if (list.any((i) => i['status'] == 'queued' || i['status'] == 'running')) {
    final timer = Timer(const Duration(seconds: 3), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return list;
});

/// Settings → "Von Spotify importieren": connect Spotify, pick liked songs / playlists, see past imports.
class SpotifyImportPage extends ConsumerWidget {
  const SpotifyImportPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    // Likes and playlists change when an import finishes.
    ref.listen(_importsProvider, (prev, next) {
      final wasRunning = prev?.value?.any((i) => i['status'] == 'running' || i['status'] == 'queued') ?? false;
      final running = next.value?.any((i) => i['status'] == 'running' || i['status'] == 'queued') ?? false;
      if (wasRunning && !running) {
        ref.read(libraryActionsProvider).libraryChanged();
        ref.invalidate(_playlistsProvider);
      }
    });
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.spotifyTitle, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncBody(
        value: ref.watch(_statusProvider),
        onRetry: () => ref.invalidate(_statusProvider),
        builder: (s) {
          if (s['configured'] != true || s['connected'] != true) {
            return ListView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, kBottomInset),
              children: [
                const _LinkImport(),
                if (s['configured'] != true) _Message(l10n.spotifyNotConfigured) else const _Connect(),
                const _ImportHistory(),
              ],
            );
          }
          return _Picker(displayName: s['display_name'] as String?);
        },
      ),
    );
  }
}

class _LinkImport extends ConsumerStatefulWidget {
  const _LinkImport();

  @override
  ConsumerState<_LinkImport> createState() => _LinkImportState();
}

class _LinkImportState extends ConsumerState<_LinkImport> {
  final _controller = TextEditingController();
  bool _download = true;
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    final l10n = context.l10n;
    final links = _controller.text.split(RegExp(r'\s+')).where((link) => link.isNotEmpty).toList();
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .startSpotifyImport(liked: false, playlistIds: [], links: links, downloadMissing: _download);
      ref.invalidate(_importsProvider);
      if (mounted) {
        _controller.clear();
        showInfo(context, l10n.spotifyStarted);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final imports = ref.watch(_importsProvider);
    final running = imports.value?.any((i) => i['status'] == 'queued' || i['status'] == 'running') ?? false;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.spotifyLinkHeading, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(l10n.spotifyLinksHint, style: const TextStyle(color: Palette.textMuted)),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            minLines: 3,
            maxLines: 6,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(hintText: l10n.spotifyLinkPlaceholder),
            onChanged: (_) => setState(() {}),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _download,
            onChanged: (value) => setState(() => _download = value),
            title: Text(l10n.spotifyDownloadMissing),
            subtitle: Text(l10n.spotifyDownloadMissingHint),
          ),
          FilledButton.icon(
            onPressed: _busy || running || _controller.text.trim().isEmpty ? null : _start,
            icon: const Icon(Icons.link),
            label: Text(l10n.spotifyImport),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: Palette.textMuted),
      ),
    ),
  );
}

class _Connect extends ConsumerStatefulWidget {
  const _Connect();

  @override
  ConsumerState<_Connect> createState() => _ConnectState();
}

class _ConnectState extends ConsumerState<_Connect> with WidgetsBindingObserver {
  Timer? _poll;
  bool _waiting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _poll?.cancel();
    super.dispose();
  }

  // Coming back from the browser: check right away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waiting) ref.invalidate(_statusProvider);
  }

  Future<void> _connect() async {
    try {
      final url = await ref.read(apiProvider).spotifyLoginUrl();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      setState(() => _waiting = true);
      // The page switches to the picker as soon as the server knows the account.
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => ref.invalidate(_statusProvider));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.queue_music, size: 56, color: Color(0xFF1DB954)),
              const SizedBox(height: 16),
              Text(l10n.spotifyConnectHint, textAlign: TextAlign.center),
              const SizedBox(height: 24),
              FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: const Color(0xFF1DB954), foregroundColor: Colors.black),
                onPressed: _connect,
                icon: const Icon(Icons.link),
                label: Text(l10n.spotifyConnect),
              ),
              if (_waiting) ...[
                const SizedBox(height: 16),
                Text(
                  l10n.spotifyWaiting,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Palette.textMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Picker extends ConsumerStatefulWidget {
  const _Picker({required this.displayName});
  final String? displayName;

  @override
  ConsumerState<_Picker> createState() => _PickerState();
}

class _PickerState extends ConsumerState<_Picker> {
  bool _liked = true;
  bool _download = true;
  final Set<String> _selected = {};
  bool _busy = false;

  Future<void> _start() async {
    final l10n = context.l10n;
    if (!_liked && _selected.isEmpty) {
      showInfo(context, l10n.spotifyNothingSelected);
      return;
    }
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .startSpotifyImport(liked: _liked, playlistIds: _selected.toList(), downloadMissing: _download);
      ref.invalidate(_importsProvider);
      if (mounted) showInfo(context, l10n.spotifyStarted);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final imports = ref.watch(_importsProvider);
    final running = imports.value?.any((i) => i['status'] == 'queued' || i['status'] == 'running') ?? false;
    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, kBottomInset),
      children: [
        ListTile(
          leading: const Icon(Icons.account_circle, color: Color(0xFF1DB954)),
          title: Text(l10n.spotifyConnectedAs(widget.displayName ?? 'Spotify')),
          trailing: TextButton(
            onPressed: () async {
              await ref.read(apiProvider).spotifyDisconnect();
              ref.invalidate(_statusProvider);
            },
            child: Text(l10n.spotifyDisconnect),
          ),
        ),
        const _LinkImport(),
        AsyncBody(
          value: ref.watch(_playlistsProvider),
          onRetry: () => ref.invalidate(_playlistsProvider),
          builder: (p) {
            final playlists = [for (final x in p['playlists'] as List) Map<String, dynamic>.from(x)];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CheckboxListTile(
                  value: _liked,
                  onChanged: (v) => setState(() => _liked = v ?? false),
                  secondary: const SizedBox(width: 48, child: LikedCover()),
                  title: Text(l10n.spotifyLikedSongs),
                  subtitle: Text(l10n.spotifyLikedHint(p['liked_count'] as int? ?? 0)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(l10n.spotifyPlaylistsHeading, style: Theme.of(context).textTheme.titleMedium),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Text(
                    l10n.spotifyPlaylistsNote,
                    style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                  ),
                ),
                for (final pl in playlists)
                  CheckboxListTile(
                    value: _selected.contains(pl['id']),
                    onChanged: (v) => setState(() => v == true ? _selected.add(pl['id']) : _selected.remove(pl['id'])),
                    secondary: SizedBox(
                      width: 48,
                      child: NetworkCover(url: pl['image_url'] as String?, icon: Icons.queue_music),
                    ),
                    title: Text(pl['name'] as String, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      [
                        l10n.spotifyPlaylistSubtitle(pl['track_count'] as int? ?? 0, pl['owner'] as String? ?? ''),
                        if (pl['imported'] == true) l10n.spotifyAlreadyImported,
                      ].join('\n'),
                      style: const TextStyle(color: Palette.textMuted),
                    ),
                  ),
                const Divider(),
                SwitchListTile(
                  value: _download,
                  onChanged: (v) => setState(() => _download = v),
                  title: Text(l10n.spotifyDownloadMissing),
                  subtitle: Text(l10n.spotifyDownloadMissingHint),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: FilledButton.icon(
                    onPressed: _busy || running ? null : _start,
                    icon: const Icon(Icons.download_for_offline),
                    label: Text(l10n.spotifyStart),
                  ),
                ),
              ],
            );
          },
        ),
        const _ImportHistory(),
      ],
    );
  }
}

class _ImportHistory extends ConsumerWidget {
  const _ImportHistory();

  @override
  Widget build(BuildContext context, WidgetRef ref) => AsyncBody(
    value: ref.watch(_importsProvider),
    builder: (list) => list.isEmpty
        ? const SizedBox()
        : Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Text(context.l10n.spotifyHistory, style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final i in list) _ImportTile(data: i),
            ],
          ),
  );
}

class _ImportTile extends ConsumerWidget {
  const _ImportTile({required this.data});
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final status = data['status'] as String;
    final created = DateTime.parse(data['created_at'] as String).toLocal();
    final when =
        '${MaterialLocalizations.of(context).formatShortDate(created)} '
        '${TimeOfDay.fromDateTime(created).format(context)}';
    final label = switch (status) {
      'queued' => l10n.spotifyStatusQueued,
      'running' => l10n.spotifyStatusRunning,
      'done' => l10n.spotifyStatusDone,
      _ => l10n.spotifyStatusFailed,
    };
    final missing = data['missing'] as int? ?? 0;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('$label • $when', style: Theme.of(context).textTheme.titleSmall)),
                if (status == 'running' || status == 'queued')
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l10n.spotifyImportCounts(
                data['matched'] as int? ?? 0,
                data['total'] as int? ?? 0,
                missing,
                data['requested'] as int? ?? 0,
              ),
              style: const TextStyle(color: Palette.textMuted),
            ),
            if (data['message'] != null) ...[
              const SizedBox(height: 4),
              Text(data['message'] as String, style: const TextStyle(color: Palette.textMuted)),
            ],
            if (missing > 0 && status == 'done')
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => _showMissing(context, ref, data['id'] as String),
                  child: Text(l10n.spotifyShowMissing),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

Future<void> _showMissing(BuildContext context, WidgetRef ref, String id) async {
  final detail = ref.read(apiProvider).spotifyImport(id);
  await showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(context.l10n.spotifyMissingTitle),
      content: SizedBox(
        width: 480,
        height: 420,
        child: FutureBuilder<Map<String, dynamic>>(
          future: detail,
          builder: (_, snap) {
            if (snap.hasError) return Text('${snap.error}');
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final tracks = snap.data!['missing_tracks'] as List;
            return ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (_, i) {
                final t = tracks[i] as Map;
                return ListTile(
                  dense: true,
                  title: Text('${t['title']}'),
                  subtitle: Text('${t['artist']} · ${t['source']}', style: const TextStyle(color: Palette.textMuted)),
                );
              },
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(context.l10n.commonClose))],
    ),
  );
}
