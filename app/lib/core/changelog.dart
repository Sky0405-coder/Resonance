import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'session.dart';
import 'updates.dart';

const changelogSeenVersionKey = 'changelog_seen_version';

class ChangelogEntry {
  const ChangelogEntry({required this.version, required this.date, required this.de, required this.en});

  factory ChangelogEntry.fromJson(Map<String, dynamic> json) => ChangelogEntry(
    version: json['version'] as String,
    date: DateTime.parse(json['date'] as String),
    de: List<String>.from(json['de'] as List),
    en: List<String>.from(json['en'] as List),
  );

  final String version;
  final DateTime date;
  final List<String> de;
  final List<String> en;

  List<String> bullets(String languageCode) => languageCode == 'de' ? de : en;
}

final changelogProvider = FutureProvider<List<ChangelogEntry>>((ref) async {
  final json = jsonDecode(await rootBundle.loadString('assets/changelog.json')) as List;
  return json.map((entry) => ChangelogEntry.fromJson(entry as Map<String, dynamic>)).toList()
    ..sort((a, b) => versionCode(b.version)!.compareTo(versionCode(a.version)!));
});

/// Independent of the update server, including when offline or on the web.
final installedVersionProvider = FutureProvider<String?>((ref) async {
  try {
    final version = (await PackageInfo.fromPlatform()).version;
    return (versionCode(version) ?? 0) > 0 ? version : null;
  } catch (_) {
    // Web deployments and platforms without package metadata cannot announce a version.
    return null;
  }
});

final whatsNewProvider = FutureProvider<List<ChangelogEntry>>((ref) async {
  final prefs = ref.watch(prefsProvider);
  final current = await ref.watch(installedVersionProvider.future);
  if (current == null) return const [];
  final currentCode = versionCode(current)!;
  final seenCode = versionCode(prefs.getString(changelogSeenVersionKey) ?? '');
  if (seenCode == null) {
    // First installation: establish a baseline without announcing the entire history.
    await prefs.setString(changelogSeenVersionKey, current);
    return const [];
  }
  if (seenCode >= currentCode) return const [];
  final entries = await ref.watch(changelogProvider.future);
  return entries.where((entry) {
    final code = versionCode(entry.version)!;
    return code > seenCode && code <= currentCode;
  }).toList();
});

/// Enabled by main() only; tests must explicitly opt in to automatic sheets.
final whatsNewEnabledProvider = Provider<bool>((ref) => false);
