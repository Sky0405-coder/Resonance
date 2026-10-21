import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/session.dart';
import 'package:resonance/core/tv_mode.dart';
import 'package:resonance/player/spectrum.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('resonance/device');

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  Future<ProviderContainer> container({bool saved = false, bool androidTv = false}) async {
    SharedPreferences.setMockInitialValues({'tv_mode': saved});
    final prefs = await SharedPreferences.getInstance();
    final result = ProviderContainer(
      overrides: [prefsProvider.overrideWithValue(prefs), androidTvProvider.overrideWithValue(androidTv)],
    );
    addTearDown(result.dispose);
    return result;
  }

  test('desktop TV mode persists and enables the visualizer only in TV mode', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    final ref = await container();
    expect(ref.read(tvModeProvider), false);
    expect(ref.read(visualizerEnabledProvider), false);
    ref.read(tvModeProvider.notifier).set(true);
    expect(ref.read(tvModeProvider), true);
    expect(ref.read(prefsProvider).getBool('tv_mode'), true);
    expect(ref.read(visualizerEnabledProvider), true);
    ref.read(tvModeProvider.notifier).set(false);
    expect(ref.read(visualizerEnabledProvider), false);
  });

  test('Android TV is always enabled and phones ignore the desktop preference', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final tv = await container(androidTv: true);
    expect(tv.read(tvModeProvider), true);
    tv.read(tvModeProvider.notifier).set(false);
    expect(tv.read(tvModeProvider), true);
    final phone = await container(saved: true);
    expect(phone.read(tvModeProvider), false);
    phone.read(tvModeProvider.notifier).set(true);
    expect(phone.read(tvModeProvider), false);
  });

  test('TV detection uses the native leanback channel and tolerates unavailable plugins', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isTv');
      return true;
    });
    expect(await detectAndroidTv(), true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    expect(await detectAndroidTv(), false);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(code: 'unavailable');
    });
    expect(await detectAndroidTv(), false);
  });
}
