import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/api.dart';
import '../../core/library.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/track_list.dart';

const _spotifyGreen = Color(0xFF1DB954);

final _statusProvider = FutureProvider.autoDispose<Map<String, dynamic>>(
  (ref) => ref.watch(apiProvider).spotifyStatus(),
);

/// The playlist's Spotify link (null when not linked); polls while a sync runs.
final _syncProvider = FutureProvider.autoDispose.family<Map<String, dynamic>?, String>((ref, id) async {
  final sync = await ref.watch(apiProvider).spotifySync(id);
  if (sync?['status'] == 'running') {
    final timer = Timer(const Duration(seconds: 3), ref.invalidateSelf);
    ref.onDispose(timer.cancel);
  }
  return sync;
});

final _spotifyPlaylistsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final data = await ref.watch(apiProvider).spotifyPlaylists();
  return [for (final p in data['playlists'] as List) Map<String, dynamic>.from(p)];
});

/// Playlist menu → "Mit Spotify abgleichen": export to Spotify or link an existing Spotify playlist, optionally
/// kept in sync in both directions by the server.
class SpotifySyncPage extends ConsumerWidget {
  const SpotifySyncPage({super.key, required this.playlistId});
  final String playlistId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    // Songs that came over from Spotify show up in the playlist.
    ref.listen(_syncProvider(playlistId), (prev, next) {
      if (prev?.value?['status'] == 'running' && next.value?['status'] != 'running') {
        ref.invalidate(playlistDetailProvider(playlistId));
        ref.invalidate(playlistsProvider);
      }
    });
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(l10n.spotifySyncTitle, style: const TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: AsyncBody(
        value: ref.watch(_statusProvider),
        onRetry: () => ref.invalidate(_statusProvider),
        builder: (s) {
          if (s['configured'] != true) return _Centered(child: Text(l10n.spotifyNotConfigured));
          if (s['connected'] != true || s['can_write'] != true) {
            return _Connect(reconnect: s['connected'] == true);
          }
          return AsyncBody(
            value: ref.watch(_syncProvider(playlistId)),
            onRetry: () => ref.invalidate(_syncProvider(playlistId)),
            builder: (sync) =>
                sync == null ? _Setup(playlistId: playlistId) : _Linked(playlistId: playlistId, sync: sync),
          );
        },
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 460), child: child),
    ),
  );
}

class _Connect extends ConsumerStatefulWidget {
  const _Connect({required this.reconnect});
  final bool reconnect;

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

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _waiting) ref.invalidate(_statusProvider);
  }

  Future<void> _connect() async {
    try {
      final url = await ref.read(apiProvider).spotifyLoginUrl();
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      setState(() => _waiting = true);
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 3), (_) => ref.invalidate(_statusProvider));
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return _Centered(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.sync, size: 56, color: _spotifyGreen),
          const SizedBox(height: 16),
          Text(
            widget.reconnect ? l10n.spotifySyncReconnectHint : l10n.spotifySyncConnectHint,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _spotifyGreen, foregroundColor: Colors.black),
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
    );
  }
}

class _Setup extends ConsumerStatefulWidget {
  const _Setup({required this.playlistId});
  final String playlistId;

  @override
  ConsumerState<_Setup> createState() => _SetupState();
}

class _SetupState extends ConsumerState<_Setup> {
  bool _existing = false;
  String? _spotifyId;
  bool _twoWay = true;
  bool _busy = false;

  Future<void> _start() async {
    setState(() => _busy = true);
    try {
      await ref
          .read(apiProvider)
          .linkSpotify(widget.playlistId, spotifyPlaylistId: _existing ? _spotifyId : null, twoWay: _twoWay);
      ref.invalidate(_syncProvider(widget.playlistId));
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final playlists = _existing ? ref.watch(_spotifyPlaylistsProvider) : null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
      children: [
        Text(l10n.spotifySyncIntro, style: const TextStyle(color: Palette.textMuted)),
        const SizedBox(height: 16),
        RadioGroup<bool>(
          groupValue: _existing,
          onChanged: (v) => setState(() => _existing = v ?? false),
          child: Column(
            children: [
              RadioListTile<bool>(value: false, title: Text(l10n.spotifySyncNew)),
              RadioListTile<bool>(value: true, title: Text(l10n.spotifySyncExisting)),
            ],
          ),
        ),
        if (playlists != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: playlists.when(
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text(
                ApiException.from(e, l10n).message,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              data: (list) => DropdownButtonFormField<String>(
                initialValue: _spotifyId,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: l10n.spotifySyncPick,
                  helperText: l10n.spotifyPlaylistsNote,
                  helperMaxLines: 2,
                ),
                items: [
                  for (final p in list)
                    DropdownMenuItem(
                      value: p['id'] as String,
                      child: Text('${p['name']} · ${p['owner']}', overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _spotifyId = v),
              ),
            ),
          ),
        const SizedBox(height: 8),
        SwitchListTile(
          value: _twoWay,
          onChanged: (v) => setState(() => _twoWay = v),
          title: Text(l10n.spotifySyncTwoWay),
          subtitle: Text(_twoWay ? l10n.spotifySyncTwoWayHint : l10n.spotifySyncOneWayHint),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: _spotifyGreen, foregroundColor: Colors.black),
            onPressed: _busy || (_existing && _spotifyId == null) ? null : _start,
            icon: const Icon(Icons.sync),
            label: Text(_existing ? l10n.spotifySyncLink : l10n.spotifySyncExport),
          ),
        ),
        const SizedBox(height: 24),
        Text(l10n.spotifySyncFriendsHint, style: const TextStyle(color: Palette.textMuted, fontSize: 13)),
      ],
    );
  }
}

class _Linked extends ConsumerWidget {
  const _Linked({required this.playlistId, required this.sync});
  final String playlistId;
  final Map<String, dynamic> sync;

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() fn) async {
    try {
      await fn();
      ref.invalidate(_syncProvider(playlistId));
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final api = ref.read(apiProvider);
    final status = sync['status'] as String?;
    final last = DateTime.tryParse(sync['last_synced_at'] as String? ?? '')?.toLocal();
    final url = sync['spotify_url'] as String?;
    final unmatched = [for (final u in (sync['unmatched'] as List? ?? const [])) Map<String, dynamic>.from(u)];
    final twoWay = sync['two_way'] == true;
    final statusText = switch (status) {
      'running' => l10n.spotifySyncRunning,
      'failed' => l10n.spotifySyncFailed((sync['error'] ?? '').toString()),
      _ when last != null => l10n.spotifySyncLast(
        '${MaterialLocalizations.of(context).formatShortDate(last)} ${TimeOfDay.fromDateTime(last).format(context)}',
      ),
      _ => '',
    };
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
      children: [
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: status == 'running'
              ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(
                  status == 'failed' ? Icons.error_outline : Icons.check_circle,
                  color: status == 'failed' ? Theme.of(context).colorScheme.error : _spotifyGreen,
                ),
          title: Text(l10n.spotifySyncLinked),
          subtitle: Text(statusText),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: twoWay,
          onChanged: (v) => _run(context, ref, () => api.updateSpotifySync(playlistId, twoWay: v)),
          title: Text(l10n.spotifySyncTwoWay),
          subtitle: Text(twoWay ? l10n.spotifySyncTwoWayHint : l10n.spotifySyncOneWayHint),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: status == 'running' ? null : () => _run(context, ref, () => api.runSpotifySync(playlistId)),
              icon: const Icon(Icons.sync),
              label: Text(l10n.spotifySyncNow),
            ),
            if (url != null)
              OutlinedButton.icon(
                onPressed: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                icon: const Icon(Icons.open_in_new),
                label: Text(l10n.spotifySyncOpen),
              ),
            TextButton.icon(
              onPressed: () async {
                if (!await confirmDelete(context, l10n.spotifySyncUnlink, l10n.spotifySyncUnlinkConfirm)) return;
                if (context.mounted) await _run(context, ref, () => api.unlinkSpotify(playlistId));
              },
              icon: const Icon(Icons.link_off),
              label: Text(l10n.spotifySyncUnlink),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(l10n.spotifySyncFriendsHint, style: const TextStyle(color: Palette.textMuted, fontSize: 13)),
        if (unmatched.isNotEmpty) ...[
          const SizedBox(height: 24),
          Text(
            l10n.spotifySyncUnmatched(unmatched.length),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          for (final u in unmatched)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: Text(u['title']?.toString() ?? ''),
              subtitle: Text(u['artist']?.toString() ?? '', style: const TextStyle(color: Palette.textMuted)),
            ),
        ],
      ],
    );
  }
}
