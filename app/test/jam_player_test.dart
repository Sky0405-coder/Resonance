import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/player/jam.dart';
import 'package:resonance/player/player.dart';
import 'package:resonance/ui/widgets/jam_sheet.dart';

import 'support/connect_engine.dart';

Track _track(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: const NamedRef('a', 'Artist'),
  artistCredit: 'Artist',
  album: const NamedRef('b', 'Album'),
  duration: 200,
);

class _Api extends ApiClient {
  _Api() : super('https://example.test', 'token');
  @override
  Future<void> reportPlay(String id, double seconds, {String? context}) async {}
}

class _Session extends SessionNotifier {
  @override
  SessionState build() => const SessionState(serverUrl: 'https://example.test');
}

class _NoJam extends JamController {
  @override
  JamView? build() => null;
}

class _HostJam extends JamController {
  @override
  JamView? build() => JamView(
    state: JamState.fromJson({
      'code': '123456',
      'host': {'id': 'u'},
      'members': [],
      'queue': [],
    }),
    listenHere: true,
    connected: true,
    myId: 'u',
  );

  @override
  Future<void> leave() async => state = null;
}

class _Router implements JamRouter {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConnectTestEngine engine;
  late PlayerController player;
  late ProviderContainer container;
  final tracks = [_track('one'), _track('two'), _track('three')];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    engine = ConnectTestEngine();
    container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(_Api()),
        sessionProvider.overrideWith(_Session.new),
        jamProvider.overrideWith(_NoJam.new),
        downloadSummaryProvider.overrideWith((ref) async => const DownloadSummary()),
        playerProvider.overrideWith(() => PlayerController(engine: engine)),
      ],
    );
    player = container.read(playerProvider.notifier);
    player.autoplay = false;
    await player.loadConnect(tracks, 1, const Duration(seconds: 42), true, false, LoopMode.off);
    engine.preservedCurrent = null;
  });
  tearDown(() => container.dispose());

  Future<void> apply(Duration expected, {bool playing = true}) {
    player.jam = _Router();
    return player.applyJam(tracks, 1, () => expected, playing, listen: true, context: 'jam:123456');
  }

  test('starting a Jam keeps the running song instead of reloading it from the start', () async {
    await apply(const Duration(milliseconds: 42300));
    expect(engine.preservedCurrent, isNull, reason: 'no new sources');
    expect(engine.position, const Duration(seconds: 42));
    expect(engine.playing, isTrue);
    expect(container.read(playerProvider).context, 'jam:123456');
  });

  test('drift between Jam updates is corrected, small differences are left alone', () async {
    await apply(const Duration(seconds: 42));
    var expected = const Duration(milliseconds: 42800);
    player.jam = _Router();
    await player.applyJam(tracks, 1, () => expected, true, listen: true, context: 'jam:123456');
    await player.syncJam();
    expect(engine.position, const Duration(seconds: 42));
    expected = const Duration(seconds: 50);
    await player.syncJam();
    expect(engine.position, const Duration(seconds: 50));
  });

  test('seeking in a Jam moves the local song right away', () async {
    await apply(const Duration(seconds: 42));
    await player.seekInJam(const Duration(seconds: 120));
    expect(engine.position, const Duration(seconds: 120));
  });

  testWidgets('ending the Jam closes only its panel, not the page beneath', (tester) async {
    final scope = ProviderContainer(
      overrides: [sessionProvider.overrideWith(_Session.new), jamProvider.overrideWith(_HostJam.new)],
    );
    addTearDown(scope.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Text('home'),
        ),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          body: Consumer(
            builder: (context, ref, _) =>
                TextButton(onPressed: () => showJamSheet(context, ref), child: const Text('player')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.text('player'));
    await tester.tap(find.text('player'));
    await tester.pumpAndSettle();
    final end = find.text(AppLocalizations.of(context).jamEnd);
    await tester.scrollUntilVisible(end, 100, scrollable: find.byType(Scrollable).last);
    await tester.tap(end);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, AppLocalizations.of(context).jamEnd));
    await tester.pumpAndSettle();
    expect(scope.read(jamProvider), isNull);
    expect(find.text('player'), findsOneWidget);
  });
}
