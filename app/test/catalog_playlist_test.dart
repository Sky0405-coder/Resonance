import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/ui/pages/download_pages.dart';

class _Api extends ApiClient {
  _Api() : super('http://localhost', 'token');
  final imports = <(List<String>, bool)>[];

  @override
  Future<CatalogPlaylistDetail> catalogPlaylist(String link) async => CatalogPlaylistDetail.fromJson({
    'source': 'deezer',
    'link': link,
    'name': 'Deutschrap Essentials',
    'owner': 'Editor',
    'image_url': null,
    'playlist_id': null,
    'tracks': [
      {'title': 'Have', 'artist': 'Artist', 'album': 'Album', 'duration': 180.0, 'library_id': 'track-1'},
      {'title': 'Missing', 'artist': 'Artist', 'album': null, 'duration': 200.0, 'library_id': null},
    ],
  });

  @override
  Future<Map<String, dynamic>> startSpotifyImport({
    required bool liked,
    required List<String> playlistIds,
    required bool downloadMissing,
    List<String> links = const [],
  }) async {
    imports.add((links, downloadMissing));
    return {};
  }
}

void main() {
  testWidgets('a found playlist shows its songs and imports with the missing ones downloaded', (tester) async {
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _Api();
    const link = 'https://www.deezer.com/playlist/77';
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => const CatalogPlaylistPage(link: link),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [apiProvider.overrideWithValue(api)],
        child: MaterialApp.router(
          locale: const Locale('de'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Deutschrap Essentials'), findsOneWidget);
    expect(find.textContaining('Deezer • Editor • 2 Songs'), findsOneWidget);
    expect(find.textContaining('1 von 2'), findsOneWidget);
    expect(find.text('Have'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    await tester.tap(find.text('Importieren und fehlende Songs laden'));
    await tester.pump();
    expect(api.imports.single.$1, [link]);
    expect(api.imports.single.$2, isTrue);
    expect(find.text('Import gestartet'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
