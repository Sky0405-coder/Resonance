import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/models.dart';
import '../../core/review.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';

/// A song's credits (tags and MusicBrainz, looked up by the server once).
final creditsProvider = FutureProvider.autoDispose.family<Credits, String>(
  (ref, trackId) => ref.watch(apiProvider).credits(trackId),
);

/// [role] as shown: known roles translated, instruments as MusicBrainz names them.
String creditRole(AppLocalizations l10n, String role) => switch (role) {
  'artist' => l10n.creditRoleArtist,
  'featured' => l10n.creditRoleFeatured,
  'composer' => l10n.creditRoleComposer,
  'lyricist' => l10n.creditRoleLyricist,
  'writer' => l10n.creditRoleWriter,
  'arranger' => l10n.creditRoleArranger,
  'producer' => l10n.creditRoleProducer,
  'co-producer' => l10n.creditRoleCoProducer,
  'executive producer' => l10n.creditRoleExecutiveProducer,
  'mix' => l10n.creditRoleMix,
  'mastering' => l10n.creditRoleMastering,
  'recording' => l10n.creditRoleRecording,
  'engineer' => l10n.creditRoleEngineer,
  'programming' => l10n.creditRoleProgramming,
  'vocals' || 'vocal' || 'lead vocals' => l10n.creditRoleVocals,
  'background vocals' => l10n.creditRoleBackgroundVocals,
  'performer' => l10n.creditRolePerformer,
  _ => role.isEmpty ? role : role[0].toUpperCase() + role.substring(1),
};

/// The sections of [credits] with their people, empty ones left out.
List<(String, List<Credit>)> creditSections(AppLocalizations l10n, Credits credits) => [
  if (credits.performers.isNotEmpty) (l10n.creditsPerformers, credits.performers),
  if (credits.writers.isNotEmpty) (l10n.creditsWriters, credits.writers),
  if (credits.producers.isNotEmpty) (l10n.creditsProducers, credits.producers),
  if (credits.engineers.isNotEmpty) (l10n.creditsEngineers, credits.engineers),
];

class CreditRow extends StatelessWidget {
  const CreditRow({super.key, required this.credit});
  final Credit credit;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(credit.name, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
        Text(
          credit.roles.map((r) => creditRole(context.l10n, r)).join(', '),
          style: const TextStyle(color: Palette.textMuted, fontSize: 13),
        ),
      ],
    ),
  );
}

Future<void> showCreditsSheet(BuildContext context, Track track) => showModalBottomSheet<void>(
  context: context,
  useRootNavigator: true,
  isScrollControlled: true,
  backgroundColor: const Color(0xFF282828),
  showDragHandle: true,
  builder: (sheet) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    maxChildSize: 0.95,
    builder: (context, controller) => _CreditsList(track: track, controller: controller),
  ),
);

class _CreditsList extends ConsumerWidget {
  const _CreditsList({required this.track, required this.controller});
  final Track track;
  final ScrollController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(creditsProvider(track.id));
    final l10n = context.l10n;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      children: [
        Text(l10n.creditsTitle, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        Text('${track.title} · ${track.artistCredit}', style: const TextStyle(color: Palette.textMuted)),
        const SizedBox(height: 16),
        ...value.when(
          loading: () => [
            const Padding(
              padding: EdgeInsets.all(32),
              child: Center(child: CircularProgressIndicator()),
            ),
          ],
          error: (e, _) => [Text(ApiException.from(e, l10n).message)],
          data: (credits) => [
            for (final (title, people) in creditSections(l10n, credits)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              ),
              for (final credit in people) CreditRow(credit: credit),
            ],
            if (credits.label != null) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Text(l10n.creditsLabel, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 17)),
              ),
              Text(credits.label!),
            ],
            if (credits.copyright != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  '© ${credits.copyright!.replaceFirst(RegExp(r'^\s*(©|\(c\))\s*', caseSensitive: false), '')}',
                  style: const TextStyle(color: Palette.textMuted),
                ),
              ),
            if (credits.sources.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  l10n.creditsSources(
                    credits.sources.map((s) => s == 'tags' ? l10n.creditsSourceTags : 'MusicBrainz').join(', '),
                  ),
                  style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

/// Now playing: the first credits of the song, with a button for all of them (like Spotify's credits card).
class CreditsCard extends ConsumerWidget {
  const CreditsCard({super.key, required this.track});
  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(creditsProvider(track.id));
    final credits = value.isLoading || value.hasError ? null : value.value;
    if (credits == null) return const SizedBox.shrink();
    final people = [for (final (_, list) in creditSections(context.l10n, credits)) ...list];
    if (people.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Material(
        color: Palette.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => showCreditsSheet(context, track),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(context.l10n.creditsTitle, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ),
                    TextButton(
                      onPressed: () => showCreditsSheet(context, track),
                      child: Text(context.l10n.creditsShowAll),
                    ),
                  ],
                ),
                for (final credit in people.take(3)) CreditRow(credit: credit),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
