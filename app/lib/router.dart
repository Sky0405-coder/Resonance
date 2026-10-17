import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'ui/widgets/jam_sheet.dart';

import 'core/session.dart';
import 'ui/pages/admin/admin_page.dart';
import 'ui/pages/admin/duplicates_page.dart';
import 'ui/pages/audiobook_pages.dart';
import 'ui/pages/auth_pages.dart';
import 'ui/pages/browse_pages.dart';
import 'ui/pages/collection_pages.dart';
import 'ui/pages/download_pages.dart';
import 'ui/pages/home_page.dart';
import 'ui/pages/world_radio_page.dart';
import 'ui/pages/now_playing_page.dart';
import 'ui/pages/lyrics_page.dart';
import 'ui/pages/settings_page.dart';
import 'ui/pages/spotify_page.dart';
import 'ui/shell.dart';

const _publicRoutes = {'/login', '/register', '/server'};

final routerProvider = Provider<GoRouter>((ref) {
  // Bridge Riverpod session changes into go_router's refresh mechanism.
  final refresh = ValueNotifier(0);
  ref.listen(sessionProvider, (_, _) => refresh.value++);
  ref.onDispose(refresh.dispose);

  return GoRouter(
    refreshListenable: refresh,
    redirect: (context, state) {
      final s = ref.read(sessionProvider);
      final loc = state.matchedLocation;
      // Remember where the user wanted to go (deep link / page reload) across splash and login.
      final from = loc == '/splash' || _publicRoutes.contains(loc)
          ? state.uri.queryParameters['from']
          : state.uri.toString();
      String withFrom(String path) => from == null || from == '/' ? path : '$path?from=${Uri.encodeComponent(from)}';

      if (s.loading) return loc == '/splash' ? null : withFrom('/splash');
      if (s.serverUrl == null && !kIsWeb) return loc == '/server' ? null : '/server';
      if (!s.loggedIn) {
        return _publicRoutes.contains(loc) ? null : withFrom('/login');
      }
      if (_publicRoutes.contains(loc) || loc == '/splash') return from ?? '/';
      if (loc.startsWith('/admin') && !(s.user?.isAdmin ?? false)) return '/';
      return null;
    },
    routes: [
      GoRoute(
        path: '/splash',
        builder: (_, _) => const Scaffold(body: Center(child: CircularProgressIndicator())),
      ),
      GoRoute(path: '/server', builder: (_, _) => const ServerPage()),
      GoRoute(path: '/login', builder: (_, _) => const LoginPage()),
      GoRoute(
        path: '/register',
        builder: (_, state) => RegisterPage(invite: state.uri.queryParameters['invite']),
      ),
      GoRoute(
        path: '/now-playing',
        pageBuilder: (_, _) => CustomTransitionPage(
          child: const NowPlayingPage(),
          transitionsBuilder: (_, animation, _, child) => SlideTransition(
            position: Tween(
              begin: const Offset(0, 1),
              end: Offset.zero,
            ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
            child: child,
          ),
        ),
      ),
      // Outside the shell so it opens above the now-playing page and the mini player.
      GoRoute(path: '/queue', builder: (_, _) => const QueuePage()),
      GoRoute(path: '/lyrics', builder: (_, _) => const LyricsPage()),
      ShellRoute(
        builder: (context, state, child) => AppShell(location: state.matchedLocation, child: child),
        routes: [
          GoRoute(
            path: '/',
            pageBuilder: (_, _) => const NoTransitionPage(child: HomePage()),
          ),
          GoRoute(
            path: '/search',
            pageBuilder: (_, _) => const NoTransitionPage(child: SearchPage()),
          ),
          GoRoute(
            path: '/library',
            pageBuilder: (_, _) => const NoTransitionPage(child: LibraryPage()),
          ),
          GoRoute(path: '/world-radio', builder: (_, _) => const WorldRadioPage()),
          GoRoute(
            path: '/jam/:code',
            builder: (_, state) => JoinJamPage(code: state.pathParameters['code']!),
          ),
          GoRoute(path: '/liked', builder: (_, _) => const LikedPage()),
          GoRoute(
            path: '/album/:id',
            builder: (_, s) => AlbumPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/artist/:id',
            builder: (_, s) => ArtistPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/playlist/:id',
            builder: (_, s) => PlaylistPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/catalog/album/:id',
            builder: (_, s) => CatalogAlbumPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/catalog/artist/:id',
            builder: (_, s) => CatalogArtistPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/downloads',
            pageBuilder: (_, _) => const NoTransitionPage(child: DownloadsPage()),
          ),
          GoRoute(
            path: '/downloads/:id',
            builder: (_, s) => RequestDetailPage(id: s.pathParameters['id']!),
          ),
          GoRoute(
            path: '/audiobooks',
            pageBuilder: (_, _) => const NoTransitionPage(child: AudiobooksPage()),
          ),
          GoRoute(
            path: '/audiobooks/item/:id',
            builder: (_, s) => AudiobookPage(id: s.pathParameters['id']!),
          ),
          GoRoute(path: '/settings', builder: (_, _) => const SettingsPage()),
          GoRoute(path: '/spotify', builder: (_, _) => const SpotifyImportPage()),
          GoRoute(
            path: '/admin',
            pageBuilder: (_, _) => const NoTransitionPage(child: AdminPage()),
          ),
          GoRoute(path: '/admin/duplicates', builder: (_, _) => const DuplicatesPage()),
        ],
      ),
    ],
  );
});
