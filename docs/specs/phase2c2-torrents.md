# Phase 2c-2 – Torrent source via Prowlarr + qBittorrent (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files. Where silent, choose the simplest option matching existing code. List any deviation
with a reason in the final report. Same general rules as `docs/specs/phase2a-backend.md` §0 (only
`backend/`, never `app/`/`docs/`, no git commands that modify index/HEAD/working tree, German
user-facing texts, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network – use `httpx.MockTransport`).

## Context
Deployment (see `docker-compose.yml`): qBittorrent and Prowlarr run inside the gluetun VPN network
namespace and are reachable from the app at `http://gluetun:8080` / `http://gluetun:9696`. qBittorrent and
the app both mount the downloads volume at `/data/downloads`, so paths reported by qBittorrent are valid
in the app. Only public trackers are available (no private trackers), so torrents are an *optional
first attempt* for **album** requests; whatever the torrent does not deliver falls back to the existing
per-track YouTube pipeline. Track requests never use torrents.

## 1. Settings / config
- `Settings`: `qbittorrent_url: str = "http://localhost:8080"`, `prowlarr_url: str = "http://localhost:9696"`
  (the compose file already sets `RESONANCE_QBITTORRENT_URL` / `RESONANCE_PROWLARR_URL`).
- `DownloadConfig` additions:
  ```python
  # Try public torrents (Prowlarr + qBittorrent) first for album requests.
  torrent_enabled: bool = False
  torrent_min_seeders: int = Field(1, ge=0, le=1000)
  # Give up (and fall back to YouTube) when a torrent makes no progress for this long.
  torrent_timeout_minutes: int = Field(60, ge=5, le=10080)
  prowlarr_api_key: str = ""
  qbittorrent_username: str = "admin"
  qbittorrent_password: str = ""
  ```

## 2. Model changes (`DownloadRequest`) + alembic revision
```python
torrent_status: String(16) | None     # None (not tried) | searching | downloading | importing | done | failed
torrent_name: Text | None             # release title of the chosen torrent
torrent_progress: Float default 0
torrent_progress_at: DateTime(tz) | None   # last time torrent_progress increased
torrent_error: Text | None
```
`DownloadRequestOut` gets `torrent_status, torrent_name, torrent_progress, torrent_error`.
Item `source` value for torrent-delivered files: `"torrent"`.

## 3. Clients – new package `app/services/torrents/`
### 3.1 `prowlarr.py`
`async def search(cfg, query: str) -> list[dict]`: `GET {prowlarr_url}/api/v1/search` with params
`query`, `categories=3000`, `type=search`, header `X-Api-Key`. Timeout 60 s. Errors → `TorrentError(msg)`.
Relevant result fields: `title, size, seeders, protocol ("torrent"|"usenet"), magnetUrl, downloadUrl,
indexer, guid`.
### 3.2 `qbittorrent.py` – class `QBittorrent`
- Session cookie via `POST /api/v2/auth/login` (form `username`, `password`; body `"Ok."` = success,
  anything else → `TorrentError("qBittorrent-Anmeldung fehlgeschlagen")`); re-login once on HTTP 403.
- `add(source: str | bytes, tag: str)`: `POST /api/v2/torrents/add` multipart; magnet string → field
  `urls`, bytes → file field `torrents` (`file.torrent`); fields `savepath="/data/downloads/torrents"`,
  `category="resonance"`, `tags=tag`.
- `info(tag: str) -> dict | None`: `GET /api/v2/torrents/info?category=resonance&tag={tag}` → first or None.
- `files(hash) -> list[dict]`: `GET /api/v2/torrents/files?hash=` (fields `name` = path inside the
  torrent, `size`, `progress`).
- `delete(hash, delete_files: bool)`: `POST /api/v2/torrents/delete` form `hashes`, `deleteFiles`.
- `version() -> str`: `GET /api/v2/app/version`.
- Torrent content root on disk: `Path(info["save_path"]) / name` for each file entry.

## 4. Choosing a torrent – pure function in `app/services/torrents/select.py`
`choose(results, artist: str, album: str, total_duration: float, min_seeders: int) -> dict | None`
- Keep `protocol == "torrent"`, `seeders >= min_seeders`, and
  `fuzz.token_set_ratio(norm(f"{artist} {album}"), norm(title)) >= 80` (`norm` from the YouTube source).
- Reject titles containing (word match, casefolded) `discography, collection, anthology, box set,
  boxset, complete works` unless the album title contains the word.
- Size plausibility: reject `size < total_duration * 16_000` (below 128 kbit/s) and `size > 3 GiB`.
- Format rank from the title: `flac` → 3, `320` → 2, `v0` or `mp3` → 1, else 0.
- Pick max by `(format_rank, min(seeders, 50), -size)`.
Query: `f"{album_artist} {album}"` of the first item's meta.

## 5. Request flow (`app/services/downloads.py`)
- **Start**: in `process_one`, after claiming an item and locking its request: if `cfg.downloads.torrent_enabled`,
  `request.kind == "album"` and `request.torrent_status is None` → in the same transaction set
  `torrent_status="searching"` and all of the request's `queued` items (including the claimed one) to
  `searching`; commit; then run `_torrent_start(request_id)` instead of `_run(item)`.
- `_torrent_start`: Prowlarr search + `choose`. Nothing found / any `TorrentError` →
  `_torrent_fallback(request_id, error)`. Otherwise get the torrent: magnetUrl starting with `magnet:` →
  add as magnet; else `GET downloadUrl` (follow redirects manually: a `Location` header starting with
  `magnet:` is added as magnet; a 200 body is added as torrent bytes). Add with `tag=str(request.id)`,
  set `torrent_status="downloading"`, `torrent_name`, `torrent_progress=0`, `torrent_progress_at=now`,
  items `searching` → `downloading`, `source="torrent"`.
- **Monitor**: new task started with the workers (`DownloadManager.start`), loop every 10 s over requests
  with `torrent_status == "downloading"`: `info(tag)`; missing → fallback `"Torrent verschwunden"`;
  update `torrent_progress` (and each item's `progress`), bump `torrent_progress_at` when it increased;
  `progress >= 1` → `_torrent_import`; no increase for `torrent_timeout_minutes` → delete torrent with
  files, fallback `"Torrent ohne Fortschritt"`.
- `_torrent_import(request)`: `torrent_status="importing"`, items → `processing`. Audio files of the
  torrent (scanner's audio extensions) are read with `read_tags`. Match every item (TrackMeta) to at most
  one file, each file used once, greedy by best score:
  `score = 0.6 * title_ratio + 0.4 * duration_score` where `title_ratio = fuzz.token_set_ratio(norm(meta.title),
  norm(tags.title))` and `duration_score` as in the YouTube scoring; a pair is valid only if
  `title_ratio >= 85` and (durations unknown or diff `<= 5 s`). If several files are valid for one item,
  prefer higher `quality()` (from the importer) before score. For each matched item: copy the file
  (`shutil.copy2`, never move or hardlink – the torrent keeps seeding and its files must stay unmodified)
  to `music_dir / target_relpath(meta, ext)`, `fetch_cover`, `write_tags(..., clear_missing=True)`,
  `import_files`, item `done`, `source="torrent"`, `track_id`, `progress=1`. Unmatched items →
  `queued` (YouTube fallback). `torrent_status="done"`; recompute; wake. The torrent stays in qBittorrent
  (seeding is governed by qBittorrent's own share limits).
- `_torrent_fallback(request_id, error)`: `torrent_status="failed"`, `torrent_error=error`, items in
  `searching|downloading` → `queued`, `source=None`, `progress=0`; recompute; wake.
- **Startup** (`DownloadManager.start`): the existing reset of `searching|downloading|processing` items
  must skip items whose request has `torrent_status == "downloading"`; requests with
  `torrent_status in {"searching", "importing"}` get `torrent_status=None` (retry from scratch) and
  their items `queued`.
- **Cancel**: if `torrent_status == "downloading"` → delete the torrent with files (errors ignored),
  `torrent_status="failed"`, `torrent_error="Abgebrochen"`; items → cancelled as before.
- **Retry** (existing endpoint): unchanged (failed items go back to the YouTube path; the torrent stage
  is not repeated).

## 6. API
`GET /api/admin/torrents/status` (admin, new router `app/api/torrents.py`) →
`{"prowlarr": {"ok": bool, "message": str}, "qbittorrent": {"ok": bool, "message": str}}`;
Prowlarr check `GET /api/v1/system/status` with the key (message = `"Version {version}"` or the
German error), qBittorrent check login + `version()` (message `"Version {v}"` or error).

## 7. Tests (`tests/test_torrents.py`, no network)
`choose` (format ranking, seeder filter, discography rejection, size plausibility, fuzzy title);
end-to-end with mocked Prowlarr/qBittorrent: album request → torrent added (magnet and .torrent bytes
variants) → monitor progress updates items → completion with a fake torrent directory containing
FLAC files for 2 of 3 tracks plus an MP3 duplicate of one → 2 items `done` from the FLAC files
(quality preference), originals unchanged, 1 item back to `queued`; stall timeout → fallback;
nothing found → fallback; cancel deletes torrent; startup recovery rules; track requests never touch
Prowlarr; status endpoint. All existing tests stay green.

## 8. Report
Files, pytest tail, migration check, deviations (or "none").
