import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../core/api.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/session.dart';
import '../l10n/l10n.dart';
import '../l10n/locale.dart';
import '../offline/offline_store.dart';
import 'player.dart';

final audioHandlerProvider = Provider<ResonanceAudioHandler?>((ref) => null);

class ResonanceAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  ResonanceAudioHandler(this.container) {
    _subscriptions.add(_controller.engine.playbackEventStream.listen((_) => _publishState()));
    _subscriptions.add(_controller.engine.playerStateStream.listen((_) => _publishState()));
    _playerSubscription = container.listen(playerProvider, (_, _) => _publish(), fireImmediately: true);
    _offlineSubscription = container.listen(offlineProvider, (_, _) => _publish());
    _localeSubscription = container.listen(appLocaleProvider, (_, _) => _publish());
  }

  final ProviderContainer container;
  final List<StreamSubscription> _subscriptions = [];
  late final ProviderSubscription<PlayerView> _playerSubscription;
  late final ProviderSubscription<OfflineState> _offlineSubscription;
  late final ProviderSubscription<Object> _localeSubscription;
  final Map<String, MediaItem> _items = {};
  final Map<String, List<Track>> _searchResults = {};

  PlayerController get _controller => container.read(playerProvider.notifier);
  PlayerView get _view => container.read(playerProvider);
  ApiClient get _api => container.read(apiProvider);
  OfflineState get _offline => container.read(offlineProvider);
  AppLocalizations get _l10n => lookupAppLocalizations(container.read(appLocaleProvider));

  Uri _cover(String albumId) {
    final file = _offline.coverPath(albumId);
    return file == null ? Uri.parse(_api.coverUrl(albumId, size: 600)) : Uri.file(file);
  }

  MediaItem _trackItem(Track track, String id) => MediaItem(
    id: id,
    title: track.title,
    artist: track.artistCredit,
    displaySubtitle: track.artistCredit,
    album: track.album.name,
    duration: track.length,
    artUri: _cover(track.album.id),
  );

  MediaItem _stationItem(Station station) => MediaItem(
    id: 'station:${station.id}',
    title: station.name,
    artist: _l10n.worldRadioTitle,
    displaySubtitle: _l10n.worldRadioTitle,
    artUri: station.favicon == null ? null : Uri.parse(station.favicon!),
  );

  void _publish() {
    final view = _view;
    final book = view.book;
    final items = view.station != null
        ? [_stationItem(view.station!)]
        : book == null
        ? [for (final track in view.queue) _trackItem(track, track.id)]
        : [
            for (final (index, part) in book.parts.indexed)
              MediaItem(
                id: '${book.itemId}:$index',
                title: book.title,
                artist: book.author,
                album: book.parts.length > 1 ? _l10n.playerBookPart(index + 1, book.parts.length) : null,
                duration: Duration(milliseconds: (part.duration * 1000).round()),
                artUri: Uri.parse(book.coverUrl),
              ),
          ];
    queue.add(items);
    final index = view.index;
    mediaItem.add(index != null && index >= 0 && index < items.length ? items[index] : null);
    _publishState();
  }

  void _publishState() {
    final view = _view;
    final engine = _controller.engine;
    playbackState.add(
      PlaybackState(
        controls: view.station != null
            ? [engine.playing ? MediaControl.pause : MediaControl.play, MediaControl.stop]
            : [
                MediaControl.skipToPrevious,
                engine.playing ? MediaControl.pause : MediaControl.play,
                MediaControl.skipToNext,
              ],
        systemActions: {
          if (view.station == null) MediaAction.seek,
          if (view.book != null) ...{MediaAction.seekForward, MediaAction.seekBackward},
        },
        androidCompactActionIndices: view.station == null ? const [0, 1, 2] : const [0, 1],
        processingState: switch (engine.processingState) {
          ProcessingState.idle => AudioProcessingState.idle,
          ProcessingState.loading => AudioProcessingState.loading,
          ProcessingState.buffering => AudioProcessingState.buffering,
          ProcessingState.ready => AudioProcessingState.ready,
          ProcessingState.completed => AudioProcessingState.completed,
        },
        playing: engine.playing,
        updatePosition: engine.position,
        bufferedPosition: engine.bufferedPosition,
        speed: engine.speed,
        queueIndex: view.index,
        shuffleMode: view.shuffle ? AudioServiceShuffleMode.all : AudioServiceShuffleMode.none,
        repeatMode: switch (view.loop) {
          LoopMode.off => AudioServiceRepeatMode.none,
          LoopMode.one => AudioServiceRepeatMode.one,
          LoopMode.all => AudioServiceRepeatMode.all,
        },
      ),
    );
  }

  @override
  Future<void> play() => _controller.play();

  @override
  Future<void> pause() => _controller.pause();

  @override
  Future<void> stop() async {
    await _controller.stop();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) => _controller.seek(position);

  @override
  Future<void> skipToNext() => _controller.next();

  @override
  Future<void> skipToPrevious() => _controller.previous();

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index >= 0 && index < queue.value.length) await _controller.jumpTo(index);
  }

  @override
  Future<void> setShuffleMode(AudioServiceShuffleMode shuffleMode) =>
      _controller.setShuffle(shuffleMode != AudioServiceShuffleMode.none);

  @override
  Future<void> setRepeatMode(AudioServiceRepeatMode repeatMode) => _controller.setLoop(switch (repeatMode) {
    AudioServiceRepeatMode.none => LoopMode.off,
    AudioServiceRepeatMode.one => LoopMode.one,
    AudioServiceRepeatMode.all || AudioServiceRepeatMode.group => LoopMode.all,
  });

  @override
  Future<void> fastForward() async {
    if (_view.book != null) await _controller.skipBook(30);
  }

  @override
  Future<void> rewind() async {
    if (_view.book != null) await _controller.skipBook(-30);
  }

  @override
  Future<void> setSpeed(double speed) => _controller.setSpeed(speed);

  MediaItem _folder(String id, String title, {String? subtitle, Uri? artUri}) =>
      MediaItem(id: id, title: title, artist: subtitle, displaySubtitle: subtitle, artUri: artUri, playable: false);

  MediaItem _playlist(Playlist playlist) => _folder(
    'playlist:${playlist.id}',
    playlist.name,
    subtitle: playlist.owner.name,
    artUri: playlist.coverKey != null
        ? Uri.parse(_api.playlistCoverUrl(playlist.id, playlist.coverKey!))
        : playlist.coverAlbumIds.isEmpty
        ? null
        : _cover(playlist.coverAlbumIds.first),
  );

  MediaItem _album(Album album) => _folder(
    'album:${album.id}',
    album.title,
    subtitle: album.artist.name,
    artUri: album.hasCover ? _cover(album.id) : null,
  );

  List<MediaItem> _offlineCollections([String? kind]) => [
    for (final collection in _offline.collections.values)
      if (kind == null || collection.kind == kind)
        _folder(
          collection.key,
          collection.kind == 'liked' ? _l10n.libraryLikedSongs : collection.name,
          subtitle: switch (collection.kind) {
            'album' => AlbumDetail.fromJson(collection.data).album.artist.name,
            'playlist' => PlaylistDetail.fromJson(collection.data).playlist.owner.name,
            _ => container.read(sessionProvider).user?.displayName,
          },
          artUri: collection.orderedTracks.isEmpty ? null : _cover(collection.orderedTracks.first.album.id),
        ),
  ];

  List<Track> _offlineTracks(String collection) => [
    for (final track in _offline.collections[collection]?.orderedTracks ?? <Track>[])
      if (_offline.isDownloaded(track.id)) track,
  ];

  Future<List<Track>> _tracks(String collection) async {
    if (collection.startsWith('search:')) return _searchResults[collection] ?? [];
    if (container.read(sessionProvider).offline) return _offlineTracks(collection);
    try {
      if (collection == 'liked') return await container.read(likedTracksProvider.future);
      final parts = collection.split(':');
      if (parts.length != 2) return [];
      return switch (parts.first) {
        'album' => (await container.read(albumProvider(parts[1]).future)).tracks,
        'playlist' || 'mix' => [
          for (final entry in (await container.read(playlistDetailProvider(parts[1]).future)).entries) entry.track,
        ],
        _ => [],
      };
    } catch (_) {
      return _offlineTracks(collection);
    }
  }

  List<MediaItem> _trackItems(List<Track> tracks, String collection) => [
    for (final track in tracks) _trackItem(track, 'track:$collection:${track.id}'),
  ];

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    try {
      final items = await _children(parentMediaId);
      for (final item in items) {
        _items[item.id] = item;
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  Future<List<MediaItem>> _children(String id) async {
    if (id == AudioService.recentRootId) return [];
    if (id == AudioService.browsableRootId) {
      return [
        _folder('home', _l10n.audioBrowseHome),
        _folder('playlists', _l10n.libraryPlaylists),
        _folder('liked', _l10n.libraryLikedSongs),
        _folder('albums', _l10n.commonAlbums),
        _folder('world-radio', _l10n.worldRadioTitle),
        if (_offline.collections.isNotEmpty) _folder('downloads', _l10n.offlineDownloaded),
      ];
    }
    if (id == 'world-radio') {
      return [for (final station in await container.read(worldRadioFavoritesProvider.future)) _stationItem(station)];
    }
    if (id == 'downloads') return _offlineCollections();
    if (id == 'home' || id == 'playlists' || id == 'albums') {
      if (container.read(sessionProvider).offline) {
        return _offlineCollections(
          id == 'playlists'
              ? 'playlist'
              : id == 'albums'
              ? 'album'
              : null,
        );
      }
      try {
        if (id == 'playlists') {
          return [for (final playlist in await container.read(playlistsProvider.future)) _playlist(playlist)];
        }
        if (id == 'albums') {
          return [for (final album in await container.read(savedAlbumsProvider.future)) _album(album)];
        }
        final mixes = await container.read(mixesProvider.future);
        final home = await container.read(homeProvider.future);
        final seen = <String>{};
        return [
          for (final playlist in [...?mixes?.$1, ...home.playlists, ...?mixes?.$2])
            if (playlist.trackCount > 0 && seen.add(playlist.id)) _playlist(playlist),
        ].take(20).toList();
      } catch (_) {
        return _offlineCollections(
          id == 'playlists'
              ? 'playlist'
              : id == 'albums'
              ? 'album'
              : null,
        );
      }
    }
    return _trackItems(await _tracks(id), id);
  }

  @override
  Future<MediaItem?> getMediaItem(String mediaId) async {
    try {
      if (_items.containsKey(mediaId)) return _items[mediaId];
      final queued = queue.value.where((item) => item.id == mediaId).firstOrNull;
      if (queued != null) return queued;
      if (mediaId.startsWith('station:')) {
        return (await getChildren('world-radio')).where((item) => item.id == mediaId).firstOrNull;
      }
      if (mediaId.startsWith('track:')) {
        final end = mediaId.lastIndexOf(':');
        final collection = mediaId.substring(6, end);
        return (await getChildren(collection)).where((item) => item.id == mediaId).firstOrNull;
      }
      if (mediaId.startsWith('playlist:') || mediaId.startsWith('mix:')) {
        final id = mediaId.split(':')[1];
        try {
          return _playlist((await container.read(playlistDetailProvider(id).future)).playlist).copyWith(id: mediaId);
        } catch (_) {
          return _offlineCollections('playlist').where((item) => item.id == 'playlist:$id').firstOrNull;
        }
      }
      if (mediaId.startsWith('album:')) {
        try {
          return _album((await container.read(albumProvider(mediaId.substring(6)).future)).album);
        } catch (_) {
          return _offlineCollections('album').where((item) => item.id == mediaId).firstOrNull;
        }
      }
      return (await getChildren(AudioService.browsableRootId)).where((item) => item.id == mediaId).firstOrNull;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    try {
      if (mediaId.startsWith('station:')) {
        final id = mediaId.substring(8);
        final station = (await container.read(worldRadioFavoritesProvider.future)).where((s) => s.id == id).firstOrNull;
        if (station != null) await _controller.playStation(station);
        return;
      }
      var collection = mediaId;
      String? trackId;
      if (mediaId.startsWith('track:')) {
        final end = mediaId.lastIndexOf(':');
        collection = mediaId.substring(6, end);
        trackId = mediaId.substring(end + 1);
      }
      final tracks = await _tracks(collection);
      final index = trackId == null ? 0 : tracks.indexWhere((track) => track.id == trackId);
      if (tracks.isEmpty || index < 0) return;
      final context = collection.startsWith('mix:')
          ? collection.replaceFirst('mix:', 'playlist:')
          : collection.startsWith('search:')
          ? 'search'
          : collection;
      await _controller.playTracks(tracks, index: index, context: context);
    } catch (_) {
      // Browse and voice clients must tolerate unavailable or empty collections.
    }
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    try {
      if (query.trim().isEmpty) return [];
      List<Track> tracks;
      try {
        if (container.read(sessionProvider).offline) throw StateError('offline');
        tracks = (await container.read(searchProvider(query).future)).tracks;
      } catch (_) {
        final seen = <String>{};
        final term = query.toLowerCase();
        tracks = [
          for (final collection in _offline.collections.values)
            for (final track in collection.orderedTracks)
              if (_offline.isDownloaded(track.id) &&
                  '${track.title} ${track.artistCredit} ${track.album.name}'.toLowerCase().contains(term) &&
                  seen.add(track.id))
                track,
        ];
      }
      final collection = 'search:${Uri.encodeComponent(query)}';
      _searchResults[collection] = tracks;
      final items = _trackItems(tracks, collection);
      for (final item in items) {
        _items[item.id] = item;
      }
      return items;
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> playFromSearch(String query, [Map<String, dynamic>? extras]) async {
    try {
      if (query.trim().isEmpty) {
        if (_view.current != null || _view.book != null || _view.station != null) {
          _controller.play().ignore();
        } else {
          final tracks = await _tracks('liked');
          if (tracks.isEmpty) return;
          await _controller.setShuffle(true);
          await _controller.playTracks(tracks, context: 'liked');
        }
        return;
      }
      final items = await search(query, extras);
      if (items.isNotEmpty) await playFromMediaId(items.first.id);
    } catch (_) {
      // Voice search has no results while the library is unavailable.
    }
  }

  void dispose() {
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _playerSubscription.close();
    _offlineSubscription.close();
    _localeSubscription.close();
  }
}
