import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/player/radio_follow.dart';

Track track(String id) => Track(
  id: id,
  title: id,
  artist: const NamedRef('artist', 'Artist'),
  artistCredit: 'Artist',
  album: const NamedRef('album', 'Album'),
  duration: 120,
);

class FakeRadio {
  String? context = 'playlist:radio';
  final queue = [track('seed')];
  final loads = <String>[];
  RadioPlaylist playlist = (isRadio: true, tracks: <Track>[], pendingDownloads: 2);
  Future<RadioPlaylist> Function(String)? load;
  late final follow = RadioFollow(
    loadPlaylist: (id) async {
      loads.add(id);
      return load == null ? playlist : await load!(id);
    },
    currentContext: () => context,
    queuedTrackIds: () => {for (final track in queue) track.id},
    append: (track, expectedContext) async {
      expectSync(context, expectedContext);
      queue.add(track);
    },
  );

  void start() => follow.contextChanged(context);
  List<String> get ids => [for (final track in queue) track.id];
}

void testRadio(String description, Future<void> Function(WidgetTester, FakeRadio) body) {
  testWidgets(description, (tester) async {
    final fake = FakeRadio();
    try {
      await body(tester, fake);
    } finally {
      fake.follow.dispose();
    }
  });
}

void main() {
  testRadio('appends only new track ids, including duplicates within and between refreshes', (tester, fake) async {
    fake.playlist = (isRadio: true, tracks: [track('seed'), track('a'), track('a')], pendingDownloads: 2);
    fake.start();
    await tester.pump();
    expect(fake.ids, ['seed', 'a']);
    fake.playlist = (isRadio: true, tracks: [track('a'), track('b'), track('seed'), track('b')], pendingDownloads: 1);
    await tester.pump(const Duration(seconds: 20));
    expect(fake.ids, ['seed', 'a', 'b']);
    expect(fake.loads, ['radio', 'radio']);
  });

  testRadio('stops immediately on a context change', (tester, fake) async {
    fake.start();
    await tester.pump();
    fake.context = 'album:other';
    fake.follow.contextChanged(fake.context);
    fake.follow.downloadRunningChanged(5);
    fake.follow.downloadRunningChanged(4);
    await tester.pump(const Duration(seconds: 40));
    expect(fake.loads, ['radio']);
    expect(fake.ids, ['seed']);
  });

  testRadio('appends the final downloads before stopping when pending reaches zero', (tester, fake) async {
    fake.start();
    await tester.pump();
    fake.playlist = (isRadio: true, tracks: [track('last')], pendingDownloads: 0);
    await tester.pump(const Duration(seconds: 20));
    expect(fake.ids, ['seed', 'last']);
    fake.follow.downloadRunningChanged(1);
    fake.follow.downloadRunningChanged(0);
    await tester.pump(const Duration(seconds: 40));
    expect(fake.loads, ['radio', 'radio']);
  });

  testRadio('does not follow ordinary playlists or non-playlist contexts', (tester, fake) async {
    fake.context = 'radio:pending';
    fake.start();
    await tester.pump();
    expect(fake.loads, isEmpty);
    fake.context = 'playlist:ordinary';
    fake.playlist = (isRadio: false, tracks: [track('a')], pendingDownloads: null);
    fake.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 40));
    expect(fake.loads, ['ordinary']);
    expect(fake.ids, ['seed']);
  });

  testRadio('refreshes immediately only when the summary running count decreases', (tester, fake) async {
    fake.start();
    await tester.pump();
    fake.follow.downloadRunningChanged(4);
    fake.follow.downloadRunningChanged(5);
    fake.follow.downloadRunningChanged(5);
    await tester.pump();
    expect(fake.loads, hasLength(1));
    fake.playlist = (isRadio: true, tracks: [track('done')], pendingDownloads: 1);
    fake.follow.downloadRunningChanged(4);
    await tester.pump();
    expect(fake.loads, hasLength(2));
    expect(fake.ids, ['seed', 'done']);
  });

  testRadio('a response for an old context cannot append after the user moves on', (tester, fake) async {
    final pending = Completer<RadioPlaylist>();
    fake.load = (_) => pending.future;
    fake.start();
    fake.context = 'album:other';
    fake.follow.contextChanged(fake.context);
    pending.complete((isRadio: true, tracks: [track('stale')], pendingDownloads: 0));
    await tester.pump();
    expect(fake.ids, ['seed']);
  });

  testRadio('switching radios permits a new request while the old request is in flight', (tester, fake) async {
    final old = Completer<RadioPlaylist>();
    fake.load = (id) async =>
        id == 'radio' ? await old.future : (isRadio: true, tracks: [track('new')], pendingDownloads: 0);
    fake.start();
    fake.context = 'playlist:new';
    fake.start();
    await tester.pump();
    old.complete((isRadio: true, tracks: [track('stale')], pendingDownloads: 0));
    await tester.pump();
    expect(fake.ids, ['seed', 'new']);
    expect(fake.loads, ['radio', 'new']);
  });

  testRadio('a download completion during a refresh schedules another refresh', (tester, fake) async {
    final pending = Completer<RadioPlaylist>();
    fake.load = (_) => pending.future;
    fake.start();
    fake.follow.downloadRunningChanged(2);
    fake.follow.downloadRunningChanged(1);
    fake.load = null;
    fake.playlist = (isRadio: true, tracks: [track('done')], pendingDownloads: 0);
    pending.complete((isRadio: true, tracks: <Track>[], pendingDownloads: 1));
    await tester.pump();
    expect(fake.loads, ['radio', 'radio']);
    expect(fake.ids, ['seed', 'done']);
  });

  testRadio('a transient error retries on the next interval', (tester, fake) async {
    fake.load = (_) async => throw StateError('offline');
    fake.start();
    await tester.pump();
    fake.load = null;
    fake.playlist = (isRadio: true, tracks: [track('done')], pendingDownloads: 0);
    await tester.pump(const Duration(seconds: 20));
    expect(fake.ids, ['seed', 'done']);
  });

  testRadio('without a pending count following ends after 30 minutes', (tester, fake) async {
    fake.playlist = (isRadio: true, tracks: <Track>[], pendingDownloads: null);
    fake.start();
    await tester.pump();
    await tester.pump(const Duration(minutes: 29));
    expect(fake.loads.length, greaterThan(1));
    await tester.pump(const Duration(minutes: 1));
    final count = fake.loads.length;
    fake.follow.downloadRunningChanged(2);
    fake.follow.downloadRunningChanged(0);
    await tester.pump(const Duration(minutes: 1));
    expect(fake.loads, hasLength(count));
  });

  testRadio('disposing cancels polling and invalidates an in-flight response', (tester, fake) async {
    final pending = Completer<RadioPlaylist>();
    fake.load = (_) => pending.future;
    fake.start();
    fake.follow.dispose();
    pending.complete((isRadio: true, tracks: [track('stale')], pendingDownloads: null));
    await tester.pump(const Duration(seconds: 40));
    expect(fake.loads, ['radio']);
    expect(fake.ids, ['seed']);
  });
}
