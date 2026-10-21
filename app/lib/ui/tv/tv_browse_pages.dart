import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../l10n/l10n.dart';
import '../pages/world_radio_page.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import 'tv_focusable.dart';
import 'tv_shelves.dart';

TvCardData tvAlbum(BuildContext context, Album album) => TvCardData(
  title: album.title,
  subtitle: album.artist.name,
  image: CoverImage(albumId: album.hasCover ? album.id : null),
  onActivate: () => context.push('/album/${album.id}'),
);

TvCardData tvArtist(BuildContext context, Artist artist) => TvCardData(
  title: artist.name,
  image: ArtistImage(artist: artist),
  onActivate: () => context.push('/artist/${artist.id}'),
);

TvCardData tvPlaylist(BuildContext context, Playlist playlist) => TvCardData(
  title: playlist.name,
  image: PlaylistCover(playlistId: playlist.id, coverKey: playlist.coverKey, albumIds: playlist.coverAlbumIds),
  onActivate: () => context.push('/playlist/${playlist.id}'),
);

TvCardData tvStation(BuildContext context, WidgetRef ref, Station station) => TvCardData(
  title: station.name,
  subtitle: station.country,
  image: NetworkCover(url: station.favicon, icon: Icons.radio),
  onActivate: () => playWorldRadio(context, ref, station),
);

TvShelfData _tracks(BuildContext context, WidgetRef ref, String title, List<Track> tracks) => TvShelfData(title, [
  for (final (index, track) in tracks.indexed)
    TvCardData(
      title: track.title,
      subtitle: track.artistCredit,
      image: CoverImage(albumId: track.album.id),
      onActivate: () => playMusic(context, ref, tracks, index: index, contextId: 'search'),
    ),
]);

class TvHomePage extends ConsumerWidget {
  const TvHomePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mixes = ref.watch(mixesProvider).value;
    final stations = ref.watch(worldRadioFavoritesProvider).value ?? [];
    return TvAsync(
      value: ref.watch(homeProvider),
      onRetry: () => ref.invalidate(homeProvider),
      builder: (home) => TvShelves(
        title: context.l10n.navHome,
        shelves: [
          TvShelfData(context.l10n.homeRecentlyPlayed, [for (final a in home.recentlyPlayed) tvAlbum(context, a)]),
          TvShelfData(context.l10n.homeYourPlaylists, [
            TvCardData(
              title: context.l10n.libraryLikedSongs,
              image: const LikedCover(),
              onActivate: () => context.push('/liked'),
            ),
            for (final p in home.playlists) tvPlaylist(context, p),
          ]),
          TvShelfData(context.l10n.worldRadioYourStations, [for (final s in stations) tvStation(context, ref, s)]),
          if (mixes != null) ...[
            TvShelfData(context.l10n.homeMadeForYou, [
              if (mixes.$3 case final discover?) tvPlaylist(context, discover),
              for (final p in mixes.$1) tvPlaylist(context, p),
            ]),
            TvShelfData(context.l10n.homeCharts, [for (final p in mixes.$5) tvPlaylist(context, p)]),
            TvShelfData(context.l10n.homeGenreMixes, [for (final p in mixes.$2) tvPlaylist(context, p)]),
            TvShelfData(context.l10n.homeDecadeMixes, [for (final p in mixes.$4) tvPlaylist(context, p)]),
          ],
          TvShelfData(context.l10n.homeRecentlyAdded, [for (final a in home.recentlyAdded) tvAlbum(context, a)]),
        ],
      ),
    );
  }
}

final _libraryProvider = FutureProvider.autoDispose((ref) async {
  final playlists = ref.watch(playlistsProvider.future);
  final saved = ref.watch(savedAlbumsProvider.future);
  final albums = ref.watch(allAlbumsProvider.future);
  final artists = ref.watch(allArtistsProvider.future);
  return await (playlists, saved, albums, artists).wait;
});

class TvLibraryPage extends ConsumerWidget {
  const TvLibraryPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) => TvAsync(
    value: ref.watch(_libraryProvider),
    onRetry: () {
      ref.invalidate(playlistsProvider);
      ref.invalidate(savedAlbumsProvider);
      ref.invalidate(allAlbumsProvider);
      ref.invalidate(allArtistsProvider);
    },
    builder: (data) => TvShelves(
      title: context.l10n.navLibrary,
      shelves: [
        TvShelfData(context.l10n.libraryPlaylists, [
          TvCardData(
            title: context.l10n.libraryLikedSongs,
            image: const LikedCover(),
            onActivate: () => context.push('/liked'),
          ),
          for (final p in data.$1) tvPlaylist(context, p),
        ]),
        TvShelfData(context.l10n.librarySavedAlbums, [for (final a in data.$2) tvAlbum(context, a)]),
        TvShelfData(context.l10n.libraryAllAlbums, [for (final a in data.$3) tvAlbum(context, a)]),
        TvShelfData(context.l10n.commonArtists, [for (final a in data.$4) tvArtist(context, a)]),
      ],
    ),
  );
}

final worldRadioPopularProvider = FutureProvider.autoDispose<List<Station>>(
  (ref) => ref.watch(apiProvider).worldRadioStations(),
);

class TvWorldRadioPage extends ConsumerWidget {
  const TvWorldRadioPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final favorites = ref.watch(worldRadioFavoritesProvider);
    return TvAsync(
      value: ref.watch(worldRadioPopularProvider),
      onRetry: () {
        ref.invalidate(worldRadioPopularProvider);
        ref.invalidate(worldRadioFavoritesProvider);
      },
      builder: (stations) => TvShelves(
        title: context.l10n.worldRadioTitle,
        leading: favorites.hasError
            ? TvButton(
                icon: Icons.refresh,
                label: context.l10n.commonRetry,
                onPressed: () => ref.invalidate(worldRadioFavoritesProvider),
              )
            : null,
        shelves: [
          TvShelfData(context.l10n.worldRadioYourStations, [
            for (final s in favorites.value ?? <Station>[]) tvStation(context, ref, s),
          ]),
          TvShelfData(context.l10n.tvPopularStations, [for (final s in stations) tvStation(context, ref, s)]),
        ],
      ),
    );
  }
}

class TvSearchPage extends ConsumerStatefulWidget {
  const TvSearchPage({super.key});

  @override
  ConsumerState<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends ConsumerState<TvSearchPage> {
  final _text = TextEditingController();
  final _field = FocusNode();
  Timer? _debounce;
  String _query = '';

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (_field.hasFocus && event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _field.nextFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _debounce?.cancel();
    _text.dispose();
    _field.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(32),
        child: TvFocusable(
          skipTraversal: true,
          descendantsAreFocusable: true,
          onActivate: () {
            _field.requestFocus();
            SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          },
          child: TextField(
            controller: _text,
            focusNode: _field,
            autofocus: true,
            style: const TextStyle(fontSize: 28),
            decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: context.l10n.searchHint),
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => FocusScope.of(context).nextFocus(),
            onChanged: (value) {
              _debounce?.cancel();
              _debounce = Timer(const Duration(milliseconds: 300), () => setState(() => _query = value.trim()));
            },
          ),
        ),
      ),
      Expanded(
        child: _query.isEmpty
            ? const SizedBox.shrink()
            : TvAsync(
                value: ref.watch(searchProvider(_query)),
                onRetry: () => ref.invalidate(searchProvider(_query)),
                builder: (result) => TvShelves(
                  title: result.isEmpty ? context.l10n.searchNoLibraryResults(_query) : context.l10n.navSearch,
                  shelves: [
                    TvShelfData(context.l10n.commonArtists, [for (final a in result.artists) tvArtist(context, a)]),
                    TvShelfData(context.l10n.commonAlbums, [for (final a in result.albums) tvAlbum(context, a)]),
                    _tracks(context, ref, context.l10n.commonSongsTitle, result.tracks),
                    TvShelfData(context.l10n.libraryPlaylists, [
                      for (final p in result.playlists) tvPlaylist(context, p),
                    ]),
                  ],
                ),
              ),
      ),
    ],
  );
}
