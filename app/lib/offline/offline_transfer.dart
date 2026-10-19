import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Null on desktop, where the store keeps its sequential dio worker.
final offlineTransferProvider = Provider<OfflineTransfer?>((ref) {
  if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) return null;
  final transfer = BackgroundOfflineTransfer();
  ref.onDispose(transfer.dispose);
  return transfer;
});

abstract class OfflineTransfer {
  Stream<TaskStatusUpdate> get updates;
  Future<List<TaskStatusUpdate>> restore();
  Future<bool> enqueue(DownloadTask task);
  Future<void> cancel(Iterable<String> taskIds);
  void configureNotifications(String running, String complete);

  Future<DownloadTask> createTask({
    required String id,
    required String url,
    required Map<String, String> headers,
    required String directory,
    required bool wifiOnly,
    required String token,
  }) async {
    // Use the actual provider directory, retaining a container-relative path on iOS.
    final (baseDirectory, subdirectory, filename) = await Task.split(filePath: '$directory/tracks/$id.download');
    return DownloadTask(
      taskId: 'offline:$id',
      group: 'offline',
      url: url,
      headers: headers,
      baseDirectory: baseDirectory,
      directory: subdirectory,
      filename: filename,
      retries: 3,
      requiresWiFi: wifiOnly,
      updates: Updates.statusAndProgress,
      allowPause: false,
      metaData: token,
    );
  }
}

class BackgroundOfflineTransfer extends OfflineTransfer {
  BackgroundOfflineTransfer() {
    _downloader.registerCallbacks(group: 'offline', taskStatusCallback: _updates.add);
  }

  final _downloader = FileDownloader();
  final _updates = StreamController<TaskStatusUpdate>.broadcast();
  Future<void>? _notificationPermission;

  @override
  Stream<TaskStatusUpdate> get updates => _updates.stream;

  @override
  Future<List<TaskStatusUpdate>> restore() async {
    await _downloader.trackTasks();
    await _downloader.resumeFromBackground();
    final active = await _downloader.allTasks(group: 'offline');
    final activeIds = active.map((task) => task.taskId).toSet();
    final records = await _downloader.database.allRecords(group: 'offline');
    return [
      for (final task in active) TaskStatusUpdate(task, TaskStatus.enqueued),
      for (final record in records)
        if (record.status.isFinalState && !activeIds.contains(record.taskId))
          TaskStatusUpdate(record.task, record.status),
    ];
  }

  @override
  Future<bool> enqueue(DownloadTask task) async {
    await (_notificationPermission ??= _requestNotificationPermission());
    return _downloader.enqueue(task);
  }

  Future<void> _requestNotificationPermission() async {
    final permissions = _downloader.permissions;
    if (await permissions.status(PermissionType.notifications) != PermissionStatus.granted) {
      await permissions.request(PermissionType.notifications);
    }
  }

  @override
  Future<void> cancel(Iterable<String> taskIds) async {
    await _downloader.cancelTasksWithIds(taskIds);
  }

  @override
  void configureNotifications(String running, String complete) {
    _downloader.configureNotificationForGroup(
      'offline',
      running: TaskNotification(running, ''),
      complete: TaskNotification(complete, ''),
      progressBar: true,
      groupNotificationId: 'offline',
    );
  }

  void dispose() {
    _downloader.unregisterCallbacks(group: 'offline');
    _updates.close();
  }
}
