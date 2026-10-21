import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/changelog.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../pages/changelog_page.dart';

class ChangelogTile extends StatelessWidget {
  const ChangelogTile({super.key});

  @override
  Widget build(BuildContext context) => ListTile(
    leading: const Icon(Icons.new_releases_outlined),
    title: Text(context.l10n.changelogTitle),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => context.push('/changelog'),
  );
}

/// Lives above both shells so navigation, resizing and TV mode cannot repeat the sheet.
class WhatsNewNotifier extends ConsumerStatefulWidget {
  const WhatsNewNotifier({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<WhatsNewNotifier> createState() => _WhatsNewNotifierState();
}

class _WhatsNewNotifierState extends ConsumerState<WhatsNewNotifier> {
  bool _shown = false;

  @override
  Widget build(BuildContext context) {
    if (ref.watch(whatsNewEnabledProvider)) {
      final entries = ref.watch(whatsNewProvider).asData?.value;
      final version = ref.watch(installedVersionProvider).asData?.value;
      if (!_shown && entries != null && entries.isNotEmpty && version != null) {
        _shown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            isDismissible: false,
            enableDrag: false,
            builder: (_) => PopScope(
              canPop: false,
              child: _WhatsNewSheet(version: version, entries: entries.take(3).toList()),
            ),
          );
        });
      }
    }
    return widget.child;
  }
}

class _WhatsNewSheet extends ConsumerWidget {
  const _WhatsNewSheet({required this.version, required this.entries});
  final String version;
  final List<ChangelogEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) => SafeArea(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(context.l10n.changelogNewVersion(version), style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child: Column(children: [for (final entry in entries) ChangelogSection(entry: entry)]),
            ),
          ),
          TextButton(onPressed: () => context.push('/changelog'), child: Text(context.l10n.changelogAll)),
          FilledButton(
            onPressed: () async {
              await ref.read(prefsProvider).setString(changelogSeenVersionKey, version);
              if (!context.mounted) return;
              ref.invalidate(whatsNewProvider);
              Navigator.pop(context);
            },
            child: Text(context.l10n.commonOk),
          ),
        ],
      ),
    ),
  );
}
