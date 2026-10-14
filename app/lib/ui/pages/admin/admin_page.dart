import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/audiobooks.dart';
import '../../../core/models.dart';
import '../../../core/session.dart';
import '../../../core/theme.dart';
import '../../widgets/collection.dart';
import '../../widgets/common.dart';
import 'import_tab.dart';
import 'metadata_editor.dart';

/// Jellyfin-style dashboard; only routed to for admins (and the API enforces it).
class AdminPage extends StatelessWidget {
  const AdminPage({super.key});

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 6,
    child: Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: const Text('Admin-Dashboard', style: TextStyle(fontWeight: FontWeight.w800)),
        bottom: const TabBar(
          isScrollable: true,
          tabAlignment: TabAlignment.start,
          tabs: [
            Tab(icon: Icon(Icons.dashboard_outlined), text: 'Übersicht'),
            Tab(icon: Icon(Icons.people_outline), text: 'Benutzer'),
            Tab(icon: Icon(Icons.link), text: 'Einladungen'),
            Tab(icon: Icon(Icons.move_to_inbox), text: 'Import'),
            Tab(icon: Icon(Icons.rule), text: 'Zu prüfen'),
            Tab(icon: Icon(Icons.tune), text: 'Server'),
          ],
        ),
      ),
      body: const TabBarView(
        children: [_OverviewTab(), _UsersTab(), _InvitesTab(), ImportTab(), ReviewTab(), _ServerTab()],
      ),
    ),
  );
}

// --- overview ----------------------------------------------------------------

final _statsProvider = FutureProvider.autoDispose<LibraryStats>((ref) => ref.watch(apiProvider).libraryStats());
final _jobsProvider = FutureProvider.autoDispose<List<Job>>((ref) => ref.watch(apiProvider).jobs());

String _bytes(int b) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i == 0 ? 0 : 1)} ${units[i]}';
}

class _OverviewTab extends ConsumerStatefulWidget {
  const _OverviewTab();

  @override
  ConsumerState<_OverviewTab> createState() => _OverviewTabState();
}

class _OverviewTabState extends ConsumerState<_OverviewTab> {
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _ensurePolling(List<Job> jobs) {
    final active = jobs.any((j) => j.isActive);
    if (active && _poll == null) {
      _poll = Timer.periodic(const Duration(seconds: 2), (_) {
        ref.invalidate(_jobsProvider);
        ref.invalidate(_statsProvider);
      });
    } else if (!active && _poll != null) {
      _poll!.cancel();
      _poll = null;
    }
  }

  Future<void> _scan(bool full) async {
    try {
      await ref.read(apiProvider).startScan(full: full);
      ref.invalidate(_jobsProvider);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = ref.watch(_statsProvider);
    final jobs = ref.watch(_jobsProvider);
    jobs.whenData(_ensurePolling);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, kBottomInset),
      children: [
        stats.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
          data: (s) => Wrap(
            spacing: 12,
            runSpacing: 12,
            children: [
              _StatCard('Songs', '${s.tracks}', Icons.music_note),
              _StatCard('Alben', '${s.albums}', Icons.album),
              _StatCard('Künstler', '${s.artists}', Icons.person),
              _StatCard('Speicher', _bytes(s.totalBytes), Icons.storage),
              _StatCard('Spielzeit', '${(s.totalSeconds / 3600).toStringAsFixed(0)} Std.', Icons.schedule),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Text('Bibliothek', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text(
          'Der schnelle Scan liest nur neue und geänderte Dateien ein. Der vollständige Scan liest alle Tags und Cover neu.',
          style: TextStyle(color: Palette.textMuted),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: () => _scan(false),
              icon: const Icon(Icons.sync),
              label: const Text('Schneller Scan'),
            ),
            OutlinedButton.icon(
              onPressed: () => _scan(true),
              icon: const Icon(Icons.manage_search),
              label: const Text('Vollständiger Scan'),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text('Aufgaben', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        jobs.when(
          loading: () => const LinearProgressIndicator(),
          error: (e, _) => Text('$e'),
          data: (list) => list.isEmpty
              ? const Text('Noch keine Aufgaben', style: TextStyle(color: Palette.textMuted))
              : Column(
                  children: [
                    for (final j in list.take(20))
                      Card(
                        color: Palette.card,
                        child: ListTile(
                          leading: Icon(switch (j.status) {
                            'done' => Icons.check_circle,
                            'failed' => Icons.error,
                            'running' => Icons.autorenew,
                            _ => Icons.hourglass_empty,
                          }, color: j.status == 'failed' ? Theme.of(context).colorScheme.error : null),
                          title: Text(j.kind == 'library_scan' ? 'Bibliotheks-Scan' : j.kind),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (j.message != null) Text(j.message!),
                              if (j.isActive) ...[
                                const SizedBox(height: 6),
                                LinearProgressIndicator(
                                  value: j.status == 'running' && j.progress > 0 ? j.progress : null,
                                ),
                              ],
                            ],
                          ),
                          trailing: Text(
                            _dateTime(j.createdAt),
                            style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

String _dateTime(DateTime d) {
  final l = d.toLocal();
  return '${l.day}.${l.month}. ${l.hour}:${l.minute.toString().padLeft(2, '0')}';
}

class _StatCard extends StatelessWidget {
  const _StatCard(this.label, this.value, this.icon);
  final String label;
  final String value;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    width: 170,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(color: Palette.card, borderRadius: BorderRadius.circular(8)),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(height: 8),
        Text(value, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
        Text(label, style: const TextStyle(color: Palette.textMuted)),
      ],
    ),
  );
}

// --- users -------------------------------------------------------------------

final _usersProvider = FutureProvider.autoDispose<List<User>>((ref) => ref.watch(apiProvider).users());

class _UsersTab extends ConsumerWidget {
  const _UsersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final users = ref.watch(_usersProvider);
    final me = ref.watch(currentUserIdProvider);
    final api = ref.read(apiProvider);

    Future<void> run(Future<void> Function() fn) async {
      try {
        await fn();
        ref.invalidate(_usersProvider);
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return AsyncBody(
      value: users,
      builder: (list) => ListView(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, kBottomInset),
        children: [
          for (final u in list)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: parseHexColor(u.accentColor),
                child: Text(
                  u.displayName.characters.first.toUpperCase(),
                  style: TextStyle(color: onColor(parseHexColor(u.accentColor))),
                ),
              ),
              title: Text('${u.displayName}${u.id == me ? ' (du)' : ''}'),
              subtitle: Text(
                '@${u.username} • ${u.isAdmin ? 'Admin' : 'Benutzer'}'
                '${u.isDisabled ? ' • deaktiviert' : ''}'
                '${u.lastSeenAt != null ? ' • zuletzt ${_dateTime(u.lastSeenAt!)}' : ''}',
              ),
              trailing: PopupMenuButton<String>(
                onSelected: (v) async {
                  switch (v) {
                    case 'role':
                      await run(() => api.updateUser(u.id, {'role': u.isAdmin ? 'user' : 'admin'}));
                    case 'disable':
                      await run(() => api.updateUser(u.id, {'is_disabled': !u.isDisabled}));
                    case 'password':
                      final pw = await _ask(context, 'Neues Passwort für ${u.username}');
                      if (pw != null && pw.length >= 8) {
                        await run(() => api.updateUser(u.id, {'new_password': pw}));
                        if (context.mounted) showInfo(context, 'Passwort gesetzt, alle Geräte abgemeldet');
                      }
                    case 'delete':
                      final ok = await _confirm(
                        context,
                        '${u.username} löschen?',
                        'Playlists und Verlauf werden ebenfalls gelöscht.',
                      );
                      if (ok) await run(() => api.deleteUser(u.id));
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'role', child: Text(u.isAdmin ? 'Admin-Rechte entziehen' : 'Zum Admin machen')),
                  PopupMenuItem(value: 'disable', child: Text(u.isDisabled ? 'Aktivieren' : 'Deaktivieren')),
                  const PopupMenuItem(value: 'password', child: Text('Passwort zurücksetzen')),
                  if (u.id != me) const PopupMenuItem(value: 'delete', child: Text('Löschen')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

Future<String?> _ask(BuildContext context, String title) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Min. 8 Zeichen'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
        FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Speichern')),
      ],
    ),
  );
}

Future<bool> _confirm(BuildContext context, String title, String body) async =>
    await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Löschen')),
        ],
      ),
    ) ??
    false;

// --- invites -----------------------------------------------------------------

final _invitesProvider = FutureProvider.autoDispose<List<Invite>>((ref) => ref.watch(apiProvider).invites());

class _InvitesTab extends ConsumerWidget {
  const _InvitesTab();

  Future<void> _create(BuildContext context, WidgetRef ref) async {
    final note = TextEditingController();
    var role = 'user';
    int? hours = 72;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => StatefulBuilder(
        builder: (d, setState) => AlertDialog(
          title: const Text('Einladungslink erstellen'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: note,
                decoration: const InputDecoration(labelText: 'Notiz (z. B. für wen)'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int?>(
                initialValue: hours,
                decoration: const InputDecoration(labelText: 'Gültig für'),
                items: const [
                  DropdownMenuItem(value: 24, child: Text('1 Tag')),
                  DropdownMenuItem(value: 72, child: Text('3 Tage')),
                  DropdownMenuItem(value: 168, child: Text('7 Tage')),
                  DropdownMenuItem(value: 720, child: Text('30 Tage')),
                  DropdownMenuItem(value: null, child: Text('Unbegrenzt')),
                ],
                onChanged: (v) => setState(() => hours = v),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Als Admin registrieren'),
                value: role == 'admin',
                onChanged: (v) => setState(() => role = v ? 'admin' : 'user'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Erstellen')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      final invite = await ref
          .read(apiProvider)
          .createInvite(note: note.text.trim().isEmpty ? null : note.text.trim(), role: role, expiresInHours: hours);
      ref.invalidate(_invitesProvider);
      final link = '${ref.read(sessionProvider).serverUrl}/register?invite=${invite.token}';
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (d) => AlertDialog(
          title: const Text('Einladungslink'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Der Link kann genau einmal benutzt werden. Er wird nur jetzt angezeigt.',
                style: TextStyle(color: Palette.textMuted),
              ),
              const SizedBox(height: 12),
              SelectableText(link),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: link));
                showInfo(context, 'Link kopiert');
              },
              child: const Text('Kopieren'),
            ),
            FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Fertig')),
          ],
        ),
      );
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invites = ref.watch(_invitesProvider);
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: isWide(context) ? 0 : 72),
        child: FloatingActionButton.extended(
          onPressed: () => _create(context, ref),
          icon: const Icon(Icons.add_link),
          label: const Text('Neuer Link'),
        ),
      ),
      body: AsyncBody(
        value: invites,
        builder: (list) => list.isEmpty
            ? const Center(
                child: Text(
                  'Noch keine Einladungen.\nErstelle einen Link, um jemanden einzuladen.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Palette.textMuted),
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, kBottomInset + 72),
                children: [
                  for (final i in list)
                    ListTile(
                      leading: Icon(
                        i.isUsed ? Icons.how_to_reg : (i.isExpired ? Icons.timer_off : Icons.link),
                        color: i.isUsed || i.isExpired ? Palette.textMuted : Theme.of(context).colorScheme.primary,
                      ),
                      title: Text(i.note ?? 'Einladung'),
                      subtitle: Text(
                        i.isUsed
                            ? 'Benutzt von ${i.usedBy ?? '?'} am ${_dateTime(i.usedAt!)}'
                            : i.isExpired
                            ? 'Abgelaufen'
                            : 'Offen • ${i.expiresAt == null ? 'läuft nicht ab' : 'gültig bis ${_dateTime(i.expiresAt!)}'}'
                                  '${i.role == 'admin' ? ' • Admin' : ''}',
                      ),
                      trailing: IconButton(
                        tooltip: 'Löschen',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          await ref.read(apiProvider).deleteInvite(i.id);
                          ref.invalidate(_invitesProvider);
                        },
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}

// --- server settings ---------------------------------------------------------

final _configProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) => ref.watch(apiProvider).adminConfig());

class _ServerTab extends ConsumerWidget {
  const _ServerTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(_configProvider);

    Future<void> patch(Map<String, dynamic> p) async {
      try {
        await ref.read(apiProvider).patchAdminConfig(p);
        ref.invalidate(_configProvider);
      } catch (e) {
        if (context.mounted) showError(context, e);
      }
    }

    return AsyncBody(
      value: config,
      builder: (c) {
        final reg = c['registration'] as Map;
        final radio = c['radio'] as Map;
        final dl = c['downloads'] as Map;
        final lib = (c['library'] ?? const {}) as Map;
        final abs = (c['audiobookshelf'] ?? const {}) as Map;
        return ListView(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, kBottomInset),
          children: [
            ListTile(
              title: const Text('Servername'),
              subtitle: Text(c['server_name']),
              trailing: const Icon(Icons.edit),
              onTap: () async {
                final ctrl = TextEditingController(text: c['server_name']);
                final name = await showDialog<String>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('Servername'),
                    content: TextField(controller: ctrl, autofocus: true),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(d, ctrl.text.trim()), child: const Text('Speichern')),
                    ],
                  ),
                );
                if (name != null && name.isNotEmpty) await patch({'server_name': name});
              },
            ),
            const _Group('Registrierung'),
            RadioGroup<String>(
              groupValue: reg['mode'],
              onChanged: (v) => patch({
                'registration': {'mode': v},
              }),
              child: const Column(
                children: [
                  RadioListTile(
                    value: 'invite',
                    title: Text('Nur mit Einladungslink'),
                    subtitle: Text('Admins erstellen einmalig nutzbare Links (empfohlen)'),
                  ),
                  RadioListTile(
                    value: 'public',
                    title: Text('Öffentliche Registrierung'),
                    subtitle: Text('Jeder, der den Server erreicht, kann ein Konto anlegen'),
                  ),
                ],
              ),
            ),
            const _Group('Bibliothek & Import'),
            ListTile(
              title: const Text('AcoustID-Schlüssel'),
              subtitle: Text(
                (lib['acoustid_api_key'] ?? '').isEmpty
                    ? 'Nicht gesetzt – kostenlos auf acoustid.org/new-application'
                    : 'Gesetzt',
              ),
              trailing: const Icon(Icons.edit),
              onTap: () async {
                final ctrl = TextEditingController(text: lib['acoustid_api_key'] ?? '');
                final key = await showDialog<String>(
                  context: context,
                  builder: (d) => AlertDialog(
                    title: const Text('AcoustID-Schlüssel'),
                    content: TextField(
                      controller: ctrl,
                      autofocus: true,
                      decoration: const InputDecoration(helperText: 'Für die Erkennung per Audio-Fingerabdruck'),
                    ),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
                      FilledButton(onPressed: () => Navigator.pop(d, ctrl.text.trim()), child: const Text('Speichern')),
                    ],
                  ),
                );
                if (key != null) {
                  await patch({
                    'library': {'acoustid_api_key': key},
                  });
                }
              },
            ),
            RadioGroup<String>(
              groupValue: lib['import_mode'] ?? 'move',
              onChanged: (v) => patch({
                'library': {'import_mode': v},
              }),
              child: const Column(
                children: [
                  RadioListTile(
                    value: 'move',
                    title: Text('Importierte Dateien verschieben'),
                    subtitle: Text('Der Import-Ordner wird danach geleert'),
                  ),
                  RadioListTile(
                    value: 'copy',
                    title: Text('Importierte Dateien kopieren'),
                    subtitle: Text('Originale bleiben unverändert im Import-Ordner'),
                  ),
                ],
              ),
            ),
            SwitchListTile(
              title: const Text('Nicht erkannte Dateien trotzdem importieren'),
              subtitle: const Text('Mit ihren vorhandenen Tags; sonst bleiben sie im Import-Ordner liegen'),
              value: lib['import_unidentified'] ?? true,
              onChanged: (v) => patch({
                'library': {'import_unidentified': v},
              }),
            ),
            SwitchListTile(
              title: const Text('Import-Ordner automatisch importieren'),
              subtitle: const Text('Prüft alle 5 Minuten auf neue Dateien (nur im Modus „Verschieben“)'),
              value: lib['auto_import'] ?? true,
              onChanged: (v) => patch({
                'library': {'auto_import': v},
              }),
            ),
            const _Group('Song-Radio'),
            SwitchListTile(
              title: const Text('Fehlende Songs automatisch herunterladen'),
              subtitle: const Text(
                'Ähnliche Songs, die noch nicht in der Bibliothek sind, landen in der Download-Warteschlange',
              ),
              value: radio['auto_download_enabled'],
              onChanged: (v) => patch({
                'radio': {'auto_download_enabled': v},
              }),
            ),
            SwitchListTile(
              title: const Text('Radio-Downloads sind temporär'),
              subtitle: Text(
                'Werden nach ${radio['temporary_retention_days']} Tagen gelöscht, außer jemand liked sie oder fügt sie einer Playlist hinzu',
              ),
              value: radio['temporary_tracks_enabled'],
              onChanged: (v) => patch({
                'radio': {'temporary_tracks_enabled': v},
              }),
            ),
            _NumberTile(
              title: 'Aufbewahrung temporärer Songs (Tage)',
              value: radio['temporary_retention_days'],
              enabled: radio['temporary_tracks_enabled'],
              onChanged: (v) => patch({
                'radio': {'temporary_retention_days': v},
              }),
            ),
            const _Group('Hörbücher'),
            SwitchListTile(
              title: const Text('Audiobookshelf einbinden'),
              subtitle: const Text(
                'Zeigt den Tab „Hörbücher“. Jeder Benutzer meldet sich dort mit seinem eigenen Audiobookshelf-Konto an.',
              ),
              value: abs['enabled'] ?? false,
              onChanged: (v) async {
                await patch({
                  'audiobookshelf': {'enabled': v},
                });
                ref.invalidate(absStatusProvider);
              },
            ),
            if (abs['enabled'] ?? false) ...[
              _TextTile(
                title: 'Audiobookshelf-Adresse',
                value: abs['url'] ?? '',
                hint: 'z. B. https://audio.example.com – auch für externe Apps gedacht',
                onChanged: (v) async {
                  await patch({
                    'audiobookshelf': {'url': v},
                  });
                  ref.invalidate(absStatusProvider);
                },
              ),
              const _AbsCheckTile(),
            ],
            const _Group('Downloads'),
            SwitchListTile(
              title: const Text('Torrents für Alben'),
              subtitle: const Text(
                'Sucht Alben zuerst über Prowlarr (öffentliche Tracker) und lädt sie mit qBittorrent über das VPN. '
                'Was dort fehlt, kommt von YouTube Music.',
              ),
              value: dl['torrent_enabled'] ?? false,
              onChanged: (v) => patch({
                'downloads': {'torrent_enabled': v},
              }),
            ),
            if (dl['torrent_enabled'] ?? false) ...[
              _TextTile(
                title: 'Prowlarr-API-Schlüssel',
                value: dl['prowlarr_api_key'] ?? '',
                secret: true,
                hint: 'Prowlarr → Settings → General → API Key',
                onChanged: (v) => patch({
                  'downloads': {'prowlarr_api_key': v},
                }),
              ),
              _TextTile(
                title: 'qBittorrent-Benutzer',
                value: dl['qbittorrent_username'] ?? '',
                onChanged: (v) => patch({
                  'downloads': {'qbittorrent_username': v},
                }),
              ),
              _TextTile(
                title: 'qBittorrent-Passwort',
                value: dl['qbittorrent_password'] ?? '',
                secret: true,
                onChanged: (v) => patch({
                  'downloads': {'qbittorrent_password': v},
                }),
              ),
              _NumberTile(
                title: 'Mindestanzahl Seeder',
                value: dl['torrent_min_seeders'] ?? 1,
                onChanged: (v) => patch({
                  'downloads': {'torrent_min_seeders': v},
                }),
              ),
              _NumberTile(
                title: 'Aufgeben nach … Minuten ohne Fortschritt',
                value: dl['torrent_timeout_minutes'] ?? 60,
                onChanged: (v) => patch({
                  'downloads': {'torrent_timeout_minutes': v},
                }),
              ),
              const _TorrentCheckTile(),
            ],
            SwitchListTile(
              title: const Text('YouTube Music als Quelle'),
              subtitle: const Text('Lädt Songs über yt-dlp von YouTube Music (Opus, ca. 130–160 kbit/s)'),
              value: dl['youtube_enabled'] ?? true,
              onChanged: (v) => patch({
                'downloads': {'youtube_enabled': v},
              }),
            ),
            SwitchListTile(
              title: const Text('Qualitäts-Upgrades'),
              subtitle: const Text(
                'Songs in niedriger Qualität (z. B. von YouTube) später durch FLAC/MP3 320 ersetzen',
              ),
              value: dl['quality_upgrade_enabled'],
              onChanged: (v) => patch({
                'downloads': {'quality_upgrade_enabled': v},
              }),
            ),
            SwitchListTile(
              title: const Text('Anfragen automatisch genehmigen'),
              subtitle: const Text('Sonst muss ein Admin Anfragen von Benutzern freigeben'),
              value: dl['auto_approve_requests'],
              onChanged: (v) => patch({
                'downloads': {'auto_approve_requests': v},
              }),
            ),
            SwitchListTile(
              title: const Text('Tageslimit pro Benutzer'),
              subtitle: Text('Max. ${dl['daily_limit_per_user']} automatische Downloads pro Tag'),
              value: dl['daily_limit_enabled'],
              onChanged: (v) => patch({
                'downloads': {'daily_limit_enabled': v},
              }),
            ),
            _NumberTile(
              title: 'Downloads pro Benutzer und Tag',
              value: dl['daily_limit_per_user'],
              enabled: dl['daily_limit_enabled'],
              onChanged: (v) => patch({
                'downloads': {'daily_limit_per_user': v},
              }),
            ),
          ],
        );
      },
    );
  }
}

class _Group extends StatelessWidget {
  const _Group(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 4),
    child: Text(
      title,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(color: Theme.of(context).colorScheme.primary),
    ),
  );
}

class _NumberTile extends StatelessWidget {
  const _NumberTile({required this.title, required this.value, required this.onChanged, this.enabled = true});
  final String title;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    enabled: enabled,
    title: Text(title),
    trailing: Text('$value', style: Theme.of(context).textTheme.titleMedium),
    onTap: () async {
      final ctrl = TextEditingController(text: '$value');
      final result = await showDialog<int>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(d, int.tryParse(ctrl.text)), child: const Text('Speichern')),
          ],
        ),
      );
      if (result != null) onChanged(result);
    },
  );
}

class _TextTile extends StatelessWidget {
  const _TextTile({required this.title, required this.value, required this.onChanged, this.secret = false, this.hint});
  final String title;
  final String value;
  final bool secret;
  final String? hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: Text(value.isEmpty ? 'Nicht gesetzt' : (secret ? '••••••••' : value)),
    trailing: const Icon(Icons.edit),
    onTap: () async {
      final ctrl = TextEditingController(text: value);
      final result = await showDialog<String>(
        context: context,
        builder: (d) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            obscureText: secret,
            decoration: InputDecoration(helperText: hint),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(d), child: const Text('Abbrechen')),
            FilledButton(onPressed: () => Navigator.pop(d, ctrl.text.trim()), child: const Text('Speichern')),
          ],
        ),
      );
      if (result != null) onChanged(result);
    },
  );
}

/// Checks the Prowlarr / qBittorrent connection with the saved credentials.
class _AbsCheckTile extends ConsumerStatefulWidget {
  const _AbsCheckTile();

  @override
  ConsumerState<_AbsCheckTile> createState() => _AbsCheckTileState();
}

class _AbsCheckTileState extends ConsumerState<_AbsCheckTile> {
  Map<String, dynamic>? _result;
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(apiProvider).absAdminStatus();
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ok = _result?['ok'] == true;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _check,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: const Text('Verbindung testen'),
          ),
          if (_result != null) ...[
            const SizedBox(width: 12),
            Icon(
              ok ? Icons.check_circle : Icons.error_outline,
              size: 18,
              color: ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text('${_result!['message'] ?? ''}')),
          ],
        ],
      ),
    );
  }
}

class _TorrentCheckTile extends ConsumerStatefulWidget {
  const _TorrentCheckTile();

  @override
  ConsumerState<_TorrentCheckTile> createState() => _TorrentCheckTileState();
}

class _TorrentCheckTileState extends ConsumerState<_TorrentCheckTile> {
  Map<String, dynamic>? _result;
  bool _busy = false;

  Future<void> _check() async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(apiProvider).torrentStatus();
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget line(String name, Map? r) {
      final ok = r?['ok'] == true;
      return Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.error_outline,
            size: 18,
            color: ok ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(child: Text('$name: ${r?['message'] ?? ''}')),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            onPressed: _busy ? null : _check,
            icon: _busy
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.network_check),
            label: const Text('Verbindung testen'),
          ),
          if (_result != null) ...[
            const SizedBox(height: 8),
            line('Prowlarr', _result!['prowlarr'] as Map?),
            const SizedBox(height: 4),
            line('qBittorrent', _result!['qbittorrent'] as Map?),
          ],
        ],
      ),
    );
  }
}
