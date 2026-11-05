import 'dart:io';

import 'package:flutter/services.dart';

import '../core/models.dart';
import 'offline_store.dart';

const _channel = MethodChannel('resonance/export');

/// [name] usable as a file or folder name on Android, Windows and Linux.
String safeFileName(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim()
      .replaceAll(RegExp(r'^\.+|\.+$'), '');
  final short = cleaned.length > 120 ? cleaned.substring(0, 120).trim() : cleaned;
  return short.isEmpty ? '_' : short;
}

/// "Artist - Title.ext" for a downloaded song file.
String exportFileName(Track track, String file) {
  final dot = file.lastIndexOf('.');
  final extension = dot < 0 ? '' : file.substring(dot).toLowerCase();
  return '${safeFileName('${track.artistCredit} - ${track.title}')}$extension';
}

String audioMime(String name) => switch (name.substring(name.lastIndexOf('.') + 1).toLowerCase()) {
  'mp3' => 'audio/mpeg',
  'flac' => 'audio/flac',
  'm4a' || 'mp4' || 'aac' => 'audio/mp4',
  'wav' => 'audio/wav',
  _ => 'audio/ogg',
};

/// One song to copy: the downloaded file, its folder (the collection) and its readable name.
typedef ExportItem = ({String path, String folder, String name});

/// The downloaded songs of [collections] (all when null), each in a folder named after its collection.
List<ExportItem> exportItems(OfflineState offline, {Iterable<String>? collections}) {
  final keys = collections?.toSet();
  return [
    for (final collection in offline.collections.values)
      if (keys == null || keys.contains(collection.key))
        for (final track in collection.orderedTracks)
          if (offline.filePath(track.id) case final path?)
            (
              path: path,
              folder: safeFileName(collection.kind == 'liked' ? 'Liked Songs' : collection.name),
              name: exportFileName(track, offline.tracks[track.id]!.file!),
            ),
  ];
}

/// Android: into Music/Resonance via MediaStore. Desktop: into a folder the user picked ([target]).
bool get exportNeedsFolder => !Platform.isAndroid;

Future<bool> exportSupported() async =>
    !Platform.isAndroid || (await _channel.invokeMethod<bool>('supported') ?? false);

/// Copies [items]; returns how many were new (existing files are kept). [progress] gets the number done.
Future<int> exportSongs(List<ExportItem> items, {String? target, void Function(int done)? progress}) async {
  var added = 0;
  for (final (i, item) in items.indexed) {
    if (Platform.isAndroid) {
      final saved = await _channel.invokeMethod<bool>('save', {
        'path': item.path,
        'folder': item.folder,
        'name': item.name,
        'mime': audioMime(item.name),
      });
      if (saved ?? false) added++;
    } else {
      final directory = Directory('$target${Platform.pathSeparator}${item.folder}');
      await directory.create(recursive: true);
      final file = File('${directory.path}${Platform.pathSeparator}${item.name}');
      if (!await file.exists()) {
        await File(item.path).copy(file.path);
        added++;
      }
    }
    progress?.call(i + 1);
  }
  return added;
}
