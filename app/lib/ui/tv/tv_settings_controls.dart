import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'tv_focusable.dart';

class TvSettingsList extends StatefulWidget {
  const TvSettingsList({super.key, required this.tvMode, required this.padding, required this.children});
  final bool tvMode;
  final EdgeInsetsGeometry padding;
  final List<Widget> children;

  @override
  State<TvSettingsList> createState() => _TvSettingsListState();
}

class _TvSettingsListState extends State<TvSettingsList> {
  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  bool _move(TraversalDirection direction, {bool controller = false}) {
    final focus = FocusManager.instance.primaryFocus;
    final focused = focus?.context;
    if (focused == null) return false;
    if (direction == TraversalDirection.down) return focus!.nextFocus();
    if (direction == TraversalDirection.up) return focus!.previousFocus();
    final right = direction == TraversalDirection.right;
    final tile = focused.findAncestorWidgetOfExactType<SwitchListTile>();
    if (tile?.onChanged != null) {
      tile!.onChanged!(right);
      return true;
    }
    final slider = focused.findAncestorWidgetOfExactType<Slider>();
    if (controller && slider?.onChanged != null) {
      final step = (slider!.max - slider.min) / (slider.divisions ?? 20);
      slider.onChanged!((slider.value + (right ? step : -step)).clamp(slider.min, slider.max));
      return true;
    }
    return false;
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (!widget.tvMode || event is KeyUpEvent) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorStateOfType<_TvSettingsListState>() != this) return KeyEventResult.ignored;
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
      LogicalKeyboardKey.arrowRight => TraversalDirection.right,
      _ => null,
    };
    return direction != null && _move(direction) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.tvMode
      ? Actions(
          actions: {
            TvDirectionIntent: CallbackAction<TvDirectionIntent>(
              onInvoke: (intent) {
                if (!_move(intent.direction, controller: true)) {
                  FocusManager.instance.primaryFocus?.focusInDirection(intent.direction);
                }
                return null;
              },
            ),
          },
          child: SingleChildScrollView(
            padding: widget.padding,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final child in widget.children) TvSettingsTile(child: child)],
            ),
          ),
        )
      : ListView(padding: widget.padding, children: widget.children);
}

/// Keeps Material's tile/slider actions while adding the TV focus treatment and remote switch adjustment.
class TvSettingsTile extends StatelessWidget {
  const TvSettingsTile({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 16),
    child: TvFocusable(
      skipTraversal: true,
      descendantsAreFocusable: true,
      onActivate: () {
        final focused = FocusManager.instance.primaryFocus?.context;
        if (focused != null) Actions.maybeInvoke(focused, const ActivateIntent());
      },
      child: Material(color: Colors.transparent, child: child),
    ),
  );
}
