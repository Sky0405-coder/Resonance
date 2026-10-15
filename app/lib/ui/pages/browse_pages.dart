import 'package:flutter/foundation.dart';

import '../../l10n/l10n.dart';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:go_router/go_router.dart';

import '../../core/downloads.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/theme.dart';
import '../widgets/collection.dart';
import '../widgets/common.dart';
import '../widgets/offline.dart';
import '../widgets/track_list.dart';
import 'download_pages.dart';
import 'home_page.dart';

class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final _controller = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _query = v.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: TextField(
                  controller: _controller,
                  autofocus: isWide(context),
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: context.l10n.searchHint,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(28), borderSide: BorderSide.none),
                    suffixIcon: _query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              _controller.clear();
                              setState(() => _query = '');
                            },
                          ),
                  ),
                ),
              ),
            ),
            Expanded(child: _query.isEmpty ? const _BrowseAll() : _Results(query: _query)),
          ],
        ),
      ),
    );
  }
}

class _Results extends ConsumerWidget {
  const _Results({required this.query});
  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(searchProvider(query));
    return AsyncBody(
      value: value,
      builder: (r) {
        return ListView(
          padding: const EdgeInsets.only(bottom: kBottomInset),
          children: [
            if (r.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Text(
                  context.l10n.searchNoLibraryResults((query).toString()),
                  style: const TextStyle(color: Palette.textMuted),
                ),
              ),
            if (r.tracks.isNotEmpty) ...[
              _Heading(context.l10n.commonSongsTitle),
              for (final (i, t) in r.tracks.take(8).indexed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: TrackRow(
                    track: t,
                    onPlay: () => playMusic(context, ref, r.tracks, index: i, contextId: 'search'),
                  ),
                ),
            ],
            Shelf(
              title: context.l10n.commonArtists,
              children: [for (final a in r.artists) ArtistCard(artist: a)],
            ),
            Shelf(
              title: context.l10n.commonAlbums,
              children: [for (final a in r.albums) AlbumCard(album: a, onPlay: () => playAlbum(context, ref, a.id))],
            ),
            CatalogSearchSection(query: query),
          ],
        );
      },
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
}

/// Shown when the search box is empty: browse all artists.
class _BrowseAll extends ConsumerWidget {
  const _BrowseAll();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final artists = ref.watch(allArtistsProvider);
    return AsyncBody(
      value: artists,
      builder: (list) => CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _Heading(context.l10n.libraryAllArtists)),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            sliver: SliverGrid.extent(
              maxCrossAxisExtent: 180,
              childAspectRatio: 0.75,
              children: [for (final a in list) ArtistCard(artist: a)],
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: kBottomInset)),
        ],
      ),
    );
  }
}

class LibraryPage extends ConsumerWidget {
  const LibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: kIsWeb ? 4 : 5,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(context.l10n.libraryTitle, style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            const _DownloadsButton(),
            IconButton(
              tooltip: context.l10n.libraryCreatePlaylist,
              icon: const Icon(Icons.add),
              onPressed: () async {
                final name = await promptText(context, context.l10n.libraryNewPlaylist, context.l10n.commonName);
                if (name == null || name.isEmpty) return;
                final p = await ref.read(libraryActionsProvider).createPlaylist(name);
                if (context.mounted) context.push('/playlist/${p.id}');
              },
            ),
          ],
          bottom: TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              if (!kIsWeb) Tab(text: context.l10n.offlineDownloaded),
              Tab(text: context.l10n.libraryPlaylists),
              Tab(text: context.l10n.librarySavedAlbums),
              Tab(text: context.l10n.libraryAllAlbums),
              Tab(text: context.l10n.commonArtists),
            ],
          ),
        ),
        body: const TabBarView(
          children: [
            if (!kIsWeb) OfflineCollections(),
            _PlaylistsTab(),
            _SavedAlbumsTab(),
            _AllAlbumsTab(),
            _ArtistsTab(),
          ],
        ),
      ),
    );
  }
}

/// Entry point to the downloads page on mobile (desktop has it in the sidebar).
class _DownloadsButton extends ConsumerWidget {
  const _DownloadsButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final running = ref.watch(downloadSummaryProvider).value?.running ?? 0;
    return IconButton(
      tooltip: context.l10n.navDownloads,
      icon: Badge(isLabelVisible: running > 0, label: Text('$running'), child: const Icon(Icons.download_outlined)),
      onPressed: () => context.push('/downloads'),
    );
  }
}

class _PlaylistsTab extends ConsumerWidget {
  const _PlaylistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final liked = ref.watch(likedTracksProvider);
    return AsyncBody(
      value: playlists,
      builder: (list) => ListView(
        padding: const EdgeInsets.only(bottom: kBottomInset, top: 8),
        children: [
          ListTile(
            leading: const SizedBox(width: 56, child: LikedCover()),
            title: Text(context.l10n.libraryLikedSongs),
            subtitle: Text(
              context.l10n.libraryPlaylistBy(
                (liked.value == null ? context.l10n.libraryLoadingSongs : songs(context.l10n, liked.value!.length))
                    .toString(),
              ),
            ),
            onTap: () => context.push('/liked'),
          ),
          for (final p in list.where((p) => !p.isRadio && !p.isMix))
            ListTile(
              leading: SizedBox(width: 56, child: PlaylistCover(albumIds: p.coverAlbumIds)),
              title: Text(p.name),
              subtitle: Text(context.l10n.libraryPlaylistBy((p.owner.name).toString())),
              onTap: () => context.push('/playlist/${p.id}'),
            ),
          if (list.any((p) => p.isRadio)) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
              child: Text(context.l10n.libraryRadios, style: Theme.of(context).textTheme.titleMedium),
            ),
            for (final p in list.where((p) => p.isRadio))
              ListTile(
                leading: SizedBox(
                  width: 56,
                  child: PlaylistCover(albumIds: p.coverAlbumIds, icon: Icons.radio),
                ),
                title: Text(p.name),
                subtitle: Text(songs(context.l10n, p.trackCount)),
                onTap: () => context.push('/playlist/${p.id}'),
              ),
          ],
        ],
      ),
    );
  }
}

class _AlbumGrid extends ConsumerWidget {
  const _AlbumGrid(this.provider, {this.empty});
  final ProviderListenable<AsyncValue<List<Album>>> provider;
  final String? empty;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(provider);
    return AsyncBody(
      value: value,
      builder: (list) => list.isEmpty
          ? Center(
              child: Text(empty ?? context.l10n.libraryNoAlbums, style: const TextStyle(color: Palette.textMuted)),
            )
          : GridView.extent(
              maxCrossAxisExtent: 200,
              childAspectRatio: 0.72,
              padding: const EdgeInsets.fromLTRB(6, 8, 6, kBottomInset),
              children: [for (final a in list) AlbumCard(album: a, onPlay: () => playAlbum(context, ref, a.id))],
            ),
    );
  }
}

class _SavedAlbumsTab extends StatelessWidget {
  const _SavedAlbumsTab();
  @override
  Widget build(BuildContext context) => _AlbumGrid(savedAlbumsProvider, empty: context.l10n.librarySaveAlbumsHint);
}

class _AllAlbumsTab extends StatelessWidget {
  const _AllAlbumsTab();
  @override
  Widget build(BuildContext context) => _AlbumGrid(allAlbumsProvider);
}

class _ArtistsTab extends ConsumerWidget {
  const _ArtistsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(allArtistsProvider);
    return AsyncBody(
      value: value,
      builder: (list) => GridView.extent(
        maxCrossAxisExtent: 180,
        childAspectRatio: 0.75,
        padding: const EdgeInsets.fromLTRB(6, 8, 6, kBottomInset),
        children: [for (final a in list) ArtistCard(artist: a)],
      ),
    );
  }
}
