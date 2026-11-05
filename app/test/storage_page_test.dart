import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/offline/offline_store.dart';
import 'package:resonance/ui/pages/storage_page.dart';

void main() {
  test('storage lists song files biggest first and sums each collection', () {
    const offline = OfflineState(
      tracks: {
        'small': OfflineTrack(albumId: 'a', collections: ['liked'], file: 'tracks/small.opus', size: 10),
        'big': OfflineTrack(albumId: 'a', collections: ['liked', 'album:a'], file: 'tracks/big.opus', size: 30),
        'pending': OfflineTrack(albumId: 'a', collections: ['album:a']),
      },
    );
    expect(storageFiles(offline).map((f) => f.id), ['big', 'small']);
    expect(storageFiles(offline).first.track, isNull, reason: 'no collection data to name it');
    expect(collectionBytes(offline), {'liked': 40, 'album:a': 30});
  });
}
