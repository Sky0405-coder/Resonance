import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:resonance/core/audiobooks.dart';
import 'package:resonance/core/books.dart';
import 'package:resonance/core/library.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/core/theme.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/offline/offline_store.dart';
import 'package:resonance/player/connect.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/player.dart';
import 'package:resonance/ui/tv/tv_focusable.dart';
import 'package:resonance/ui/tv/tv_shell.dart';
import 'package:resonance/ui/tv/tv_detail_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/idle_connect.dart';

class _Engine implements PlaybackEngine {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Offline extends OfflineController {
  @override
  OfflineState build() => const OfflineState();
}

class _Player extends PlayerController {
  _Player() : super(engine: _Engine());

  List<Track>? played;
  int? playedIndex;
  final shuffles = <bool>[];

  @override
  PlayerView build() {
    ref.onDispose(() {
      userVolume.dispose();
      errors.close();
    });
    return const PlayerView();
  }

  @override
  Future<void> setShuffle(bool enabled) async => shuffles.add(enabled);

  @override
  Future<void> playTracks(List<Track> tracks, {int? index, String? context, bool isRadio = false}) async {
    played = tracks;
    playedIndex = index;
  }
}

const _album = Album(
  id: 'album',
  title: 'Album',
  artist: NamedRef('artist', 'Artist'),
  hasCover: false,
  trackCount: 200,
);

Track _track(int index) => Track(
  id: 'track-$index',
  title: 'Track $index',
  artist: const NamedRef('artist', 'Artist'),
  artistCredit: 'Artist',
  album: const NamedRef('album', 'Album'),
  duration: 60,
);

Future<(ProviderContainer, GoRouter, _Player)> _setup(List<Track> tracks) async {
  SharedPreferences.setMockInitialValues({'tv_mode': true});
  final prefs = await SharedPreferences.getInstance();
  final player = _Player();
  final container = ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      connectProvider.overrideWith(IdleConnect.new),
      playerProvider.overrideWith(() => player),
      positionProvider.overrideWith((ref) => const Stream.empty()),
      durationProvider.overrideWith((ref) => const Stream.empty()),
      audiobooksVisibleProvider.overrideWithValue(false),
      ebooksVisibleProvider.overrideWithValue(false),
      offlineProvider.overrideWith(_Offline.new),
      albumProvider('album')
          .overrideWith((ref) async => AlbumDetail(_album, tracks, (60 * tracks.length).toDouble(), false)),
    ],
  );
  final router = GoRouter(
    initialLocation: '/album/album',
    routes: [
      GoRoute(
        path: '/album/album',
        builder: (_, _) => const TvShell(
          location: '/album/album',
          child: TvDetailPage(kind: 'album', id: 'album'),
        ),
      ),
      GoRoute(
        path: '/now-playing',
        builder: (_, _) => const Scaffold(body: Text('Now playing route')),
      ),
    ],
  );
  return (container, router, player);
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => SessionState(
    serverUrl: 'https://resonance.example',
    token: 'test',
    user: User(
      id: 'user',
      username: 'user',
      displayName: 'User',
      role: 'user',
      accentColor: '#1DB954',
      isDisabled: false,
      createdAt: DateTime(2026),
    ),
  );
}

Widget _app(ProviderContainer container, GoRouter router) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp.router(
    theme: buildTheme(defaultAccent),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    routerConfig: router,
  ),
);

String? _focusedLabel() =>
    FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TvFocusable>()?.label;

void main() {
  testWidgets('TV detail lazily builds and focuses track 31 after 30 down presses', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (container, router, _) = await _setup([for (var index = 1; index <= 200; index++) _track(index)]);
    addTearDown(container.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(container, router));
    await tester.pumpAndSettle();
    expect(_focusedLabel(), 'Play');
    expect(find.text('Track 200'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusedLabel(), 'Track 1');

    for (var index = 0; index < 30; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }

    expect(_focusedLabel(), 'Track 31');
    expect(tester.getRect(find.text('Track 31')).overlaps(const Rect.fromLTWH(0, 0, 1280, 800)), true);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('TV detail track rows stay in place while Play and Shuffle open now playing', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final (container, router, player) = await _setup([_track(1), _track(2)]);
    addTearDown(container.dispose);
    addTearDown(router.dispose);
    await tester.pumpWidget(_app(container, router));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(_focusedLabel(), 'Track 1');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/album/album');
    expect(player.playedIndex, 0);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    expect(_focusedLabel(), 'Play');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/now-playing');
    expect(player.shuffles, [false]);

    router.pop();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(_focusedLabel(), 'Shuffle');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(router.state.uri.path, '/now-playing');
    expect(player.shuffles, [false, true]);
    debugDefaultTargetPlatformOverride = null;
  });
}
