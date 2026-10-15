import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/session.dart';
import '../../core/theme.dart';
import '../../player/player.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/update.dart';
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
      appBar: AppBar(
        title: Text(context.l10n.navSettings, style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
        children: [
          _Section(context.l10n.settingsAccount),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: accent,
              child: Text(user.displayName.characters.first.toUpperCase(), style: TextStyle(color: onColor(accent))),
            ),
            title: Text(user.displayName),
            subtitle: Text('@${user.username}${user.isAdmin ? context.l10n.settingsAdministratorSuffix : ''}'),
            trailing: const Icon(Icons.edit),
            onTap: () async {
              final name = await promptText(
                context,
                context.l10n.settingsDisplayName,
                context.l10n.commonName,
                initial: user.displayName,
              );
              if (name == null || name.isEmpty) return;
              final updated = await ref.read(apiProvider).updateMe({'display_name': name});
              ref.read(sessionProvider.notifier).updateUser(updated);
            },
          ),
          ListTile(
            leading: const Icon(Icons.lock_outline),
            title: Text(context.l10n.settingsChangePassword),
            onTap: () => _changePassword(context, ref),
          ),
          _Section(context.l10n.settingsAppearance),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(context.l10n.settingsAccentColor, style: TextStyle(color: Palette.textMuted)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final c in accentPresets)
                  _Swatch(
                    color: c,
                    selected: toHexColor(c) == user.accentColor,
                    onTap: () => _setAccent(context, ref, c),
                  ),
                _Swatch(
                  color: Colors.transparent,
                  selected: !accentPresets.any((c) => toHexColor(c) == user.accentColor),
                  icon: Icons.colorize,
                  onTap: () async {
                    var picked = accent;
                    final ok = await showDialog<bool>(
                      context: context,
                      builder: (d) => AlertDialog(
                        title: Text(context.l10n.settingsCustomColor),
                        content: SingleChildScrollView(
                          child: ColorPicker(
                            pickerColor: accent,
                            enableAlpha: false,
                            labelTypes: const [],
                            onColorChanged: (c) => picked = c,
                          ),
                        ),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.l10n.commonCancel)),
                          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.commonApply)),
                        ],
                      ),
                    );
                    if (ok == true && context.mounted) await _setAccent(context, ref, picked);
                  },
                ),
              ],
            ),
          ),
          _Section(context.l10n.settingsPlayback),
          StatefulBuilder(
            builder: (context, setState) => SwitchListTile(
              title: Text(context.l10n.settingsNormalizeVolume),
              subtitle: Text(context.l10n.settingsNormalizeVolumeHint),
              value: prefs.getBool(_kNormalize) ?? true,
              onChanged: (v) {
                prefs.setBool(_kNormalize, v);
                ref.read(playerProvider.notifier).setNormalize(v);
                setState(() {});
              },
            ),
          ),
          const AppVersionTile(),
          _Section(context.l10n.settingsSignedInDevices),
          sessions.when(
            loading: () => const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
            error: (e, _) => ListTile(title: Text('$e')),
            data: (list) => Column(
              children: [
                for (final s in list)
                  ListTile(
                    leading: const Icon(Icons.devices),
                    title: Text(
                      '${s['device_name'] ?? context.l10n.settingsUnknownDevice}${s['current'] == true ? context.l10n.settingsCurrentDeviceSuffix : ''}',
                    ),
                    subtitle: Text(context.l10n.settingsLastActive((_date(context, s['last_used_at'])).toString())),
                    trailing: s['current'] == true
                        ? null
                        : IconButton(
                            tooltip: context.l10n.commonSignOut,
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
              label: Text(context.l10n.commonSignOut),
              onPressed: () => ref.read(sessionProvider.notifier).logout(),
            ),
          ),
        ],
      ),
    );
  }

  static String _date(BuildContext context, dynamic iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    if (d == null) return '-';
    return '${MaterialLocalizations.of(context).formatShortDate(d)} ${TimeOfDay.fromDateTime(d).format(context)}';
  }

  Future<void> _changePassword(BuildContext context, WidgetRef ref) async {
    final current = TextEditingController();
    final next = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(context.l10n.settingsChangePassword),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: current,
              obscureText: true,
              decoration: InputDecoration(labelText: context.l10n.settingsCurrentPassword),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: next,
              obscureText: true,
              decoration: InputDecoration(labelText: context.l10n.settingsNewPassword),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(d, false), child: Text(context.l10n.commonCancel)),
          FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(context.l10n.commonChange)),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(apiProvider).updateMe({'current_password': current.text, 'new_password': next.text});
      if (context.mounted) showInfo(context, context.l10n.settingsPasswordChanged);
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
