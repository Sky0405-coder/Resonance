import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop.dart';
import 'session.dart';

/// Resolved before runApp so Android TV never briefly displays the touch shell.
final androidTvProvider = Provider<bool>((ref) => false);

Future<bool> detectAndroidTv() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return false;
  try {
    return await const MethodChannel('resonance/device').invokeMethod<bool>('isTv') ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

final tvModeProvider = NotifierProvider<TvMode, bool>(TvMode.new);

class TvMode extends Notifier<bool> {
  @override
  bool build() {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) return ref.watch(androidTvProvider);
    return isDesktop && (ref.read(prefsProvider).getBool('tv_mode') ?? false);
  }

  void set(bool enabled) {
    if (!isDesktop) return;
    ref.read(prefsProvider).setBool('tv_mode', enabled);
    state = enabled;
  }

  Future<void> toggleFullscreen() async {
    if (!isDesktop) return;
    set(!state);
    try {
      await windowManager.setFullScreen(state);
    } on PlatformException catch (error) {
      debugPrint('TV fullscreen unavailable: $error');
    } on MissingPluginException {
      // A missing window host must not prevent switching the interface.
    }
  }
}
