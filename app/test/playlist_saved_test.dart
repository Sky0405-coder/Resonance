import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/models.dart';

Playlist playlist({String kind = 'user', bool? saved}) => Playlist.fromJson({
  'id': 'p',
  'name': 'P',
  'is_public': true,
  'owner': {'id': 'u', 'name': 'U'},
  'kind': kind,
  'saved': ?saved,
});

void main() {
  test('mixes show in the library once saved, radios never, own and shared playlists always', () {
    expect(playlist().inLibrary, isTrue);
    expect(playlist(saved: true).inLibrary, isTrue);
    expect(playlist(kind: 'mix').inLibrary, isFalse);
    expect(playlist(kind: 'mix', saved: true).inLibrary, isTrue);
    expect(playlist(kind: 'radio', saved: true).inLibrary, isFalse);
  });

  test('servers without saved playlists send no flag', () {
    expect(playlist().saved, isFalse);
  });
}
