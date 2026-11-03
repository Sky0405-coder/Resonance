import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/models.dart';

void main() {
  test('collaborative playlists carry who may edit and who added each song', () {
    final detail = PlaylistDetail.fromJson({
      'id': 'p',
      'name': 'Roadtrip',
      'description': null,
      'is_public': false,
      'owner': {'id': 'owner', 'name': 'Kjell'},
      'collaborative': true,
      'can_edit': true,
      'editable': true,
      'track_count': 1,
      'duration': 200,
      'cover_album_ids': [],
      'entries': [
        {
          'entry_id': 'e',
          'added_by': {'id': 'friend', 'name': 'Mia'},
          'track': {
            'id': 't',
            'title': 'Song',
            'artist': {'id': 'a', 'name': 'Artist'},
            'artist_credit': 'Artist',
            'album': {'id': 'b', 'title': 'Album'},
            'duration': 200,
          },
        },
      ],
    });
    expect(detail.playlist.collaborative, isTrue);
    expect(detail.playlist.canEdit, isTrue);
    expect(detail.editable, isTrue);
    expect(detail.entries.single.addedBy!.name, 'Mia');
    final plain = Playlist.fromJson({
      'id': 'q',
      'name': 'Old server',
      'is_public': false,
      'owner': {'id': 'owner', 'name': 'Kjell'},
    });
    expect(plain.collaborative, isFalse);
    expect(plain.canEdit, isFalse);
  });
}
