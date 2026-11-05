import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/offline/export.dart';
import 'package:resonance/offline/offline_store.dart';

Map<String, dynamic> _track(String id, String title, String artist) => {
  'id': id,
  'title': title,
  'artist': {'id': 'a', 'name': artist},
  'artist_credit': artist,
  'album': {'id': 'al', 'name': 'Album'},
  'duration': 200,
};

void main() {
  test('file names are readable and safe everywhere', () {
    expect(safeFileName('AC/DC: Back in Black?'), 'AC_DC_ Back in Black_');
    expect(safeFileName('  ...  '), '_');
    expect(audioMime('a.opus'), 'audio/ogg');
    expect(audioMime('a.FLAC'), 'audio/flac');
  });

  test('downloaded songs are copied into a folder per collection, once', () async {
    final root = await Directory.systemTemp.createTemp('export');
    addTearDown(() => root.delete(recursive: true));
    await Directory('${root.path}/tracks').create();
    await File('${root.path}/tracks/one.opus').writeAsString('one');
    final offline = OfflineState(
      directory: root.path,
      collections: {
        'liked': OfflineCollection(
          kind: 'liked',
          id: 'liked',
          name: 'Liked',
          addedAt: DateTime.utc(2026),
          data: [_track('one', 'Without Me', 'Eminem'), _track('missing', 'Not downloaded', 'X')],
        ),
      },
      tracks: const {
        'one': OfflineTrack(albumId: 'al', collections: ['liked'], file: 'tracks/one.opus', size: 3),
        'missing': OfflineTrack(albumId: 'al', collections: ['liked']),
      },
    );
    final items = exportItems(offline);
    expect(items.map((i) => (i.folder, i.name)), [('Liked Songs', 'Eminem - Without Me.opus')]);
    final target = '${root.path}/out';
    final progress = <int>[];
    expect(await exportSongs(items, target: target, progress: progress.add), 1);
    expect(progress, [1]);
    expect(await File('$target/Liked Songs/Eminem - Without Me.opus').readAsString(), 'one');
    expect(await exportSongs(items, target: target), 0, reason: 'already exported songs are kept');
    expect(exportItems(offline, collections: ['album:x']), isEmpty);
  });
}
