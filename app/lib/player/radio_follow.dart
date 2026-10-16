import 'dart:async';

import '../core/models.dart';

typedef RadioPlaylist = ({bool isRadio, List<Track> tracks, int? pendingDownloads});

/// Follows a playing radio without loading or restarting its current item.
class RadioFollow {
  RadioFollow({
    required this.loadPlaylist,
    required this.currentContext,
    required this.queuedTrackIds,
    required this.append,
  });

  final Future<RadioPlaylist> Function(String id) loadPlaylist;
  final String? Function() currentContext;
  final Set<String> Function() queuedTrackIds;
  final Future<void> Function(Track track, String context) append;

  Timer? _timer;
  Timer? _deadline;
  String? _context;
  int _generation = 0;
  int? _refreshing;
  bool _refreshAgain = false;
  int? _running;

  void contextChanged(String? context) {
    if (context == _context) return;
    _stop();
    if (context == null || !context.startsWith('playlist:')) return;
    _context = context;
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _refresh());
    // Playlist responses currently have no pending count.
    _deadline = Timer(const Duration(minutes: 30), _stop);
    _refresh();
  }

  void downloadRunningChanged(int running) {
    final previous = _running;
    _running = running;
    if (previous != null && running < previous) _refresh();
  }

  bool _current(int generation, String context) =>
      _generation == generation && _context == context && currentContext() == context;

  Future<void> _refresh() async {
    final context = _context;
    if (context == null) return;
    if (currentContext() != context) {
      _stop();
      return;
    }
    final generation = _generation;
    if (_refreshing == generation) {
      _refreshAgain = true;
      return;
    }
    _refreshing = generation;
    try {
      final playlist = await loadPlaylist(context.substring('playlist:'.length));
      if (!_current(generation, context)) return;
      if (!playlist.isRadio) {
        _stop();
        return;
      }
      if (playlist.pendingDownloads != null) {
        _deadline?.cancel();
        _deadline = null;
      }
      final seen = queuedTrackIds();
      for (final track in playlist.tracks) {
        if (!_current(generation, context)) return;
        if (!seen.add(track.id)) continue;
        await append(track, context);
      }
      if (_current(generation, context) && playlist.pendingDownloads == 0) _stop();
    } catch (_) {
      // A transient refresh failure leaves playback alone; retry on the next tick.
    } finally {
      if (_refreshing == generation) {
        _refreshing = null;
        final again = _refreshAgain;
        _refreshAgain = false;
        if (again && _current(generation, context)) _refresh();
      }
    }
  }

  void _stop() {
    _generation++;
    _timer?.cancel();
    _deadline?.cancel();
    _timer = _deadline = null;
    _context = null;
    _refreshAgain = false;
  }

  void dispose() => _stop();
}
