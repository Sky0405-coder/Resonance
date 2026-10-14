import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/audiobooks.dart';
import '../core/downloads.dart';
import '../core/library.dart';
import '../core/models.dart';
import '../core/session.dart';
import '../core/theme.dart';
import 'widgets/common.dart';
import 'widgets/player_bar.dart';
import 'widgets/track_list.dart';

/// App frame: Spotify-style sidebar + player bar on desktop, bottom nav + mini player on mobile.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.child, required this.location});
  final Widget child;
  final String location;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(sessionProvider.select((s) => s.user?.isAdmin ?? false));
    final audiobooks = ref.watch(absStatusProvider).value?.enabled ?? false;
    final pendingApproval = isAdmin ? ref.watch(downloadSummaryProvider).value?.pendingApproval ?? 0 : 0;
    // Refresh library views whenever downloads finish.
    ref.listen(downloadSummaryProvider, (prev, next) {
      final before = prev?.value?.running ?? 0;
      final now = next.value?.running;
      if (now != null && now < before) ref.read(downloadActionsProvider).libraryChanged();
    });

    if (isWide(context)) {
      return Scaffold(
        backgroundColor: Palette.sidebar,
        body: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    SizedBox(
                      width: 300,
                      child: _Sidebar(location: location, isAdmin: isAdmin),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ColoredBox(color: Palette.background, child: child),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const DesktopPlayerBar(),
          ],
        ),
      );
    }

    final tabs = [
      ('/', Icons.home_outlined, Icons.home, 'Start'),
      ('/search', Icons.search, Icons.search, 'Suche'),
      ('/library', Icons.library_music_outlined, Icons.library_music, 'Bibliothek'),
      if (audiobooks) ('/audiobooks', Icons.headphones_outlined, Icons.headphones, 'Hörbücher'),
      if (isAdmin) ('/admin', Icons.admin_panel_settings_outlined, Icons.admin_panel_settings, 'Admin'),
    ];
    var selected = tabs.lastIndexWhere((t) => t.$1 != '/' && location.startsWith(t.$1));
    if (selected < 0) selected = 0;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: child),
          const Positioned(left: 0, right: 0, bottom: 4, child: MiniPlayer()),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 64,
        selectedIndex: selected,
        onDestinationSelected: (i) => context.go(tabs[i].$1),
        destinations: [
          for (final t in tabs)
            NavigationDestination(
              icon: Badge(
                isLabelVisible: t.$1 == '/admin' && pendingApproval > 0,
                label: Text('$pendingApproval'),
                child: Icon(t.$2),
              ),
              selectedIcon: Icon(t.$3),
              label: t.$4,
            ),
        ],
      ),
    );
  }
}

class _Sidebar extends ConsumerWidget {
  const _Sidebar({required this.location, required this.isAdmin});
  final String location;
  final bool isAdmin;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final userId = ref.watch(currentUserIdProvider);
    final summary = ref.watch(downloadSummaryProvider).value ?? const DownloadSummary();

    Widget nav(String path, IconData icon, IconData activeIcon, String label, {int badge = 0}) {
      final active = path == '/' ? location == '/' : location.startsWith(path);
      return ListTile(
        leading: Badge(
          isLabelVisible: badge > 0,
          label: Text('$badge'),
          child: Icon(active ? activeIcon : icon, color: active ? Colors.white : Palette.textMuted),
        ),
        title: Text(
          label,
          style: TextStyle(fontWeight: FontWeight.w700, color: active ? Colors.white : Palette.textMuted),
        ),
        onTap: () => context.go(path),
      );
    }

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(color: Palette.surface, borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            children: [
              nav('/', Icons.home_outlined, Icons.home, 'Start'),
              nav('/search', Icons.search, Icons.search, 'Suche'),
              nav('/downloads', Icons.download_outlined, Icons.download, 'Downloads', badge: summary.running),
              if (ref.watch(absStatusProvider).value?.enabled ?? false)
                nav('/audiobooks', Icons.headphones_outlined, Icons.headphones, 'Hörbücher'),
              if (isAdmin)
                nav(
                  '/admin',
                  Icons.admin_panel_settings_outlined,
                  Icons.admin_panel_settings,
                  'Admin-Dashboard',
                  badge: summary.pendingApproval,
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: Palette.surface, borderRadius: BorderRadius.circular(8)),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.library_music, color: Palette.textMuted),
                  title: const Text(
                    'Bibliothek',
                    style: TextStyle(fontWeight: FontWeight.w700, color: Palette.textMuted),
                  ),
                  onTap: () => context.go('/library'),
                  trailing: IconButton(
                    tooltip: 'Playlist erstellen',
                    icon: const Icon(Icons.add, color: Palette.textMuted),
                    onPressed: () async {
                      final name = await promptText(context, 'Neue Playlist', 'Name');
                      if (name == null || name.isEmpty) return;
                      final p = await ref.read(libraryActionsProvider).createPlaylist(name);
                      if (context.mounted) context.go('/playlist/${p.id}');
                    },
                  ),
                ),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      _SidebarItem(
                        image: const LikedCover(),
                        title: 'Lieblingssongs',
                        subtitle: 'Playlist',
                        active: location == '/liked',
                        onTap: () => context.go('/liked'),
                      ),
                      ...?playlists.value?.map(
                        (p) => _SidebarItem(
                          image: PlaylistCover(albumIds: p.coverAlbumIds),
                          title: p.name,
                          subtitle: p.owner.id == userId ? 'Playlist' : 'Playlist • ${p.owner.name}',
                          active: location == '/playlist/${p.id}',
                          onTap: () => context.go('/playlist/${p.id}'),
                        ),
                      ),
                    ],
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_outlined, color: Palette.textMuted),
                  title: const Text('Einstellungen', style: TextStyle(color: Palette.textMuted)),
                  onTap: () => context.go('/settings'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SidebarItem extends StatelessWidget {
  const _SidebarItem({
    required this.image,
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onTap,
  });

  final Widget image;
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: active ? Colors.white12 : Colors.transparent,
    borderRadius: BorderRadius.circular(6),
    child: InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            SizedBox(width: 48, child: image),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  Text(subtitle, style: const TextStyle(color: Palette.textMuted, fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
