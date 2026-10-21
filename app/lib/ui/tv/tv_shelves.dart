import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api.dart';
import '../../core/theme.dart';
import '../../l10n/l10n.dart';
import 'tv_focusable.dart';

class TvCardData {
  const TvCardData({required this.title, required this.image, required this.onActivate, this.subtitle});
  final String title;
  final String? subtitle;
  final Widget image;
  final VoidCallback onActivate;
}

class TvShelfData {
  const TvShelfData(this.title, this.cards);
  final String title;
  final List<TvCardData> cards;
}

/// All rows stay mounted so D-pad traversal can reach shelves outside the viewport.
class TvShelves extends StatefulWidget {
  const TvShelves({super.key, required this.title, required this.shelves, this.leading});
  final String title;
  final List<TvShelfData> shelves;
  final Widget? leading;

  @override
  State<TvShelves> createState() => _TvShelvesState();
}

class _TvShelvesState extends State<TvShelves> {
  final _nodes = <String, List<FocusNode>>{};

  List<TvShelfData> get _shelves => widget.shelves.where((row) => row.cards.isNotEmpty).toList();

  void _syncNodes() {
    final shelves = _shelves;
    for (final key in _nodes.keys.toList()) {
      if (!shelves.any((row) => row.title == key)) {
        for (final node in _nodes.remove(key)!) {
          node.dispose();
        }
      }
    }
    for (final shelf in shelves) {
      final nodes = _nodes.putIfAbsent(shelf.title, () => []);
      while (nodes.length > shelf.cards.length) {
        nodes.removeLast().dispose();
      }
      while (nodes.length < shelf.cards.length) {
        nodes.add(FocusNode(debugLabel: '${shelf.title}/${nodes.length}'));
      }
    }
  }

  bool _move(TraversalDirection direction) {
    final rows = _shelves;
    for (var row = 0; row < rows.length; row++) {
      final nodes = _nodes[rows[row].title]!;
      final column = nodes.indexWhere((node) => node.hasFocus);
      if (column < 0) continue;
      switch (direction) {
        case TraversalDirection.left:
          if (column == 0) return false;
          nodes[column - 1].requestFocus();
        case TraversalDirection.right:
          if (column == nodes.length - 1) return true;
          nodes[column + 1].requestFocus();
        case TraversalDirection.up:
          if (row == 0) return false;
          final target = _nodes[rows[row - 1].title]!;
          target[math.min(column, target.length - 1)].requestFocus();
        case TraversalDirection.down:
          if (row == rows.length - 1) return false;
          final target = _nodes[rows[row + 1].title]!;
          target[math.min(column, target.length - 1)].requestFocus();
      }
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    for (final nodes in _nodes.values) {
      for (final node in nodes) {
        node.dispose();
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _syncNodes();
    return Actions(
      actions: {
        TvDirectionIntent: CallbackAction<TvDirectionIntent>(
          onInvoke: (intent) {
            if (!_move(intent.direction)) FocusManager.instance.primaryFocus?.focusInDirection(intent.direction);
            return null;
          },
        ),
      },
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: (_, event) {
          if (event is KeyUpEvent) return KeyEventResult.ignored;
          final direction = switch (event.logicalKey) {
            LogicalKeyboardKey.arrowUp => TraversalDirection.up,
            LogicalKeyboardKey.arrowDown => TraversalDirection.down,
            LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
            LogicalKeyboardKey.arrowRight => TraversalDirection.right,
            _ => null,
          };
          return direction != null && _move(direction) ? KeyEventResult.handled : KeyEventResult.ignored;
        },
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(32, 0, 32, 24),
                child: Text(widget.title, style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800)),
              ),
              if (widget.leading != null) Padding(padding: const EdgeInsets.all(32), child: widget.leading),
              for (final shelf in _shelves) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 8),
                  child: Text(shelf.title, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.fromLTRB(32, 16, 32, 30),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final (index, card) in shelf.cards.indexed)
                        Padding(
                          padding: const EdgeInsets.only(right: 24),
                          child: SizedBox(
                            width: 226,
                            child: TvFocusable(
                              autofocus: shelf == _shelves.first && index == 0,
                              focusNode: _nodes[shelf.title]![index],
                              onActivate: card.onActivate,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  SizedBox(width: 220, height: 220, child: card.image),
                                  Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(card.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                                        if (card.subtitle != null)
                                          Text(
                                            card.subtitle!,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(color: Palette.textMuted, fontSize: 18),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class TvAsync<T> extends StatelessWidget {
  const TvAsync({super.key, required this.value, required this.builder, required this.onRetry});
  final AsyncValue<T> value;
  final Widget Function(T data) builder;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => value.when(
    data: builder,
    loading: () => const Center(child: CircularProgressIndicator()),
    error: (error, _) => Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ApiException.from(error, context.l10n).message),
            const SizedBox(height: 24),
            TvButton(icon: Icons.refresh, label: context.l10n.commonRetry, onPressed: onRetry, autofocus: true),
          ],
        ),
      ),
    ),
  );
}
