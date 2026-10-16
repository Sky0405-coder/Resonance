import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/player/jam.dart';
import 'package:resonance/player/player.dart';

Map<String, dynamic> track(String id, {double duration = 200}) => {
  'id': id,
  'title': 'Song $id',
  'artist': {'id': 'a', 'name': 'Artist'},
  'artist_credit': 'Artist',
  'album': {'id': 'b', 'title': 'Album', 'name': 'Album'},
  'track_no': 1,
  'disc_no': 1,
  'duration': duration,
  'codec': 'flac',
  'bitrate': 900,
  'replaygain_track_gain': null,
  'replaygain_album_gain': null,
  'liked': false,
};

JamState state({bool playing = true, int position = 10000, int serverTime = 1000, int index = 0}) => JamState.fromJson({
  'code': 'ABC234',
  'host': {'id': 'h', 'name': 'Host'},
  'members': [
    {'id': 'h', 'name': 'Host', 'is_host': true, 'online': true},
    {'id': 'g', 'name': 'Guest', 'is_host': false, 'online': false},
  ],
  'members_control': false,
  'playing': playing,
  'position_ms': position,
  'server_time_ms': serverTime,
  'version': 3,
  'index': index,
  'queue': [
    {'entry_id': 'e1', 'added_by': {'id': 'h', 'name': 'Host'}, 'track': track('t1')},
    {'entry_id': 'e2', 'added_by': {'id': 'g', 'name': 'Guest'}, 'track': track('t2', duration: 100)},
  ],
});

void main() {
  test('parses the server state', () {
    final s = state();
    expect(s.code, 'ABC234');
    expect(s.members.map((m) => m.isHost), [true, false]);
    expect(s.membersControl, isFalse);
    expect(s.current!.track.id, 't1');
    expect(s.queue[1].addedByName, 'Guest');
    expect(state(index: -1).current, isNull);
  });

  test('clock offset is the median of the samples', () {
    expect(clockOffset([]), 0);
    expect(clockOffset([50, -10, 40, 9000, 45]), 45);
    expect(offsetSample(sentMs: 1000, receivedMs: 1100, serverMs: 5050), 4000);
  });

  test('expected position follows server time while playing', () {
    expect(expectedPositionMs(state(), 6000), 15000);
    expect(expectedPositionMs(state(playing: false), 6000), 10000);
    // Never runs past the end of the song and never backwards.
    expect(expectedPositionMs(state(index: 1, position: 90000), 50000), 100000);
    expect(expectedPositionMs(state(), 0), 10000);
  });

  test('only audible drift is corrected', () {
    expect(needsSeek(10000, 10900), isFalse);
    expect(needsSeek(10000, 11200), isTrue);
    expect(needsJamSeek(const Duration(milliseconds: 500), Duration.zero), isFalse);
    expect(needsJamSeek(const Duration(seconds: 3), Duration.zero), isTrue);
  });

  test('host and members_control decide who controls playback', () {
    final s = state();
    expect(JamView(state: s, listenHere: true, connected: true, myId: 'h').canControl, isTrue);
    expect(JamView(state: s, listenHere: true, connected: true, myId: 'g').canControl, isFalse);
  });
}
