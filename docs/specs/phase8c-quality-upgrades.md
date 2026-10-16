# Phase 8c – Automatic quality upgrades (backend + small app part)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: same as `docs/specs/phase2a-backend.md` §0 for the backend (no git commands that modify
index/HEAD/working tree, German user-facing texts, existing style, `ruff format --line-length 120` on
new/rewritten files, tests without network – fake Prowlarr/qBittorrent/Deezer like the existing torrent tests).
Run backend tests against the database given in the task prompt only (guards `startswith("app_test")`); the
whole existing suite must still pass. App: all user-visible texts via gen-l10n (keys in **both**
`lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`),
`~/flutter/bin/flutter analyze` without issues, `JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk
--release` and `~/flutter/bin/flutter build web --release --wasm` must succeed. Do not touch `docs/`, do not run
the release script, do not upload/deploy anything.

## Goal
The admin setting `downloads.quality_upgrade_enabled` ("Replace low-quality (e.g. YouTube) files with better
releases when found") exists but does nothing. Implement it: in the background, albums that contain low-quality
tracks are looked up as torrents (the existing Prowlarr + qBittorrent pipeline); when a better file is found it
replaces the track **in place** (same track id, like the re-download feature in `DownloadManager._replace`).

## 1. Which tracks are "low quality"
`def needs_upgrade(track) -> bool` in `app/services/upgrades.py` (new): lossy codec (`mp3`, `aac`, `opus`,
`vorbis`, `wma`, anything not `flac`/`alac`/`wav`/`aiff`/`ape`/`wavpack`) **and** (`bitrate` is `None` or
`< 256` kbps for mp3/aac/vorbis/wma, any bitrate for opus – YouTube downloads are opus/aac ~128–160 kbps).
Temporary radio tracks (`is_temporary`) are skipped.

## 2. Model + migration
- New table `quality_upgrade_attempts`: `album_id` uuid pk FK `albums.id` ondelete CASCADE, `tried_at`
  timestamptz server_default now, `result: String(24)` (`"requested"`, `"no_catalog"`, `"no_torrent"`,
  `"upgraded"`, `"not_better"`, `"failed"`).
- `DownloadItem.replace_track_id: uuid | None`, FK `tracks.id` ondelete SET NULL.
- One Alembic migration after the current head.

## 3. Scheduler (`app/services/upgrades.py`)
- Background loop started/stopped with the app like the other services (`start()`/`stop()` used in
  `app/main.py`'s lifespan), first run 10 min after start, then every 6 h. Each run: if
  `quality_upgrade_enabled` **and** `torrent_enabled` → pick up to **3** albums that have at least one
  `needs_upgrade` track and no attempt within the last 30 days (oldest-added first), and for each call
  `request_upgrade(db, album)`. Skip the run while another `kind="upgrade"` request is still active.
- `request_upgrade(db, album)`:
  1. Deezer album id: from any `DownloadItem.meta["deezer_album_id"]` of a done item whose `track_id` is one of
     the album's tracks; else search Deezer (`deezer.search_albums(f"{album artist} {album title}", 10)`) and
     take the first result with equal normalized title and artist (normalize like `app/services/matching.py`'s
     name keys). None → attempt `no_catalog`, done.
  2. `resolve_album(deezer_id)` → metas. Match every `needs_upgrade` library track of the album to a meta
     (normalized title equal or `token_set_ratio ≥ 90`, and duration ±5 s); unmatched tracks are ignored.
     No match → `no_catalog`.
  3. Create a `DownloadRequest(kind="upgrade", user=<first admin by created_at>, catalog_id=deezer_id,
     title=album title, artist=album artist, cover_url=deezer cover_medium, status="active", is_temporary=False)`
     with one item per matched track (`meta`, `replace_track_id=track.id`, `status="queued"`, `title`, `artist`,
     `duration`, `position`). Attempt `requested`. Commit, `manager.wake()`.

## 4. Processing (`app/services/downloads.py`)
- `process_one`: torrent branch also for `request.kind == "upgrade"` (requires `torrent_enabled`; if torrents
  are disabled by now, mark all queued items of that request `failed` with "Torrents sind deaktiviert").
  `kind == "upgrade"` items **never** go to YouTube.
- `_torrent_fallback` for upgrade requests: items → `failed` with the given error (no re-queue), attempt row →
  `no_torrent` (for "Kein passender Torrent gefunden") or `failed` (other errors).
- `_torrent_import` for upgrade requests: for each matched file (existing matching logic), compare
  `quality(new tags)` with `quality(read_tags(current file))` (`app/services/importer.py` `quality`). Better →
  replace in place via the replace helper used for re-downloads (generalize `_replace(track_id, path, meta)` so it
  can **copy** from the torrent directory instead of moving: torrent files must stay for seeding) and item
  `done`; not better → item `exists` with `error=None`. Unmatched items → `failed` "Nicht im Torrent enthalten".
  Attempt row → `upgraded` if any item was replaced, else `not_better`.
- The re-download (`kind="redownload"`) behaviour must stay exactly as it is.

## 5. API + app
- `DownloadRequestOut.kind` already carries the kind. App downloads page (`download_pages.dart`): kind
  `'upgrade'` → label "Qualitäts-Upgrade" / "Quality upgrade", icon `Icons.high_quality`.
- Admin page: the existing switch keeps its key; change its subtitle (or add one) to "Sucht im Hintergrund
  bessere Versionen (Torrent) für Songs in niedriger Qualität und ersetzt sie. Benötigt aktivierte Torrents." /
  "Looks for better versions (torrent) of low-quality songs in the background and replaces them. Requires
  torrents to be enabled.".
- New admin endpoint `POST /api/admin/upgrades/run` (admin only, 202) → runs one scheduler pass now (in the
  background) and returns `{"started": true}`; admin page: `TextButton` "Jetzt suchen" / "Search now" next to/below
  the switch, `showInfo` "Suche gestartet" / "Search started".

## 6. Tests (`tests/test_upgrades.py`)
`needs_upgrade` table; candidate selection (30-day attempts, temporary tracks skipped, limit 3, skip while active
upgrade request); Deezer id from download items vs. search; request creation with matched items; processing with
fake torrent: better file replaces in place (same id, like kept, torrent file still present), worse/equal →
`exists`, no torrent → items failed + attempt `no_torrent`, never YouTube; admin run endpoint.

## Report
Changed/new files, backend test count, how you verified the app, deviations.
