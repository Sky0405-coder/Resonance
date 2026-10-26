import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/widgets/ringtone_sheet.dart';

const _track = Track(
  id: 'song',
  title: 'Song',
  duration: 200,
  artist: NamedRef('artist', 'Artist'),
  artistCredit: 'Artist',
  album: NamedRef('album', 'Album'),
);

class _Api extends ApiClient {
  _Api() : super('http://localhost', 'token');
  final downloads = <String>[];

  @override
  Future<({double start, double duration})> ringtoneSuggestion(String trackId, int length) async =>
      (start: 62.0, duration: 200.0);

  @override
  Future<void> downloadMedia(String url, String Function(String? contentType) destination, {cancelToken}) async {
    downloads.add(url);
    destination('audio/mpeg');
  }
}

void main() {
  late List<MethodCall> calls;
  late bool canWrite;

  setUp(() {
    calls = [];
    canWrite = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('resonance/ringtone'),
      (call) async {
        calls.add(call);
        return switch (call.method) {
          'supported' => true,
          'canWriteSettings' => canWrite,
          'save' => 'content://media/external/audio/media/7',
          _ => null,
        };
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => '/tmp',
    );
  });

  Future<_Api> show(WidgetTester tester) async {
    final api = _Api();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp(
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) =>
                  TextButton(onPressed: () => showRingtoneSheet(context, ref, _track), child: const Text('open')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    calls.clear();
    return api;
  }

  testWidgets('starts at the suggested chorus and sets the chosen sound', (tester) async {
    final api = await show(tester);
    expect(find.text('1:02 – 1:32'), findsOneWidget);

    await tester.tap(find.text('Wecker'));
    await tester.tap(find.text('20 s'));
    await tester.pump();
    expect(find.text('1:02 – 1:22'), findsOneWidget);

    await tester.tap(find.text('Festlegen'));
    await tester.pumpAndSettle();
    expect(api.downloads.single, contains('/api/tracks/song/ringtone?start=62.0&length=20'));
    final save = calls.firstWhere((call) => call.method == 'save');
    expect(save.arguments, {
      'path': '/tmp/ringtone.mp3',
      'title': 'Artist - Song',
      'artist': 'Artist',
      'type': 'alarm',
    });
    final set = calls.firstWhere((call) => call.method == 'setDefault');
    expect(set.arguments, {'uri': 'content://media/external/audio/media/7', 'type': 'alarm'});
    expect(find.text('„Song“ ist jetzt dein Weckton'), findsOneWidget);
  });

  // Semantics off: a dialog over a modal sheet trips a framework assertion in the test binding's semantics pass
  // (_SemanticsGeometry.computeChildGeometry), unrelated to this sheet.
  testWidgets('without the permission it keeps the saved file and opens the sound settings', semanticsEnabled: false, (
    tester,
  ) async {
    canWrite = false;
    await show(tester);
    await tester.tap(find.text('Festlegen'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Berechtigung nötig'), findsOneWidget);

    await tester.tap(find.text('Selbst auswählen'));
    await tester.pumpAndSettle();
    expect(calls.map((call) => call.method), ['save', 'canWriteSettings', 'openSoundSettings']);
    expect(find.text('Gespeichert – wähle „Artist - Song“ in den Toneinstellungen aus'), findsOneWidget);
  });
}
