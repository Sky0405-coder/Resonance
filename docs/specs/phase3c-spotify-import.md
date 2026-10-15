# Phase 3c – Spotify import: liked songs and own playlists (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files. Where silent, choose the simplest option matching existing code. List any deviation
with a reason in the final report. Same general rules as `docs/specs/phase2a-backend.md` §0 (only
`backend/`, never `app/`/`docs/`, no git commands that modify index/HEAD/working tree, German
user-facing texts, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network – use `httpx.MockTransport` / monkeypatching). Run tests against the database `app_test` only.

## Context
Each Resonance user can connect their own Spotify account (OAuth, Authorization Code flow) and import, on
demand ("einmalig"), their **liked songs** into Resonance likes and their **own playlists** into Resonance
playlists. Tracks are matched to the library by ISRC (then artist+title). Missing tracks can be requested
for download; once a download finishes, the track is added to the like list / playlist at its Spotify
position automatically.

Spotify Web API facts (Development Mode, since Feb 2026) – use exactly these endpoints:
- Authorize: `https://accounts.spotify.com/authorize?response_type=code&client_id=…&scope=…&redirect_uri=…&state=…`
  with scope `playlist-read-private playlist-read-collaborative user-library-read`.
- Token: `POST https://accounts.spotify.com/api/token` (form, HTTP Basic auth `client_id:client_secret`):
  `grant_type=authorization_code&code=…&redirect_uri=…` → `{access_token, refresh_token, expires_in}`;
  refresh: `grant_type=refresh_token&refresh_token=…` → new `access_token`, `expires_in` and **optionally** a
  new `refresh_token` (store it if present).
- `GET https://api.spotify.com/v1/me` → `{id, display_name}`.
- `GET /v1/me/playlists?limit=50&offset=…` → `{items: [{id, name, owner: {id, display_name},
  collaborative, images: [{url}], items: {total}}], next}` (the track count is `items.total`; if a playlist
  object has `tracks.total` instead, use that).
- `GET /v1/playlists/{id}/items?limit=100&offset=…&additional_types=track` → `{items: [{added_at, item:
  {type, id, name, duration_ms, is_local, external_ids: {isrc}, artists: [{name}], album: {name}}}], next}`.
  Only works for playlists the user owns or collaborates on (others: 403 → skip with a message). Entries with
  `item == null`, `item.type != "track"` or `is_local == true` are skipped.
- `GET /v1/me/tracks?limit=50&offset=…` → `{items: [{added_at, track: {…same track object…}}], next, total}`.
- 429 → wait `Retry-After` seconds (default 5, max 60) and retry the same request (max 5 times, then fail the
  import with `"Spotify-Limit erreicht – bitte später erneut versuchen"`). 401 on API calls → refresh once and
  retry. Use one `httpx.AsyncClient` per import run, timeout 30 s.

## 1. Config
`ServerConfig.spotify: SpotifyConfig`:
```python
class SpotifyConfig(BaseModel):
    # From https://developer.spotify.com/dashboard – Redirect URI: <server>/api/spotify/callback
    client_id: str = ""
    client_secret: str = ""
```

## 2. Models + one alembic revision
```python
class SpotifyAccount(Base):            # "spotify_accounts"
    user_id: UUID PK FK users.id ON DELETE CASCADE
    spotify_user_id: String(128); display_name: String(256) | None
    access_token: Text; refresh_token: Text; expires_at: DateTime(tz)
    created_at / updated_at

class SpotifyPlaylistLink(Base):       # "spotify_playlist_links"; which Resonance playlist an import created
    id: UUID PK
    user_id FK users ON DELETE CASCADE, index; spotify_playlist_id: String(64)
    playlist_id FK playlists.id ON DELETE CASCADE
    UniqueConstraint(user_id, spotify_playlist_id)

class SpotifyImport(Base):             # "spotify_imports"
    id: UUID PK; user_id FK users ON DELETE CASCADE, index
    status: String(16)  # queued | running | done | failed
    liked: bool; playlist_ids: JSONB (list[str]); download_missing: bool
    total: int = 0; matched: int = 0; missing: int = 0; requested: int = 0
    message: Text | None
    missing_tracks: JSONB (list of {"title","artist","source"}; max 2000 entries; source = "Lieblingssongs" or
                    the playlist name)
    created_at; finished_at: DateTime(tz) | None

class SpotifyPending(Base):            # "spotify_pending"; tracks waiting for their download
    id: UUID PK; user_id FK users ON DELETE CASCADE, index
    isrc: String(16) | None, index; deezer_id: String(32) | None
    title: String(512); artist: String(1024); duration: Float | None
    like: bool                          # add to likes when it arrives
    like_at: DateTime(tz) | None        # Spotify added_at, used as TrackLike.created_at
    playlist_id: UUID | None FK playlists ON DELETE CASCADE
    position: Float | None              # Spotify index within the playlist
    created_at
```

## 3. Service `app/services/spotify.py`
### 3.1 OAuth
- `redirect_uri(request)` = `str(request.url_for("spotify_callback"))` (uvicorn runs with proxy headers, so this
  is the public https URL).
- `_states: dict[str, tuple[uuid.UUID, float]]` in memory: `state = secrets.token_urlsafe(24)` → (user_id,
  created monotonic); valid 10 minutes, single use.
- `exchange_code(cfg, code, redirect_uri) -> dict` and `refresh(db, account)` (updates tokens, `expires_at =
  now + expires_in - 60 s`, commit). Refresh failing with 400/401 → delete the account, raise
  `SpotifyError(401, "Spotify-Verbindung abgelaufen – bitte neu verbinden")`.
- `class SpotifyError(Exception)` with `status` and German `message` (like `ABSError`).

### 3.2 Reading
`async def fetch_playlists(db, account) -> list[dict]` (all pages, only `owner.id == account.spotify_user_id`
**or** `collaborative == true`; output `{id, name, owner, track_count, image_url (first image or None)}`),
`fetch_liked(db, account) -> list[SpotifyTrack]`, `fetch_playlist_tracks(db, account, id) -> list[SpotifyTrack]`
where
```python
@dataclass
class SpotifyTrack:
    title: str; artist: str        # artists joined with ", "
    album: str | None; isrc: str | None (upper-case); duration: float | None (s)
    added_at: datetime | None; position: int
```

### 3.3 Matching
`async def match(db, tracks: list[SpotifyTrack]) -> list[uuid.UUID | None]`: build `CatalogTrack`s
(`id=""`, `title`, `artist`, `duration`, `album`, `isrc`, other fields None) and call
`matching.match_tracks` in chunks of 500; return `library_id`s in order. Additionally reject a name match
(no ISRC equality) when both durations are known and differ by more than 10 s (load `Track.duration` for the
matched ids in one query).

### 3.4 Import run `async def run_import(import_id)`
Runs as an `asyncio` task (keep references in a module set, like the importer). Status `running`, then:
1. **Liked songs** (if `liked`): fetch, match. For each matched track: insert `TrackLike(user_id, track_id,
   created_at=added_at)` if the user has not liked it yet (never remove likes). Unmatched → see 4.
2. **Playlists** (each id in `playlist_ids`, in order): fetch metadata from the cached `fetch_playlists` result
   (unknown/not owned → add `"<id>: Playlist nicht verfügbar"` to `message`, continue); 403 while reading items
   → message `"„<name>“: Spotify gibt die Songs dieser Playlist nicht frei"`, continue. Find/create the
   Resonance playlist via `SpotifyPlaylistLink` (create: owner = user, `name` = Spotify name,
   `description = "Von Spotify importiert"`, private). Re-import = sync: delete all existing entries of that
   playlist and delete `SpotifyPending` rows of that playlist, then insert one `PlaylistEntry(track_id,
   position=float(spotify position))` per matched track (duplicates allowed, like Spotify). Update the
   playlist `name` to the current Spotify name.
3. **Missing tracks**: counters `total` (+1 per Spotify track processed), `matched`, `missing`. Each missing
   track is appended to `missing_tracks` (until 2000). If `download_missing`:
   - Deezer id: `deezer._get(f"track/isrc:{isrc}")` (add a public method `DeezerClient.track_by_isrc(isrc)
     -> dict | None` returning None on `NotFound`); without ISRC or not found → search
     `search_tracks(f'artist:"{artist}" track:"{title}"', 5)` and take the first result with
     `fuzz.token_set_ratio(norm(title), norm(r.title)) >= 90` and duration diff `<= 5 s`; none → stays missing.
   - `create_request(db, user, "track", deezer_id, temporary=False)`; count `requested` (+1 per new or existing
     request). HTTPException 429 (daily limit) → stop requesting for the rest of this run and append
     `"Tageslimit erreicht – weitere fehlende Songs wurden nicht angefragt"` once to `message`; other
     HTTPException → treat as not found.
   - Insert a `SpotifyPending` row (like/like_at for liked songs; playlist_id/position for playlist entries)
     for every missing track that got a request. The same Spotify track in likes and a playlist → two rows.
4. Commit after each phase and every 200 tracks. Finish: `status="done"`, `finished_at`. Any `SpotifyError` →
   `status="failed"`, `message` = its message; other exceptions → `"Import fehlgeschlagen"` + log.
5. Startup: imports left `queued`/`running` → `failed` with `"Durch Neustart abgebrochen"`.

### 3.5 Resolving pending tracks
`async def resolve_pending(db) -> int`: for all `SpotifyPending` rows find a non-temporary `Track` by `isrc`
(if set) else by the downloaded request item: `DownloadItem` with `meta->>'deezer_track_id' == deezer_id` and
`track_id` not null (use the newest). Found → add like (`created_at = like_at`, skip if already liked) and/or
`PlaylistEntry(position=position)` (skip if the playlist already has this track at that exact position);
delete the row. Rows older than 30 days are deleted. Called (a) from a background loop every 60 s started in
the app lifespan (`spotify.start()/stop()` like `importer`), and (b) right after a download item becomes
`done` in `downloads.py` (fire-and-forget, errors only logged).

## 4. API – `app/api/spotify.py`, prefix `/api/spotify`
All `CurrentUser` except the callback.
- `GET /status` → `{"configured": bool, "connected": bool, "display_name": str | None}`.
- `GET /login` → `{"url": str}`; not configured → 409 `"Spotify ist auf diesem Server nicht eingerichtet"`.
- `GET /callback?code=&state=&error=` (name `spotify_callback`, no auth): validates the state, exchanges the
  code, `GET /me`, upserts `SpotifyAccount`. Returns a small German HTML page (`HTMLResponse`), dark background,
  text `"Spotify ist verbunden. Du kannst dieses Fenster schließen und zu Resonance zurückkehren."` or on error
  `"Verbindung fehlgeschlagen: <reason>"` (invalid/expired state, `error` param, token exchange failure).
- `DELETE /login` → 204, deletes the account (no Spotify call).
- `GET /playlists` → `{"liked_count": int, "playlists": [{"id","name","owner","track_count","image_url",
  "imported": bool}]}` (`liked_count` from `GET /v1/me/tracks?limit=1` → `total`; `imported` = a
  `SpotifyPlaylistLink` exists). Not connected → 409 `"Kein Spotify-Konto verbunden"`.
- `POST /imports` body `{"liked": bool, "playlist_ids": list[str] (max 200), "download_missing": bool}` → 202
  `SpotifyImportOut`; nothing selected → 422 `"Nichts ausgewählt"`; another import of this user
  `queued|running` → 409 `"Es läuft bereits ein Import"`.
- `GET /imports` → last 20 of the user, newest first (without `missing_tracks`).
- `GET /imports/{id}` → `SpotifyImportOut` incl. `missing_tracks`; other users' imports → 404.
`SpotifyErrors` map to their status/message.

## 5. Tests (`tests/test_spotify.py`, no network)
Mock accounts.spotify.com / api.spotify.com / Deezer with `httpx.MockTransport` (monkeypatch the module's
client factory). Cover: login URL + state, callback success / bad state / expired state / `error` param,
token refresh (incl. rotated refresh token) and refresh failure deleting the account, 401 retry, 429 with
Retry-After (monkeypatch sleep), pagination for playlists/likes/items, owner/collaborative filter, 403 playlist
skipped with message, local/null/episode items skipped; import of likes (created_at = added_at, existing likes
kept), playlist creation + re-import sync (entries replaced, order = Spotify order, name updated), ISRC match and
name match with the 10 s duration guard, missing tracks → Deezer by ISRC and by search → `create_request`
called (monkeypatched) → pending rows; daily-limit 429 stops requesting; `resolve_pending` adds likes/entries at
the right position after a matching Track appears (by ISRC and by deezer id through a DownloadItem); status /
imports listing / per-user isolation / 409 conflicts; startup recovery. All existing tests stay green.

## 6. Report
Files, pytest tail, migration check (`alembic upgrade head` on a fresh DB + `alembic check`), deviations.
