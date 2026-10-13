// Plain data classes mirroring the server's JSON (see backend/app/schemas.py).

DateTime? _date(dynamic v) => v == null ? null : DateTime.parse(v as String);

class NamedRef {
  const NamedRef(this.id, this.name);
  final String id;
  final String name;

  factory NamedRef.fromJson(Map<String, dynamic> j) => NamedRef(j['id'] as String, (j['name'] ?? j['title']) as String);
}

class User {
  const User({
    required this.id,
    required this.username,
    required this.displayName,
    required this.role,
    required this.accentColor,
    required this.isDisabled,
    required this.createdAt,
    this.lastSeenAt,
  });

  final String id;
  final String username;
  final String displayName;
  final String role;
  final String accentColor;
  final bool isDisabled;
  final DateTime createdAt;
  final DateTime? lastSeenAt;

  bool get isAdmin => role == 'admin';

  factory User.fromJson(Map<String, dynamic> j) => User(
    id: j['id'],
    username: j['username'],
    displayName: j['display_name'],
    role: j['role'],
    accentColor: j['accent_color'],
    isDisabled: j['is_disabled'] ?? false,
    createdAt: DateTime.parse(j['created_at']),
    lastSeenAt: _date(j['last_seen_at']),
  );
}

class Track {
  const Track({
    required this.id,
    required this.title,
    required this.artist,
    required this.artistCredit,
    required this.album,
    required this.duration,
    this.trackNo,
    this.discNo,
    this.codec,
    this.bitrate,
    this.replayGainTrack,
    this.replayGainAlbum,
    this.liked = false,
  });

  final String id;
  final String title;
  final NamedRef artist;
  final String artistCredit;
  final NamedRef album;
  final double duration;
  final int? trackNo;
  final int? discNo;
  final String? codec;
  final int? bitrate;
  final double? replayGainTrack;
  final double? replayGainAlbum;
  final bool liked;

  Duration get length => Duration(milliseconds: (duration * 1000).round());

  Track copyWith({bool? liked}) => Track(
    id: id,
    title: title,
    artist: artist,
    artistCredit: artistCredit,
    album: album,
    duration: duration,
    trackNo: trackNo,
    discNo: discNo,
    codec: codec,
    bitrate: bitrate,
    replayGainTrack: replayGainTrack,
    replayGainAlbum: replayGainAlbum,
    liked: liked ?? this.liked,
  );

  factory Track.fromJson(Map<String, dynamic> j) => Track(
    id: j['id'],
    title: j['title'],
    artist: NamedRef.fromJson(j['artist']),
    artistCredit: j['artist_credit'],
    album: NamedRef.fromJson(j['album']),
    duration: (j['duration'] as num).toDouble(),
    trackNo: j['track_no'],
    discNo: j['disc_no'],
    codec: j['codec'],
    bitrate: j['bitrate'],
    replayGainTrack: (j['replaygain_track_gain'] as num?)?.toDouble(),
    replayGainAlbum: (j['replaygain_album_gain'] as num?)?.toDouble(),
    liked: j['liked'] ?? false,
  );
}

class Album {
  const Album({
    required this.id,
    required this.title,
    required this.artist,
    required this.hasCover,
    required this.trackCount,
    this.year,
    this.genre,
  });

  final String id;
  final String title;
  final NamedRef artist;
  final int? year;
  final String? genre;
  final bool hasCover;
  final int trackCount;

  factory Album.fromJson(Map<String, dynamic> j) => Album(
    id: j['id'],
    title: j['title'],
    artist: NamedRef.fromJson(j['artist']),
    year: j['year'],
    genre: j['genre'],
    hasCover: j['has_cover'] ?? false,
    trackCount: j['track_count'] ?? 0,
  );
}

class AlbumDetail {
  const AlbumDetail(this.album, this.tracks, this.duration, this.saved);
  final Album album;
  final List<Track> tracks;
  final double duration;
  final bool saved;

  factory AlbumDetail.fromJson(Map<String, dynamic> j) => AlbumDetail(
    Album.fromJson(j),
    [for (final t in j['tracks']) Track.fromJson(t)],
    (j['duration'] as num).toDouble(),
    j['saved'] ?? false,
  );
}

class Artist {
  const Artist({required this.id, required this.name, required this.albumCount, this.coverAlbumId});
  final String id;
  final String name;
  final int albumCount;
  final String? coverAlbumId;

  factory Artist.fromJson(Map<String, dynamic> j) =>
      Artist(id: j['id'], name: j['name'], albumCount: j['album_count'] ?? 0, coverAlbumId: j['cover_album_id']);
}

class ArtistDetail {
  const ArtistDetail(this.artist, this.albums, this.topTracks);
  final Artist artist;
  final List<Album> albums;
  final List<Track> topTracks;

  factory ArtistDetail.fromJson(Map<String, dynamic> j) => ArtistDetail(
    Artist.fromJson(j),
    [for (final a in j['albums']) Album.fromJson(a)],
    [for (final t in j['top_tracks']) Track.fromJson(t)],
  );
}

class Playlist {
  const Playlist({
    required this.id,
    required this.name,
    required this.isPublic,
    required this.owner,
    required this.trackCount,
    required this.duration,
    required this.coverAlbumIds,
    this.description,
  });

  final String id;
  final String name;
  final String? description;
  final bool isPublic;
  final NamedRef owner;
  final int trackCount;
  final double duration;
  final List<String> coverAlbumIds;

  factory Playlist.fromJson(Map<String, dynamic> j) => Playlist(
    id: j['id'],
    name: j['name'],
    description: j['description'],
    isPublic: j['is_public'],
    owner: NamedRef.fromJson(j['owner']),
    trackCount: j['track_count'] ?? 0,
    duration: (j['duration'] as num? ?? 0).toDouble(),
    coverAlbumIds: [for (final id in j['cover_album_ids'] ?? const []) id as String],
  );
}

class PlaylistEntry {
  const PlaylistEntry(this.entryId, this.track);
  final String entryId;
  final Track track;
}

class PlaylistDetail {
  const PlaylistDetail(this.playlist, this.entries, this.editable);
  final Playlist playlist;
  final List<PlaylistEntry> entries;
  final bool editable;

  factory PlaylistDetail.fromJson(Map<String, dynamic> j) => PlaylistDetail(
    Playlist.fromJson(j),
    [for (final e in j['entries']) PlaylistEntry(e['entry_id'], Track.fromJson(e['track']))],
    j['editable'] ?? false,
  );
}

class Home {
  const Home(this.recentlyPlayed, this.recentlyAdded, this.playlists, this.mostPlayed);
  final List<Album> recentlyPlayed;
  final List<Album> recentlyAdded;
  final List<Playlist> playlists;
  final List<Track> mostPlayed;

  factory Home.fromJson(Map<String, dynamic> j) => Home(
    [for (final a in j['recently_played']) Album.fromJson(a)],
    [for (final a in j['recently_added']) Album.fromJson(a)],
    [for (final p in j['playlists']) Playlist.fromJson(p)],
    [for (final t in j['most_played']) Track.fromJson(t)],
  );
}

class SearchResult {
  const SearchResult(this.artists, this.albums, this.tracks);
  final List<Artist> artists;
  final List<Album> albums;
  final List<Track> tracks;

  bool get isEmpty => artists.isEmpty && albums.isEmpty && tracks.isEmpty;

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
    [for (final a in j['artists']) Artist.fromJson(a)],
    [for (final a in j['albums']) Album.fromJson(a)],
    [for (final t in j['tracks']) Track.fromJson(t)],
  );
}

class Invite {
  const Invite({
    required this.id,
    required this.role,
    required this.createdAt,
    this.note,
    this.expiresAt,
    this.usedAt,
    this.usedBy,
    this.token,
  });

  final String id;
  final String? note;
  final String role;
  final DateTime createdAt;
  final DateTime? expiresAt;
  final DateTime? usedAt;
  final String? usedBy;
  // Only present right after creation.
  final String? token;

  bool get isUsed => usedAt != null;
  bool get isExpired => expiresAt != null && expiresAt!.isBefore(DateTime.now());

  factory Invite.fromJson(Map<String, dynamic> j) => Invite(
    id: j['id'],
    note: j['note'],
    role: j['role'],
    createdAt: DateTime.parse(j['created_at']),
    expiresAt: _date(j['expires_at']),
    usedAt: _date(j['used_at']),
    usedBy: j['used_by_username'],
    token: j['token'],
  );
}

class Job {
  const Job(this.id, this.kind, this.status, this.progress, this.message, this.createdAt);
  final String id;
  final String kind;
  final String status;
  final double progress;
  final String? message;
  final DateTime createdAt;

  bool get isActive => status == 'queued' || status == 'running';

  factory Job.fromJson(Map<String, dynamic> j) => Job(
    j['id'],
    j['kind'],
    j['status'],
    (j['progress'] as num).toDouble(),
    j['message'],
    DateTime.parse(j['created_at']),
  );
}

class LibraryStats {
  const LibraryStats(this.artists, this.albums, this.tracks, this.totalBytes, this.totalSeconds);
  final int artists;
  final int albums;
  final int tracks;
  final int totalBytes;
  final double totalSeconds;

  factory LibraryStats.fromJson(Map<String, dynamic> j) => LibraryStats(
    j['artists'],
    j['albums'],
    j['tracks'],
    j['total_bytes'],
    (j['total_seconds'] as num).toDouble(),
  );
}

class AuthStatus {
  const AuthStatus(this.serverName, this.setupRequired, this.registrationMode);
  final String serverName;
  final bool setupRequired;
  final String registrationMode;

  factory AuthStatus.fromJson(Map<String, dynamic> j) =>
      AuthStatus(j['server_name'], j['setup_required'], j['registration_mode']);
}

// --- catalog (MusicBrainz) & download requests -------------------------------

class CatalogArtist {
  const CatalogArtist({required this.id, required this.name, this.pictureUrl, this.libraryId});
  final String id;
  final String name;
  final String? pictureUrl;
  final String? libraryId;

  factory CatalogArtist.fromJson(Map<String, dynamic> j) =>
      CatalogArtist(id: j['id'], name: j['name'], pictureUrl: j['picture_url'], libraryId: j['library_id']);
}

class CatalogAlbum {
  const CatalogAlbum({
    required this.id,
    required this.title,
    required this.artist,
    this.artistId,
    this.recordType,
    this.year,
    this.coverUrl,
    this.coverBigUrl,
    this.libraryId,
  });
  final String id;
  final String title;
  final String artist;
  final String? artistId;
  final String? recordType;
  final int? year;
  final String? coverUrl;
  final String? coverBigUrl;
  final String? libraryId;

  /// German label for Deezer's record type.
  String get typeLabel => switch (recordType) {
    'ep' => 'EP',
    'single' => 'Single',
    'compile' => 'Compilation',
    _ => 'Album',
  };

  factory CatalogAlbum.fromJson(Map<String, dynamic> j) => CatalogAlbum(
    id: j['id'],
    title: j['title'],
    artist: j['artist'],
    artistId: j['artist_id'],
    recordType: j['record_type'],
    year: j['year'],
    coverUrl: j['cover_url'],
    coverBigUrl: j['cover_big_url'],
    libraryId: j['library_id'],
  );
}

class CatalogTrack {
  const CatalogTrack({
    required this.id,
    required this.title,
    required this.artist,
    this.artistId,
    this.album,
    this.albumId,
    this.coverUrl,
    this.duration,
    this.isrc,
    this.previewUrl,
    this.discNo,
    this.trackNo,
    this.libraryId,
  });
  final String id;
  final String title;
  final String artist;
  final String? artistId;
  final String? album;
  final String? albumId;
  final String? coverUrl;
  final double? duration;
  final String? isrc;
  final String? previewUrl;
  final int? discNo;
  final int? trackNo;
  final String? libraryId;

  factory CatalogTrack.fromJson(Map<String, dynamic> j) => CatalogTrack(
    id: j['id'],
    title: j['title'],
    artist: j['artist'],
    artistId: j['artist_id'],
    album: j['album'],
    albumId: j['album_id'],
    coverUrl: j['cover_url'],
    duration: (j['duration'] as num?)?.toDouble(),
    isrc: j['isrc'],
    previewUrl: j['preview_url'],
    discNo: j['disc_no'],
    trackNo: j['track_no'],
    libraryId: j['library_id'],
  );
}

class CatalogSearch {
  const CatalogSearch(this.artists, this.albums, this.tracks);
  final List<CatalogArtist> artists;
  final List<CatalogAlbum> albums;
  final List<CatalogTrack> tracks;

  bool get isEmpty => artists.isEmpty && albums.isEmpty && tracks.isEmpty;

  factory CatalogSearch.fromJson(Map<String, dynamic> j) => CatalogSearch(
    [for (final a in j['artists']) CatalogArtist.fromJson(a)],
    [for (final a in j['albums']) CatalogAlbum.fromJson(a)],
    [for (final t in j['tracks']) CatalogTrack.fromJson(t)],
  );
}

class CatalogArtistDetail {
  const CatalogArtistDetail(this.artist, this.topTracks, this.albums);
  final CatalogArtist artist;
  final List<CatalogTrack> topTracks;
  final List<CatalogAlbum> albums;

  factory CatalogArtistDetail.fromJson(Map<String, dynamic> j) => CatalogArtistDetail(
    CatalogArtist.fromJson(j['artist']),
    [for (final t in j['top_tracks']) CatalogTrack.fromJson(t)],
    [for (final a in j['albums']) CatalogAlbum.fromJson(a)],
  );
}

class CatalogAlbumDetail {
  const CatalogAlbumDetail(this.album, this.tracks, {this.label, this.genres = const []});
  final CatalogAlbum album;
  final List<CatalogTrack> tracks;
  final String? label;
  final List<String> genres;

  int get inLibraryCount => tracks.where((t) => t.libraryId != null).length;

  factory CatalogAlbumDetail.fromJson(Map<String, dynamic> j) => CatalogAlbumDetail(
    CatalogAlbum.fromJson(j),
    [for (final t in j['tracks']) CatalogTrack.fromJson(t)],
    label: j['label'],
    genres: [for (final g in j['genres'] ?? const []) g as String],
  );
}

/// Item statuses that still need work by the server.
const openItemStatuses = {'waiting', 'queued', 'searching', 'downloading', 'processing'};

class DownloadItem {
  const DownloadItem({
    required this.id,
    required this.position,
    required this.title,
    required this.artist,
    required this.status,
    required this.progress,
    this.duration,
    this.source,
    this.error,
    this.trackId,
  });
  final String id;
  final int position;
  final String title;
  final String artist;
  final double? duration;
  final String status;
  final double progress;
  final String? source;
  final String? error;
  final String? trackId;

  factory DownloadItem.fromJson(Map<String, dynamic> j) => DownloadItem(
    id: j['id'],
    position: j['position'],
    title: j['title'],
    artist: j['artist'],
    duration: (j['duration'] as num?)?.toDouble(),
    status: j['status'],
    progress: (j['progress'] as num).toDouble(),
    source: j['source'],
    error: j['error'],
    trackId: j['track_id'],
  );
}

class DownloadRequest {
  const DownloadRequest({
    required this.id,
    required this.kind,
    this.catalogId,
    required this.title,
    required this.artist,
    required this.status,
    required this.isTemporary,
    required this.user,
    required this.progress,
    required this.itemCount,
    required this.doneCount,
    required this.failedCount,
    required this.createdAt,
    this.coverUrl,
    this.note,
    this.items = const [],
  });
  final String id;
  final String kind;
  final String? catalogId;
  final String title;
  final String artist;
  final String? coverUrl;
  final String status;
  final bool isTemporary;
  final String? note;
  final NamedRef user;
  final double progress;
  final int itemCount;
  final int doneCount;
  final int failedCount;
  final DateTime createdAt;
  final List<DownloadItem> items;

  bool get isOpen => status == 'pending_approval' || status == 'active';

  factory DownloadRequest.fromJson(Map<String, dynamic> j) => DownloadRequest(
    id: j['id'],
    kind: j['kind'],
    catalogId: j['catalog_id'],
    title: j['title'],
    artist: j['artist'],
    coverUrl: j['cover_url'],
    status: j['status'],
    isTemporary: j['is_temporary'] ?? false,
    note: j['note'],
    user: NamedRef(j['user']['id'], j['user']['username']),
    progress: (j['progress'] as num).toDouble(),
    itemCount: j['item_count'],
    doneCount: j['done_count'],
    failedCount: j['failed_count'],
    createdAt: DateTime.parse(j['created_at']),
    items: [for (final i in j['items'] ?? const []) DownloadItem.fromJson(i)],
  );
}

class DownloadSummary {
  const DownloadSummary({this.active = 0, this.queued = 0, this.failed = 0, this.pendingApproval = 0});
  final int active;
  final int queued;
  final int failed;
  final int pendingApproval;

  /// Songs currently being worked on or waiting for a worker.
  int get running => active + queued;

  factory DownloadSummary.fromJson(Map<String, dynamic> j) => DownloadSummary(
    active: j['active'],
    queued: j['queued'],
    failed: j['failed'],
    pendingApproval: j['pending_approval'],
  );
}
