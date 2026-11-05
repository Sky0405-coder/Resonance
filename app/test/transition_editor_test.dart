import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/downloads.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/jam.dart';
import 'package:resonance/player/mix_lanes.dart';
import 'package:resonance/player/player.dart';
import 'package:resonance/player/spectrum.dart';
import 'package:resonance/ui/pages/transition_editor_page.dart';

import 'support/connect_engine.dart';

Track _track(String id) => Track(
  id: id,
  title: 'Song $id',
  artist: const NamedRef('a', 'Artist'),
  artistCredit: 'Artist',
  album: const NamedRef('b', 'Album'),
  duration: 210,
);

const _points = MixPoints(bpm: 120, mixIn: 0.5, mixOut: 200, end: 210, key: '8A', keyConfidence: 0.5);

class _Api extends ApiClient {
  _Api() : super('https://example.test', 'token');
  final saved = <String, CustomTransition>{};
  final calls = <String>[];

  @override
  Future<Map<String, MixPoints?>> mixPoints(List<String> ids) async => {for (final id in ids) id: _points};
  @override
  Future<Map<String, CustomTransition>> transitions(String playlistId) async => {...saved};
  @override
  Future<void> saveTransition(String playlistId, String fromId, String toId, CustomTransition transition) async {
    calls.add('save $playlistId $fromId>$toId');
    saved['$fromId>$toId'] = transition;
  }

  @override
  Future<void> resetTransition(String playlistId, String fromId, String toId) async {
    calls.add('reset $playlistId $fromId>$toId');
    saved.remove('$fromId>$toId');
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Api api;
  late ConnectTestEngine engine;

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockStreamHandler(
      const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
  });

  Future<ProviderContainer> container() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    api = _Api();
    engine = ConnectTestEngine();
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(api),
        sessionProvider.overrideWith(_Session.new),
        jamProvider.overrideWith(_NoJam.new),
        downloadSummaryProvider.overrideWith((ref) async => const DownloadSummary()),
        playerProvider.overrideWith(() => PlayerController(engine: engine)),
        spectrumProvider.overrideWith((ref, id) async => null),
      ],
    );
    container.read(playerProvider.notifier).autoplay = false;
    return container;
  }

  Future<void> open(WidgetTester tester, ProviderContainer scope, {bool canEdit = true}) async {
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: scope,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      TransitionEditorPage(playlistId: 'p', from: _track('one'), to: _track('two'), canEdit: canEdit),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
  }

  testWidgets('a preset, a length and a lane choice save a transition for the pair; automatic resets it', (
    tester,
  ) async {
    final scope = (await tester.runAsync(container))!;
    await open(tester, scope);
    expect(find.text('Song one'), findsOneWidget);
    expect(find.text('120 bpm'), findsNWidgets(2));
    // Automatic and unchanged: nothing to save.
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Fade out'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Fade out'));
    await tester.pumpAndSettle();
    expect(find.text('Fade in and out'), findsOneWidget);
    expect(find.text('Bass fade-out'), findsOneWidget);
    await tester.tap(find.text('4 bars'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('8 bars').last);
    await tester.pumpAndSettle();
    // A lane of its own: an echo that rings out; the preset no longer matches, so the transition is custom.
    await tester.ensureVisible(find.text('Effects'));
    await tester.tap(find.text('Effects'));
    await tester.pumpAndSettle();
    final echo = find.text('Echo every ¾ beat rings out until the end');
    await tester.scrollUntilVisible(
      echo,
      80,
      scrollable: find.descendant(of: find.byType(BottomSheet), matching: find.byType(Scrollable)),
    );
    await tester.ensureVisible(echo);
    await tester.pumpAndSettle();
    await tester.tap(echo);
    await tester.pumpAndSettle();
    Navigator.of(tester.element(echo.last)).pop();
    await tester.pumpAndSettle();
    // Back up to the presets.
    await tester.drag(find.byType(ListView).first, const Offset(0, 2000));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ChoiceChip, 'Custom'), findsOneWidget);
    await tester.tap(save);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(api.calls, ['save p one>two']);
    final transition = api.saved['one>two']!;
    expect(transition.bars, 8);
    expect(
      transition.lanes,
      const MixLanes(volume: VolumeLane.fadeInOut, eq: EqLane.bassFadeOut, effect: EffectLane.echoThreeQuarterTail),
    );
    // Older apps play it as the closest style.
    expect(transition.style, TransitionStyle.fadeOut);
    // The automatic plan's start, on the beat grid.
    expect(transition.start, 200);

    await open(tester, scope);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Custom')).selected, isTrue);
    await tester.ensureVisible(find.widgetWithText(ChoiceChip, 'Automatic'));
    await tester.tap(find.widgetWithText(ChoiceChip, 'Automatic'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pumpAndSettle();
    expect(api.calls.last, 'reset p one>two');
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('people who may only listen see the transition but cannot change it', (tester) async {
    final scope = (await tester.runAsync(container))!;
    await open(tester, scope, canEdit: false);
    expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
    expect(tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Crossfade')).onSelected, isNull);
    expect(find.text('Only people who can edit the playlist can change transitions.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    scope.dispose();
    await tester.pump(const Duration(seconds: 10));
  });

  test('a playlist plays its saved transition instead of AutoMix\'s own', () async {
    final scope = await container();
    addTearDown(scope.dispose);
    final player = scope.read(playerProvider.notifier);
    api.saved['one>two'] = const CustomTransition(
      style: TransitionStyle.fadeIn,
      bars: 2,
      start: 150,
      incomingStart: 30,
    );
    await player.playTracks([_track('one'), _track('two')], index: 0, context: 'playlist:p');
    // The first lookups load the playlist's transitions and the analyses (the engine asks again and again).
    for (var i = 0; i < 3; i++) {
      engine.customPlanForIndex!(0, 1);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final plan = engine.customPlanForIndex!(0, 1)!;
    expect(
      (plan.start, plan.incomingStart, plan.intro),
      (const Duration(seconds: 150), const Duration(seconds: 30), true),
    );
    expect(plan.duration, const Duration(seconds: 4));
    // Other playlists and other pairs keep AutoMix's own.
    expect(engine.customPlanForIndex!(1, 0), isNull);
    await player.playTracks([_track('one'), _track('two')], index: 0, context: 'album:x');
    expect(engine.customPlanForIndex!(0, 1), isNull);
  });
}
