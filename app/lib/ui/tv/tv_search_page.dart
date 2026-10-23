import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/downloads.dart';
import '../../core/library.dart';
import '../../core/models.dart';
import '../../core/session.dart';
import '../../core/tv_mode.dart';
import '../../l10n/l10n.dart';
import '../widgets/catalog.dart';
import '../widgets/common.dart';
import 'tv_browse_pages.dart';
import 'tv_focusable.dart';
import 'tv_keyboard.dart';
import 'tv_shelves.dart';

class TvSearchPage extends ConsumerStatefulWidget {
  const TvSearchPage({super.key});

  @override
  ConsumerState<TvSearchPage> createState() => _TvSearchPageState();
}

class _TvSearchPageState extends ConsumerState<TvSearchPage> {
  final _firstResult = FocusNode(debugLabel: 'TV first search result');
  Timer? _debounce;
  String _input = '';
  String _query = '';
  bool _pendingSubmit = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  void _onText(String value) => _updateInput('$_input$value');

  void _onBackspace() {
    final characters = _input.characters;
    if (characters.isNotEmpty) _updateInput(characters.skipLast(1).toString());
  }

  void _onClear() => _updateInput('');

  void _updateInput(String value) {
    setState(() => _input = value);
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = _input.trim());
    });
  }

  void _submit() {
    _debounce?.cancel();
    setState(() {
      _query = _input.trim();
      _pendingSubmit = _query.isNotEmpty;
    });
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (!ref.read(tvModeProvider) || event is! KeyDownEvent) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<TextField>() != null) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _onBackspace();
      return KeyEventResult.handled;
    }
    if ({LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter}.contains(event.logicalKey)) {
      _submit();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null || character.isEmpty || character.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return KeyEventResult.ignored;
    }
    _onText(character);
    return KeyEventResult.handled;
  }

  bool _hasCatalogCards(CatalogSearch? catalog) =>
      (catalog?.albums.any((album) => album.libraryId == null) ?? false) ||
      (catalog?.tracks.any((track) => track.libraryId == null) ?? false);

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _debounce?.cancel();
    _firstResult.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final canRequestDownloads = ref.watch(sessionProvider).loggedIn;
    final libraryValue = _query.isEmpty ? null : ref.watch(searchProvider(_query));
    final catalogValue = canRequestDownloads && _query.isNotEmpty ? ref.watch(catalogSearchProvider(_query)) : null;
    final result = libraryValue?.value;
    final catalog = catalogValue?.value;
    final pendingIds = canRequestDownloads && _query.isNotEmpty ? ref.watch(openRequestIdsProvider) : const <String>{};

    if (_pendingSubmit && libraryValue != null && (libraryValue.hasValue || libraryValue.hasError)) {
      final catalogSettled = catalogValue == null || catalogValue.hasValue || catalogValue.hasError;
      if (catalogSettled) {
        final hasResults = !(result?.isEmpty ?? true) || _hasCatalogCards(catalog);
        _pendingSubmit = false;
        if (hasResults) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _firstResult.context != null) _firstResult.requestFocus();
          });
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.all(32),
          child: InputDecorator(
            isEmpty: _input.isEmpty,
            decoration: searchDecoration(context.l10n.searchHint),
            child: Text(_input, style: const TextStyle(fontSize: 28)),
          ),
        ),
        TvKeyboard(onText: _onText, onBackspace: _onBackspace, onClear: _onClear, onSubmit: _submit),
        Expanded(
          child: _query.isEmpty
              ? const SizedBox.shrink()
              : TvAsync(
                  value: libraryValue!,
                  onRetry: () => ref.invalidate(searchProvider(_query)),
                  builder: (library) => TvShelves(
                    title: library.isEmpty ? context.l10n.searchNoLibraryResults(_query) : context.l10n.navSearch,
                    autofocusFirstCard: false,
                    firstCardFocusNode: _firstResult,
                    shelves: [
                      TvShelfData(context.l10n.commonArtists, [
                        for (final artist in library.artists) tvArtist(context, artist),
                      ]),
                      TvShelfData(context.l10n.commonAlbums, [
                        for (final album in library.albums) tvAlbum(context, album),
                      ]),
                      TvShelfData(context.l10n.commonSongsTitle, [
                        for (final (index, track) in library.tracks.indexed)
                          TvCardData(
                            title: track.title,
                            subtitle: track.artistCredit,
                            image: CoverImage(albumId: track.album.id),
                            onActivate: () =>
                                playMusic(context, ref, library.tracks, index: index, contextId: 'search'),
                          ),
                      ]),
                      TvShelfData(context.l10n.libraryPlaylists, [
                        for (final playlist in library.playlists) tvPlaylist(context, playlist),
                      ]),
                      if (canRequestDownloads && catalog != null)
                        TvShelfData(context.l10n.tvSearchAvailableAlbums, [
                          for (final album in catalog.albums)
                            if (album.libraryId == null)
                              TvCardData(
                                title: album.title,
                                subtitle: pendingIds.contains(album.id) ? context.l10n.catalogRequested : album.artist,
                                image: NetworkCover(url: album.coverBigUrl ?? album.coverUrl),
                                onActivate: () => _activateCatalog(
                                  context,
                                  kind: 'album',
                                  catalogId: album.id,
                                  title: album.title,
                                  artist: album.artist,
                                  requested: pendingIds.contains(album.id),
                                ),
                              ),
                        ]),
                      if (canRequestDownloads && catalog != null)
                        TvShelfData(context.l10n.tvSearchAvailableSongs, [
                          for (final track in catalog.tracks)
                            if (track.libraryId == null)
                              TvCardData(
                                title: track.title,
                                subtitle: pendingIds.contains(track.id) ? context.l10n.catalogRequested : track.artist,
                                image: NetworkCover(url: track.coverUrl, icon: Icons.music_note),
                                onActivate: () => _activateCatalog(
                                  context,
                                  kind: 'track',
                                  catalogId: track.id,
                                  title: track.title,
                                  artist: track.artist,
                                  requested: pendingIds.contains(track.id),
                                ),
                              ),
                        ]),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _activateCatalog(
    BuildContext context, {
    required String kind,
    required String catalogId,
    required String title,
    required String artist,
    required bool requested,
  }) async {
    if (requested) {
      showInfo(context, context.l10n.catalogRequested);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(title),
        content: Text(context.l10n.tvCatalogRequestBy(artist)),
        actions: [
          TvButton(
            icon: Icons.download,
            label: context.l10n.catalogDownload,
            autofocus: true,
            onPressed: () => Navigator.pop(dialogContext, true),
          ),
          TvButton(
            icon: Icons.close,
            label: context.l10n.commonCancel,
            onPressed: () => Navigator.pop(dialogContext, false),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    try {
      final request = await ref.read(downloadActionsProvider).request(kind, catalogId);
      if (!context.mounted) return;
      showInfo(context, switch (request.status) {
        'pending_approval' => context.l10n.catalogAwaitingApproval(request.title),
        'done' => context.l10n.catalogAlreadyInLibrary(request.title),
        _ => context.l10n.catalogDownloadingTitle(request.title),
      });
    } catch (error) {
      if (context.mounted) showError(context, error);
    }
  }
}
