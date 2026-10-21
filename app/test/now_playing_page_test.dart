import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/library.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/core/theme.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/offline/offline_store.dart';
import 'package:resonance/player/engine.dart';
import 'package:resonance/player/player.dart';
import 'package:resonance/player/spectrum.dart';
import 'package:resonance/player/visualizer_themes.dart';
import 'package:resonance/ui/pages/now_playing_page.dart';
import 'package:resonance/ui/widgets/catalog.dart';
import 'package:resonance/ui/widgets/common.dart';
import 'package:resonance/ui/widgets/reflection.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tracks = [
  Track(
    id: 'one',
    title: 'First song',
    duration: 120,
    artist: NamedRef('artist', 'Artist'),
    artistCredit: 'Artist',
    album: NamedRef('one', 'First album'),
  ),
  Track(
    id: 'two',
    title: 'Second song',
    duration: 120,
    artist: NamedRef('artist', 'Artist'),
    artistCredit: 'Artist',
    album: NamedRef('two', 'Second album'),
  ),
  Track(
    id: 'three',
    title: 'Third song',
    duration: 120,
    artist: NamedRef('artist', 'Artist'),
    artistCredit: 'Artist',
    album: NamedRef('three', 'Third album'),
  ),
];

class _Engine implements PlaybackEngine {
  @override
  final automixing = ValueNotifier(false);
  @override
  Duration get position => Duration.zero;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  bool playing = false;
  @override
  double get speed => 1;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Player extends PlayerController {
  _Player(this.initial) : super(engine: _Engine());
  final PlayerView initial;
  final jumps = <int>[];

  @override
  PlayerView build() {
    ref.onDispose(() {
      engine.automixing.dispose();
      userVolume.dispose();
      errors.close();
    });
    return initial;
  }

  void update(PlayerView view) => state = view;

  @override
  Future<void> jumpTo(int index) async {
    jumps.add(index);
    state = PlayerView(queue: state.queue, index: index);
  }
}

class _Offline extends OfflineController {
  _Offline(this.directory);
  final String directory;
  @override
  OfflineState build() => OfflineState(directory: directory);
}

void main() {
  late Directory directory;

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('resonance-now-playing-');
    await Directory('${directory.path}/covers').create();
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=',
    );
    for (final track in _tracks) {
      await File('${directory.path}/covers/${track.album.id}.jpg').writeAsBytes(png);
    }
  });
  tearDownAll(() => directory.delete(recursive: true));

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool coverflow = false,
    bool visualizer = true,
    String theme = 'retro',
    Locale locale = const Locale('en'),
    PlayerView view = const PlayerView(queue: _tracks, index: 1),
    Color? color = Colors.orange,
    Spectrum? spectrum,
  }) async {
    SharedPreferences.setMockInitialValues({'coverflow': coverflow, 'visualizer_theme': theme});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        apiProvider.overrideWithValue(ApiClient('https://resonance.example', 'test')),
        playerProvider.overrideWith(() => _Player(view)),
        offlineProvider.overrideWith(() => _Offline(directory.path)),
        visualizerEnabledProvider.overrideWithBuild((ref, notifier) => visualizer),
        coverColorProvider.overrideWith(
          (ref, image) async => image == FileImage(File('${directory.path}/covers/three.jpg')) ? Colors.blue : color,
        ),
        spectrumProvider.overrideWith((ref, id) async => spectrum),
        lyricsProvider.overrideWith(
          (ref, id) async => const Lyrics(synced: false, instrumental: false, source: null, lines: []),
        ),
        positionProvider.overrideWith((ref) => const Stream.empty()),
        durationProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: ThemeData.dark(),
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const NowPlayingPage(),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    return container;
  }

  LinearGradient background(WidgetTester tester) {
    final box = tester.widget<DecoratedBox>(
      find.descendant(of: find.byType(TweenAnimationBuilder<Color?>), matching: find.byType(DecoratedBox)).first,
    );
    return (box.decoration as BoxDecoration).gradient! as LinearGradient;
  }

  for (final size in [const Size(360, 640), const Size(1280, 800)]) {
    for (final coverflow in [false, true]) {
      testWidgets('covers and reflections fit $size with coverflow $coverflow', (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        await mount(tester, coverflow: coverflow, visualizer: size.width < 900);
        expect(find.byType(CoverReflection), findsWidgets);
        for (final element in find.byType(CoverReflection).evaluate()) {
          final finder = find.byWidget(element.widget);
          final rect = tester.getRect(finder);
          final rendered = tester.getSize(finder);
          expect(rendered.height, closeTo(rendered.width * 0.22, 0.001));
          expect(rect.bottom, lessThanOrEqualTo(size.height));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('cover tint uses capped HSL and animates track changes over 600 milliseconds', (tester) async {
    final container = await mount(tester);
    final expected = HSLColor.fromColor(Colors.orange).withLightness(0.22).withSaturation(0.65).toColor();
    expect(background(tester).colors, [expected, Palette.background]);
    expect(background(tester).stops, [0.0, 0.85]);
    (container.read(playerProvider.notifier) as _Player).update(const PlayerView(queue: _tracks, index: 2));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final blue = HSLColor.fromColor(Colors.blue).withLightness(0.22).withSaturation(0.65).toColor();
    expect(background(tester).colors.first, isNot(expected));
    expect(background(tester).colors.first, isNot(blue));
    await tester.pump(const Duration(milliseconds: 300));
    expect(background(tester).colors.first, blue);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final (visualizer, color) in [(true, null), (false, null), (false, Colors.orange)]) {
    testWidgets('accent gradient is kept with visualizer $visualizer and cover color $color', (tester) async {
      await mount(tester, visualizer: visualizer, color: color);
      final context = tester.element(find.byType(NowPlayingPage));
      expect(background(tester).colors.first, Theme.of(context).colorScheme.primary.withValues(alpha: 0.45));
      expect(background(tester).stops, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('cover tint preserves darker muted colors and makes them opaque', (tester) async {
    final color = const HSLColor.fromAHSL(0.4, 100, 0.2, 0.1).toColor();
    await mount(tester, color: color);
    expect(background(tester).colors.first, HSLColor.fromColor(color).withAlpha(1).toColor());
  });

  for (final theme in ['retro', 'matrix', 'auto', 'ocean']) {
    testWidgets('$theme reflects the requested artwork and toggles dots for peak themes', (tester) async {
      final container = await mount(tester, theme: theme, locale: const Locale('de'));
      final peaks = theme == 'retro' || theme == 'matrix';
      expect(
        find.descendant(of: find.byType(CoverReflection), matching: find.byType(SpectrumVisualizer)),
        peaks ? findsOneWidget : findsNothing,
      );
      final cover = find.byType(CoverImage).first;
      await tester.tap(cover);
      await tester.pump();
      expect(container.read(visualizerPeaksProvider), !peaks);
      if (peaks) {
        expect(find.text('Punkte aus'), findsOneWidget);
        expect(container.read(prefsProvider).getBool('visualizer_peaks'), isFalse);
        ScaffoldMessenger.of(tester.element(cover)).removeCurrentSnackBar();
        await tester.pump();
        await tester.tap(cover);
        await tester.pump();
        expect(container.read(visualizerPeaksProvider), isTrue);
        expect(find.text('Punkte an'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('the last bubble repaints when it expires after playback stops', (tester) async {
    final data = ByteData(14)
      ..setUint32(0, 0x52535031)
      ..setUint8(4, 1)
      ..setFloat32(5, 20, Endian.little)
      ..setUint32(9, 1, Endian.little)
      ..setUint8(13, 204);
    final container = await mount(tester, spectrum: Spectrum.parse(data.buffer.asUint8List()));
    final engine = container.read(playerProvider.notifier).engine as _Engine;
    engine.playing = true;
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
    engine.playing = false;
    for (var i = 0; i < 9; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final painter = tester
        .widget<CustomPaint>(
          find.descendant(of: find.byType(SpectrumVisualizer).first, matching: find.byType(CustomPaint)),
        )
        .painter!;
    var repaints = 0;
    void onRepaint() => repaints++;
    painter.addListener(onRepaint);
    await tester.pump(const Duration(milliseconds: 800));
    expect(repaints, 1);
    await tester.pump(const Duration(milliseconds: 100));
    expect(repaints, 1);
    painter.removeListener(onRepaint);
    expect(tester.takeException(), isNull);
  });

  testWidgets('only the centered coverflow item has visualizers and responds to peak-dot taps', (tester) async {
    final container = await mount(tester, coverflow: true);
    final visualizers = tester.widgetList<SpectrumVisualizer>(find.byType(SpectrumVisualizer));
    expect(visualizers, hasLength(2));
    expect(visualizers.every((visualizer) => visualizer.trackId == 'two'), isTrue);
    expect(find.byType(CoverReflection), findsAtLeastNWidgets(2));
    await tester.tapAt(tester.getCenter(find.byType(PageView)));
    await tester.pump();
    expect(container.read(visualizerPeaksProvider), isFalse);
    expect(find.text('Peak dots off'), findsOneWidget);
  });

  testWidgets('coverflow starts at the queue index, jumps once after a swipe and follows external changes', (
    tester,
  ) async {
    final container = await mount(tester, coverflow: true, visualizer: false);
    final player = container.read(playerProvider.notifier) as _Player;
    final pages = find.byType(PageView);
    final controller = tester.widget<PageView>(pages).controller!;
    expect(controller.viewportFraction, 0.72);
    expect(controller.page, 1);
    await tester.drag(pages, const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 2);
    expect(player.jumps, [2]);
    player.update(const PlayerView(queue: _tracks, index: 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 150));
    expect(controller.page, greaterThan(0));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    expect(player.jumps, [2]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('station identity appears above song artwork only and has no reflection', (tester) async {
    const station = Station(
      id: 'radio',
      name: 'Radio One',
      country: 'Germany',
      countryCode: 'DE',
      tags: [],
      codec: 'MP3',
    );
    final container = await mount(tester, view: const PlayerView(station: station));
    expect(find.byType(NetworkCover), findsOneWidget);
    expect(find.byType(CoverReflection), findsNothing);
    (container.read(playerProvider.notifier) as _Player).update(
      const PlayerView(
        station: station,
        stationNow: StationNowPlaying(raw: 'Artist - Song', title: 'Song', coverUrl: 'https://cover.example/song'),
      ),
    );
    await tester.pump();
    final covers = find.byType(NetworkCover);
    expect(covers, findsNWidgets(2));
    final favicon = tester.getRect(covers.first);
    final song = tester.getRect(covers.last);
    expect(favicon.size, const Size(28, 28));
    expect(song.top - favicon.bottom, closeTo(12, 0.001));
    expect(find.byType(CoverReflection), findsNothing);
    expect(background(tester).stops, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reflection mirrors the bottom first, fades downward and ignores taps', (tester) async {
    final key = GlobalKey();
    var tapped = false;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: RepaintBoundary(
            key: key,
            child: SizedBox(
              width: 200,
              child: CoverReflection(
                child: GestureDetector(
                  onTap: () => tapped = true,
                  child: Column(
                    children: [
                      Expanded(flex: 9, child: Container(color: const Color(0xFFFF0000))),
                      Expanded(child: Container(color: const Color(0xFF0000FF))),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = (await tester.runAsync(() => boundary.toImage()))!;
    final pixels = (await tester.runAsync(() => image.toByteData(format: ui.ImageByteFormat.rawStraightRgba)))!;
    final top = (2 * image.width + 100) * 4;
    final lower = (30 * image.width + 100) * 4;
    expect(pixels.getUint8(top + 2), greaterThan(200));
    expect(pixels.getUint8(top), 0);
    expect(pixels.getUint8(lower), greaterThan(200));
    expect(pixels.getUint8(lower + 2), 0);
    expect(pixels.getUint8(top + 3), greaterThan(pixels.getUint8(lower + 3)));
    image.dispose();
    await tester.tap(find.byType(CoverReflection), warnIfMissed: false);
    expect(tapped, isFalse);
    expect(tester.takeException(), isNull);
  });
}
