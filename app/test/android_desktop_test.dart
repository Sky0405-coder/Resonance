import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:resonance/core/desktop.dart';
import 'package:resonance/core/theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Android on a desktop screen gets the desktop look', () {
    final desktop = buildTheme(Colors.green, desktop: true);
    expect(desktop.platform, TargetPlatform.linux);
    expect(desktop.visualDensity, VisualDensity.compact);
    expect(buildTheme(Colors.green).platform, TargetPlatform.android);
  });

  test('follows DeX being switched on and off while the app runs', () async {
    final container = ProviderContainer(overrides: [androidDesktopProvider.overrideWith(() => AndroidDesktop(true))]);
    addTearDown(container.dispose);
    expect(container.read(desktopUiProvider), isTrue);
    container.read(androidDesktopProvider.notifier).listen();
    Future<void> send(bool on) =>
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          'resonance/device',
          const StandardMethodCodec().encodeMethodCall(MethodCall('desktopMode', on)),
          (_) {},
        );
    await send(false);
    expect(container.read(desktopUiProvider), isFalse);
    await send(true);
    expect(container.read(desktopUiProvider), isTrue);
  });
}
