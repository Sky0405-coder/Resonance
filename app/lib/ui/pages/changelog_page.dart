import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/changelog.dart';
import '../../core/updates.dart';
import '../../l10n/l10n.dart';

class ChangelogPage extends ConsumerWidget {
  const ChangelogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(changelogProvider);
    final installed = ref.watch(installedVersionProvider).asData?.value;
    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.changelogTitle)),
      body: entries.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: TextButton.icon(
            onPressed: () => ref.invalidate(changelogProvider),
            icon: const Icon(Icons.refresh),
            label: Text(context.l10n.commonRetry),
          ),
        ),
        data: (list) => ListView.builder(
          padding: const EdgeInsets.all(24),
          itemCount: list.length,
          itemBuilder: (_, index) => ChangelogSection(
            entry: list[index],
            installed: installed != null && versionCode(list[index].version) == versionCode(installed),
          ),
        ),
      ),
    );
  }
}

class ChangelogSection extends StatelessWidget {
  const ChangelogSection({super.key, required this.entry, this.installed = false});

  final ChangelogEntry entry;
  final bool installed;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(entry.version, style: Theme.of(context).textTheme.titleLarge),
            Text(DateFormat.yMMMd(Localizations.localeOf(context).languageCode).format(entry.date)),
            if (installed) Chip(label: Text(context.l10n.changelogInstalled)),
          ],
        ),
        const SizedBox(height: 8),
        for (final bullet in entry.bullets(Localizations.localeOf(context).languageCode))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('•  '),
                Expanded(child: Text(bullet)),
              ],
            ),
          ),
      ],
    ),
  );
}
