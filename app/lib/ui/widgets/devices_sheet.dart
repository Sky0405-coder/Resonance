import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/l10n.dart';
import '../../player/connect.dart';
import '../../player/jam.dart';
import 'common.dart';

IconData deviceKindIcon(String kind) => switch (kind) {
  'phone' => Icons.phone_android,
  'web' => Icons.language,
  'tv' => Icons.tv,
  _ => Icons.computer,
};

class DevicesButton extends ConsumerWidget {
  const DevicesButton({super.key, this.size = 24});
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final remote = ref.watch(remoteDeviceProvider);
    final jam = ref.watch(jamProvider) != null;
    return IconButton(
      tooltip: jam ? context.l10n.connectJamHint : context.l10n.connectPlayOn,
      icon: Icon(remote == null ? Icons.devices : Icons.speaker_group, size: size),
      color: remote == null ? null : Theme.of(context).colorScheme.primary,
      onPressed: () {
        if (jam) {
          showInfo(context, context.l10n.connectJamHint);
          return;
        }
        showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          builder: (_) => const DevicesSheet(),
        );
      },
    );
  }
}

class DevicesSheet extends ConsumerWidget {
  const DevicesSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final view = ref.watch(connectProvider);
    final jam = ref.watch(jamProvider) != null;
    final active = view.active;
    final devices = [
      ConnectDevice(
        id: view.deviceId,
        name: view.name,
        kind: view.kind,
        active: active == null || active.id == view.deviceId,
      ),
      ...view.devices.where((d) => d.id != view.deviceId),
    ];
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.75),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 16),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
              child: Text(context.l10n.connectPlayOn, style: Theme.of(context).textTheme.titleLarge),
            ),
            if (jam || !view.connected)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                child: Text(jam ? context.l10n.connectJamHint : context.l10n.connectUnavailable),
              ),
            for (final device in devices)
              ListTile(
                enabled: view.connected && !jam,
                selected: device.active,
                selectedColor: Theme.of(context).colorScheme.primary,
                leading: Icon(deviceKindIcon(device.kind)),
                title: Text(device.id == view.deviceId ? context.l10n.connectThisDevice : device.name),
                subtitle: device.id == view.deviceId ? Text(device.name) : null,
                trailing: device.active ? const Icon(Icons.equalizer) : null,
                onTap: () async {
                  try {
                    await ref.read(connectProvider.notifier).transferTo(device.id);
                    if (context.mounted) Navigator.of(context).pop();
                  } catch (e) {
                    if (context.mounted) showError(context, e);
                  }
                },
              ),
          ],
        ),
      ),
    );
  }
}

class ConnectBanner extends ConsumerWidget {
  const ConnectBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = ref.watch(remoteDeviceProvider);
    if (device == null) return const SizedBox.shrink();
    final accent = Theme.of(context).colorScheme.primary;
    return Container(
      width: double.infinity,
      color: accent,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Text(
        context.l10n.connectPlayingOn(device.name),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : Colors.black,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
