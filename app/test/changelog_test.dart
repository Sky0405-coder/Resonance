import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:resonance/core/changelog.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/core/updates.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<ProviderContainer> _container({String? seen, String? current = '1.6.10'}) async {
  SharedPreferences.setMockInitialValues({changelogSeenVersionKey: ?seen});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [prefsProvider.overrideWithValue(prefs), installedVersionProvider.overrideWith((ref) async => current)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundled notes cover every release and tag with matching dates and bilingual bullets', () async {
    final container = await _container();
    final entries = await container.read(changelogProvider.future);
    final tags = await Process.run('git', ['tag', '--sort=-version:refname', '-l', 'v*']);
    expect(tags.exitCode, 0);
    final versions = (tags.stdout as String).trim().split('\n').map((tag) => tag.substring(1));
    expect(entries.map((entry) => entry.version), versions);
    final releases = await Process.run('git', ['log', '--format=%s', '--grep=^Release ']);
    expect(releases.exitCode, 0);
    for (final release in (releases.stdout as String).trim().split('\n')) {
      expect(entries.map((entry) => entry.version), contains(release.substring('Release '.length)));
    }
    for (final entry in entries) {
      expect(entry.de.length, inInclusiveRange(2, 8), reason: entry.version);
      expect(entry.en.length, entry.de.length, reason: entry.version);
      expect([...entry.de, ...entry.en].every((bullet) => bullet.trim().isNotEmpty), isTrue);
      final date = await Process.run('git', ['log', '-1', '--format=%cs', 'v${entry.version}']);
      expect(date.exitCode, 0);
      expect(entry.date, DateTime.parse((date.stdout as String).trim()));
      expect(entry.bullets('de'), entry.de);
      expect(entry.bullets('en'), entry.en);
      expect(entry.bullets('fr'), entry.en);
    }
  });

  test('first installation saves the running version without showing any history', () async {
    final container = await _container();
    expect(await container.read(whatsNewProvider.future), isEmpty);
    expect(container.read(prefsProvider).getString(changelogSeenVersionKey), '1.6.10');
  });

  test('updates include every unseen version in numeric order through the running version', () async {
    final container = await _container(seen: '1.6.7');
    final entries = await container.read(whatsNewProvider.future);
    expect(entries.map((entry) => entry.version), ['1.6.10', '1.6.9', '1.6.8']);
    expect(container.read(prefsProvider).getString(changelogSeenVersionKey), '1.6.7');
  });

  test('future releases are excluded and build suffixes do not change the version comparison', () async {
    final container = await _container(seen: '1.6.7+37', current: '1.6.9+39');
    final entries = await container.read(whatsNewProvider.future);
    expect(entries.map((entry) => entry.version), ['1.6.9', '1.6.8']);
  });

  for (final seen in ['1.6.10', '1.6.11', '2.0.0']) {
    test('equal versions and downgrades show nothing and preserve the seen version $seen', () async {
      final container = await _container(seen: seen);
      expect(await container.read(whatsNewProvider.future), isEmpty);
      expect(container.read(prefsProvider).getString(changelogSeenVersionKey), seen);
    });
  }

  test('an invalid saved preference establishes a new baseline', () async {
    final container = await _container(seen: 'invalid');
    expect(await container.read(whatsNewProvider.future), isEmpty);
    expect(container.read(prefsProvider).getString(changelogSeenVersionKey), '1.6.10');
  });

  test('unavailable package metadata leaves preferences untouched and shows nothing', () async {
    for (final seen in [null, '1.6.7']) {
      final container = await _container(seen: seen, current: null);
      expect(await container.read(whatsNewProvider.future), isEmpty);
      expect(container.read(prefsProvider).getString(changelogSeenVersionKey), seen);
    }
  });

  test('acknowledged versions stay hidden in a fresh container', () async {
    final container = await _container(seen: '1.6.9');
    expect(await container.read(whatsNewProvider.future), hasLength(1));
    final prefs = container.read(prefsProvider);
    await prefs.setString(changelogSeenVersionKey, '1.6.10');
    final restarted = ProviderContainer(
      overrides: [
        prefsProvider.overrideWithValue(prefs),
        installedVersionProvider.overrideWith((ref) async => '1.6.10'),
      ],
    );
    addTearDown(restarted.dispose);
    expect(await restarted.read(whatsNewProvider.future), isEmpty);
  });

  test('package metadata supplies the installed version independently of the server', () async {
    for (final version in ['1.6.10', '', 'unknown', '0.0.0']) {
      PackageInfo.setMockInitialValues(
        appName: 'Resonance',
        packageName: 'de.knode.resonance',
        version: version,
        buildNumber: '40',
        buildSignature: '',
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      expect(await container.read(installedVersionProvider.future), versionCode(version) == 1006010 ? version : null);
    }
  });

  test('release guard blocks missing or invalid notes before changing the version or building', () async {
    final source = File('../scripts/release-android.sh').readAsStringSync();
    final directory = Directory.systemTemp.createTempSync('resonance-release-test-');
    addTearDown(() => directory.deleteSync(recursive: true));
    Directory('${directory.path}/scripts').createSync();
    Directory('${directory.path}/app/assets').createSync(recursive: true);
    final script = File('${directory.path}/scripts/release-android.sh')..writeAsStringSync(source);
    final pubspec = File('${directory.path}/app/pubspec.yaml');
    final notes = File('${directory.path}/app/assets/changelog.json');
    final marker = File('${directory.path}/build-invoked');
    final flutter = File('${directory.path}/flutter')
      ..writeAsStringSync('#!/bin/sh\nprintf "%s" "\$*" > "\$RELEASE_TEST_BUILD"\nexit 42\n');
    await Process.run('chmod', ['+x', flutter.path]);
    final environment = {'FLUTTER': flutter.path, 'RESONANCE_TOKEN': 'test-token', 'RELEASE_TEST_BUILD': marker.path};
    for (final content in [null, 'invalid', '{}', '[]', '[{"version":"1.6.9"}]']) {
      pubspec.writeAsStringSync('version: 1.6.9+39\n');
      if (content != null) notes.writeAsStringSync(content);
      final result = await Process.run('sh', [script.path], environment: environment);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Release blocked: app/assets/changelog.json:'));
      expect(result.stderr, contains('Add the changelog entry before releasing.'));
      expect(pubspec.readAsStringSync(), 'version: 1.6.9+39\n');
      expect(marker.existsSync(), false);
    }
    for (final override in [null, '1.7.0']) {
      pubspec.writeAsStringSync('version: 1.6.9+39\n');
      final version = override ?? '1.6.10';
      notes.writeAsStringSync(
        jsonEncode([
          {'version': version},
        ]),
      );
      final result = await Process.run('sh', [script.path], environment: {...environment, 'VERSION': ?override});
      expect(result.exitCode, 42, reason: '${result.stdout}\n${result.stderr}');
      expect(marker.readAsStringSync(), 'build apk --release');
      expect(pubspec.readAsStringSync(), 'version: $version+40\n');
    }
  });
}
