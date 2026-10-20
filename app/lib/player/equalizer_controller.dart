import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/session.dart';
import 'equalizer.dart';

bool get supportsEqualizer =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows);

class EqualizerController extends Notifier<EqualizerSettings> {
  Timer? _save;
  EqualizerSettings? _pending;

  @override
  EqualizerSettings build() {
    final prefs = ref.read(prefsProvider);
    ref.onDispose(() {
      _save?.cancel();
      final pending = _pending;
      if (pending != null) prefs.setString('equalizer', jsonEncode(pending.toJson()));
    });
    final saved = prefs.getString('equalizer');
    if (saved != null) {
      try {
        return EqualizerSettings.fromJson(jsonDecode(saved) as Map<String, dynamic>);
      } catch (_) {
        // An invalid preference falls back to a disabled, flat equalizer.
      }
    }
    return EqualizerSettings();
  }

  void set(EqualizerSettings settings) {
    state = settings;
    _pending = settings;
    _save?.cancel();
    _save = Timer(const Duration(milliseconds: 80), () {
      ref.read(prefsProvider).setString('equalizer', jsonEncode(settings.toJson()));
      _pending = null;
    });
  }
}

final equalizerProvider = NotifierProvider<EqualizerController, EqualizerSettings>(EqualizerController.new);
