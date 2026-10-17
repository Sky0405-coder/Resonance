# Phase 10a – Duplicate songs: admin cleanup + prevention (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: backend like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working
tree, German user-facing texts **plus** an English entry in `app/i18n.py` `_EXACT` for every new message,
existing style, `ruff format --line-length 120` on new/rewritten files, tests without network). Run backend tests
against the database given in the task prompt only (guards `startswith("app_test")`); the whole suite must pass.
App: all user-visible texts via gen-l10n (keys in **both** `lib/l10n/app_de.arb` (template) and
`lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`), `~/flutter/bin/flutter analyze` without issues,
`~/flutter/bin/flutter test` passes, `~/flutter/bin/flutter build web --release --wasm` must succeed. Do not touch
`docs/`, no release script, no upload/deploy. **No migration** (no model changes).

## Background
Album "Fallen" exists twice per song in `music_dir`: `Evanescence/Fallen (2003)/01 - Going Under.flac` and
`… /01 - Going Under.mp3` (same album row, same disc/track number, same title, same `mb_recording_id`). Cause: the
importer (`services/importer.py` `_place`) and the downloader (`services/downloads.py`, normal download branch)
only treat a file as duplicate when the **exact** target path (including extension) exists, so a FLAC and an MP3
of the same song both get imported.

## 1. Duplicate detection (new `backend/app/services/duplicates.py`)
- `def track_quality(track: Track) -> int`: `10_000` if `(track.codec or "").casefold()` is in
  `{"flac", "alac", "ape", "wavpack", "wave", "wav", "aiff"}`, else `track.bitrate or 0`.
- Two tracks are duplicates when **all** hold: same `album_id`; same `coalesce(disc_no, 1)`; same `track_no` and
  it is not null; same `name_key(title)` (`services/matching.name_key`); `abs(duration difference) <= 5` s.
- `async def find_groups(db) -> list[list[Track]]`: one SQL query that loads candidate tracks (tracks whose
  `(album_id, coalesce(disc_no,1), track_no)` occurs more than once, `track_no` not null; options: album + album
  artist + artist eager-loaded), then group in Python by `(album_id, disc, track_no, name_key(title))`; inside a
  key, build groups greedily by duration (sorted by duration; a track joins the current group when within 5 s of
  the group's first track). Only groups with ≥ 2 tracks. Each group is sorted keeper-first: highest
  `track_quality`, then non-temporary before temporary, then oldest `created_at`, then `id`. Groups ordered by
  album artist name, album title, disc, track number.
- `async def merge_group(db, keeper: Track, losers: list[Track]) -> None` (no commit inside): move all references
  of each loser to the keeper, then delete the losers with `services/deletion.delete_tracks` semantics (DB row +
  file; `delete_tracks` commits – call it once at the end with all loser ids). References:
  - `playlist_entries.track_id` → keeper (plain UPDATE; a playlist may then contain the song twice, that is ok
    because it was in there twice before).
  - `track_likes`: for each loser like, if the same user already likes the keeper delete the loser like, else
    UPDATE to keeper (unique `(user_id, track_id)`).
  - `play_events.track_id` → keeper.
  - `download_items.track_id`, `download_items.replace_track_id`, `download_requests.replace_track_id`,
    `import_files.track_id` → keeper.
  - `track_lyrics`: if the keeper has no row and a loser has one, move it (UPDATE `track_id`), otherwise leave it
    (deleted by cascade).
  - If any loser has `is_temporary == False`, set `keeper.is_temporary = False`. If any loser has
    `reviewed == True`, set `keeper.reviewed = True`.
- Safety: never delete a file outside `get_settings().music_dir` (`delete_tracks` already only deletes
  library-relative paths; verify, and if it would touch anything else, skip that file and log a warning).

## 2. Admin API (in `api/admin.py`, `AdminUser` required)
- `GET /api/admin/library/duplicates` → `list[DuplicateGroupOut]`:
  `DuplicateGroupOut {album_id: UUID, album_title: str, artist_name: str, tracks: list[DuplicateTrackOut]}`,
  `DuplicateTrackOut {id: UUID, title: str, path: str, codec: str|None, bitrate: int|None, size: int,
  duration: float, keep: bool}` – `keep` is true for the first track of the group only.
- `POST /api/admin/library/duplicates/merge` body `{"keep_ids": [UUID, …]}` (max 5000): re-runs `find_groups`;
  for every current group whose keeper (`tracks[0]`) id is in `keep_ids`, merge it. Groups whose keeper is not in
  the list are left alone (the list changed meanwhile or the admin unchecked it). Returns
  `{"merged_groups": int, "deleted_tracks": int, "freed_bytes": int}`.
- The keeper is always computed by the server (no free choice of which file to keep).

## 3. Prevention
- Importer `_place`: after computing `target`/`dest` and before the existing `replace` logic: look for an existing
  `Track` (not the row being cleaned up in `inplace` mode, i.e. `Track.path != row.path`) whose path has the same
  directory and the same file stem as `target` but a **different** suffix (compare `PurePosixPath(path).with_suffix("")`
  case-insensitively). If found:
  - if `quality(tags)` (importer's existing function) `<=` its `track_quality` → `row.status = "duplicate"`,
    return `False` (same as today's exact-path duplicate);
  - else import the new file normally to its own path, and afterwards (same function, after the file is in place
    and imported/relocated) call `merge_group(db, new_track, [old_track])` where `new_track` is the library
    `Track` for `target` (use `scanner.import_file(db, target)` if it is not in the DB yet). This deletes the
    worse file and keeps likes/playlists.
- Downloader (normal download branch in `downloads.py`, right before `target_relpath`/move): compute
  `rel = target_relpath(meta, path.suffix)` **without** `unique` changes; then the same stem check as above
  against existing tracks. If an existing track with same stem and `track_quality >= quality(read_tags(path))`
  exists: delete the downloaded temp file, mark the item `done` with `track_id` = existing track id (and set
  `existing.is_temporary = False` if `temporary` is false); do not create a new file. If the existing one is worse:
  continue as today and afterwards `merge_group(db, imported, [existing])`.
- Redownload / upgrade (`_replace`) is unchanged (it already replaces in place).

## 4. App (admin)
- `api.dart`: `Future<List<DuplicateGroup>> duplicates()` and `Future<DuplicateMergeResult> mergeDuplicates(List<String> keepIds)`
  with model classes in `core/models.dart` (`DuplicateGroup`, `DuplicateTrack`, `DuplicateMergeResult`, fields as
  in the API, `fromJson`).
- Admin overview tab (`admin_page.dart` `_OverviewTab`), in the "Bibliothek" section: a third button next to the
  scan buttons: `OutlinedButton.icon(icon: Icon(Icons.copy_all), label: "Duplikate" / "Duplicates")` →
  `context.push('/admin/duplicates')` (add the route in `router.dart` next to the other admin routes, admin only
  like them).
- New `lib/ui/pages/admin/duplicates_page.dart`, `DuplicatesPage` (Scaffold + AppBar "Duplikate"/"Duplicates"):
  - Loading/error like other admin pages. Empty: centered text "Keine Duplikate gefunden" / "No duplicates found".
  - Header text: "{groups} Songs liegen mehrfach vor. Behalten wird jeweils die beste Datei, die anderen werden
    gelöscht. Likes, Playlists und Verlauf gehen auf die behaltene Datei über." (English equivalent).
  - One `CheckboxListTile` per group (all checked initially): title `"{artist} – {album}: {title}"`, subtitle one
    line per file: `"✓ FLAC · 989 kbps · 25,1 MB"` for the keeper (primary colour) and `"✗ MP3 · 192 kbps ·
    5,0 MB"` for the others (muted). Format: codec upper-case, bitrate `kbps`, size MB with one decimal using the
    existing byte formatter if there is one.
  - Bottom bar: `FilledButton` "{n} Duplikate löschen" / "Delete {n} duplicates" (n = number of loser files in
    checked groups; disabled when 0) → confirm dialog ("Duplikate löschen?" / "Die schlechteren Dateien werden
    endgültig gelöscht." + cancel/delete) → `mergeDuplicates(keeper ids of checked groups)` → snackbar
    "{deleted} Dateien gelöscht, {freed} frei geworden" → reload list. Errors via `showError`.

## 5. Tests
- `backend/tests/test_duplicates.py` (create tracks directly in the DB + real small files in the test music dir
  like existing deletion tests do):
  - `find_groups`: FLAC+MP3 same album/disc/track/title → one group, FLAC first; different track numbers → no
    group; same title but duration 30 s apart → no group; different albums → no group; `disc_no` None vs 1 →
    same group.
  - `merge_group`: like on loser moves to keeper; like on both → one like remains; playlist entry moved; play
    event moved; loser file deleted from disk, keeper file still there; keeper becomes non-temporary when a loser
    was permanent.
  - API: GET as admin returns the group with `keep` flags, 403 for non-admin; POST merge with keeper id → counts,
    second GET empty; POST with a non-keeper id → nothing merged.
  - Importer: existing MP3 + import FLAC of the same song → one track remains (FLAC), like kept; existing FLAC +
    import MP3 → row status `duplicate`, MP3 not in library.
  - Downloader: existing FLAC, download produces MP3 → item `done` with existing track id, no new file.
- `app/test/duplicates_test.dart`: `DuplicateGroup.fromJson` parses keep flags.
