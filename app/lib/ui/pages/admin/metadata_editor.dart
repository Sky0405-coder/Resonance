import '../../../l10n/l10n.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/library.dart';
import '../../../core/models.dart';
import '../../../core/session.dart';
import '../../../core/theme.dart';
import '../../widgets/catalog.dart';
import '../../widgets/collection.dart';
import '../../widgets/common.dart';

// Admin-only tools to fix songs, albums and covers the automatic import got wrong.

final _uuid = RegExp(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', caseSensitive: false);

Widget _dialogFrame(BuildContext context, String title, Widget child, {double maxWidth = 760}) => Dialog(
  clipBehavior: Clip.antiAlias,
  child: ConstrainedBox(
    constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: 680),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 8, 0),
          child: Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleLarge)),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ],
          ),
        ),
        Expanded(child: child),
      ],
    ),
  ),
);

String _durationLabel(double? seconds) => seconds == null ? '' : formatDuration(Duration(seconds: seconds.round()));

String _sourceLabel(BuildContext context, String source) => switch (source) {
  'apple' => context.l10n.editorSourceApple,
  'discogs' => context.l10n.editorSourceDiscogs,
  'musicbrainz' => context.l10n.editorSourceMusicBrainz,
  _ => context.l10n.editorSourceDeezer,
};

// --- song --------------------------------------------------------------------

/// Song menu → "Metadaten korrigieren": catalog search, AcoustID matches or manual edit.
Future<void> showTrackEditor(BuildContext context, WidgetRef ref, Track track) async {
  final updated = await showDialog<Track>(
    context: context,
    builder: (_) => _TrackEditor(track: track),
  );
  if (updated == null || !context.mounted) return;
  ref.read(libraryActionsProvider).libraryChanged();
  await ref.read(coverVersionsProvider.notifier).bump(updated.album.id);
  if (context.mounted) {
    showInfo(
      context,
      context.l10n.editorSavedTrack(
        (updated.title).toString(),
        (updated.artistCredit).toString(),
        (updated.album.name).toString(),
      ),
    );
  }
}

class _TrackEditor extends ConsumerStatefulWidget {
  const _TrackEditor({required this.track});
  final Track track;

  @override
  ConsumerState<_TrackEditor> createState() => _TrackEditorState();
}

class _TrackEditorState extends ConsumerState<_TrackEditor> {
  late final Future<TrackFile> _file = ref.read(apiProvider).trackFile(widget.track.id);
  bool _busy = false;

  Future<void> _apply(Map<String, dynamic> body) async {
    setState(() => _busy = true);
    try {
      final t = await ref.read(apiProvider).matchTrack(widget.track.id, body);
      if (mounted) Navigator.pop(context, t);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return _dialogFrame(
      context,
      context.l10n.editorCorrectMetadata,
      FutureBuilder<TrackFile>(
        future: _file,
        builder: (context, snap) {
          if (snap.hasError) {
            return Center(
              child: Text('${snap.error}', style: const TextStyle(color: Palette.textMuted)),
            );
          }
          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
          final f = snap.data!;
          return Stack(
            children: [
              DefaultTabController(
                length: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                      child: SelectableText(
                        '${f.path}\n${[f.codec?.toUpperCase(), if (f.bitrate != null) context.l10n.editorBitrate(f.bitrate!), _durationLabel(f.duration)].whereType<String>().join(' • ')}',
                        style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                      ),
                    ),
                    TabBar(
                      tabs: [
                        Tab(text: context.l10n.editorTabSearch),
                        Tab(text: context.l10n.editorTabFingerprint),
                        Tab(text: context.l10n.editorTabEdit),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _SearchTab(
                            file: f,
                            onPick: (source, id) =>
                                _apply({'source': source, source == 'apple' ? 'apple_id' : 'deezer_id': id}),
                          ),
                          _FingerprintTab(
                            trackId: widget.track.id,
                            onPick: (recording, release) =>
                                _apply({'source': 'musicbrainz', 'recording_id': recording, 'release_id': release}),
                          ),
                          _EditTab(file: f, onSave: (meta) => _apply({'source': 'manual', 'meta': meta})),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (_busy)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black54,
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _SearchTab extends ConsumerStatefulWidget {
  const _SearchTab({required this.file, required this.onPick});
  final TrackFile file;
  final void Function(String source, String id) onPick;

  @override
  ConsumerState<_SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends ConsumerState<_SearchTab> with AutomaticKeepAliveClientMixin {
  late final _query = TextEditingController(text: widget.file.query);
  Future<CatalogSearch>? _results;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (widget.file.query.trim().isNotEmpty) _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() => _results = ref.read(apiProvider).editorSearch(q, types: 'track'));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _query,
            autofocus: true,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: searchDecoration(
              context.l10n.editorSearchTrackHint,
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(context.l10n.editorChooseTrackHint, style: TextStyle(color: Palette.textMuted, fontSize: 12)),
        ),
        Expanded(
          child: _results == null
              ? const SizedBox()
              : FutureBuilder<CatalogSearch>(
                  future: _results,
                  builder: (context, snap) {
                    if (snap.hasError) return Center(child: Text('${snap.error}'));
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final tracks = snap.data!.tracks;
                    if (tracks.isEmpty) {
                      return Center(
                        child: Text(context.l10n.commonNothingFound, style: TextStyle(color: Palette.textMuted)),
                      );
                    }
                    return ListView.builder(
                      itemCount: tracks.length,
                      itemBuilder: (_, i) {
                        final t = tracks[i];
                        // Same length as the file (±3 s) is a strong hint for the right version.
                        final close = t.duration != null && (t.duration! - widget.file.duration).abs() <= 3;
                        return ListTile(
                          leading: SizedBox(
                            width: 44,
                            child: NetworkCover(url: t.coverUrl, icon: Icons.music_note),
                          ),
                          title: Text(t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            [t.artist, ?t.album, _sourceLabel(context, t.source)].join(' • '),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Palette.textMuted),
                          ),
                          trailing: Text(
                            _durationLabel(t.duration),
                            style: TextStyle(
                              color: close ? Theme.of(context).colorScheme.primary : Palette.textMuted,
                              fontWeight: close ? FontWeight.w700 : null,
                            ),
                          ),
                          onTap: () => widget.onPick(t.source, t.id),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _FingerprintTab extends ConsumerStatefulWidget {
  const _FingerprintTab({required this.trackId, required this.onPick});
  final String trackId;
  final void Function(String recordingId, String? releaseId) onPick;

  @override
  ConsumerState<_FingerprintTab> createState() => _FingerprintTabState();
}

class _FingerprintTabState extends ConsumerState<_FingerprintTab> with AutomaticKeepAliveClientMixin {
  late final Future<List<FingerprintMatch>> _matches = ref.read(apiProvider).trackFingerprint(widget.trackId);

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<FingerprintMatch>>(
      future: _matches,
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text('${snap.error}', style: const TextStyle(color: Palette.textMuted)),
          );
        }
        if (!snap.hasData) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text(context.l10n.editorFingerprintSearching, style: TextStyle(color: Palette.textMuted)),
              ],
            ),
          );
        }
        final matches = snap.data!;
        if (matches.isEmpty) {
          return Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                context.l10n.editorFingerprintUnknown,
                textAlign: TextAlign.center,
                style: TextStyle(color: Palette.textMuted),
              ),
            ),
          );
        }
        final accent = Theme.of(context).colorScheme.primary;
        return ListView(
          padding: const EdgeInsets.only(bottom: 16),
          children: [
            for (final m in matches) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: [m.title ?? context.l10n.editorUnknownTitle, ?m.artist].join(' – '),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: context.l10n.editorFingerprintScore((m.score * 100).round()),
                        style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              ListTile(
                dense: true,
                leading: Icon(Icons.auto_awesome, color: accent),
                title: Text(context.l10n.editorAutoSelectAlbum),
                onTap: () => widget.onPick(m.recordingId, null),
              ),
              for (final r in m.releases)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.album_outlined),
                  title: Text('${r.album ?? context.l10n.editorUnknownAlbum}${r.year != null ? ' (${r.year})' : ''}'),
                  subtitle: Text(
                    [
                      if (r.discNo != null && r.discNo! > 1) context.l10n.commonDiscNumber(r.discNo!),
                      if (r.trackNo != null)
                        context.l10n.editorTrackNumberWithTotal(
                          r.trackNo!,
                          (r.releaseTracks != null ? context.l10n.editorTrackTotalSuffix(r.releaseTracks!) : '')
                              .toString(),
                        ),
                    ].join(' • '),
                    style: const TextStyle(color: Palette.textMuted),
                  ),
                  onTap: () => widget.onPick(m.recordingId, r.releaseId),
                ),
            ],
          ],
        );
      },
    );
  }
}

class _EditTab extends StatefulWidget {
  const _EditTab({required this.file, required this.onSave});
  final TrackFile file;
  final void Function(Map<String, dynamic> meta) onSave;

  @override
  State<_EditTab> createState() => _EditTabState();
}

class _EditTabState extends State<_EditTab> with AutomaticKeepAliveClientMixin {
  late final Map<String, String> _initial = {
    'title': widget.file.title ?? '',
    'artist': widget.file.artist ?? '',
    'album': widget.file.album ?? '',
    'album_artist': widget.file.albumArtist ?? '',
    'year': widget.file.year?.toString() ?? '',
    'track_no': widget.file.trackNo?.toString() ?? '',
    'disc_no': widget.file.discNo?.toString() ?? '',
    'genre': widget.file.genre ?? '',
  };
  late final Map<String, TextEditingController> _c = {
    for (final e in _initial.entries) e.key: TextEditingController(text: e.value),
  };

  static const _numeric = {'year', 'track_no', 'disc_no'};

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _swap() {
    final title = _c['title']!.text;
    _c['title']!.text = _c['artist']!.text;
    _c['artist']!.text = title;
  }

  void _save() {
    final meta = <String, dynamic>{};
    for (final e in _c.entries) {
      final value = e.value.text.trim();
      if (value == _initial[e.key] || value.isEmpty) continue;
      if (_numeric.contains(e.key)) {
        final n = int.tryParse(value);
        if (n == null) {
          showError(context, context.l10n.editorNumbersOnly);
          return;
        }
        meta[e.key] = n;
      } else {
        meta[e.key] = value;
      }
    }
    if (meta.isEmpty) {
      showInfo(context, context.l10n.editorNoChanges);
      return;
    }
    widget.onSave(meta);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    Widget field(String key, String label, {double? width, bool number = false}) => SizedBox(
      width: width,
      child: TextField(
        controller: _c[key],
        keyboardType: number ? TextInputType.number : TextInputType.text,
        decoration: InputDecoration(labelText: label),
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: field('title', context.l10n.editorTitle)),
            IconButton(
              tooltip: context.l10n.editorSwapTitleArtist,
              icon: const Icon(Icons.swap_horiz),
              onPressed: _swap,
            ),
            Expanded(child: field('artist', context.l10n.commonArtist)),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: field('album', context.l10n.commonAlbum)),
            const SizedBox(width: 16),
            Expanded(child: field('album_artist', context.l10n.editorAlbumArtist)),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            field('year', context.l10n.editorYear, width: 100, number: true),
            field('track_no', context.l10n.editorTrackNumber, width: 80, number: true),
            field('disc_no', context.l10n.editorDisc, width: 80, number: true),
            field('genre', context.l10n.editorGenre, width: 220),
          ],
        ),
        const SizedBox(height: 16),
        Text(context.l10n.editorManualHint, style: TextStyle(color: Palette.textMuted, fontSize: 12)),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(
            onPressed: _save,
            icon: const Icon(Icons.save),
            label: Text(context.l10n.commonSave),
          ),
        ),
      ],
    );
  }
}

// --- album -------------------------------------------------------------------

/// Album page → "Album zuordnen": maps all songs of a library album onto a catalog release.
/// Returns the album the songs ended up in (may be a different id).
Future<Album?> showAlbumMatcher(BuildContext context, WidgetRef ref, AlbumDetail album) async {
  final result = await showDialog<AlbumMatchResult>(
    context: context,
    builder: (_) => _AlbumMatcher(album: album),
  );
  if (result == null || !context.mounted) return null;
  ref.read(libraryActionsProvider).libraryChanged();
  if (result.album != null) await ref.read(coverVersionsProvider.notifier).bump(result.album!.id);
  if (!context.mounted) return result.album;
  await showDialog<void>(
    context: context,
    builder: (d) => AlertDialog(
      title: Text(context.l10n.editorMatchedSongs(result.matched, result.matched + result.unmatched.length)),
      content: result.unmatched.isEmpty
          ? null
          : SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(context.l10n.editorUnmatchedSongs),
                  const SizedBox(height: 8),
                  for (final t in result.unmatched)
                    Text('• ${t.title} – ${t.artistCredit}', style: const TextStyle(color: Palette.textMuted)),
                ],
              ),
            ),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: Text(context.l10n.commonOk))],
    ),
  );
  return result.album;
}

class _AlbumMatcher extends ConsumerStatefulWidget {
  const _AlbumMatcher({required this.album});
  final AlbumDetail album;

  @override
  ConsumerState<_AlbumMatcher> createState() => _AlbumMatcherState();
}

class _AlbumMatcherState extends ConsumerState<_AlbumMatcher> {
  late final _query = TextEditingController(text: '${widget.album.album.artist.name} ${widget.album.album.title}');
  Future<CatalogSearch>? _results;
  String? _mbid;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _search();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    // A pasted MusicBrainz release link/id is used directly.
    final mbid = _uuid.firstMatch(q)?.group(0);
    setState(() {
      _mbid = mbid;
      _results = mbid == null ? ref.read(apiProvider).editorSearch(q, types: 'album') : null;
    });
  }

  Future<void> _apply(String source, String id) async {
    setState(() => _busy = true);
    try {
      final r = await ref.read(apiProvider).matchAlbum(widget.album.album.id, source, id);
      if (mounted) Navigator.pop(context, r);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.album.tracks.length;
    return _dialogFrame(
      context,
      context.l10n.editorMatchAlbum,
      Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onSubmitted: (_) => _search(),
                  decoration: searchDecoration(
                    context.l10n.editorSearchAlbumHint,
                    suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  context.l10n.editorMatchAlbumHint(count),
                  style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                ),
              ),
              Expanded(
                child: _mbid != null
                    ? ListView(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.album),
                            title: Text(context.l10n.editorUseMusicBrainzRelease),
                            subtitle: Text(_mbid!, style: const TextStyle(color: Palette.textMuted)),
                            onTap: () => _apply('musicbrainz', _mbid!),
                          ),
                        ],
                      )
                    : _results == null
                    ? const SizedBox()
                    : FutureBuilder<CatalogSearch>(
                        future: _results,
                        builder: (context, snap) {
                          if (snap.hasError) return Center(child: Text('${snap.error}'));
                          if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                          final albums = snap.data!.albums;
                          if (albums.isEmpty) {
                            return Center(
                              child: Text(context.l10n.commonNothingFound, style: TextStyle(color: Palette.textMuted)),
                            );
                          }
                          return ListView.builder(
                            itemCount: albums.length,
                            itemBuilder: (_, i) {
                              final a = albums[i];
                              return ListTile(
                                leading: SizedBox(width: 48, child: NetworkCover(url: a.coverUrl)),
                                title: Text(a.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                subtitle: Text(
                                  [
                                    a.artist,
                                    _sourceLabel(context, a.source),
                                    if (a.year != null) '${a.year}',
                                    if (a.recordType != null) a.recordType!,
                                  ].join(' • '),
                                  style: const TextStyle(color: Palette.textMuted),
                                ),
                                onTap: () => _apply(a.source, a.id),
                              );
                            },
                          );
                        },
                      ),
              ),
            ],
          ),
          if (_busy)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [CircularProgressIndicator(), SizedBox(height: 12), Text(context.l10n.editorRetagging)],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// --- cover -------------------------------------------------------------------

/// Album page → "Cover ändern": pick a suggested cover or upload an image.
Future<void> showCoverPicker(BuildContext context, WidgetRef ref, String albumId) async {
  final changed = await showDialog<bool>(
    context: context,
    builder: (_) => _CoverPicker(albumId: albumId),
  );
  if (changed != true || !context.mounted) return;
  await ref.read(coverVersionsProvider.notifier).bump(albumId);
  ref.read(libraryActionsProvider).libraryChanged();
  if (context.mounted) showInfo(context, context.l10n.editorCoverSaved);
}

class _CoverPicker extends ConsumerStatefulWidget {
  const _CoverPicker({required this.albumId});
  final String albumId;

  @override
  ConsumerState<_CoverPicker> createState() => _CoverPickerState();
}

class _CoverPickerState extends ConsumerState<_CoverPicker> {
  late final Future<List<CoverOption>> _options = ref.read(apiProvider).coverOptions(widget.albumId);
  bool _busy = false;

  Future<void> _run(Future<void> Function() fn) async {
    setState(() => _busy = true);
    try {
      await fn();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        showError(context, e);
      }
    }
  }

  Future<void> _upload() async {
    final file = await FilePicker.pickFile(type: FileType.image);
    if (file == null) return;
    final bytes = await file.readAsBytes();
    await _run(() => ref.read(apiProvider).uploadCover(widget.albumId, bytes, file.name));
  }

  @override
  Widget build(BuildContext context) {
    return _dialogFrame(
      context,
      context.l10n.editorChangeCover,
      Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        context.l10n.editorCoverSuggestionsHint,
                        style: TextStyle(color: Palette.textMuted, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _upload,
                      icon: const Icon(Icons.upload),
                      label: Text(context.l10n.editorUploadImage),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FutureBuilder<List<CoverOption>>(
                  future: _options,
                  builder: (context, snap) {
                    if (snap.hasError) return Center(child: Text('${snap.error}'));
                    if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                    final options = snap.data!;
                    if (options.isEmpty) {
                      return Center(
                        child: Text(context.l10n.editorNoCoverSuggestions, style: TextStyle(color: Palette.textMuted)),
                      );
                    }
                    return GridView.builder(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.78,
                      ),
                      itemCount: options.length,
                      itemBuilder: (_, i) {
                        final o = options[i];
                        return InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: _busy
                              ? null
                              : () => _run(() => ref.read(apiProvider).setCoverFromUrl(widget.albumId, o.url)),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              NetworkCover(url: o.url),
                              const SizedBox(height: 6),
                              Text(
                                o.label,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: ColoredBox(
                color: Colors.black54,
                child: Center(child: CircularProgressIndicator()),
              ),
            ),
        ],
      ),
    );
  }
}

// --- review list (admin tab) ---------------------------------------------------

/// Admin → "Zu prüfen": songs without MusicBrainz match and albums without cover.
class ReviewTab extends ConsumerStatefulWidget {
  const ReviewTab({super.key});

  @override
  ConsumerState<ReviewTab> createState() => _ReviewTabState();
}

class _ReviewTabState extends ConsumerState<ReviewTab> {
  static const _page = 50;
  String _kind = 'unidentified';
  final List<ReviewTrack> _items = [];
  int? _total;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
      if (reset) {
        _items.clear();
        _total = null;
      }
    });
    try {
      final (items, total) = await ref.read(apiProvider).review(kind: _kind, offset: _items.length, limit: _page);
      if (!mounted) return;
      setState(() {
        _items.addAll(items);
        _total = total;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _open(ReviewTrack r) async {
    if (_kind == 'no_cover') {
      await showCoverPicker(context, ref, r.track.album.id);
    } else {
      await showTrackEditor(context, ref, r.track);
    }
    // Fixed entries drop out of the list; reload the current window.
    if (mounted) _load(reset: true);
  }

  Future<void> _markReviewed(ReviewTrack r) async {
    try {
      await ref.read(apiProvider).markTrackReviewed(r.track.id);
      if (!mounted) return;
      setState(() {
        if (_items.remove(r) && _total != null) _total = _total! - 1;
      });
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final noCover = _kind == 'no_cover';
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, kBottomInset),
      itemCount: _items.length + 2,
      itemBuilder: (context, i) {
        if (i == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Wrap(
              spacing: 16,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(
                      value: 'unidentified',
                      label: Text(context.l10n.adminImportUnidentified),
                      icon: Icon(Icons.help_outline),
                    ),
                    ButtonSegment(
                      value: 'no_cover',
                      label: Text(context.l10n.editorNoCover),
                      icon: Icon(Icons.hide_image_outlined),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) {
                    _kind = s.first;
                    _load(reset: true);
                  },
                ),
                if (_total != null)
                  Text(
                    noCover ? context.l10n.editorAlbumCount(_total!) : songs(context.l10n, _total!),
                    style: const TextStyle(color: Palette.textMuted),
                  ),
              ],
            ),
          );
        }
        if (i == _items.length + 1) {
          if (_error != null) return Center(child: Text('$_error'));
          if (_loading) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          if (_total != null && _items.length < _total!) {
            return Center(
              child: TextButton(onPressed: _load, child: Text(context.l10n.editorLoadMore)),
            );
          }
          if (_items.isEmpty) {
            return Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text(context.l10n.editorAllDone, style: TextStyle(color: Palette.textMuted)),
              ),
            );
          }
          return const SizedBox();
        }
        final r = _items[i - 1];
        final t = r.track;
        return ListTile(
          leading: SizedBox(width: 44, child: CoverImage(albumId: noCover ? null : t.album.id, size: 64)),
          title: Text(noCover ? t.album.name : t.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${noCover ? t.artist.name : '${t.artistCredit} • ${t.album.name}'}\n${r.path}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Palette.textMuted),
          ),
          isThreeLine: true,
          trailing: noCover
              ? const Icon(Icons.image_search)
              : IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: context.l10n.editorLooksGood,
                  onPressed: () => _markReviewed(r),
                ),
          onTap: () => _open(r),
        );
      },
    );
  }
}
