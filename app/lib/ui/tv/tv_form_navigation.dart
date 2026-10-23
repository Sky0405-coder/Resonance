import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tv_mode.dart';
import 'tv_focusable.dart';

/// Single-line inputs use Up/Down for form traversal on a TV, leaving Left/Right available for text editing.
class TvFormNavigation extends ConsumerStatefulWidget {
  const TvFormNavigation({super.key, required this.child});
  final Widget child;

  @override
  ConsumerState<TvFormNavigation> createState() => _TvFormNavigationState();
}

class _TvFormNavigationState extends ConsumerState<TvFormNavigation> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  bool _move(TraversalDirection direction) {
    final focus = FocusManager.instance.primaryFocus;
    switch (direction) {
      case TraversalDirection.down:
        return focus?.nextFocus() ?? false;
      case TraversalDirection.up:
        return focus?.previousFocus() ?? false;
      default:
        return focus?.focusInDirection(direction) ?? false;
    }
  }

  bool _bubble(TvDirectionIntent intent) {
    if (Actions.maybeFind<TvDirectionIntent>(context) != null) {
      Actions.invoke(context, intent);
      return true;
    }
    return FocusManager.instance.primaryFocus?.focusInDirection(intent.direction) ?? false;
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (event is KeyUpEvent || !ref.read(tvModeProvider)) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorStateOfType<_TvFormNavigationState>() != this) return KeyEventResult.ignored;
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };
    if (direction == null) return KeyEventResult.ignored;
    if (_move(direction)) return KeyEventResult.handled;
    return _bubble(TvDirectionIntent(direction)) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      TvDirectionIntent: CallbackAction<TvDirectionIntent>(
        onInvoke: (intent) {
          if (!_move(intent.direction)) _bubble(intent);
          return null;
        },
      ),
    },
    child: widget.child,
  );
}
