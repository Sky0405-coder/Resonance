import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'session.dart';

/// Installed version and, if the server has a newer APK, that release (Android only).
class AppUpdate {
  const AppUpdate({required this.installed, required this.installedCode, this.availableName, this.availableCode});
  final String installed;
  final int installedCode;
  final String? availableName;
  final int? availableCode;

  bool get available => availableCode != null && availableCode! > installedCode;
}

final appUpdateProvider = FutureProvider<AppUpdate?>((ref) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  final api = ref.watch(apiProvider);
  if (api.token == null) return null;
  final info = await PackageInfo.fromPlatform();
  final release = await api.androidRelease();
  return AppUpdate(
    installed: info.version,
    installedCode: int.tryParse(info.buildNumber) ?? 0,
    availableName: release?.versionName,
    availableCode: release?.versionCode,
  );
});
