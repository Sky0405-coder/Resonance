import 'package:flutter/widgets.dart';

import '../l10n/locale.dart';
import '../l10n/l10n.dart';

import 'package:dio/dio.dart';

import 'models.dart';

class ApiException implements Exception {
  ApiException(this.message, [this.statusCode]);
  final String message;
  final int? statusCode;

  @override
  String toString() => message;

  static ApiException from(Object e, [AppLocalizations? localizations]) {
    final l10n =
        localizations ?? lookupAppLocalizations(resolveAppLocale(WidgetsBinding.instance.platformDispatcher.locales));
    if (e is ApiException) return e;
    if (e is DioException) {
      final data = e.response?.data;
      final detail = data is Map ? data['detail'] : null;
      final msg = switch (detail) {
        String s => s,
        List l when l.isNotEmpty => (l.first as Map)['msg']?.toString() ?? l10n.errorInvalidInput,
        _ =>
          e.response == null ? l10n.errorServerUnreachable : l10n.errorHttpStatus((e.response!.statusCode).toString()),
      };
      return ApiException(msg, e.response?.statusCode);
    }
    return ApiException(e.toString());
  }
}

/// Thin typed wrapper around the server's REST API.
class ApiClient {
  ApiClient(this.baseUrl, this.token, {this.languageCode = 'en'})
    : _dio = Dio(
        BaseOptions(
          baseUrl: baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
          headers: {'Accept-Language': languageCode, if (token != null) 'Authorization': 'Bearer $token'},
        ),
      );

  final String baseUrl;
  final String languageCode;
  final String? token;
  final Dio _dio;

  Future<T> _call<T>(Future<T> Function() fn) async {
    try {
      return await fn();
    } catch (e) {
      throw ApiException.from(e, lookupAppLocalizations(Locale(languageCode)));
    }
  }

  Future<dynamic> _get(String path, [Map<String, dynamic>? query]) =>
      _call(() async => (await _dio.get(path, queryParameters: query)).data);
  Future<dynamic> _post(String path, [Object? body]) => _call(() async => (await _dio.post(path, data: body)).data);
  Future<dynamic> _patch(String path, Object body) => _call(() async => (await _dio.patch(path, data: body)).data);
  Future<dynamic> _put(String path, [Object? body]) => _call(() async => (await _dio.put(path, data: body)).data);
  Future<dynamic> _delete(String path) => _call(() async => (await _dio.delete(path)).data);

  /// Keep the server response intact for the on-device collection cache.
  Future<dynamic> offlineCollection(String kind, String id) => _get(switch (kind) {
    'album' => '/api/albums/$id',
    'playlist' => '/api/playlists/$id',
    'liked' => '/api/me/likes/tracks',
    _ => throw ArgumentError.value(kind, 'kind'),
  });

  /// Uses the authenticated client, streaming directly to disk rather than buffering audio in memory.
  Future<void> downloadMedia(
    String url,
    String Function(String? contentType) destination, {
    CancelToken? cancelToken,
  }) => _call(() async {
    await _dio.download(
      url,
      (Headers headers) => destination(headers.value('content-type')),
      cancelToken: cancelToken,
      options: Options(receiveTimeout: const Duration(minutes: 10)),
    );
  });

  // --- media URLs (token in query so players/images work without headers) ---

  /// `auto` lets the server pass through natively playable files and transcode the rest.
  String streamUrl(String trackId, {String format = 'auto', int? bitrate}) =>
      '$baseUrl/api/tracks/$trackId/stream?format=$format${bitrate == null ? '' : '&bitrate=$bitrate'}&token=$token';

  String coverUrl(String albumId, {int size = 300}) => '$baseUrl/api/albums/$albumId/cover?size=$size&token=$token';

  // --- auth -----------------------------------------------------------------

  Future<AuthStatus> status() async => AuthStatus.fromJson(await _get('/api/auth/status'));

  Future<bool> checkInvite(String token) async => (await _get('/api/auth/invites/$token'))['valid'] as bool;

  Future<(String, User)> login(String username, String password, String device) async {
    final j = await _post('/api/auth/login', {'username': username, 'password': password, 'device_name': device});
    return (j['token'] as String, User.fromJson(j['user']));
  }

  Future<(String, User)> register(String username, String password, String device, {String? invite}) async {
    final j = await _post('/api/auth/register', {
      'username': username,
      'password': password,
      'device_name': device,
      'invite': ?invite,
    });
    return (j['token'] as String, User.fromJson(j['user']));
  }

  Future<void> logout() => _post('/api/auth/logout');

  Future<String> discordClientId() async => (await _get('/api/client-config'))['discord_client_id'] as String;

  // --- me -------------------------------------------------------------------

  Future<User> me() async => User.fromJson(await _get('/api/me'));

  Future<String> generateSubsonicPassword() async => (await _post('/api/me/subsonic-password'))['password'] as String;

  Future<void> removeSubsonicPassword() => _delete('/api/me/subsonic-password');

  Future<User> updateMe(Map<String, dynamic> patch) async => User.fromJson(await _patch('/api/me', patch));

  Future<List<Map<String, dynamic>>> sessions() async => [
    for (final s in await _get('/api/me/sessions')) Map<String, dynamic>.from(s),
  ];

  Future<void> revokeSession(String id) => _delete('/api/me/sessions/$id');

  Future<List<Track>> likedTracks() async => [for (final t in await _get('/api/me/likes/tracks')) Track.fromJson(t)];

  Future<void> setLiked(String trackId, bool liked) =>
      liked ? _put('/api/me/likes/tracks/$trackId') : _delete('/api/me/likes/tracks/$trackId');

  Future<void> setAlbumSaved(String albumId, bool saved) =>
      saved ? _put('/api/me/albums/$albumId') : _delete('/api/me/albums/$albumId');

  Future<void> reportPlay(String trackId, double seconds, {String? context}) =>
      _post('/api/me/plays', {'track_id': trackId, 'seconds_played': seconds, 'context': context});

  // --- library --------------------------------------------------------------

  Future<Home> home() async => Home.fromJson(await _get('/api/home'));

  Future<Lyrics> lyrics(String trackId) async => Lyrics.fromJson(await _get('/api/tracks/$trackId/lyrics'));

  Future<List<Album>> albums({String sort = 'recent', bool saved = false, int offset = 0, int limit = 200}) async {
    final j = await _get('/api/albums', {'sort': sort, 'saved': saved, 'offset': offset, 'limit': limit});
    return [for (final a in j['items']) Album.fromJson(a)];
  }

  Future<AlbumDetail> album(String id) async => AlbumDetail.fromJson(await _get('/api/albums/$id'));

  Future<List<Artist>> artists({int offset = 0, int limit = 500}) async {
    final j = await _get('/api/artists', {'offset': offset, 'limit': limit});
    return [for (final a in j['items']) Artist.fromJson(a)];
  }

  Future<ArtistDetail> artist(String id) async => ArtistDetail.fromJson(await _get('/api/artists/$id'));

  Future<SearchResult> search(String q) async => SearchResult.fromJson(await _get('/api/search', {'q': q}));

  // --- playlists ------------------------------------------------------------

  Future<List<Playlist>> playlists() async => [for (final p in await _get('/api/playlists')) Playlist.fromJson(p)];

  Future<PlaylistDetail> playlist(String id) async => PlaylistDetail.fromJson(await _get('/api/playlists/$id'));

  Future<Playlist> createPlaylist(String name, {String? description}) async =>
      Playlist.fromJson(await _post('/api/playlists', {'name': name, 'description': description}));

  Future<void> updatePlaylist(String id, Map<String, dynamic> patch) => _patch('/api/playlists/$id', patch);

  Future<void> deletePlaylist(String id) => _delete('/api/playlists/$id');

  Future<void> setPlaylistShares(String id, List<String> userIds) =>
      _put('/api/playlists/$id/shares', {'user_ids': userIds});

  /// Other (active) users of this server, e.g. to share a playlist with.
  Future<List<NamedRef>> otherUsers() async => [for (final u in await _get('/api/users')) NamedRef.fromJson(u)];

  /// Catalog id of a library album (to download its missing songs).
  Future<String> albumCatalogId(String albumId) async =>
      (await _get('/api/library/albums/$albumId/catalog'))['catalog_id'] as String;

  /// Catalog songs of a library album that are not in the library: (catalog album id, songs).
  Future<(String, List<CatalogTrack>)> albumMissing(String albumId) async {
    final j = await _get('/api/library/albums/$albumId/missing');
    return (j['catalog_id'] as String, [for (final t in j['tracks']) CatalogTrack.fromJson(t)]);
  }

  /// Builds (or reuses) a radio for a library song or album: (radio playlist, number of requested downloads).
  Future<(Playlist, int)> startRadio(String seedType, String id) async {
    final j = await _post('/api/radio', {'seed_type': seedType, 'id': id});
    return (Playlist.fromJson(j['playlist']), j['requested'] as int);
  }

  /// Radio: turns it into a normal playlist. Mix: creates a dated normal copy. Returns the normal playlist.
  Future<Playlist> keepPlaylist(String playlistId) async =>
      Playlist.fromJson(await _post('/api/playlists/$playlistId/keep'));

  /// Generated playlists of the current user: (made for you, genre mixes).
  Future<(List<Playlist>, List<Playlist>)> mixes() async {
    final j = await _get('/api/mixes');
    return (
      [for (final p in j['made_for_you']) Playlist.fromJson(p)],
      [for (final p in j['genres']) Playlist.fromJson(p)],
    );
  }

  Future<void> deleteLibraryTrack(String id) => _delete('/api/admin/library/tracks/$id');

  Future<void> deleteLibraryAlbum(String id) => _delete('/api/admin/library/albums/$id');

  Future<void> addToPlaylist(String id, List<String> trackIds) =>
      _post('/api/playlists/$id/tracks', {'track_ids': trackIds});

  Future<void> removeFromPlaylist(String id, String entryId) => _delete('/api/playlists/$id/entries/$entryId');

  Future<void> moveInPlaylist(String id, String entryId, String? beforeEntryId) =>
      _post('/api/playlists/$id/move', {'entry_id': entryId, 'before_entry_id': beforeEntryId});

  // --- catalog & requests ---------------------------------------------------

  Future<CatalogSearch> catalogSearch(String q, {int limit = 10}) async =>
      CatalogSearch.fromJson(await _get('/api/catalog/search', {'q': q, 'limit': limit}));

  Future<CatalogArtistDetail> catalogArtist(String id) async =>
      CatalogArtistDetail.fromJson(await _get('/api/catalog/artists/$id'));

  Future<CatalogAlbumDetail> catalogAlbum(String id) async =>
      CatalogAlbumDetail.fromJson(await _get('/api/catalog/albums/$id'));

  /// [catalogId] is the catalog (Deezer) id of the track or album.
  Future<DownloadRequest> createRequest(String kind, String catalogId) async =>
      DownloadRequest.fromJson(await _post('/api/requests', {'kind': kind, 'id': catalogId}));

  Future<DownloadRequest> redownload(String trackId, {String? youtubeUrl}) async =>
      DownloadRequest.fromJson(await _post('/api/tracks/$trackId/redownload', {'youtube_url': youtubeUrl}));

  Future<List<DownloadRequest>> requests({String scope = 'mine', String state = 'all', int limit = 100}) async {
    final j = await _get('/api/requests', {'scope': scope, 'state': state, 'limit': limit});
    return [for (final r in j['items']) DownloadRequest.fromJson(r)];
  }

  Future<DownloadRequest> request(String id) async => DownloadRequest.fromJson(await _get('/api/requests/$id'));

  Future<DownloadSummary> downloadSummary() async => DownloadSummary.fromJson(await _get('/api/requests/summary'));

  /// [action] is one of approve, cancel, retry.
  Future<void> requestAction(String id, String action) => _post('/api/requests/$id/$action');

  Future<void> rejectRequest(String id, {String? note}) => _post('/api/requests/$id/reject', {'note': note});

  Future<void> deleteRequest(String id) => _delete('/api/requests/$id');

  // --- admin ----------------------------------------------------------------

  Future<Map<String, dynamic>> adminConfig() async => Map<String, dynamic>.from(await _get('/api/admin/config'));

  Future<Map<String, dynamic>> patchAdminConfig(Map<String, dynamic> patch) async =>
      Map<String, dynamic>.from(await _patch('/api/admin/config', patch));

  Future<List<User>> users() async => [for (final u in await _get('/api/admin/users')) User.fromJson(u)];

  Future<User> updateUser(String id, Map<String, dynamic> patch) async =>
      User.fromJson(await _patch('/api/admin/users/$id', patch));

  Future<void> deleteUser(String id) => _delete('/api/admin/users/$id');

  Future<List<Invite>> invites() async => [for (final i in await _get('/api/admin/invites')) Invite.fromJson(i)];

  Future<Invite> createInvite({String? note, String role = 'user', int? expiresInHours = 72}) async => Invite.fromJson(
    await _post('/api/admin/invites', {'note': note, 'role': role, 'expires_in_hours': expiresInHours}),
  );

  Future<void> deleteInvite(String id) => _delete('/api/admin/invites/$id');

  Future<LibraryStats> libraryStats() async => LibraryStats.fromJson(await _get('/api/admin/library/stats'));

  Future<Job> startScan({bool full = false}) async => Job.fromJson(
    await _call(() async => (await _dio.post('/api/admin/library/scan', queryParameters: {'full': full})).data),
  );

  Future<ImportInfo> importInfo() async => ImportInfo.fromJson(await _get('/api/admin/imports/info'));

  Future<List<ImportBatch>> importBatches() async => [
    for (final b in await _get('/api/admin/imports')) ImportBatch.fromJson(b),
  ];

  /// [kind] is `import` (import folder) or `cleanup` (library in place).
  Future<ImportBatch> startImport(String kind) async =>
      ImportBatch.fromJson(await _post('/api/admin/imports', {'kind': kind}));

  Future<void> cancelImport(String id) => _post('/api/admin/imports/$id/cancel');

  Future<List<ImportFile>> importFiles(String batchId, {String? status, int limit = 200}) async {
    final j = await _get('/api/admin/imports/$batchId/files', {'status': ?status, 'limit': limit});
    return [for (final f in j['items']) ImportFile.fromJson(f)];
  }

  Future<Map<String, dynamic>> torrentStatus() async =>
      Map<String, dynamic>.from(await _get('/api/admin/torrents/status'));

  Future<void> runQualityUpgrades() => _post('/api/admin/upgrades/run');

  // --- Audiobookshelf (proxied by the server, see /api/abs) ---------------

  Future<Map<String, dynamic>> absStatus() async => Map<String, dynamic>.from(await _get('/api/abs/status'));

  Future<void> absLogin(String username, String password) =>
      _post('/api/abs/login', {'username': username, 'password': password});

  Future<Map<String, dynamic>> absAdminStatus() async => Map<String, dynamic>.from(await _get('/api/admin/abs/status'));

  Future<void> absLogout() => _delete('/api/abs/login');

  /// Raw Audiobookshelf API call; [path] is relative to ABS's `/api/`, e.g. `libraries`.
  Future<dynamic> absGet(String path, [Map<String, dynamic>? query]) => _get('/api/abs/api/$path', query);

  Future<dynamic> absPost(String path, [Object? body]) => _post('/api/abs/api/$path', body);

  Future<dynamic> absPatch(String path, Object body) => _patch('/api/abs/api/$path', body);

  /// URL for media (covers, audio files) with the token in the query string.
  String absUrl(String path, [Map<String, String> query = const {}]) {
    final q = {...query, 'token': ?token};
    return '$baseUrl/api/abs/api/$path?${Uri(queryParameters: q).query}';
  }

  // --- app updates (Android) ------------------------------------------------

  /// Latest APK uploaded to the server, or null if there is none.
  Future<({String versionName, int versionCode})?> androidRelease() async {
    try {
      final j = await _get('/api/app/android');
      return (versionName: j['version_name'] as String, versionCode: j['version_code'] as int);
    } on ApiException catch (e) {
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  String get androidApkUrl => '$baseUrl/api/app/android/apk?token=$token';

  // --- Spotify import ----------------------------------------------------------

  Future<Map<String, dynamic>> spotifyStatus() async => Map<String, dynamic>.from(await _get('/api/spotify/status'));

  Future<String> spotifyLoginUrl() async => (await _get('/api/spotify/login'))['url'] as String;

  Future<void> spotifyDisconnect() => _delete('/api/spotify/login');

  Future<Map<String, dynamic>> spotifyPlaylists() async =>
      Map<String, dynamic>.from(await _get('/api/spotify/playlists'));

  Future<Map<String, dynamic>> startSpotifyImport({
    required bool liked,
    required List<String> playlistIds,
    required bool downloadMissing,
    List<String> links = const [],
  }) async => Map<String, dynamic>.from(
    await _post('/api/spotify/imports', {
      'liked': liked,
      'playlist_ids': playlistIds,
      'links': links,
      'download_missing': downloadMissing,
    }),
  );

  Future<List<Map<String, dynamic>>> spotifyImports() async => [
    for (final i in await _get('/api/spotify/imports')) Map<String, dynamic>.from(i),
  ];

  Future<Map<String, dynamic>> spotifyImport(String id) async =>
      Map<String, dynamic>.from(await _get('/api/spotify/imports/$id'));

  // --- metadata editor (admin) -----------------------------------------------

  Future<TrackFile> trackFile(String trackId) async =>
      TrackFile.fromJson(await _get('/api/admin/library/tracks/$trackId/file'));

  Future<List<FingerprintMatch>> trackFingerprint(String trackId) async => [
    for (final m in await _get('/api/admin/library/tracks/$trackId/fingerprint')) FingerprintMatch.fromJson(m),
  ];

  /// [body] is one of `{source: deezer, deezer_id}`, `{source: musicbrainz, recording_id, release_id?}`,
  /// `{source: manual, meta: {...}}`.
  Future<Track> matchTrack(String trackId, Map<String, dynamic> body) async =>
      Track.fromJson(await _post('/api/admin/library/tracks/$trackId/match', body));

  Future<AlbumMatchResult> matchAlbum(String albumId, String source, String id) async =>
      AlbumMatchResult.fromJson(await _post('/api/admin/library/albums/$albumId/match', {'source': source, 'id': id}));

  Future<List<CoverOption>> coverOptions(String albumId) async => [
    for (final o in await _get('/api/admin/library/albums/$albumId/cover-options')) CoverOption.fromJson(o),
  ];

  Future<void> setCoverFromUrl(String albumId, String url) =>
      _post('/api/admin/library/albums/$albumId/cover', {'url': url});

  Future<void> uploadCover(String albumId, List<int> bytes, String filename) => _post(
    '/api/admin/library/albums/$albumId/cover',
    FormData.fromMap({'file': MultipartFile.fromBytes(bytes, filename: filename)}),
  );

  Future<(List<ReviewTrack>, int)> review({String kind = 'unidentified', int offset = 0, int limit = 50}) async {
    final j = await _get('/api/admin/library/review', {'kind': kind, 'offset': offset, 'limit': limit});
    return ([for (final t in j['items']) ReviewTrack.fromJson(t)], j['total'] as int);
  }

  Future<List<Job>> jobs() async => [for (final j in await _get('/api/admin/jobs')) Job.fromJson(j)];
}
