import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audiobooks.dart';
import '../../core/podcasts.dart';
import '../../core/books.dart';
import '../../core/desktop.dart';
import '../../core/media_sections.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../core/tv_mode.dart';
import '../../integrations/discord_presence.dart';
import '../../player/player.dart';
import '../../player/connect.dart';
import '../../player/spectrum.dart';
import '../../player/visualizer_themes.dart';
import '../../player/equalizer_controller.dart';
import '../../offline/offline_store.dart';
import 'equalizer_page.dart';
import '../widgets/collection.dart';
import '../widgets/changelog.dart';
import '../widgets/common.dart';
import '../widgets/offline.dart';
import '../widgets/shortcuts.dart';
import '../tv/tv_settings_controls.dart';
import '../tv/tv_ambient.dart';
import '../tv/tv_focusable.dart';
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
    final selectedAccentIndex = accentPresets.indexWhere((color) => toHexColor(color) == user.accentColor);
    final prefs = ref.read(prefsProvider);
    final sessions = ref.watch(_sessionsProvider);
    final ebooksEnabled = ref.watch(booksStatusProvider).value?.enabled ?? false;
    final audiobooksEnabled = ref.watch(absStatusProvider).value?.enabled ?? false;
    final tvMode = ref.watch(tvModeProvider);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        title: Text(context.l10n.navSettings, style: TextStyle(fontWeight: FontWeight.w800)),
      ),
      body: TvSettingsList(
        tvMode: tvMode,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
        children: [
          if (isDesktop)
            SwitchListTile(
              title: Text(context.l10n.settingsTvMode),
              subtitle: Text(context.l10n.settingsTvModeHint),
              value: ref.watch(tvModeProvider),
              onChanged: ref.read(tvModeProvider.notifier).set,
            ),
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
          ListTile(
            leading: const Icon(Icons.apps),
            title: Text(context.l10n.settingsSubsonicTitle),
            subtitle: Text(context.l10n.settingsSubsonicSubtitle),
            onTap: () => showDialog<void>(context: context, builder: (_) => const _SubsonicDialog()),
          ),
          ListTile(
            leading: const Icon(Icons.devices),
            title: Text(context.l10n.connectDeviceName),
            subtitle: Text(ref.watch(connectProvider.select((v) => v.name))),
            onTap: () async {
              final name = await promptText(
                context,
                context.l10n.connectDeviceName,
                context.l10n.commonName,
                initial: ref.read(connectProvider).name,
              );
              if (name != null) await ref.read(connectProvider.notifier).rename(name);
            },
          ),
          _Section(context.l10n.settingsAppearance),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Text(context.l10n.settingsAccentColor, style: TextStyle(color: Palette.textMuted)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: TvHorizontalGroup(
              initialFocusIndex: selectedAccentIndex < 0 ? accentPresets.length : selectedAccentIndex,
              child: FocusTraversalGroup(
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final c in accentPresets)
                      _Swatch(
                        color: c,
                        selected: toHexColor(c) == user.accentColor,
                        tvMode: tvMode,
                        onTap: () => _setAccent(context, ref, c),
                      ),
                    _Swatch(
                      color: Colors.transparent,
                      selected: !accentPresets.any((c) => toHexColor(c) == user.accentColor),
                      tvMode: tvMode,
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
                            actions: tvMode
                                ? [
                                    TvButton(
                                      icon: Icons.close,
                                      label: context.l10n.commonCancel,
                                      autofocus: true,
                                      onPressed: () => Navigator.pop(d, false),
                                    ),
                                    TvButton(
                                      icon: Icons.check,
                                      label: context.l10n.commonApply,
                                      onPressed: () => Navigator.pop(d, true),
                                    ),
                                  ]
                                : [
                                    TextButton(
                                      onPressed: () => Navigator.pop(d, false),
                                      child: Text(context.l10n.commonCancel),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(d, true),
                                      child: Text(context.l10n.commonApply),
                                    ),
                                  ],
                          ),
                        );
                        if (ok == true && context.mounted) await _setAccent(context, ref, picked);
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
          _Section(context.l10n.settingsMediaTabs),
          if (ebooksEnabled)
            SwitchListTile(
              title: Text(context.l10n.settingsEbooks),
              subtitle: Text(context.l10n.settingsShowInMenu),
              value: ref.watch(ebooksVisibleProvider),
              onChanged: (v) => ref.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.ebooks, !v),
            ),
          if (audiobooksEnabled)
            SwitchListTile(
              title: Text(context.l10n.navAudiobooks),
              subtitle: Text(context.l10n.settingsShowInMenu),
              value: ref.watch(audiobooksVisibleProvider),
              onChanged: (v) => ref.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.audiobooks, !v),
            ),
          SwitchListTile(
            title: Text(context.l10n.navPodcasts),
            subtitle: Text(context.l10n.settingsShowInMenu),
            value: ref.watch(podcastsVisibleProvider),
            onChanged: (v) => ref.read(hiddenMediaSectionsProvider.notifier).setHidden(MediaSection.podcasts, !v),
          ),
          _Section(context.l10n.settingsPlayback),
          const TvAmbientModeSetting(),
          if (isDiscordDesktop)
            SwitchListTile(
              title: Text(context.l10n.settingsDiscordPresence),
              subtitle: Text(
                (ref.watch(discordClientIdProvider).asData?.value ?? '').isEmpty
                    ? context.l10n.settingsDiscordNotConfigured
                    : context.l10n.settingsDiscordPresenceHint,
              ),
              value: ref.watch(discordPresenceSettingProvider),
              onChanged: (ref.watch(discordClientIdProvider).asData?.value ?? '').isEmpty
                  ? null
                  : ref.read(discordPresenceSettingProvider.notifier).setEnabled,
            ),
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
          StatefulBuilder(
            builder: (context, setState) {
              final controller = ref.read(playerProvider.notifier);
              final seconds = controller.crossfadeSeconds;
              return Column(
                children: [
                  ListTile(
                    title: Text(context.l10n.settingsCrossfade),
                    subtitle: Text(
                      seconds == 0 ? context.l10n.settingsCrossfadeOff : context.l10n.settingsCrossfadeSeconds(seconds),
                    ),
                  ),
                  Slider(
                    value: seconds.toDouble(),
                    min: 0,
                    max: 20,
                    divisions: 20,
                    label: seconds == 0
                        ? context.l10n.settingsCrossfadeOff
                        : context.l10n.settingsCrossfadeSeconds(seconds),
                    onChanged: (value) {
                      controller.setCrossfade(value.round());
                      setState(() {});
                    },
                  ),
                ],
              );
            },
          ),
          StatefulBuilder(
            builder: (context, setState) => SwitchListTile(
              title: Text(context.l10n.settingsAutomix),
              subtitle: Text(context.l10n.settingsAutomixHint),
              value: ref.read(playerProvider.notifier).automix,
              onChanged: (v) {
                ref.read(playerProvider.notifier).setAutomix(v);
                setState(() {});
              },
            ),
          ),
          SwitchListTile(
            title: Text(context.l10n.settingsVisualizer),
            subtitle: Text(context.l10n.settingsVisualizerHint),
            value: ref.watch(visualizerEnabledProvider),
            onChanged: ref.read(visualizerEnabledProvider.notifier).set,
          ),
          if (ref.watch(visualizerEnabledProvider))
            ListTile(
              title: Text(context.l10n.settingsVisualizerStyle),
              subtitle: Text(visualizerThemeName(context.l10n, ref.watch(visualizerThemeProvider).id)),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => FractionallySizedBox(heightFactor: 0.85, child: VisualizerThemeSheet(accent: accent)),
              ),
            ),
          SwitchListTile(
            title: Text(context.l10n.settingsVisualizerReflection),
            subtitle: Text(context.l10n.settingsVisualizerReflectionHint),
            value: ref.watch(visualizerReflectionProvider),
            onChanged: ref.read(visualizerReflectionProvider.notifier).set,
          ),
          SwitchListTile(
            title: Text(context.l10n.settingsCoverflow),
            subtitle: Text(context.l10n.settingsCoverflowHint),
            value: ref.watch(coverflowProvider),
            onChanged: ref.read(coverflowProvider.notifier).set,
          ),
          if (ref.watch(coverflowProvider))
            SwitchListTile(
              title: Text(context.l10n.settingsCoverflowFlip),
              subtitle: Text(context.l10n.settingsCoverflowFlipHint),
              value: ref.watch(coverflowFlipProvider),
              onChanged: ref.read(coverflowFlipProvider.notifier).set,
            ),
          if (supportsEqualizer)
            ListTile(
              leading: const Icon(Icons.equalizer),
              title: Text(context.l10n.equalizerTitle),
              subtitle: Text(
                ref.watch(equalizerProvider).enabled
                    ? equalizerPresetName(context.l10n, ref.watch(equalizerProvider).preset)
                    : context.l10n.equalizerOff,
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/equalizer'),
            ),
          StatefulBuilder(
            builder: (context, setState) => SwitchListTile(
              title: Text(context.l10n.settingsAutoplay),
              subtitle: Text(context.l10n.settingsAutoplayHint),
              value: ref.read(playerProvider.notifier).autoplay,
              onChanged: (v) {
                ref.read(playerProvider.notifier).setAutoplay(v);
                setState(() {});
              },
            ),
          ),
          ListTile(
            leading: const Icon(Icons.queue_music),
            title: Text(context.l10n.spotifyTitle),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/spotify'),
          ),
          if (isDesktop)
            ListTile(
              leading: const Icon(Icons.keyboard),
              title: Text(context.l10n.shortcutsTitle),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showShortcutsDialog(context),
            ),
          if (!kIsWeb) const _OfflineSettings(),
          const AppVersionTile(),
          const ChangelogTile(),
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

class VisualizerThemeSheet extends ConsumerWidget {
  const VisualizerThemeSheet({super.key, required this.accent});
  final Color accent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(visualizerThemeProvider);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(context.l10n.settingsVisualizerStyle, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: MediaQuery.sizeOf(context).width > 600 ? 3 : 2,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              mainAxisExtent: 132,
              children: [
                for (final theme in visualizerThemes)
                  Semantics(
                    selected: theme == selected,
                    child: Material(
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: theme == selected ? accent : Colors.transparent, width: 2),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () {
                          ref.read(visualizerThemeProvider.notifier).set(theme);
                          Navigator.pop(context);
                        },
                        child: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            children: [
                              SpectrumPreview(theme: theme, color: accent),
                              const SizedBox(height: 8),
                              Expanded(
                                child: Center(
                                  child: Text(
                                    visualizerThemeName(context.l10n, theme.id),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SubsonicDialog extends ConsumerStatefulWidget {
  const _SubsonicDialog();

  @override
  ConsumerState<_SubsonicDialog> createState() => _SubsonicDialogState();
}

class _SubsonicDialogState extends ConsumerState<_SubsonicDialog> {
  String? _password;
  bool _busy = false;

  Future<void> _change({required bool remove}) async {
    setState(() => _busy = true);
    try {
      final api = ref.read(apiProvider);
      if (remove) {
        await api.removeSubsonicPassword();
        if (mounted) setState(() => _password = null);
      } else {
        final password = await api.generateSubsonicPassword();
        if (mounted) setState(() => _password = password);
      }
      final user = await api.me();
      if (mounted) ref.read(sessionProvider.notifier).updateUser(user);
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    final user = session.user!;
    final l10n = context.l10n;
    final hasPassword = user.hasSubsonicPassword || _password != null;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(l10n.settingsSubsonicTitle),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(l10n.settingsSubsonicConnection(session.serverUrl ?? '', user.username)),
              const SizedBox(height: 16),
              Text(hasPassword ? l10n.settingsSubsonicConfigured : l10n.settingsSubsonicHint),
              if (_password != null) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: SelectableText(_password!, style: const TextStyle(fontFamily: 'monospace')),
                    ),
                    IconButton(
                      tooltip: l10n.commonCopy,
                      icon: const Icon(Icons.copy),
                      onPressed: () async {
                        await Clipboard.setData(ClipboardData(text: _password!));
                        if (context.mounted) showInfo(context, l10n.settingsSubsonicCopied);
                      },
                    ),
                  ],
                ),
                Text(l10n.settingsSubsonicShownOnce),
              ],
              if (_busy) ...[const SizedBox(height: 16), const LinearProgressIndicator()],
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: Text(l10n.commonClose)),
          if (hasPassword)
            TextButton(onPressed: _busy ? null : () => _change(remove: true), child: Text(l10n.settingsSubsonicRemove)),
          FilledButton(
            onPressed: _busy ? null : () => _change(remove: false),
            child: Text(hasPassword ? l10n.settingsSubsonicRegenerate : l10n.settingsSubsonicGenerate),
          ),
        ],
      ),
    );
  }
}

/// Apply the persisted normalisation preference on startup.
void applyPlaybackPrefs(WidgetRef ref) {
  final enabled = ref.read(prefsProvider).getBool(_kNormalize) ?? true;
  ref.read(playerProvider.notifier).setNormalize(enabled);
  ref.read(playerProvider.notifier).setCrossfade(ref.read(prefsProvider).getInt('crossfade_seconds') ?? 0);
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

class _Swatch extends StatefulWidget {
  const _Swatch({required this.color, required this.selected, required this.onTap, required this.tvMode, this.icon});
  final Color color;
  final bool selected;
  final VoidCallback onTap;
  final bool tvMode;
  final IconData? icon;

  @override
  State<_Swatch> createState() => _SwatchState();
}

class _SwatchState extends State<_Swatch> {
  bool _focused = false;

  Widget _swatch({required bool focused}) => AnimatedScale(
    scale: focused ? 1.15 : 1,
    duration: const Duration(milliseconds: 150),
    child: Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: widget.color,
        shape: BoxShape.circle,
        border: Border.all(
          color: focused || widget.selected ? Colors.white : Colors.white24,
          width: focused || widget.selected ? 3 : 1,
        ),
      ),
      child: widget.icon != null
          ? Icon(widget.icon, size: 20)
          : widget.selected
          ? Icon(Icons.check, size: 20, color: onColor(widget.color))
          : null,
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!widget.tvMode) {
      return InkWell(customBorder: const CircleBorder(), onTap: widget.onTap, child: _swatch(focused: false));
    }
    return Actions(
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
      child: Focus(
        onFocusChange: (focused) => setState(() => _focused = focused),
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if ({
            LogicalKeyboardKey.enter,
            LogicalKeyboardKey.numpadEnter,
            LogicalKeyboardKey.select,
            LogicalKeyboardKey.gameButtonA,
            LogicalKeyboardKey.space,
          }.contains(event.logicalKey)) {
            widget.onTap();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          button: true,
          selected: widget.selected,
          child: GestureDetector(
            onTap: widget.onTap,
            child: _swatch(focused: _focused),
          ),
        ),
      ),
    );
  }
}

class _OfflineSettings extends ConsumerWidget {
  const _OfflineSettings();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (kIsWeb) return const SizedBox.shrink();
    final settings = ref.watch(offlineSettingsProvider);
    final offline = ref.watch(offlineProvider);
    final controller = ref.read(offlineSettingsProvider.notifier);
    final bytes = offline.totalBytes;
    final gigabytes = bytes >= 1024 * 1024 * 1024;
    final value = NumberFormat(
      '0.0',
      Localizations.localeOf(context).toLanguageTag(),
    ).format(bytes / (gigabytes ? 1024 * 1024 * 1024 : 1024 * 1024));
    final size = gigabytes ? context.l10n.offlineGigabytes(value) : context.l10n.offlineMegabytes(value);
    final count = offline.tracks.keys.where(offline.isDownloaded).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Section(context.l10n.navDownloads),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(context.l10n.offlineQuality, style: const TextStyle(color: Palette.textMuted)),
        ),
        RadioGroup<String>(
          groupValue: settings.quality,
          onChanged: (value) {
            if (value != null) controller.setQuality(value);
          },
          child: Column(
            children: [
              RadioListTile<String>(value: 'normal', title: Text(context.l10n.offlineQualityNormal)),
              RadioListTile<String>(value: 'high', title: Text(context.l10n.offlineQualityHigh)),
              RadioListTile<String>(value: 'original', title: Text(context.l10n.offlineQualityOriginal)),
            ],
          ),
        ),
        SwitchListTile(
          title: Text(context.l10n.offlineWifiOnly),
          value: settings.wifiOnly,
          onChanged: controller.setWifiOnly,
        ),
        ListTile(
          leading: const Icon(Icons.storage),
          title: Text(context.l10n.offlineStorage),
          subtitle: Text(
            [
              context.l10n.offlineStorageUsed(size, count),
              if (offline.queued > 0) context.l10n.offlineDownloading(offline.queued),
            ].join('\n'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: OutlinedButton(
            onPressed: () async {
              if (!await confirmOfflineDelete(context, context.l10n.offlineClearConfirm)) return;
              try {
                await ref.read(offlineProvider.notifier).clearAll();
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
            child: Text(context.l10n.offlineClearAll),
          ),
        ),
      ],
    );
  }
}
