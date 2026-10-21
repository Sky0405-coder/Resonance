import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/audiobooks.dart';
import '../../core/books.dart';
import '../../core/desktop.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import '../widgets/logo.dart';
import 'tv_focusable.dart';
import 'tv_now_playing.dart';

class TvShell extends ConsumerStatefulWidget {
  const TvShell({super.key, required this.location, required this.child});
  final String location;
  final Widget child;

  @override
  ConsumerState<TvShell> createState() => _TvShellState();
}

class _TvShellState extends ConsumerState<TvShell> {
  final _rail = FocusScopeNode(debugLabel: 'TV navigation');
  final _content = FocusScopeNode(debugLabel: 'TV content');
  final _home = FocusNode(debugLabel: 'TV Home');

  void _enterContent() {
    FocusNode target = _content;
    while (target is FocusScopeNode && target.focusedChild != null) {
      target = target.focusedChild!;
    }
    if (target is FocusScopeNode) {
      _content.nextFocus();
    } else {
      target.requestFocus();
    }
  }

  void _back() {
    final router = GoRouter.of(context);
    if (router.canPop()) {
      router.pop();
    } else if (widget.location != '/') {
      router.go('/');
    } else if (!_rail.hasFocus) {
      _home.requestFocus();
    } else if (!isDesktop) {
      SystemNavigator.pop();
    }
  }

  @override
  void dispose() {
    _rail.dispose();
    _content.dispose();
    _home.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final entries = [
      ('/', Icons.home_outlined, l10n.navHome),
      ('/search', Icons.search, l10n.navSearch),
      ('/library', Icons.library_music_outlined, l10n.navLibrary),
      ('/world-radio', Icons.public, l10n.worldRadioTitle),
      if (ref.watch(audiobooksVisibleProvider)) ('/audiobooks', Icons.headphones, l10n.navAudiobooks),
      if (ref.watch(ebooksVisibleProvider)) ('/books', Icons.menu_book, l10n.navBooks),
      ('/settings', Icons.settings_outlined, l10n.navSettings),
    ];
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.apply(fontSizeFactor: 1.35),
        focusColor: Colors.white24,
        listTileTheme: const ListTileThemeData(contentPadding: EdgeInsets.all(16), minTileHeight: 80),
      ),
      child: Actions(
        actions: {TvBackIntent: CallbackAction<TvBackIntent>(onInvoke: (_) => _back())},
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) _back();
          },
          child: Scaffold(
            backgroundColor: Palette.background,
            body: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        SizedBox(
                          width: MediaQuery.sizeOf(context).width < 1100 ? 210 : 280,
                          child: ColoredBox(
                            color: Palette.sidebar,
                            child: FocusScope(
                              node: _rail,
                              child: Actions(
                                actions: {
                                  TvDirectionIntent: CallbackAction<TvDirectionIntent>(
                                    onInvoke: (intent) {
                                      if (intent.direction == TraversalDirection.right) {
                                        _enterContent();
                                      } else {
                                        FocusManager.instance.primaryFocus?.focusInDirection(intent.direction);
                                      }
                                      return null;
                                    },
                                  ),
                                },
                                child: Focus(
                                  canRequestFocus: false,
                                  onKeyEvent: (_, event) {
                                    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.arrowRight) {
                                      _enterContent();
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: SingleChildScrollView(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        const Center(child: ResonanceLogo(size: 64)),
                                        const SizedBox(height: 32),
                                        for (final (path, icon, label) in entries)
                                          Padding(
                                            padding: const EdgeInsets.only(bottom: 16),
                                            child: TvFocusable(
                                              autofocus: path == '/',
                                              focusNode: path == '/' ? _home : null,
                                              onActivate: () => context.go(path),
                                              child: Padding(
                                                padding: const EdgeInsets.all(16),
                                                child: Row(
                                                  children: [
                                                    Icon(
                                                      icon,
                                                      color: widget.location == path ? theme.colorScheme.primary : null,
                                                    ),
                                                    const SizedBox(width: 14),
                                                    Expanded(child: Text(label, maxLines: 2)),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Expanded(
                          child: FocusScope(
                            node: _content,
                            child: FocusTraversalGroup(child: widget.child),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const TvNowPlayingBar(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
