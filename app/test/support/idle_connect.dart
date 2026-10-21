import 'package:resonance/player/connect.dart';

/// Widget tests that exercise local playback do not open a network connection.
class IdleConnect extends ConnectController {
  @override
  ConnectView build() {
    ref.onDispose(messages.close);
    return const ConnectView(deviceId: 'test-device', name: 'Test device', kind: 'desktop');
  }
}
