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
    showInfo(context, 'Gespeichert: ${updated.title} – ${updated.artistCredit} (${updated.album.name})');
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
      'Metadaten korrigieren',
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
                        '${f.path}\n${[f.codec?.toUpperCase(), if (f.bitrate != null) '${f.bitrate} kbit/s', _durationLabel(f.duration)].whereType<String>().join(' • ')}',
                        style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                      ),
                    ),
                    const TabBar(
                      tabs: [
                        Tab(text: 'Suchen'),
                        Tab(text: 'Fingerabdruck'),
                        Tab(text: 'Bearbeiten'),
                      ],
                    ),
                    Expanded(
                      child: TabBarView(
                        children: [
                          _SearchTab(file: f, onPick: (id) => _apply({'source': 'deezer', 'deezer_id': id})),
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
  final void Function(String deezerId) onPick;

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
    setState(() => _results = ref.read(apiProvider).catalogSearch(q, limit: 25));
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
            decoration: InputDecoration(
              hintText: 'Künstler und Titel',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
            ),
          ),
        ),
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: Text(
            'Tippe auf den richtigen Song – Tags, Cover und Dateiname werden übernommen.',
            style: TextStyle(color: Palette.textMuted, fontSize: 12),
          ),
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
                      return const Center(
                        child: Text('Nichts gefunden', style: TextStyle(color: Palette.textMuted)),
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
                            [t.artist, ?t.album].join(' • '),
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
                          onTap: () => widget.onPick(t.id),
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
          return const Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('Audio-Fingerabdruck wird abgeglichen …', style: TextStyle(color: Palette.textMuted)),
              ],
            ),
          );
        }
        final matches = snap.data!;
        if (matches.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'AcoustID kennt diese Aufnahme nicht. Versuche es über „Suchen“ oder „Bearbeiten“.',
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
                        text: [m.title ?? 'Unbekannter Titel', ?m.artist].join(' – '),
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      TextSpan(
                        text: '   ${(m.score * 100).round()} % Übereinstimmung',
                        style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              ListTile(
                dense: true,
                leading: Icon(Icons.auto_awesome, color: accent),
                title: const Text('Originalalbum automatisch wählen'),
                onTap: () => widget.onPick(m.recordingId, null),
              ),
              for (final r in m.releases)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.album_outlined),
                  title: Text('${r.album ?? 'Unbekanntes Album'}${r.year != null ? ' (${r.year})' : ''}'),
                  subtitle: Text(
                    [
                      if (r.discNo != null && r.discNo! > 1) 'CD ${r.discNo}',
                      if (r.trackNo != null)
                        'Nr. ${r.trackNo}${r.releaseTracks != null ? ' von ${r.releaseTracks}' : ''}',
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
          showError(context, 'Bitte nur Zahlen bei Jahr, Nr. und CD eingeben');
          return;
        }
        meta[e.key] = n;
      } else {
        meta[e.key] = value;
      }
    }
    if (meta.isEmpty) {
      showInfo(context, 'Keine Änderungen');
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
            Expanded(child: field('title', 'Titel')),
            IconButton(tooltip: 'Titel und Künstler tauschen', icon: const Icon(Icons.swap_horiz), onPressed: _swap),
            Expanded(child: field('artist', 'Künstler')),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(child: field('album', 'Album')),
            const SizedBox(width: 16),
            Expanded(child: field('album_artist', 'Album-Künstler')),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 12,
          children: [
            field('year', 'Jahr', width: 100, number: true),
            field('track_no', 'Nr.', width: 80, number: true),
            field('disc_no', 'CD', width: 80, number: true),
            field('genre', 'Genre', width: 220),
          ],
        ),
        const SizedBox(height: 16),
        const Text(
          'Leere Felder bleiben unverändert. Die Datei wird danach nach „Album-Künstler/Album (Jahr)/Nr - Titel“ umbenannt.',
          style: TextStyle(color: Palette.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.icon(onPressed: _save, icon: const Icon(Icons.save), label: const Text('Speichern')),
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
      title: Text('${result.matched} von ${result.matched + result.unmatched.length} Songs zugeordnet'),
      content: result.unmatched.isEmpty
          ? null
          : SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Nicht zugeordnet (unverändert):'),
                  const SizedBox(height: 8),
                  for (final t in result.unmatched)
                    Text('• ${t.title} – ${t.artistCredit}', style: const TextStyle(color: Palette.textMuted)),
                ],
              ),
            ),
      actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('OK'))],
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
      _results = mbid == null ? ref.read(apiProvider).catalogSearch(q, limit: 25) : null;
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
      'Album zuordnen',
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
                  decoration: InputDecoration(
                    hintText: 'Künstler und Album oder MusicBrainz-Link',
                    prefixIcon: const Icon(Icons.search),
                    suffixIcon: IconButton(icon: const Icon(Icons.arrow_forward), onPressed: _search),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                child: Text(
                  'Die $count Songs dieses Albums werden per Titel, Position und Länge den Songs der gewählten '
                  'Veröffentlichung zugeordnet. Was nicht passt, bleibt unverändert.',
                  style: const TextStyle(color: Palette.textMuted, fontSize: 12),
                ),
              ),
              Expanded(
                child: _mbid != null
                    ? ListView(
                        children: [
                          ListTile(
                            leading: const Icon(Icons.album),
                            title: const Text('MusicBrainz-Veröffentlichung verwenden'),
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
                            return const Center(
                              child: Text('Nichts gefunden', style: TextStyle(color: Palette.textMuted)),
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
                                    if (a.year != null) '${a.year}',
                                    if (a.recordType != null) a.recordType!,
                                  ].join(' • '),
                                  style: const TextStyle(color: Palette.textMuted),
                                ),
                                onTap: () => _apply('deezer', a.id),
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
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [CircularProgressIndicator(), SizedBox(height: 12), Text('Songs werden neu getaggt …')],
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
  if (context.mounted) showInfo(context, 'Cover gespeichert');
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
      'Cover ändern',
      Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Vorschläge von MusicBrainz und Deezer. Das Cover wird in alle Songs des Albums eingebettet.',
                        style: TextStyle(color: Palette.textMuted, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _upload,
                      icon: const Icon(Icons.upload),
                      label: const Text('Bild hochladen'),
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
                      return const Center(
                        child: Text('Keine Vorschläge gefunden', style: TextStyle(color: Palette.textMuted)),
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
                  segments: const [
                    ButtonSegment(value: 'unidentified', label: Text('Nicht erkannt'), icon: Icon(Icons.help_outline)),
                    ButtonSegment(value: 'no_cover', label: Text('Ohne Cover'), icon: Icon(Icons.hide_image_outlined)),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) {
                    _kind = s.first;
                    _load(reset: true);
                  },
                ),
                if (_total != null)
                  Text(noCover ? '$_total Alben' : songs(_total!), style: const TextStyle(color: Palette.textMuted)),
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
              child: TextButton(onPressed: _load, child: const Text('Mehr laden')),
            );
          }
          if (_items.isEmpty) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(
                child: Text('Alles erledigt 🎉', style: TextStyle(color: Palette.textMuted)),
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
          trailing: Icon(noCover ? Icons.image_search : Icons.edit_note),
          onTap: () => _open(r),
        );
      },
    );
  }
}
