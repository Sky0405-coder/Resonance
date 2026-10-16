# Phase 9b – SoundCloud as download source + songs that are not in the catalog (backend + small app part)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: backend like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working
tree, German user-facing texts **plus** an English entry in `app/i18n.py` `_EXACT`/`_PATTERNS` for every new
message, existing style, `ruff format --line-length 120` on new/rewritten files, tests **without network** – fake
yt-dlp/ytmusicapi/Deezer like the existing download tests). Run backend tests against the database given in the
task prompt only (guards `startswith("app_test")`); the whole suite must pass. App: gen-l10n keys in **both**
ARB files, `~/flutter/bin/flutter gen-l10n`, `flutter analyze` clean, `flutter test` passes, APK and web (`--wasm`)
release builds succeed. Do not touch `docs/`, no release script, no upload/deploy. One Alembic migration for all
model changes, after the current head.

## Problem
1. Niche songs (lo-fi, underground, remixes) are often not on Deezer. A Spotify playlist import then cannot request
   them at all (`_deezer_id` → `None` → nothing happens), although YouTube or SoundCloud usually has them.
2. Some songs exist only on SoundCloud.

## 1. SoundCloud source (`app/services/sources/soundcloud.py`, new)
- `class SoundCloudSource` with `name = "soundcloud"`, implementing the `Source` protocol of
  `app/services/sources/base.py` (`find(meta, exclude)`, `download(candidate, dest_dir, progress, cancelled)`) and
  `candidate(ref)` like `YouTubeMusicSource`.
- `find`: in a thread, `yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "extract_flat": True})
  .extract_info(f"scsearch10:{meta.artist} {meta.title}", download=False)`; for each entry (skip refs in `exclude`)
  use `url` as `ref`, `title`, `[uploader]` as artists (entries may carry the artist only in the title as
  "Artist - Title": if `" - "` is in the title, also try artists `[left part]` and title = right part and keep the
  better score), `duration`. Score with the existing `score_candidate(meta, title, artists, duration,
  is_video=False)` from `sources/youtube.py`; return the best candidate or `None`. Network/extractor errors →
  `None` (log debug).
- `download`: same as `YouTubeMusicSource.download` (progress hook, cancellation, cookie file option not needed),
  `format` `"bestaudio[ext=opus]/bestaudio[ext=mp3]/bestaudio"`, URL = `candidate.ref`. Output: opus → copy into
  `audio.opus`, mp3 → copy into `audio.mp3`, aac/m4a → `audio.m4a`, anything else → transcode to opus 192k
  (same ffmpeg call style as YouTube). Extract the shared ffmpeg/finish code into a helper in
  `sources/base.py` or a new `sources/ytdlp.py` so both sources use it (YouTube behaviour must stay identical).
- Config `DownloadConfig.soundcloud_enabled: bool = True` with comment "SoundCloud via yt-dlp as a fallback
  download source." `enabled_sources(cfg)`: `[youtube]` if enabled, then `[soundcloud]` if enabled (module-level
  singletons like now). The existing loop in `DownloadManager._run` already tries sources in order.
- Forced re-download with a pasted URL (`create_redownload` with `youtube_url`): additionally accept
  `https://soundcloud.com/<user>/<track>` (also `m.soundcloud.com`, `on.soundcloud.com` short links are **not**
  accepted → 422 like other invalid URLs); stores `source="soundcloud"`, `source_ref=<url>`; `_run` picks the
  source by `item.source` instead of hard-coding YouTube. The app dialog hint text changes to "YouTube- oder
  SoundCloud-Link (optional)" / "YouTube or SoundCloud link (optional)" (update the existing ARB strings).
- Admin page: `SwitchListTile` "SoundCloud als Quelle" / "SoundCloud as a source", subtitle "Wird versucht, wenn
  YouTube nichts findet" / "Tried when YouTube finds nothing", directly below the YouTube switch, key
  `downloads.soundcloud_enabled`.
- Quality upgrades (`services/upgrades.py`) treat SoundCloud files like YouTube files (they are lossy; no code
  change expected – verify with a test that an mp3 128 kbps track `needs_upgrade`).

## 2. Requests without catalog id ("search" requests)
- `create_search_request(db, user, *, title: str, artist: str, album: str | None, duration: float | None,
  temporary: bool) -> DownloadRequest` in `services/downloads.py`: `kind="search"`, `catalog_id =
  f"search:{name_key(artist)}:{name_key(title)}"[:64]` (existing active request with same user/kind/catalog_id
  → return it, like `create_request`), `title`, `artist`, `cover_url=None`, one `DownloadItem` with a `TrackMeta`
  built from the arguments: `artist`, `album_artist` = first artist (split on ", "), `album` = `album` or `title`,
  `track_no=1`, `track_total=1`, `disc_no=1`, `disc_total=1`, `duration`, all ids/isrc/year/genre `None`. Daily
  limit, approval (`auto_approve_requests`) and `match_tracks` "already exists" handling exactly like
  `create_request` (extract the shared parts instead of duplicating them).
- Processing: `kind="search"` items go through `_run` like track requests (no torrent).
- `DownloadRequestOut.kind` may now be `"search"`; app downloads page shows it like a track request (icon
  `Icons.travel_explore`, label "Suche" / "Search").
- Spotify import (`services/spotify.py` `process`): when `download_missing` and `_deezer_id(track)` is `None`, call
  `create_search_request(db, user, title=track.title, artist=track.artist, album=track.album,
  duration=track.duration, temporary=False)` instead of skipping; count it in `batch.requested`; 429 handling as
  today. Add `SpotifyPending.download_item_id: uuid | None` (FK `download_items.id`, `ondelete SET NULL`); search
  requests store their item id there (and `deezer_id=None`). `resolve_pending`: if `download_item_id` is set, the
  track id is that item's `track_id` (non-temporary track); else today's logic.
- Tests: SoundCloud `find` scoring incl. "Artist - Title" split (fake `YoutubeDL`); source order YouTube → SoundCloud
  (YouTube finds nothing → SoundCloud downloads); `soundcloud_enabled=False` skips it; re-download with a
  SoundCloud URL; `create_search_request` (dedupe, limit, approval); Spotify import with a track not on Deezer →
  search request + pending row → after the fake download the song lands in the playlist.

## Report
Changed/new files, migration revision, backend test count, how you verified the app, deviations.
