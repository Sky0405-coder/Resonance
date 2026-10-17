# Phase 10b – Export Resonance playlists to Spotify + two-way sync (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields, settings or
files beyond what is listed. Where silent, choose the simplest option matching the existing code. List any
deviation with a reason in the final report.

General rules: like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working tree,
German user-facing texts **plus** an English entry in `app/i18n.py` `_EXACT` for every new message, existing
style, `ruff format --line-length 120` on new/rewritten files, tests without network – mock Spotify the same way
`tests/test_spotify.py` does). Run backend tests against the database given in the task prompt only; the whole
suite must pass. **Only touch `backend/`** (the Flutter app is done separately). Do not touch `docs/`.

## Background / Spotify API facts (2026, development mode – use exactly these endpoints)
- Base `https://api.spotify.com/v1/`. Reads go through the existing `services/spotify._get` (refresh, 401 retry,
  429 handling). Add a sibling `async def _send(db, account, client, method: str, path: str, json: dict) -> dict`
  with identical refresh/401/429/error behaviour for POST/DELETE (and the same `SpotifyError` messages).
- Create playlist: `POST me/playlists` body `{"name": str, "public": false, "description": str}` → 201 with `id`,
  `external_urls.spotify`, `snapshot_id`.
- Playlist items: `GET playlists/{id}/items` (already used by `_fetch_tracks(..., "item", 100)`). Spotify only
  returns items for playlists the user **owns or collaborates on**; otherwise 403 → treat as
  `SpotifyError(403, "Spotify gibt die Songs dieser Playlist nicht frei")`.
- Add: `POST playlists/{id}/items` body `{"uris": [..]}` – max 100 URIs per request, appends.
- Remove: `DELETE playlists/{id}/items` body `{"items": [{"uri": ..}, ..]}` – max 100 per request; removes all
  occurrences of each URI.
- Search: `GET search` params `q`, `type=track`, `limit=10` (10 is the maximum now).
- Required OAuth scopes are extended (see §3). Writes without them answer 403.

## 1. Data model (one Alembic migration, revision id `7ec4b2d8a1f6`, down_revision = current head)
- `spotify_accounts.scope: Text NULL` – the `scope` string of the last token response (set on code exchange and
  whenever a refresh response contains `scope`).
- New table `spotify_syncs` (model `SpotifySync` in `app/models/spotify.py`, export it in `app/models/__init__.py`):
  - `id UUID PK`, `user_id FK users CASCADE (index)`, `playlist_id FK playlists CASCADE UNIQUE`,
    `spotify_playlist_id String(64)`, `spotify_url Text NULL`,
  - `two_way Bool NOT NULL` (true = automatic two-way sync, false = one-way export that only runs on request),
  - `status String(16)` one of `idle|running|failed`, `error Text NULL`, `last_synced_at timestamptz NULL`,
  - `prev_spotify JSONB NOT NULL default []` – list of Spotify URIs present after the last successful sync,
  - `prev_tracks JSONB NOT NULL default []` – list of Resonance track ids (strings) present after the last sync,
  - `unmatched JSONB NOT NULL default []` – list of `{"title", "artist"}` of Resonance songs not found on Spotify
    in the last run (max 500 entries),
  - `created_at`, `updated_at` like the other models.
- New table `spotify_track_map` (model `SpotifyTrackMap`): `track_id FK tracks CASCADE PK`,
  `spotify_uri String(64) NULL` (NULL = searched, not found), `checked_at timestamptz NOT NULL`.

## 2. Matching (in `services/spotify_sync.py`, new)
- `SpotifyTrack` (existing dataclass) gets a new last field `uri: str | None = None`; `_fetch_tracks` fills it
  from `item["uri"]` (keep everything else).
- `async def spotify_uri(db, account, client, track: Track) -> str | None`:
  - Use `spotify_track_map` row if present and (`spotify_uri` not null or `checked_at` newer than 7 days).
  - Otherwise search: first, if `track.isrc`: `q = f"isrc:{track.isrc}"`; take the first result whose duration is
    within 10 s (or the first result if durations are missing). If nothing: `q = f'track:"{title}" artist:"{first
    artist}"'` where first artist = `track.artist_credit` split at the first of `", "`, `" & "`, `" feat. "`,
    `" ft. "`, `" featuring "`, `" x "` (case-insensitive) – quotes inside title/artist removed. Candidate is
    accepted when `fuzz.token_set_ratio(norm(track.title), norm(name)) >= 85`, max over the candidate's artists of
    `fuzz.token_set_ratio(norm(first artist), norm(artist_name)) >= 70`, and (duration unknown or
    `abs(diff) <= 10` s). `norm` = `services/sources/youtube.norm`. Best accepted = highest
    `title_ratio + artist_ratio`, ties: smaller duration diff, then search order.
  - Upsert the map row (`checked_at = now`) and return the URI (or None).
- Spotify → Resonance: the existing `spotify.match(db, tracks)` for the `SpotifyTrack`s. When a Spotify URI is
  matched to a track id, upsert `spotify_track_map(track_id, uri, now)` too.

## 3. OAuth scope
`api/spotify.py` `login`: scope becomes
`"playlist-read-private playlist-read-collaborative user-library-read playlist-modify-private playlist-modify-public"`.
Store `tokens.get("scope")` in `account.scope` in `callback` and in `_refresh` (only when present).
`GET /api/spotify/status` gets a new field `can_write: bool` = account exists and both `playlist-modify-private`
and `playlist-modify-public` are in `(account.scope or "").split()`.

## 4. Sync algorithm – `async def run_sync(sync_id: UUID, *, pull: bool) -> None` (in `spotify_sync.py`)
Own session (`SessionLocal`) and `_client_factory()` client. Skip when the row is gone. Set `status="running"`,
`error=None`, commit. Load the account of `sync.user_id` (missing → fail with "Kein Spotify-Konto verbunden").
`pull` is true for two-way syncs (automatic or manual) and false for one-way exports.

1. `S_now` = ordered list of `SpotifyTrack` from `playlists/{id}/items` (skip items without `uri`, and skip
   `spotify:local:` URIs). `S_set` = set of their URIs. `S_prev = set(sync.prev_spotify)`.
2. `R_now` = playlist entries ordered by `position` (track ids). `R_set` = set of track ids (as str).
   `R_prev = set(sync.prev_tracks)`.
3. **Resonance removals** (only if `pull`): for every track id in `R_prev - R_set`: if the map has a URI for it
   and that URI is in `S_set` and in `S_prev` → collect for Spotify removal. Remove collected URIs (chunks of 100)
   and drop them from `S_set`.
4. **Spotify removals** (only if `pull`): for every URI in `S_prev - S_set_before_step_3`: delete all playlist
   entries of the Resonance playlist whose track id maps (via `spotify_track_map`) to that URI and whose track id
   is in `R_prev` (entries added in Resonance since the last sync stay). Update `R_set` accordingly.
5. **Spotify additions** (only if `pull`): for every `SpotifyTrack` of `S_now` whose URI is in `S_set - S_prev`
   (in Spotify order): `match` it. If matched and the track id is not in `R_set` → append a `PlaylistEntry`
   (position = current max position + 1, or 0) and add to `R_set`. If not matched → exactly like the import with
   `download_missing=True`: `_deezer_id` → `create_request(db, user, "track", id, temporary=False)` or
   `create_search_request(...)`, and a `SpotifyPending(like=False, playlist_id=..., position=max+1, ...)`; on a
   429 `HTTPException` stop requesting for the rest of this run (no error). Skip requesting when a
   `SpotifyPending` row with the same `playlist_id` and (same `isrc` if set, else same title+artist) exists.
6. **Resonance additions → Spotify** (always): for every track id of `R_now` (playlist order, distinct) that is not
   in `R_prev` (on the very first run `R_prev` is empty, so all): `uri = spotify_uri(...)`; if None → add
   `{"title", "artist": artist_credit}` to `unmatched`; elif URI not in `S_set` → collect (keep order). Add
   collected URIs in chunks of 100 and add them to `S_set`. `unmatched` is replaced by this run's list (when no
   new tracks were processed in this run, keep the previous list minus tracks no longer in the playlist – simply
   recompute it: tracks of `R_now` whose map row has `spotify_uri NULL`).
7. Save `prev_spotify = sorted(S_set)`, `prev_tracks = sorted(R_set)`, `status="idle"`, `error=None`,
   `last_synced_at=now`, commit.
- Errors: `SpotifyError` → `status="failed"`, `error=e.message` (403 on a write →
  `"Spotify-Schreibrechte fehlen – bitte Spotify in den Einstellungen neu verbinden"`); 404 on the playlist →
  `"Spotify-Playlist nicht gefunden – Verknüpfung bitte neu anlegen"`. Other exceptions: log + `"Abgleich
  fehlgeschlagen"`. Never leave `status="running"` behind.
- Concurrency: one run per sync at a time (an in-memory `set` of running ids in the module; a second launch for a
  running id is a no-op).
- Commit progress at the end only (the run is small); playlist entries and pending rows are committed together
  with the sync row.

## 5. API (new router `api/spotify_sync.py`, prefix `/api/playlists`, `CurrentUser`; include it in `main.py`)
Only the playlist owner may use these (else 404 `"Playlist nicht gefunden"`); `kind` must be `"user"` (mixes,
radio playlists → 409 `"Diese Playlist kann nicht mit Spotify verknüpft werden"`).
- `GET /api/playlists/{id}/spotify` → `SpotifySyncOut | null` (200 with JSON `null` when not linked).
  `SpotifySyncOut {spotify_playlist_id, spotify_url: str|None, two_way: bool, status, error: str|None (translated
  like other messages), last_synced_at, unmatched: list[{title, artist}]}`.
- `POST /api/playlists/{id}/spotify` body `{"spotify_playlist_id": str|None, "two_way": bool}` → 201
  `SpotifySyncOut`:
  - 409 `"Kein Spotify-Konto verbunden"` without account; 409 `"Spotify-Schreibrechte fehlen – bitte Spotify in den
    Einstellungen neu verbinden"` when `can_write` is false; 409 `"Playlist ist bereits mit Spotify verknüpft"` if
    a row exists.
  - `spotify_playlist_id` null → create a new private Spotify playlist with the Resonance name and description
    `"Aus Resonance exportiert"`; store `id` and `external_urls.spotify`. Otherwise it must be one of
    `_fetch_playlists` (own or collaborative) → else 422 `"Spotify-Playlist nicht verfügbar"`; url =
    `https://open.spotify.com/playlist/{id}`.
  - Insert the row (`status="running"`), commit, launch `run_sync(id, pull=two_way)` as a background task (like
    `launch_import`), return.
- `POST /api/playlists/{id}/spotify/sync` → 202 `SpotifySyncOut` (sets `status="running"` and launches the run;
  if already running just returns). 404 `"Nicht mit Spotify verknüpft"` when no row.
- `PATCH /api/playlists/{id}/spotify` body `{"two_way": bool}` → `SpotifySyncOut`.
- `DELETE /api/playlists/{id}/spotify` → 204, deletes the row only (the Spotify playlist stays).
- `PlaylistDetail`/`PlaylistOut` are **not** changed.

## 6. Background loop
In `spotify_sync.py`: `start()`/`stop()` like `services/spotify.py` (call them from `main.py` lifespan next to
`spotify_service`). On start: rows with `status="running"` → `"failed"` with `"Durch Neustart abgebrochen"`.
Loop: every 10 minutes run `run_sync(id, pull=True)` sequentially for all rows with `two_way=True` and status
not `running`. Exceptions in the loop are logged, never kill it.
Also: when a track is deleted, `spotify_track_map` cascades (FK) – nothing else.

## 7. Tests (`tests/test_spotify_sync.py`, mocked Spotify transport, no network)
1. Export new: playlist with 3 tracks (one with ISRC found by isrc search, one found by text search, one not
   found) → creates Spotify playlist via `POST me/playlists`, adds 2 URIs, `unmatched` has the third, row idle,
   `prev_*` set, map rows written (incl. NULL row).
2. Two-way: after export, Spotify side adds a URI matching a library track and removes one exported URI;
   Resonance side adds a new track and removes one → after `run_sync(pull=True)`: the library track is appended
   to the Resonance playlist, the Spotify-removed track's entry is gone, the new Resonance track was added on
   Spotify, the Resonance-removed track's URI was removed on Spotify. Second run with no changes makes no write
   calls.
3. Spotify addition not in the library → a download request + `SpotifyPending` with the playlist id are created;
   a second run does not create another.
4. One-way (`pull=False`): Spotify-side additions/removals do not change the Resonance playlist.
5. Permission/validation: other user's playlist → 404; mix playlist → 409; no write scope → 409; linking twice
   → 409; foreign Spotify playlist id → 422; `DELETE` removes the row; `status` shows `can_write`.
6. Write 403 → row `failed` with the re-connect message; 404 playlist → not-found message.
7. Map cache: a NULL map row younger than 7 days is not searched again; older → searched again.
