import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/ui/widgets/playlist_order.dart';

PlaylistEntry entry(String id, String title, String artist, String album, double duration, {int? no}) => PlaylistEntry(
  id,
  Track(
    id: 't$id',
    title: title,
    artist: NamedRef('a', artist),
    artistCredit: artist,
    album: NamedRef('b', album),
    duration: duration,
    trackNo: no,
  ),
);

void main() {
  test('playlist sorts by title, artist, album order, length and reversed', () {
    final entries = [
      entry('1', 'b song', 'Zed', 'Album', 200, no: 2),
      entry('2', 'A song', 'alpha', 'Album', 100, no: 1),
      entry('3', 'C song', 'Alpha', 'Other', 300, no: 1),
    ];
    expect(sortedEntryIds(entries, PlaylistSort.title), ['2', '1', '3']);
    expect(sortedEntryIds(entries, PlaylistSort.artist), ['2', '3', '1']);
    expect(sortedEntryIds(entries, PlaylistSort.album), ['2', '1', '3']);
    expect(sortedEntryIds(entries, PlaylistSort.length), ['2', '1', '3']);
    expect(sortedEntryIds(entries, PlaylistSort.reverse), ['3', '2', '1']);
  });
}
