# Phase 7b – Re-download a wrong version (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: same as `docs/specs/phase2a-backend.md` §0 for the backend (no git commands that modify
index/HEAD/working tree, German user-facing texts, existing style, `ruff format --line-length 120` on
new/rewritten files, tests without network – monkeypatch YouTube/Deezer). Run backend tests against the database
`app_test` only (guards `startswith("app_test")`); the whole existing suite must still pass. App: all
user-visible texts via gen-l10n (keys in **both** `lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run
`~/flutter/bin/flutter gen-l10n`), `~/flutter/bin/flutter analyze` without issues,
`~/flutter/bin/flutter build apk --release` and `~/flutter/bin/flutter build web --release --wasm` must
succeed. Do not touch `docs/`, do not run the release script, do not upload/deploy anything.

## Goal
Sometimes the library holds the wrong version of a song (instrumental, censored "clean" edit, live, cover…).
Every logged-in user can say "wrong version – download again" on any song. The server then downloads the song
again from YouTube Music, **skipping the sources that were used before**, and replaces the audio file **in place**:
the track keeps its id, so likes, playlists, play history and queue entries stay intact. Optionally the user
can paste a YouTube / YouTube Music link to force a specific video.

## Backend

### 1. Model + migration
- `DownloadRequest`: new nullable column `replace_track_id: uuid | None`, FK `tracks.id` `ondelete="SET NULL"`.
- `DownloadItem`: new column `exclude_refs: JSONB` (list of strings), `nullable=False`, `server_default '[]'`,
  python default `list`.
- One Alembic migration after the current head.
- New request `kind` value `"redownload"` (kind is a free string column already; no enum change).

### 2. Sources (`app/services/sources/`)
- `Source.find(meta, exclude: frozenset[str] = frozenset())` (protocol in `base.py` and `YouTubeMusicSource`):
  results whose `videoId` is in `exclude` are skipped (both the "songs" and the "videos" pass).
- New helper in `youtube.py`: `def video_id(url: str) -> str | None` accepting
  `https://music.youtube.com/watch?v=ID…`, `https://www.youtube.com/watch?v=ID…`, `https://youtube.com/watch?v=ID`,
  `https://m.youtube.com/watch?v=ID`, `https://youtu.be/ID…` (ID = 11 chars `[A-Za-z0-9_-]`); anything else → `None`.
- New method `YouTubeMusicSource.candidate(ref: str) -> Candidate` returning
  `Candidate(self.name, ref, "", "", None, 100.0)` (download works with the ref alone).

### 3. Creating a re-download (`app/services/downloads.py`)
`async def create_redownload(db, user, track: Track, youtube_url: str | None) -> DownloadRequest`:
- `youtube_url` given but `video_id()` returns `None` → `HTTPException(422, "Kein gültiger YouTube-Link")`.
- If the same user already has a request with `kind="redownload"`, `replace_track_id == track.id` and status in
  `pending_approval`/`active` → return it.
- Daily limit: same rule and message as `create_request` (counts as 1 song; admins exempt).
- Approval: `user.is_admin or cfg.downloads.auto_approve_requests` → `active`/item `queued`, else
  `pending_approval`/item `waiting` (same as `create_request`).
- `meta`: a `TrackMeta` built from the library row (load album + album artist): `title`, `artist=artist_credit`,
  `album=album.title`, `album_artist` = album artist name, `track_no`, `disc_no`, `year`, `date=None`,
  `duration`, `isrc`, `genre`, `mb_recording_id`, other fields `None`/defaults, `cover_url=None`.
- `exclude_refs`: every non-empty `source_ref` of earlier `DownloadItem`s with `source == "youtube"` and
  `track_id == track.id` (any user, any status), deduplicated, in creation order. If `youtube_url` is given:
  `exclude_refs=[]` and the item's `source="youtube"`, `source_ref=<video id>` are preset (forced pick).
- Request: `kind="redownload"`, `catalog_id=None`, `replace_track_id=track.id`, `title=track.title`,
  `artist=track.artist_credit`, `cover_url=None`, `is_temporary=False`, one item (`position=0`, `title`, `artist`,
  `duration`, `meta`, `track_id=None`).
- Commit, `manager.wake()`, return.

### 4. Processing (`DownloadManager._run`)
For items of a request with `kind == "redownload"`:
- Skip the `match_tracks` "exists" shortcut.
- If `item.source == "youtube"` and `item.source_ref` are preset → use `YouTubeMusicSource.candidate(ref)` directly
  (fails with "Keine Download-Quelle aktiviert" when YouTube is disabled, like now). Else call
  `source.find(meta, frozenset(item.exclude_refs))`; nothing found → `failed`, error
  `"Keine andere Version gefunden"`.
- Download + `write_tags(path, meta, cover)` where `cover` = the existing file's embedded cover
  (`app/services/tags.py` already has a cover reader – reuse it) or the album folder's `cover.jpg`, else `None`.
- If `replace_track_id` is `None` (track deleted meanwhile) or the track row is gone → `failed`,
  `"Song wurde gelöscht"`.
- Replace in place, holding `scanner.library_lock` for the file operations + DB update:
  `old = music_dir / track.path`; `new_rel = str(Path(track.path).with_suffix(path.suffix))`;
  move the download to `music_dir / new_rel` via a temp file in the same directory + `os.replace`; if
  `new_rel != track.path` delete the old file (missing is fine) and set `track.path = new_rel`
  (use `relocate_track` if it fits, but note it takes `library_lock` itself – do not deadlock). Keep the existing
  sidecar `.lrc` only if the path stayed the same; when the suffix changed, rename it to the new stem.
  Then re-read tags/technical data for the row via `import_files(db, [new_rel])` (it must update the existing row
  matched by path, keeping the id – verify, and adapt minimally if it would create a new row).
  Delete the `TrackLyrics` row of the track (the old version may have been cached as instrumental).
  Keep `is_temporary` as it was.
- Item → `done`, `track_id=track.id`, `progress=1`. Errors/retries/cancel exactly like normal downloads.
- `retry` (`api/requests.py`) must work for redownload items too (items keep `exclude_refs` and a preset ref).
- `spotify.resolve_after_download()`/`radio.resolve_after_download()` are not needed for redownloads (harmless if
  called).

### 5. API
- `POST /api/tracks/{track_id}/redownload` (in `app/api/library.py`), any logged-in user, body
  `RedownloadIn {youtube_url: str | None = None}` (max length 500), unknown track → 404,
  response `DownloadRequestDetail` (status 201; reuse `_out` from `api/requests.py` – move it to a shared place if
  needed).
- `DownloadRequestOut` gets `replace_track_id: uuid | None`.

### 6. Tests (`tests/test_redownload.py`)
- Creating: excludes earlier YouTube refs of that track; invalid link → 422; link presets the ref; dedup of an
  active request; non-admin without auto-approve → `pending_approval`.
- Processing (fake source + fake download writing a small real audio file created with the helpers the existing
  tests use): file replaced in place, same track id, like + playlist entry still there, path suffix change handled
  (old file gone, `.lrc` renamed), `TrackLyrics` row deleted, excluded refs passed to `find`, nothing found →
  `"Keine andere Version gefunden"`, track deleted meanwhile → `"Song wurde gelöscht"`.

## App

### 7. API + models
`ApiClient.redownload(String trackId, {String? youtubeUrl}) → Future<DownloadRequest>`;
`DownloadRequest.replaceTrackId` (`String?`).

### 8. Track menu (`lib/ui/widgets/track_list.dart` `showTrackMenu`)
For **everyone** (not only admins), after "Zum Künstler" and before the `extra` actions: `ListTile`
`Icons.restart_alt`, "Falsche Version? Neu herunterladen" / "Wrong version? Download again". Hidden on web? No –
show everywhere, but hide in offline mode if the app has such a flag where the menu is built (otherwise always
show). Opens a dialog:
- Title "Neu herunterladen" / "Download again".
- Text "Der Song wird erneut gesucht und ersetzt. Die bisher verwendete Quelle wird übersprungen. Likes und
  Playlists bleiben erhalten." / "The song is searched again and replaced. The source used before is skipped.
  Likes and playlists are kept."
- Optional `TextField` label "YouTube-Link (optional)" / "YouTube link (optional)", hint
  "Falls du eine bestimmte Version willst" / "If you want a specific version".
- Buttons "Abbrechen" / "Cancel" and "Neu herunterladen" / "Download again".
- On confirm: call the API; success → `showInfo` "Neu-Download gestartet" / "Re-download started" (or, when the
  returned status is `pending_approval`, "Anfrage gesendet – ein Admin muss sie freigeben" / "Request sent – an
  admin has to approve it"); API error → the existing error snackbar helper with the server message.
- Invalidate the download summary/list providers like the existing request creation does.

### 9. Downloads page (`lib/ui/pages/download_pages.dart`)
Requests with `kind == 'redownload'`: kind label "Neu-Download" / "Re-download", icon `Icons.restart_alt`
instead of the album/note icon; otherwise shown like a song request.

### 10. After completion
When a redownload request the app knows about switches to `done` (the downloads page/summary polling already
refreshes requests), nothing else is required. The audio URL stays the same; do **not** add cache busting.

## Report
Changed/new files, backend test count, how you verified the app (analyze, builds), deviations.
