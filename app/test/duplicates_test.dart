import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/models.dart';

void main() {
  test('DuplicateGroup.fromJson parses tracks and keep flags', () {
    final group = DuplicateGroup.fromJson({
      'album_id': 'album',
      'album_title': 'Fallen',
      'artist_name': 'Evanescence',
      'tracks': [
        for (final keep in [true, false])
          {
            'id': keep ? 'flac' : 'mp3',
            'title': 'Going Under',
            'path': 'Evanescence/Fallen/01 - Going Under.${keep ? 'flac' : 'mp3'}',
            'codec': keep ? 'flac' : null,
            'bitrate': keep ? 989 : null,
            'size': keep ? 25100000 : 5000000,
            'duration': keep ? 210 : 210.5,
            'keep': keep,
          },
      ],
    });

    expect(group.albumId, 'album');
    expect(group.albumTitle, 'Fallen');
    expect(group.artistName, 'Evanescence');
    expect(group.tracks.map((track) => track.keep), [true, false]);
    expect(group.tracks.first.codec, 'flac');
    expect(group.tracks.first.bitrate, 989);
    expect(group.tracks.first.size, 25100000);
    expect(group.tracks.first.duration, 210.0);
    expect(group.tracks.last.codec, isNull);
    expect(group.tracks.last.bitrate, isNull);
    expect(group.tracks.last.duration, 210.5);
  });
}
