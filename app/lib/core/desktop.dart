import 'dart:async';
import 'dart:io';
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

/// Menu entry for an AppImage started directly (Exec = the AppImage's path). Wayland desktops look up the taskbar
/// icon by app id in the .desktop files, so without it KDE/GNOME show a generic icon.
String appImageDesktopEntry(String appImage) {
  final exec = appImage.replaceAllMapped(RegExp(r'["`$\\]'), (m) => '\\${m[0]}').replaceAll('\\', '\\\\');
  return """[Desktop Entry]
Type=Application
Name=Resonance
GenericName=Music player
Comment=Your self-hosted music library
Exec="$exec" %U
Icon=de.knode.resonance
Categories=AudioVideo;Audio;Player;
StartupWMClass=de.knode.resonance
Terminal=false
""";
}

/// Installs/updates the menu entry and icon of the running AppImage in ~/.local/share (also after it was moved).
Future<void> registerAppImage() async {
  final appImage = Platform.environment['APPIMAGE'];
  final home = Platform.environment['HOME'];
  if (defaultTargetPlatform != TargetPlatform.linux || appImage == null || home == null) return;
  final dataHome = Platform.environment['XDG_DATA_HOME'] ?? '$home/.local/share';
  try {
    final icon = File('${File(Platform.resolvedExecutable).parent.path}/data/resonance.png');
    final iconTarget = File('$dataHome/icons/hicolor/512x512/apps/de.knode.resonance.png');
    if (!await iconTarget.exists() || await iconTarget.length() != await icon.length()) {
      await iconTarget.parent.create(recursive: true);
      await icon.copy(iconTarget.path);
    }
    final entry = File('$dataHome/applications/de.knode.resonance.desktop');
    final content = appImageDesktopEntry(appImage);
    if (await entry.exists() && await entry.readAsString() == content) return;
    await entry.parent.create(recursive: true);
    await entry.writeAsString(content);
  } on FileSystemException catch (e) {
    debugPrint('AppImage desktop integration failed: $e');
  }
}
