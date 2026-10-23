import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/api.dart';
import 'package:resonance/core/models.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/l10n/l10n.dart';
import 'package:resonance/core/theme.dart';
import 'package:resonance/ui/tv/tv_focusable.dart';
import 'package:resonance/ui/tv/tv_search_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

class _Api extends ApiClient {
  _Api() : super('https://resonance.example', 'test');

  final createdRequests = <(String, String)>[];
  static const albumResult = CatalogAlbum(id: 'catalog-album', title: 'Catalog album', artist: 'Catalog artist');

  @override
  Future<SearchResult> search(String query) async => const SearchResult([], [], []);

  @override
  Future<CatalogSearch> catalogSearch(String query, {int limit = 10}) async =>
      const CatalogSearch([], [albumResult], []);

  @override
  Future<List<DownloadRequest>> requests({String scope = 'mine', String state = 'all', int limit = 100}) async => [];

  @override
  Future<DownloadRequest> createRequest(String kind, String catalogId) async {
    createdRequests.add((kind, catalogId));
    return DownloadRequest(
      id: 'request',
      kind: kind,
      catalogId: catalogId,
      title: albumResult.title,
      artist: albumResult.artist,
      status: 'pending_approval',
      isTemporary: false,
      user: const NamedRef('user', 'user'),
      progress: 0,
      itemCount: 1,
      doneCount: 0,
      failedCount: 0,
      createdAt: DateTime(2026),
    );
  }
}

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: buildTheme(defaultAccent),
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(body: TvSearchPage()),
  ),
);

Future<ProviderContainer> _container(_Api api) async {
  SharedPreferences.setMockInitialValues({'tv_mode': true});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      prefsProvider.overrideWithValue(prefs),
      sessionProvider.overrideWith(_Session.new),
      apiProvider.overrideWithValue(api),
    ],
  );
}

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  testWidgets('TV search opens on a and A activates h and i', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await _container(_Api());
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    final a = tester.widget<TvFocusable>(find.byKey(const ValueKey('tv-key-a')));
    expect(FocusManager.instance.primaryFocus, a.focusNode);
    for (final key in ['h', 'i']) {
      final focusable = tester.widget<TvFocusable>(find.byKey(ValueKey('tv-key-$key')));
      focusable.focusNode!.requestFocus();
      await tester.pumpAndSettle();
      Actions.invoke(FocusManager.instance.primaryFocus!.context!, const ActivateIntent());
      await tester.pumpAndSettle();
    }
    expect(find.text('hi'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('physical typing works and Search focuses the first result', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await _container(_Api());
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyH, character: 'h');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyI, character: 'i');
    await tester.pumpAndSettle();
    expect(find.text('hi'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    final searchKey = tester.widget<TvFocusable>(find.byKey(const ValueKey('tv-key-submit')));
    searchKey.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    Actions.invoke(FocusManager.instance.primaryFocus!.context!, const ActivateIntent());
    await tester.pumpAndSettle();
    expect(FocusManager.instance.primaryFocus!.debugLabel, 'TV first search result');
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('catalog result opens a confirmation and creates an album request', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    await tester.binding.setSurfaceSize(const Size(1280, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final api = _Api();
    final container = await _container(api);
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.keyC, character: 'c');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Catalog album'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Catalog album'));
    await tester.pumpAndSettle();
    expect(find.text('By Catalog artist'), findsOneWidget);

    Actions.invoke(FocusManager.instance.primaryFocus!.context!, const ActivateIntent());
    await tester.pumpAndSettle();
    expect(api.createdRequests, [('album', 'catalog-album')]);
    debugDefaultTargetPlatformOverride = null;
  });
}
