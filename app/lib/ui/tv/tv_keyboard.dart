import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import 'tv_focusable.dart';

class TvKeyboard extends StatefulWidget {
  const TvKeyboard({
    super.key,
    required this.onText,
    required this.onBackspace,
    required this.onClear,
    required this.onSubmit,
  });

  final ValueChanged<String> onText;
  final VoidCallback onBackspace;
  final VoidCallback onClear;
  final VoidCallback onSubmit;

  @override
  State<TvKeyboard> createState() => _TvKeyboardState();
}

class _TvKeyboardState extends State<TvKeyboard> {
  static const _letters = [
    ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'],
    ['q', 'w', 'e', 'r', 't', 'z', 'u', 'i', 'o', 'p', 'ü'],
    ['a', 's', 'd', 'f', 'g', 'h', 'j', 'k', 'l', 'ö', 'ä'],
    ['y', 'x', 'c', 'v', 'b', 'n', 'm', 'ß', '-', "'"],
  ];

  late final _nodes = [
    for (final (row, keys) in [..._letters, List.filled(4, '')].indexed)
      [for (var column = 0; column < keys.length; column++) FocusNode(debugLabel: 'TV keyboard $row/$column')],
  ];

  void _activate(_KeyboardKey key) {
    switch (key.action) {
      case _KeyboardAction.space:
        widget.onText(' ');
      case _KeyboardAction.backspace:
        widget.onBackspace();
      case _KeyboardAction.clear:
        widget.onClear();
      case _KeyboardAction.submit:
        widget.onSubmit();
      case null:
        widget.onText(key.value!);
    }
  }

  bool _move(TraversalDirection direction) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return false;
    final row = _nodes.indexWhere((nodes) => nodes.contains(focus));
    if (row < 0) return false;
    final nodes = _nodes[row];
    final column = nodes.indexOf(focus);
    switch (direction) {
      case TraversalDirection.left:
        if (column == 0) return false;
        nodes[column - 1].requestFocus();
        return true;
      case TraversalDirection.right:
        if (column == nodes.length - 1) return true;
        nodes[column + 1].requestFocus();
        return true;
      case TraversalDirection.up:
        if (row == 0) return true;
        _focusAdjacent(row - 1, column, nodes.length);
        return true;
      case TraversalDirection.down:
        if (row == _nodes.length - 1) return false;
        _focusAdjacent(row + 1, column, nodes.length);
        return true;
    }
  }

  void _focusAdjacent(int row, int column, int sourceLength) {
    final target = _nodes[row];
    final targetColumn = sourceLength == 4 || target.length == 4
        ? (column / (sourceLength - 1) * (target.length - 1)).round()
        : math.min(column, target.length - 1);
    target[targetColumn].requestFocus();
  }

  bool _bubble(BuildContext context, TvDirectionIntent intent) {
    if (Actions.maybeFind<TvDirectionIntent>(context) != null) {
      Actions.invoke(context, intent);
      return true;
    }
    return FocusManager.instance.primaryFocus?.focusInDirection(intent.direction) ?? false;
  }

  @override
  void dispose() {
    for (final nodes in _nodes) {
      for (final node in nodes) {
        node.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rows = [
      for (final row in _letters) [for (final key in row) _KeyboardKey.character(key)],
      [
        _KeyboardKey.button(l10n.tvKeyboardSpace, Icons.space_bar, _KeyboardAction.space),
        _KeyboardKey.button(l10n.tvKeyboardDelete, Icons.backspace, _KeyboardAction.backspace),
        _KeyboardKey.button(l10n.tvKeyboardClear, Icons.clear_all, _KeyboardAction.clear),
        _KeyboardKey.button(l10n.tvKeyboardSearch, Icons.search, _KeyboardAction.submit),
      ],
    ];
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        final direction = switch (event.logicalKey) {
          LogicalKeyboardKey.arrowUp => TraversalDirection.up,
          LogicalKeyboardKey.arrowDown => TraversalDirection.down,
          LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
          LogicalKeyboardKey.arrowRight => TraversalDirection.right,
          _ => null,
        };
        if (direction == null) return KeyEventResult.ignored;
        if (_move(direction)) return KeyEventResult.handled;
        return _bubble(context, TvDirectionIntent(direction)) ? KeyEventResult.handled : KeyEventResult.ignored;
      },
      child: Actions(
        actions: {
          TvDirectionIntent: CallbackAction<TvDirectionIntent>(
            onInvoke: (intent) {
              if (!_move(intent.direction)) _bubble(context, intent);
              return null;
            },
          ),
        },
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final (rowIndex, row) in rows.indexed) ...[
                if (rowIndex > 0) const SizedBox(height: 10),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final (column, key) in row.indexed) ...[
                      if (column > 0) const SizedBox(width: 10),
                      SizedBox(
                        width: key.action == null ? 64 : 200,
                        height: 64,
                        child: TvFocusable(
                          key: ValueKey('tv-key-${key.value ?? key.action!.name}'),
                          focusNode: _nodes[rowIndex][column],
                          autofocus: rowIndex == 2 && column == 0,
                          label: key.value ?? key.label,
                          onActivate: () => _activate(key),
                          child: Center(
                            child: key.action == null
                                ? Text(key.value!, style: const TextStyle(fontSize: 26))
                                : Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(key.icon, size: 28),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          key.label,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(fontSize: 26),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _KeyboardAction { space, backspace, clear, submit }

class _KeyboardKey {
  const _KeyboardKey.character(this.value) : action = null, label = '', icon = null;
  const _KeyboardKey.button(this.label, this.icon, this.action) : value = null;

  final String? value;
  final String label;
  final IconData? icon;
  final _KeyboardAction? action;
}
