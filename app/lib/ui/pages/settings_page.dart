import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/track_list.dart';

const _kNormalize = 'normalize_volume';

const accentPresets = <Color>[
  defaultAccent,
  Color(0xFF1E90FF),
  Color(0xFF8A2BE2),
  Color(0xFFE91E63),
  Color(0xFFFF5722),
  Color(0xFFFFC107),
  Color(0xFF00BCD4),
  Color(0xFFF44336),
  Color(0xFF9E9E9E),
  Color(0xFFFFFFFF),
];

final _sessionsProvider = FutureProvider.autoDispose((ref) async {
  final api = ref.watch(apiProvider);
  // Raw JSON is enough here; this list is only shown on this page.
  return api.sessions();
});

class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  Future<void> _setAccent(BuildContext context, WidgetRef ref, Color c) async {
    try {
      final user = await ref.read(apiProvider).updateMe({'accent_color': toHexColor(c)});
      ref.read(sessionProvider.notifier).updateUser(user);
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(sessionProvider).user!;
    final accent = parseHexColor(user.accentColor);
    final prefs = ref.read(prefsProvider);
    final sessions = ref.watch(_sessionsProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: const Text('Einstellungen', style: TextStyle(fontWeight: FontWeight.w800))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
        children: [
          _Section('Konto'),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: accent,
              child: Text(user.displayName.characters.first.toUpperCase(), style: TextStyle(color: onColor(accent))),
            ),
            title: Text(user.displayName),
            subtitle: Text('@${user.username}${user.isAdmin ? ' • Administrator' : ''}'),
            trailing: const Icon(Icons.edit),
            onTap: () async {
              final name = await promptText(context, 'Anzeigename', 'Name', initial: user.displayName);
              if (name == null || name.isEmpty) return;
              final updated = await ref.read(apiProvider).updateMe({'display_name': name});
              ref.read(sessionProvider.notifier).updateUser(updated);
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: const Text('Passwort ändern'),
            onTap: () => _changePassword(context, ref),
          ),
          _Section('Darstellung'),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text('Akzentfarbe', style: TextStyle(color: Palette.textMuted)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in accentPresets)
                  _Swatch(color: c, selected: toHexColor(c) == user.accentColor, onTap: () => _setAccent(context, ref, c)),
                _Swatch(
                  color: Colors.transparent,
                  selected: !accentPresets.any((c) => toHexColor(c) == user.accentColor),
                  icon: Icons.colorize,
                  onTap: () async {
                    var picked = accent;
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: const Text('Eigene Farbe'),
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: accent,
                            enableAlpha: false,
                            labelTypes: const [],
                            onColorChanged: (c) => picked = c,
                          ),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Übernehmen')),
                        ],
                      ),
                    );
                    if (ok == true && context.mounted) await _setAccent(context, ref, picked);
                  },
                ),
              ],
            ),
          ),
          _Section('Wiedergabe'),
          StatefulBuilder(
            builder: (context, setState) => SwitchListTile(
              title: const Text('Lautstärke angleichen'),
              subtitle: const Text('Nutzt ReplayGain, damit alle Songs ähnlich laut sind'),
              value: prefs.getBool(_kNormalize) ?? true,
              onChanged: (v) {
                prefs.setBool(_kNormalize, v);
                ref.read(playerProvider.notifier).setNormalize(v);
                setState(() {});
              },
            ),
          ),
          _Section('Angemeldete Geräte'),
          sessions.when(
            loading: () => const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
            error: (e, _) => ListTile(title: Text('$e')),
            data: (list) => Column(
              children: [
                for (final s in list)
                  ListTile(
                    leading: const Icon(Icons.devices),
                    title: Text('${s['device_name'] ?? 'Unbekanntes Gerät'}${s['current'] == true ? ' (dieses Gerät)' : ''}'),
                    subtitle: Text('Zuletzt aktiv: ${_date(s['last_used_at'])}'),
                    trailing: s['current'] == true
                        ? null
                        : IconButton(
                            tooltip: 'Abmelden',
                            icon: const Icon(Icons.logout),
                            onPressed: () async {
                              await ref.read(apiProvider).revokeSession(s['id']);
                              ref.invalidate(_sessionsProvider);
                            },
                          ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Center(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.logout),
              label: const Text('Abmelden'),
              onPressed: () => ref.read(sessionProvider.notifier).logout(),
            ),
          ),
        ],
      ),
    );
  }

  static String _date(dynamic iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    if (d == null) return '-';
    return '${d.day}.${d.month}.${d.year} ${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: const Text('Passwort ändern'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: current, obscureText: true, decoration: const InputDecoration(labelText: 'Aktuelles Passwort')),
            const SizedBox(height: 12),
            TextField(controller: next, obscureText: true, decoration: const InputDecoration(labelText: 'Neues Passwort')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Ändern')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).updateMe({'current_password': current.text, 'new_password': next.text});
      if (context.mounted) showInfo(context, 'Passwort geändert');
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }
}

/// Apply the persisted normalisation preference on startup.
void applyPlaybackPrefs(WidgetRef ref) {
  final enabled = ref.read(prefsProvider).getBool(_kNormalize) ?? true;
  ref.read(playerProvider.notifier).setNormalize(enabled);
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(title, style: Theme.of(context).textTheme.titleLarge),
  );
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap, this.icon});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => InkWell(
    customBorder: const CircleBorder(),
    onTap: onTap,
    child: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: selected ? Colors.white : Colors.white24, width: selected ? 3 : 1),
      ),
      child: icon != null
          ? Icon(icon, size: 20)
          : selected
          ? Icon(Icons.check, size: 20, color: onColor(color))
          : null,
    ),
  );
}
