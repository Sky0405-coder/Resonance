import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/tv_mode.dart';
import '../widgets/common.dart';
import 'tv_keyboard.dart';

class TvKeyboardSearch extends ConsumerStatefulWidget {
  const TvKeyboardSearch({super.key, required this.hint, required this.resultsBuilder});

  final String hint;
  final Widget Function(BuildContext context, String query, FocusNode firstResult) resultsBuilder;

  @override
  ConsumerState<TvKeyboardSearch> createState() => _TvKeyboardSearchState();
}

class _TvKeyboardSearchState extends ConsumerState<TvKeyboardSearch> {
  late final _firstResult = _SearchResultFocusNode(onAttach: _focusFirstResult, debugLabel: 'TV first search result');
  Timer? _debounce;
  String _input = '';
  String _query = '';
  bool _pendingSubmit = false;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addEarlyKeyEventHandler(_handleKey);
  }

  void _onText(String value) => _updateInput('$_input$value');

  void _onBackspace() {
    final characters = _input.characters;
    if (characters.isNotEmpty) _updateInput(characters.skipLast(1).toString());
  }

  void _onClear() => _updateInput('');

  void _updateInput(String value) {
    setState(() {
      _input = value;
      _pendingSubmit = false;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = _input.trim());
    });
  }

  void _submit() {
    _debounce?.cancel();
    setState(() {
      _query = _input.trim();
      _pendingSubmit = _query.isNotEmpty;
    });
    if (_pendingSubmit && _firstResult.context != null) _focusFirstResult();
  }

  void _focusFirstResult() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pendingSubmit || _firstResult.context == null) return;
      _pendingSubmit = false;
      _firstResult.requestFocus();
    });
  }

  KeyEventResult _handleKey(KeyEvent event) {
    if (!ref.read(tvModeProvider) || event is! KeyDownEvent) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused?.findAncestorWidgetOfExactType<TextField>() != null) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _onBackspace();
      return KeyEventResult.handled;
    }
    if ({LogicalKeyboardKey.enter, LogicalKeyboardKey.numpadEnter}.contains(event.logicalKey)) {
      _submit();
      return KeyEventResult.handled;
    }
    final character = event.character;
    if (character == null || character.isEmpty || character.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return KeyEventResult.ignored;
    }
    _onText(character);
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    FocusManager.instance.removeEarlyKeyEventHandler(_handleKey);
    _debounce?.cancel();
    _firstResult.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.all(32),
        child: InputDecorator(
          isEmpty: _input.isEmpty,
          decoration: searchDecoration(widget.hint),
          child: Text(_input, style: const TextStyle(fontSize: 28)),
        ),
      ),
      TvKeyboard(onText: _onText, onBackspace: _onBackspace, onClear: _onClear, onSubmit: _submit),
      Expanded(child: _query.isEmpty ? const SizedBox.shrink() : widget.resultsBuilder(context, _query, _firstResult)),
    ],
  );
}

class _SearchResultFocusNode extends FocusNode {
  _SearchResultFocusNode({required this.onAttach, super.debugLabel});

  final VoidCallback onAttach;

  @override
  // ignore: deprecated_member_use
  FocusAttachment attach(BuildContext? context, {FocusOnKeyEventCallback? onKeyEvent, FocusOnKeyCallback? onKey}) {
    // ignore: deprecated_member_use
    final attachment = super.attach(context, onKeyEvent: onKeyEvent, onKey: onKey);
    onAttach();
    return attachment;
  }
}
