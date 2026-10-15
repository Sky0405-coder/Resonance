# Phase 5a – Song and album radio, temporary tracks cleanup (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files beyond what is listed. Where silent, choose the simplest option matching existing code.
List any deviation with a reason in the final report. Same general rules as `docs/specs/phase2a-backend.md`
§0 (only `backend/`, never `app/`/`docs/`, no git commands that modify index/HEAD/working tree, German
user-facing texts, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network – use monkeypatching of `deezer.*` and `create_request`). Run tests against the database `app_test`
only. The whole existing test suite must still pass.

## Context
A user starts a **radio** from a library song or album. The server builds a playlist of similar songs:
songs already in the library are added immediately; missing ones are requested for download as
*temporary* tracks (if enabled) and appended to the radio once downloaded. Radios are kept as playlists of
kind `radio` for a configurable time after their last use, then deleted. Temporary tracks are deleted after
`radio.temporary_retention_days` unless someone liked them or put them into a normal playlist.

## 1. Config (`app/services/server_config.py`, `RadioConfig`)
Add (keep existing fields):
```
# Radio playlists are deleted this many days after they were last started (0 = keep forever).
playlist_retention_days: int = Field(30, ge=0, le=3650)
# Maximum number of missing songs requested for download per radio start (0 = none).
max_downloads_per_radio: int = Field(10, ge=0, le=50)
```

## 2. Model + migration
`Playlist` (`app/models/collection.py`) gets:
```
kind: Mapped[str] = mapped_column(String(16), default="user", server_default="user")   # "user" | "radio"
# "track:<library track uuid>" or "album:<library album uuid>" for radios, else NULL.
radio_seed: Mapped[str | None] = mapped_column(String(64))
last_used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
```
Index on `(owner_id, radio_seed)`.

New model `RadioPending` (same module):
```
__tablename__ = "radio_pending"
id: uuid pk
playlist_id: FK playlists.id ondelete CASCADE, index
deezer_id: String(20)
created_at: server_default now()
```
One Alembic migration (revision after the current head `d95a320b8e14`).

## 3. Deezer client (`app/services/deezer.py`)
Add:
- `async def artist_radio(self, id: str) -> list[dict]` → `GET artist/{id}/radio` with `limit=50`, returns `data`.
- `async def artist_related(self, id: str, limit: int = 10) -> list[dict]` → `GET artist/{id}/related`
  with `limit`, returns `data`.

## 4. Radio generation (`app/services/radio.py`, new)
`async def build_radio(db, user, seed_type: Literal["track", "album"], seed_id: uuid.UUID) -> tuple[Playlist, int]`
returns the playlist and the number of requested downloads.

1. **Seed.** Load the library track (with album + artist) or album (with artist); unknown → 404
   `"Nicht gefunden"`. `seed_artist_name` = track's primary artist (`primary_artist(track.artist_credit)`
   from `app.services.tags`) for a track, the album artist for an album.
2. **Reuse.** If the user already has a playlist with `kind="radio"` and `radio_seed == f"{seed_type}:{seed_id}"`:
   if its `created_at` is younger than 24 hours, only set `last_used_at = now()`, commit and return it with
   `0` downloads. Otherwise delete it (cascade removes entries and pending rows) and build a new one.
3. **Deezer seed artist.** For a track with an ISRC: `deezer.track_by_isrc(isrc)` → its `artist.id`. Otherwise
   (or if that returns None) `deezer.search_artists(seed_artist_name, 5)` → first result with
   `name_key(result["name"]) == name_key(seed_artist_name)`. No match or `DeezerError` → `artist_id = None`.
4. **Candidates** (list of Deezer track dicts, only if `artist_id`):
   - `radio = deezer.artist_radio(artist_id)`
   - `related = deezer.artist_related(artist_id, 10)[:8]`, for each `deezer.artist_top(rel["id"], 5)`
   - `own = deezer.artist_top(artist_id, 10)`
   Merge by round-robin over the lists `[radio, own, *related_tops]` (take one from each list in turn until all
   are exhausted). Drop duplicates by Deezer id and by `(name_key(primary_artist(artist_string(t))),
   name_key(t["title"]))`, at most 3 tracks per primary artist, stop at 80 candidates. Any `DeezerError` while
   collecting → continue with what was collected so far.
5. **Match.** Convert candidates with `app.api.catalog._track` (no album argument) and run `match_tracks`.
   Matched → their library track ids (any library track, temporary ones included), keep the candidate order.
6. **Library fill.** For every distinct candidate primary-artist name key that exists as `Artist.name_key` in
   the library, add up to 3 random library tracks of that artist (by `Track.artist_id`) that are not already
   chosen. Additionally add up to 5 random tracks of the seed artist (library). For an album seed, add up to 3
   random tracks of that album first.
7. **Order.** Track seed: the seed track first. Then all other chosen tracks shuffled with
   `random.Random(f"{user.id}:{seed_type}:{seed_id}:{date.today()}")`. Max 100 entries, no duplicates.
   If nothing was found at all (no Deezer match, no library tracks besides the seed): still create the radio
   with the seed (track) / album tracks (album).
8. **Playlist.** Create `Playlist(owner_id=user.id, kind="radio", radio_seed=…, name=f"{title} Radio",
   is_public=False, last_used_at=now())` where `title` is the track title / album title; entries with positions
   1..n.
9. **Downloads.** If `cfg.radio.auto_download_enabled` and `cfg.radio.max_downloads_per_radio > 0`: for the
   unmatched candidates in candidate order, up to `max_downloads_per_radio`, call
   `create_request(db, user, "track", str(t["id"]), temporary=cfg.radio.temporary_tracks_enabled, radio=True)`
   and add a `RadioPending(playlist_id, deezer_id)` per request. Stop at the first `HTTPException` with status 429
   (daily limit); skip single tracks on other `HTTPException`s. Count successful requests.
   `create_request` gets a new keyword `radio: bool = False`; with `radio=True` the temporary flag is honoured
   for non-admins too (`is_temporary = temporary and (user.is_admin or radio)`). Nothing else changes there.
10. Commit, return.

## 5. Pending resolution
In `app/services/radio.py`: `async def resolve_radio_pending(db) -> int`, analogous to
`spotify.resolve_pending`: for each `RadioPending` row (locked, skip_locked) find the downloaded track via
`DownloadItem.meta["deezer_track_id"].astext == row.deezer_id` with a non-null `track_id` (newest first;
temporary tracks allowed). If found and not already in the playlist: append a `PlaylistEntry` at
`max(position)+1`, delete the row. Rows older than 7 days are deleted without resolving. Hook it in exactly where
`spotify.resolve_after_download()` is triggered (`app/services/downloads.py`), as a separate background task
(`radio.resolve_after_download()`), and in a loop like `spotify._resolve_loop` (every 60 s) started/stopped from
the app lifespan via `radio.start()` / `radio.stop()`.

## 6. Cleanup (in the same loop, at most once per hour)
`async def cleanup(db) -> tuple[int, int]` (deleted radios, deleted tracks):
1. If `playlist_retention_days > 0`: delete radio playlists whose `coalesce(last_used_at, created_at)` is older
   than that many days.
2. Temporary tracks: `Track.is_temporary` and `Track.created_at < now - temporary_retention_days`, that have no
   `TrackLike` and no `PlaylistEntry` in a playlist with `kind == "user"` → delete them with
   `app.services.deletion.delete_tracks` (files too). Radio entries do not protect a track.

## 7. API (`app/api/radio.py`, new router, registered in `main.py`)
- `POST /api/radio` body `{"seed_type": "track"|"album", "id": uuid}` → `RadioOut {playlist: PlaylistOut,
  requested: int}` (any logged-in user).
- `POST /api/playlists/{playlist_id}/keep` (in `app/api/playlists.py`) → `PlaylistOut`: owner only
  (`_get_owned`); 400 `"Keine Radio-Playlist"` if `kind != "radio"`. Sets `kind="user"`, `radio_seed=None`,
  marks all temporary tracks of its entries `is_temporary=False` and deletes its `RadioPending` rows.

Playlist changes:
- `PlaylistOut` gets `kind: str = "user"`.
- Radios are never visible to other users: `_get_visible` / list must not return other users' radio playlists
  even if `is_public` or shared; `PATCH` with `is_public=true` and `PUT …/shares` on a radio → 400
  `"Radios können nicht geteilt werden"`.
- Adding tracks to a radio via `POST /api/playlists/{id}/tracks` must **not** clear `is_temporary` (only for
  `kind == "user"`).
- `GET /api/playlists` keeps returning both kinds (the app separates them by `kind`).
- `GET /api/home`: only `kind == "user"` playlists.

## 8. Tests (`tests/test_radio.py`)
With monkeypatched Deezer methods and `create_request`:
- track radio: seed first, matched candidates + library fill present, no duplicates, positions 1..n, name
  `"<title> Radio"`, `kind="radio"`; missing candidates requested (≤ max) with `temporary=True, radio=True`,
  RadioPending rows created.
- reuse within 24 h returns the same playlist id and updates `last_used_at`; older → rebuilt (new id).
- 429 from `create_request` stops further requests; `auto_download_enabled=False` → none requested.
- Deezer failure → radio from library only.
- album radio contains album tracks first (up to 3).
- pending resolution appends the downloaded track; keep → kind user, tracks permanent, pending removed.
- cleanup deletes expired radios and old unprotected temporary tracks, keeps liked / user-playlist ones.
- radios invisible to other users, not shareable/public (400), home excludes radios.

## Report
List changed/new files, test count, deviations.
