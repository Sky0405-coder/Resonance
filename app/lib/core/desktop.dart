import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Linux and Windows apps (not the web build).
bool get isDesktop =>
    !kIsWeb && (defaultTargetPlatform == TargetPlatform.linux || defaultTargetPlatform == TargetPlatform.windows);

const _boundsKey = 'window_bounds';
const _maximizedKey = 'window_maximized';
const minWindowSize = Size(800, 560);

/// "x,y,w,h" → Rect; null for missing or broken values and windows smaller than the minimum.
Rect? parseBounds(String? value) {
  final parts = value?.split(',').map(double.tryParse).toList();
  if (parts == null || parts.length != 4 || parts.contains(null)) return null;
  final rect = Rect.fromLTWH(parts[0]!, parts[1]!, parts[2]!, parts[3]!);
  return rect.width < minWindowSize.width || rect.height < minWindowSize.height ? null : rect;
}

String formatBounds(Rect r) => [r.left, r.top, r.width, r.height].map((v) => v.round()).join(',');

/// Title, minimum size, and the size/position from the last session.
Future<void> initDesktopWindow(SharedPreferences prefs) async {
  await windowManager.ensureInitialized();
  final bounds = parseBounds(prefs.getString(_boundsKey));
  await windowManager.waitUntilReadyToShow(
    WindowOptions(title: 'Resonance', minimumSize: minWindowSize, size: bounds?.size ?? const Size(1280, 800)),
    () async {
      // Wayland does not let apps place windows; the position only applies on X11 and Windows.
      if (bounds != null) await windowManager.setPosition(bounds.topLeft);
      if (prefs.getBool(_maximizedKey) ?? false) await windowManager.maximize();
      await windowManager.show();
      await windowManager.focus();
    },
  );
  windowManager.addListener(_WindowSaver(prefs));
}

class _WindowSaver extends WindowListener {
  _WindowSaver(this.prefs);
  final SharedPreferences prefs;
  Timer? _debounce;

  void _save() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (await windowManager.isMaximized() || await windowManager.isMinimized()) return;
      await prefs.setString(_boundsKey, formatBounds(await windowManager.getBounds()));
    });
  }

  @override
  void onWindowResized() => _save();

  @override
  void onWindowMoved() => _save();

  @override
  void onWindowMaximize() => prefs.setBool(_maximizedKey, true);

  @override
  void onWindowUnmaximize() => prefs.setBool(_maximizedKey, false);
}
