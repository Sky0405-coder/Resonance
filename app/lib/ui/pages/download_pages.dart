import '../../l10n/l10n.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/api.dart';
import '../../core/downloads.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/theme.dart';
import '../widgets/catalog.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/track_list.dart';

/// Catalog results below the library search results.
class CatalogSearchSection extends ConsumerWidget {
  const CatalogSearchSection({super.key, required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(catalogSearchProvider(query));
    final heading = Padding(
      padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.l10n.catalogDiscoverMore, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 2),
          Text(context.l10n.catalogDownloadHint, style: TextStyle(color: Palette.textMuted, fontSize: 13)),
        ],
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        heading,
        value.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: Text(ApiException.from(e, context.l10n).message, style: const TextStyle(color: Palette.textMuted)),
          ),
          data: (r) => r.isEmpty
              ? Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(context.l10n.catalogNoResults, style: TextStyle(color: Palette.textMuted)),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 8),
                    for (final t in r.tracks.take(6))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: CatalogTrackRow(track: t),
                      ),
                    Shelf(
                      title: context.l10n.commonAlbums,
                      children: [for (final a in r.albums) CatalogAlbumCard(album: a)],
                    ),
                    Shelf(
                      title: context.l10n.commonArtists,
                      children: [for (final a in r.artists) CatalogArtistCard(artist: a)],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class CatalogAlbumPage extends ConsumerWidget {
  const CatalogAlbumPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(catalogAlbumProvider(id));
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AsyncBody(
        value: value,
        onRetry: () => ref.invalidate(catalogAlbumProvider(id)),
        builder: (d) {
          final a = d.album;
          final total = d.tracks.length;
          final have = d.inLibraryCount;
          final multiDisc = d.tracks.map((t) => t.discNo ?? 1).toSet().length > 1;
          final rows = <Widget>[];
          int? disc;
          for (final t in d.tracks) {
            if (multiDisc && t.discNo != disc) {
              disc = t.discNo;
              rows.add(
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                  child: Text(
                    context.l10n.commonDiscNumber(disc ?? 1),
                    style: const TextStyle(color: Palette.textMuted, fontWeight: FontWeight.w700),
                  ),
                ),
              );
            }
            rows.add(CatalogTrackRow(track: t, number: t.trackNo, showCover: false));
          }
          final duration = d.tracks.fold<double>(0, (s, t) => s + (t.duration ?? 0));
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: CollectionHeader(
                  image: NetworkCover(url: a.coverBigUrl ?? a.coverUrl),
                  kind: a.typeLabel(context.l10n),
                  title: a.title,
                  meta: Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      InkWell(
                        onTap: a.artistId == null ? null : () => context.push('/catalog/artist/${a.artistId}'),
                        child: Text(
                          a.artist,
                          style: const TextStyle(fontWeight: FontWeight.w700, color: Colors.white),
                        ),
                      ),
                      Text(
                        [
                          if (a.year != null) ' • ${a.year}',
                          ' • ${songs(context.l10n, total)}',
                          if (duration > 0) ', ${formatLongDuration(context.l10n, duration)}',
                          ' • ${have == total ? context.l10n.catalogAllInLibrary : context.l10n.catalogLibraryCount(have, total)}',
                        ].join(),
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (have < total)
                        RequestButton(
                          kind: 'album',
                          catalogId: a.id,
                          inLibrary: false,
                          label: have == 0
                              ? context.l10n.catalogDownloadAlbum
                              : total - have == 1
                              ? context.l10n.catalogDownloadMissingSong
                              : context.l10n.catalogDownloadMissingSongs(total - have),
                        ),
                      if (a.libraryId != null)
                        OutlinedButton.icon(
                          onPressed: () => context.push('/album/${a.libraryId}'),
                          icon: const Icon(Icons.library_music_outlined),
                          label: Text(context.l10n.catalogOpenInLibrary),
                        ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                sliver: SliverList.list(children: rows),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
            ],
          );
        },
      ),
    );
  }
}

class CatalogArtistPage extends ConsumerWidget {
  const CatalogArtistPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(catalogArtistProvider(id));
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AsyncBody(
        value: value,
        onRetry: () => ref.invalidate(catalogArtistProvider(id)),
        builder: (d) {
          final groups = [
            (context.l10n.commonAlbums, d.albums.where((a) => a.recordType == 'album').toList()),
            (context.l10n.catalogEps, d.albums.where((a) => a.recordType == 'ep').toList()),
            (context.l10n.catalogSingles, d.albums.where((a) => a.recordType == 'single').toList()),
          ];
          final have = d.albums.where((a) => a.libraryId != null).length;
          return CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: CollectionHeader(
                  circleImage: true,
                  image: NetworkCover(url: d.artist.pictureUrl, radius: 0, icon: Icons.person),
                  kind: context.l10n.commonArtist,
                  title: d.artist.name,
                  meta: Text(context.l10n.catalogArtistReleases(d.albums.length, have)),
                ),
              ),
              if (d.artist.libraryId != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: () => context.push('/artist/${d.artist.libraryId}'),
                        icon: const Icon(Icons.library_music_outlined),
                        label: Text(context.l10n.catalogOpenInLibrary),
                      ),
                    ),
                  ),
                ),
              if (d.topTracks.isNotEmpty) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                    child: Text(context.l10n.artistPopular, style: Theme.of(context).textTheme.titleLarge),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  sliver: SliverList.list(children: [for (final t in d.topTracks) CatalogTrackRow(track: t)]),
                ),
              ],
              for (final (title, albums) in groups)
                if (albums.isNotEmpty) ...[
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
                      child: Text(title, style: Theme.of(context).textTheme.titleLarge),
                    ),
                  ),
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    sliver: SliverGrid.extent(
                      maxCrossAxisExtent: 200,
                      childAspectRatio: 0.72,
                      children: [for (final a in albums) CatalogAlbumCard(album: a, showArtist: false)],
                    ),
                  ),
                ],
              const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
            ],
          );
        },
      ),
    );
  }
}

/// Downloads overview: own requests for everyone, all requests + approvals for admins.
class DownloadsPage extends ConsumerStatefulWidget {
  const DownloadsPage({super.key});

  @override
  ConsumerState<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends ConsumerState<DownloadsPage> {
  String _scope = 'mine';

  @override
  Widget build(BuildContext context) {
    final isAdmin = ref.watch(sessionProvider.select((s) => s.user?.isAdmin ?? false));
    final scope = isAdmin ? _scope : 'mine';
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(context.l10n.navDownloads, style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            if (isAdmin)
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    ButtonSegment(value: 'mine', label: Text(context.l10n.downloadsMine)),
                    ButtonSegment(value: 'all', label: Text(context.l10n.downloadsAllUsers)),
                  ],
                  selected: {scope},
                  onSelectionChanged: (s) => setState(() => _scope = s.first),
                ),
              ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: context.l10n.downloadsOpen),
              Tab(text: context.l10n.downloadsCompleted),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _RequestList(scope: scope, state: 'open', empty: context.l10n.downloadsEmptyActive),
            _RequestList(scope: scope, state: 'finished', empty: context.l10n.downloadsEmptyCompleted),
          ],
        ),
      ),
    );
  }
}

class _RequestList extends ConsumerWidget {
  const _RequestList({required this.scope, required this.state, required this.empty});
  final String scope;
  final String state;
  final String empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(requestsProvider((scope, state)));
    return AsyncBody(
      value: value,
      onRetry: () => ref.invalidate(requestsProvider((scope, state))),
      builder: (list) => list.isEmpty
          ? Center(
              child: Text(
                empty,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Palette.textMuted),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, kBottomInset),
              itemCount: list.length,
              itemBuilder: (_, i) => _RequestTile(request: list[i], showUser: scope == 'all'),
            ),
    );
  }
}

class _RequestTile extends ConsumerWidget {
  const _RequestTile({required this.request, required this.showUser});
  final DownloadRequest request;
  final bool showUser;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final r = request;
    final isAdmin = ref.watch(sessionProvider.select((s) => s.user?.isAdmin ?? false));
    const muted = TextStyle(color: Palette.textMuted, fontSize: 13);
    final counts = r.kind == 'album' ? ' • ${r.doneCount}/${songs(context.l10n, r.itemCount)}' : '';
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => context.push('/downloads/${r.id}'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(
              width: 56,
              child: NetworkCover(
                url: r.coverUrl,
                icon: r.kind == 'redownload'
                    ? Icons.restart_alt
                    : r.kind == 'album'
                    ? Icons.album
                    : Icons.music_note,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(
                    [
                      r.kind == 'redownload'
                          ? context.l10n.downloadsRedownload
                          : r.kind == 'album'
                          ? context.l10n.commonAlbum
                          : context.l10n.commonSong,
                      r.artist,
                      if (showUser) context.l10n.downloadsRequestedBySuffix((r.user.name).toString()),
                    ].join(' • '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: muted,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Icon(requestStatusIcon(r.status), size: 14, color: requestStatusColor(context, r.status)),
                      const SizedBox(width: 4),
                      Text('${requestStatusLabel(context.l10n, r.status)}$counts', style: muted.copyWith(fontSize: 12)),
                    ],
                  ),
                  if (r.status == 'active') ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(value: r.progress, minHeight: 3, borderRadius: BorderRadius.circular(2)),
                  ],
                ],
              ),
            ),
            if (isAdmin && r.status == 'pending_approval') ...[
              const SizedBox(width: 8),
              IconButton(
                tooltip: context.l10n.downloadsReject,
                icon: const Icon(Icons.close),
                onPressed: () => _reject(context, ref, r),
              ),
              IconButton.filled(
                tooltip: context.l10n.downloadsApprove,
                icon: const Icon(Icons.check),
                onPressed: () => _run(context, () => ref.read(downloadActionsProvider).action(r.id, 'approve')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<void> _run(BuildContext context, Future<void> Function() fn) async {
  try {
    await fn();
  } catch (e) {
    if (context.mounted) showError(context, e);
  }
}

Future<void> _reject(BuildContext context, WidgetRef ref, DownloadRequest r) async {
  final note = await promptText(context, context.l10n.downloadsRejectRequest, context.l10n.downloadsReasonOptional);
  if (note == null || !context.mounted) return;
  await _run(context, () => ref.read(downloadActionsProvider).reject(r.id, note: note.isEmpty ? null : note));
}

class RequestDetailPage extends ConsumerWidget {
  const RequestDetailPage({super.key, required this.id});
  final String id;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(requestDetailProvider(id));
    final user = ref.watch(sessionProvider.select((s) => s.user));
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(context.l10n.downloadsDownload)),
      body: AsyncBody(
        value: value,
        onRetry: () => ref.invalidate(requestDetailProvider(id)),
        builder: (r) {
          final isAdmin = user?.isAdmin ?? false;
          final actions = ref.read(downloadActionsProvider);
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, kBottomInset),
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 120,
                    child: NetworkCover(
                      url: r.coverUrl,
                      icon: r.kind == 'redownload' ? Icons.restart_alt : Icons.album,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          r.title,
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        Text(r.artist, style: const TextStyle(color: Palette.textMuted)),
                        const SizedBox(height: 8),
                        Text(
                          context.l10n.downloadsProgress(
                            (requestStatusLabel(context.l10n, r.status)).toString(),
                            r.doneCount,
                            r.itemCount,
                            (r.failedCount > 0 ? context.l10n.downloadsFailedSuffix(r.failedCount) : '').toString(),
                          ),
                        ),
                        if (isAdmin)
                          Text(
                            context.l10n.downloadsRequestedBy((r.user.name).toString()),
                            style: const TextStyle(color: Palette.textMuted),
                          ),
                        if (r.note != null)
                          Text(
                            context.l10n.downloadsReason((r.note).toString()),
                            style: const TextStyle(color: Palette.textMuted),
                          ),
                        if (r.torrentStatus != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _torrentLabel(context.l10n, r),
                            style: const TextStyle(color: Palette.textMuted),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (r.torrentStatus == 'downloading') ...[
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              value: r.torrentProgress,
                              minHeight: 3,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (isAdmin && r.status == 'pending_approval') ...[
                    FilledButton.icon(
                      onPressed: () => _run(context, () => actions.action(r.id, 'approve')),
                      icon: const Icon(Icons.check),
                      label: Text(context.l10n.downloadsApprove),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => _reject(context, ref, r),
                      icon: const Icon(Icons.close),
                      label: Text(context.l10n.downloadsReject),
                    ),
                  ],
                  if (r.failedCount > 0 && r.status != 'rejected')
                    FilledButton.tonalIcon(
                      onPressed: () => _run(context, () => actions.action(r.id, 'retry')),
                      icon: const Icon(Icons.refresh),
                      label: Text(context.l10n.downloadsRetryFailed),
                    ),
                  if (r.isOpen)
                    OutlinedButton.icon(
                      onPressed: () => _run(context, () => actions.action(r.id, 'cancel')),
                      icon: const Icon(Icons.stop_circle_outlined),
                      label: Text(context.l10n.commonCancel),
                    ),
                  if (isAdmin && !r.isOpen)
                    TextButton.icon(
                      onPressed: () => _run(context, () async {
                        await actions.delete(r.id);
                        if (context.mounted) context.pop();
                      }),
                      icon: const Icon(Icons.delete_outline),
                      label: Text(context.l10n.downloadsDeleteEntry),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              for (final item in r.items) _ItemRow(item: item),
            ],
          );
        },
      ),
    );
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item});
  final DownloadItem item;

  @override
  Widget build(BuildContext context) {
    const muted = TextStyle(color: Palette.textMuted, fontSize: 13);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Icon(requestStatusIcon(item.status), size: 20, color: requestStatusColor(context, item.status)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(
                  [
                    item.artist,
                    requestStatusLabel(context.l10n, item.status),
                    if (item.source == 'youtube') context.l10n.catalogYouTubeMusic,
                    if (item.source == 'torrent') context.l10n.downloadsTorrent,
                  ].join(' • '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: muted,
                ),
                if (item.error != null)
                  Text(item.error!, style: muted.copyWith(color: Theme.of(context).colorScheme.error)),
                if (item.status == 'downloading') ...[
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: item.progress, minHeight: 3, borderRadius: BorderRadius.circular(2)),
                ],
              ],
            ),
          ),
          if (item.duration != null)
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(formatDuration(Duration(seconds: item.duration!.round())), style: muted),
            ),
        ],
      ),
    );
  }
}

String _torrentLabel(AppLocalizations l10n, DownloadRequest r) => switch (r.torrentStatus) {
  'searching' => l10n.downloadsSearchingTorrent,
  'downloading' => l10n.downloadsTorrentProgress((r.torrentName ?? '').toString(), (r.torrentProgress * 100).round()),
  'importing' => l10n.downloadsImportingTorrent,
  'done' => l10n.downloadsTorrentName((r.torrentName ?? '').toString()),
  'failed' => l10n.downloadsTorrentFallback((r.torrentError == null ? '' : ' (${r.torrentError})').toString()),
  _ => '',
};
