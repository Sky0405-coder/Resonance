import 'models.dart';

// The yearly review (Wrapped), blends and song credits (see backend/app/schemas.py).

class WrappedTrack {
  const WrappedTrack(this.track, this.plays, this.minutes);
  final Track track;
  final int plays;
  final int minutes;

  factory WrappedTrack.fromJson(Map<String, dynamic> j) =>
      WrappedTrack(Track.fromJson(j['track']), j['plays'] as int, j['minutes'] as int);
}

class WrappedArtist {
  const WrappedArtist(
    this.id,
    this.name,
    this.plays,
    this.minutes,
    this.songs, {
    this.hasImage = false,
    this.coverAlbumId,
  });
  final String id;
  final String name;
  final int plays;
  final int minutes;
  final int songs;
  final bool hasImage;
  final String? coverAlbumId;

  /// For the artist image widgets.
  Artist get artist => Artist(id: id, name: name, albumCount: 0, coverAlbumId: coverAlbumId, hasImage: hasImage);

  factory WrappedArtist.fromJson(Map<String, dynamic> j) => WrappedArtist(
    j['id'] as String,
    j['name'] as String,
    j['plays'] as int,
    j['minutes'] as int,
    j['songs'] as int? ?? 0,
    hasImage: j['has_image'] as bool? ?? false,
    coverAlbumId: j['cover_album_id'] as String?,
  );
}

class Wrapped {
  const Wrapped({
    required this.year,
    this.years = const [],
    this.minutes = 0,
    this.plays = 0,
    this.songs = 0,
    this.artists = 0,
    this.newArtists = 0,
    this.topTracks = const [],
    this.topArtists = const [],
    this.topGenres = const [],
    this.months = const [],
    this.hours = const [],
    this.topDay,
    this.topDayMinutes = 0,
    this.firstTrack,
    this.playlistId,
  });

  final int year;
  final List<int> years;
  final int minutes;
  final int plays;
  final int songs;
  final int artists;
  final int newArtists;
  final List<WrappedTrack> topTracks;
  final List<WrappedArtist> topArtists;

  /// Genre names with their part of the listening time (0..1).
  final List<(String, double)> topGenres;

  /// Minutes per month (12) and per hour of the day (24).
  final List<int> months;
  final List<int> hours;
  final DateTime? topDay;
  final int topDayMinutes;
  final Track? firstTrack;
  final String? playlistId;

  bool get isEmpty => plays == 0;

  /// The hour of the day with the most listening (null without any).
  int? get peakHour {
    if (hours.isEmpty || hours.every((m) => m == 0)) return null;
    var best = 0;
    for (var i = 1; i < hours.length; i++) {
      if (hours[i] > hours[best]) best = i;
    }
    return best;
  }

  factory Wrapped.fromJson(Map<String, dynamic> j) => Wrapped(
    year: j['year'] as int,
    years: [for (final y in j['years'] as List? ?? const []) y as int],
    minutes: j['minutes'] as int? ?? 0,
    plays: j['plays'] as int? ?? 0,
    songs: j['songs'] as int? ?? 0,
    artists: j['artists'] as int? ?? 0,
    newArtists: j['new_artists'] as int? ?? 0,
    topTracks: [for (final t in j['top_tracks'] as List? ?? const []) WrappedTrack.fromJson(t)],
    topArtists: [for (final a in j['top_artists'] as List? ?? const []) WrappedArtist.fromJson(a)],
    topGenres: [
      for (final g in j['top_genres'] as List? ?? const []) (g['name'] as String, (g['share'] as num).toDouble()),
    ],
    months: [for (final m in j['months'] as List? ?? const []) m as int],
    hours: [for (final h in j['hours'] as List? ?? const []) h as int],
    topDay: j['top_day'] == null ? null : DateTime.parse(j['top_day'] as String),
    topDayMinutes: j['top_day_minutes'] as int? ?? 0,
    firstTrack: j['first_track'] == null ? null : Track.fromJson(j['first_track']),
    playlistId: j['playlist_id'] as String?,
  );
}

class Blend {
  const Blend(this.id, this.partner, this.playlistId, this.match);
  final String id;
  final NamedRef partner;
  final String? playlistId;

  /// How alike both tastes are (0..1).
  final double match;

  factory Blend.fromJson(Map<String, dynamic> j) => Blend(
    j['id'] as String,
    NamedRef.fromJson(j['partner']),
    j['playlist_id'] as String?,
    (j['match'] as num).toDouble(),
  );
}

class Credit {
  const Credit(this.name, this.roles);
  final String name;

  /// "artist", "featured", "composer", "lyricist", "producer", "mix", …; instruments by their name.
  final List<String> roles;

  factory Credit.fromJson(Map<String, dynamic> j) =>
      Credit(j['name'] as String, [for (final r in j['roles'] as List) r as String]);
}

class Credits {
  const Credits({
    this.performers = const [],
    this.writers = const [],
    this.producers = const [],
    this.engineers = const [],
    this.label,
    this.copyright,
    this.sources = const [],
  });

  final List<Credit> performers;
  final List<Credit> writers;
  final List<Credit> producers;
  final List<Credit> engineers;
  final String? label;
  final String? copyright;
  final List<String> sources;

  static List<Credit> _list(dynamic v) => [for (final c in v as List? ?? const []) Credit.fromJson(c)];

  factory Credits.fromJson(Map<String, dynamic> j) => Credits(
    performers: _list(j['performers']),
    writers: _list(j['writers']),
    producers: _list(j['producers']),
    engineers: _list(j['engineers']),
    label: j['label'] as String?,
    copyright: j['copyright'] as String?,
    sources: [for (final s in j['sources'] as List? ?? const []) s as String],
  );
}
