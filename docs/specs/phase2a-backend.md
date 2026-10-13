# Phase 2a – Request & download pipeline (backend only)

This is a precise implementation spec. Implement exactly what is written. Where something is not
specified, choose the simplest option that matches existing code patterns. Do not add features,
endpoints, fields, settings or files that are not listed here. Do not refactor unrelated code.

Repository: `/home/kjell/Documents/SpotifyClone`. Work only inside `backend/`, plus the two
`Dockerfile` lines listed in §11. Never touch `app/` (Flutter client – developed in parallel by someone else).
Do not run any git command that changes the index, HEAD or working tree of files you did not write
(no `git add`, `git commit`, `git stash`, `git checkout`, `git reset`). `git diff` / `git status` are fine.

Note: `backend/app/services/scanner.py` (`_walk`), `backend/app/services/tags.py` (`_codec`, `.mpc`) and
`backend/app/api/library.py` (`format=auto`) contain recent uncommitted edits – keep them.

## 0. Conventions (follow existing code)

- Python 3.12, async SQLAlchemy 2 (`Mapped`/`mapped_column`), pydantic v2, FastAPI routers with the
  `DB`, `CurrentUser`, `AdminUser` aliases from `app/deps.py`, `Page[T]` from `app/schemas.py`
  (`items,total,offset,limit`; query params `offset` default 0, `limit` default 50, max 200).
- User-facing error messages (`HTTPException.detail`, `error` fields) in **German**; code comments in
  English, sparse, only where non-obvious.
- Line length 120. Type hints everywhere. No new global state except what is listed.
- Logging via `logging.getLogger(__name__)`.

## 1. Dependencies (`backend/pyproject.toml`)

Add to `dependencies`: `"yt-dlp[default]>=2025.10"`, `"ytmusicapi>=1.10"`, `"rapidfuzz>=3.9"`.
Install into `backend/.venv` (`.venv/bin/pip install -e '.[dev]'`).

## 2. Settings (`app/config.py`, class `Settings`)

Add exactly these fields (env prefix stays `RESONANCE_`):

```python
# Working directory for in-progress downloads (same disk as music_dir so moves are cheap).
downloads_dir: Path = Path("/data/downloads")
# Contact for the MusicBrainz User-Agent (their API policy asks for one), e.g. an e-mail or URL.
musicbrainz_contact: str = ""
# Number of parallel download workers; 0 disables the background worker (tests).
download_workers: int = 2
# Optional Netscape cookies file for yt-dlp (age-restricted videos).
ytdlp_cookies_file: Path | None = None
```

## 3. Server config (`app/services/server_config.py`)

In `DownloadConfig` add one field: `youtube_enabled: bool = True` (comment: "YouTube Music via yt-dlp
as a download source."). Nothing else.

## 4. Models – new file `app/models/downloads.py`, export both classes from `app/models/__init__.py`

```python
class DownloadRequest(Base):
    __tablename__ = "download_requests"
    id: uuid pk default uuid4
    user_id: FK users.id ondelete CASCADE, index
    kind: String(16)                 # "track" | "album"
    mb_id: String(36)                # recording MBID (track) or release-group MBID (album)
    mb_release_id: String(36) | None # the concrete release chosen (§6.4)
    title: String(512)
    artist: String(1024)             # artist credit string
    cover_url: Text | None
    status: String(24), index        # see §8.5
    is_temporary: bool default False
    note: Text | None                # rejection reason
    created_at, updated_at: DateTime(tz) server_default now(), updated_at onupdate now()
    items: relationship("DownloadItem", back_populates="request", cascade="all, delete-orphan",
                        order_by="DownloadItem.position")
    user: relationship(User)

class DownloadItem(Base):
    __tablename__ = "download_items"
    id: uuid pk
    request_id: FK download_requests.id ondelete CASCADE, index
    position: int                    # 0-based order within the request
    title: String(512)
    artist: String(1024)             # artist credit string
    duration: Float | None           # seconds, from MusicBrainz
    meta: JSONB                      # TrackMeta.model_dump() (§5)
    status: String(16), index        # waiting|queued|searching|downloading|processing|done|exists|failed|cancelled
    progress: Float default 0        # 0..1, only meaningful while downloading
    source: String(32) | None        # "youtube"
    source_ref: Text | None          # e.g. YouTube video id
    error: Text | None
    attempts: int default 0
    track_id: FK tracks.id ondelete SET NULL | None
    created_at, updated_at like above
    request: relationship(back_populates="items")
```

Alembic: create the migration with `.venv/bin/alembic revision --autogenerate -m "downloads"`
(against DB `app` on localhost:55432, which is at head), review it, make sure downgrade drops both
tables. Test `upgrade head` → `downgrade -1` → `upgrade head`.

## 5. `TrackMeta` (in `app/services/musicbrainz.py`)

```python
class TrackMeta(BaseModel):
    title: str
    artist: str                      # credit string, e.g. "A feat. B" (joinphrases concatenated)
    artist_mbid: str | None          # first credited artist
    album: str
    album_artist: str                # release artist credit string
    album_artist_mbid: str | None
    track_no: int | None
    track_total: int | None
    disc_no: int | None
    disc_total: int | None
    year: int | None
    date: str | None                 # release date as given by MB ("2019", "2019-05", "2019-05-03")
    duration: float | None           # seconds
    isrc: str | None                 # first ISRC
    genre: str | None                # highest-count MB genre of the release-group, title-cased; else None
    label: str | None
    mb_recording_id: str
    mb_release_id: str
    mb_release_group_id: str
```

## 6. MusicBrainz client – new file `app/services/musicbrainz.py`

### 6.1 Transport
- Module-level singleton `mb = MusicBrainzClient()`; methods are `async`.
- `httpx.AsyncClient(base_url="https://musicbrainz.org/ws/2/", timeout=20)`, created lazily.
- User-Agent: `f"Resonance/{VERSION} ( {contact} )"` if `settings.musicbrainz_contact` else
  `f"Resonance/{VERSION}"`, `VERSION = "0.1.0"`. Always `fmt=json`.
- Rate limit: one `asyncio.Lock`; inside it, sleep so that ≥ 1.1 s passed since the previous request
  started. On HTTP 503 wait 2 s and retry once. On 404 raise `NotFound` (own exception). Other errors
  raise `MusicBrainzError(str)`.
- In-memory TTL cache keyed by (path, sorted params): TTL 3600 s, at most 2000 entries (drop oldest).

### 6.2 Search
- `search_artists(q, limit) -> list[CatalogArtist]` → `GET artist?query={q}&limit={limit}`
- `search_albums(q, limit) -> list[CatalogAlbum]` → `GET release-group?query={q}&limit={limit}`;
  keep only `primary-type` in {Album, EP, Single}.
- `search_tracks(q, limit) -> list[CatalogTrack]` → `GET recording?query={q}&limit={limit}`;
  drop recordings with `video: true`. `album`/`cover_url` from the first release in the result whose
  release-group primary-type is Album, else the first release, else None.

### 6.3 Lookups
- `artist(mbid) -> CatalogArtistDetail`: `GET artist/{mbid}` plus
  `GET release-group?artist={mbid}&type=album|ep|single&limit=100` (browse). Exclude release groups
  with any secondary type (compilations, live, soundtracks, remixes…). Sort by year desc, then title.
- `album(rg_mbid) -> CatalogAlbumDetail`: `GET release?release-group={rg}&inc=media&limit=100`,
  pick a release (§6.4), then `release_full(release_id)`.
- `release_full(release_id) -> dict` (raw JSON):
  `GET release/{id}?inc=recordings+artist-credits+isrcs+release-groups+labels+genres+media`.
- `track_meta_list(release_json) -> list[TrackMeta]`: one entry per track on every medium, skipping
  tracks whose recording has `video: true`. `track_total` = tracks on that medium,
  `disc_total` = number of media.
- `recording_meta(recording_mbid) -> TrackMeta`: `GET recording/{id}?inc=releases+release-groups`,
  pick a release among `releases` (§6.4), `release_full`, find the track whose recording id matches and
  return its `TrackMeta`. Raise `NotFound` if none.

### 6.4 Release choice (deterministic)
Sort candidates by this tuple ascending, take the first:
1. `0` if status == "Official" else `1`
2. (recording only) `0` if release-group has no secondary types else `1`
3. (recording only) primary-type rank: Album 0, EP 1, Single 2, other 3
4. format rank of the first medium: "Digital Media" 0, "CD" 1, anything else 2 (unknown when the
   payload has no media → 2)
5. `date` or `"9999"`
6. release id

### 6.5 Catalog schemas (add to `app/schemas.py`)
```python
class CatalogArtist(BaseModel):
    mbid: str; name: str; disambiguation: str | None; country: str | None
    library_id: uuid.UUID | None     # matching local Artist (§6.6)

class CatalogAlbum(BaseModel):
    mbid: str                        # release-group
    title: str; artist: str; artist_mbid: str | None
    primary_type: str | None; year: int | None
    cover_url: str                   # f"https://coverartarchive.org/release-group/{mbid}/front-250"
    library_id: uuid.UUID | None     # matching local Album

class CatalogTrack(BaseModel):
    mbid: str                        # recording
    title: str; artist: str; artist_mbid: str | None
    duration: float | None
    album: str | None
    cover_url: str | None            # release-group front-250 of the release used for `album`
    disc_no: int | None; track_no: int | None   # only filled inside CatalogAlbumDetail
    library_id: uuid.UUID | None     # matching local Track

class CatalogArtistDetail(BaseModel):
    artist: CatalogArtist
    albums: list[CatalogAlbum]

class CatalogAlbumDetail(CatalogAlbum):
    release_mbid: str
    tracks: list[CatalogTrack]

class CatalogSearchOut(BaseModel):
    artists: list[CatalogArtist]; albums: list[CatalogAlbum]; tracks: list[CatalogTrack]
```

### 6.6 Library matching – new file `app/services/matching.py`
Use the same key function as the scanner (`" ".join(value.casefold().split())`; move `_key` from
scanner.py to matching.py as `name_key` and import it in scanner.py).
- Artist: `Artist.mb_artist_id == mbid` else `Artist.name_key == name_key(name)`.
- Album: join Artist: `Artist.name_key == name_key(artist)` and `Album.title_key == name_key(title)`.
- Track: `Track.mb_recording_id == mbid`, else join Artist (track artist **or** album artist) with
  `Artist.name_key == name_key(primary artist)` and `func.lower(Track.title) == title.casefold()`.
  Primary artist = text before the first joinphrase (use `app.services.tags.primary_artist` if it fits;
  it splits on feat./ft./featuring).
- Provide batch helpers `match_artists(db, list[CatalogArtist])`, `match_albums(...)`,
  `match_tracks(...)` that set `library_id` in place using at most one query per helper.

## 7. Download sources – new package `app/services/sources/`

`base.py`:
```python
@dataclass
class Candidate:
    source: str; ref: str; title: str; artist: str; duration: float | None; score: float

class Cancelled(Exception): ...

class Source(Protocol):
    name: str
    async def find(self, meta: TrackMeta) -> Candidate | None: ...
    async def download(self, candidate: Candidate, dest_dir: Path,
                       progress: Callable[[float], None], cancelled: Callable[[], bool]) -> Path: ...
```

`youtube.py` – class `YouTubeMusicSource`, `name = "youtube"`:

**find**: `YTMusic()` (unauthenticated, created once), run in `asyncio.to_thread`:
`search(f"{meta.artist} {meta.title}", filter="songs", limit=10)`. Score every result with the pure
function `score_candidate(meta, title, artists: list[str], duration: float | None, is_video: bool) -> float | None`:
- `norm(s)`: casefold; remove bracketed parts `(...)`/`[...]` that contain any of
  `remaster, remastered, version, edit, explicit, clean, mono, stereo`; remove `feat. …`/`ft. …`/
  `featuring …` up to the end or the next bracket; collapse whitespace; strip.
- `title_ratio = fuzz.token_set_ratio(norm(meta.title), norm(title))`
- `artist_ratio = max(fuzz.token_set_ratio(norm(meta.artist), norm(a)) for a in artists)` (0 if empty)
- duration diff `d = abs(meta.duration - duration)`; if either is None → `duration_score = 50`,
  else `100` if `d <= 2`, `0` if `d >= 15`, linear in between.
- Reject (return None) if `title_ratio < 70` or `artist_ratio < 60` or (`d` known and `d > 15`).
- Reject if the candidate title contains one of `live, cover, karaoke, instrumental, remix, sped up,
  slowed, nightcore, 8d, reverb` (word match, casefolded) that `meta.title` does not contain.
- `score = 0.5*title_ratio + 0.3*artist_ratio + 0.2*duration_score`; for videos `score -= 10` and reject
  videos with known `d > 5`.
If no song passes, repeat the search with `filter="videos"`. Return the best-scoring Candidate
(`ref` = videoId) or None.

**download**: `yt_dlp.YoutubeDL` in `asyncio.to_thread` with
`format="bestaudio[acodec=opus]/bestaudio[ext=m4a]/bestaudio"`, `outtmpl=str(dest_dir/"source.%(ext)s")`,
`noplaylist=True`, `quiet=True`, `no_warnings=True`, `cookiefile` if configured, a progress hook that
calls `progress(downloaded_bytes/total_bytes_or_estimate)` (thread-safe: hook runs in a thread – use
`loop.call_soon_threadsafe`) and raises `Cancelled` when `cancelled()` is true. URL:
`https://music.youtube.com/watch?v={ref}`. Afterwards remux without re-encoding with ffmpeg
(`settings.ffmpeg_path`, `-nostdin -loglevel error -i src -map 0:a:0 -vn -c:a copy`) to
`dest_dir/"audio.opus"` if `acodec` starts with `opus`, `dest_dir/"audio.m4a"` if it starts with `mp4a`,
otherwise re-encode to `audio.opus` with `-c:a libopus -b:a 192k`. Delete the source file. Return the path.

`__init__.py`: `def enabled_sources(cfg: ServerConfig) -> list[Source]` returns
`[YouTubeMusicSource()]` if `cfg.downloads.youtube_enabled` else `[]` (instances cached at module level).
Tests monkeypatch this function.

## 8. Pipeline – new file `app/services/downloads.py`

### 8.1 Tagging – new file `app/services/tagger.py`
`write_tags(path: Path, meta: TrackMeta, cover: bytes | None) -> None` (sync; call via to_thread) using
mutagen, for `.opus`/`.ogg` (Vorbis comments; cover as base64 `METADATA_BLOCK_PICTURE`), `.m4a`
(MP4 atoms incl. `----:com.apple.iTunes:MusicBrainz Track Id` style freeform atoms), `.flac`, `.mp3`
(ID3v2.4). Fields: title, artist, album, albumartist, tracknumber/totaltracks, discnumber/totaldiscs,
date, genre, isrc, label, musicbrainz_trackid (= recording id, Picard convention), musicbrainz_albumid,
musicbrainz_releasegroupid, musicbrainz_artistid, musicbrainz_albumartistid. Requirement:
`app.services.tags.read_tags` must read back title, artist, album, album_artist, track_no, disc_no,
year, mb_recording_id, isrc, mb_album_id, mb_artist_id, mb_album_artist_id for every format (unit test).
If `read_tags` fails to read a field that tagger writes in a standard Picard way, fix `read_tags`.

Cover: `async fetch_cover(meta) -> bytes | None`: cache file `data_dir/caa/{mb_release_id}.jpg`;
otherwise GET `https://coverartarchive.org/release/{release}/front-1200`, on 404
`https://coverartarchive.org/release-group/{rg}/front-1200`; follow redirects; on failure None.

### 8.2 Library path – new file `app/services/library_paths.py`
`target_relpath(meta: TrackMeta, ext: str) -> str`:
`{album_artist}/{album}{f" ({year})" if year else ""}/{f"{disc_no}-" if (disc_total or 1) > 1 else ""}{track_no:02d} - {title}{ext}`
(`track_no` missing → omit `"NN - "`). Sanitize each path component: replace `/ \ : * ? " < > |` and
control chars with `_`, collapse whitespace, strip spaces and trailing dots, max 120 chars, empty →
`"_"`. If the target exists, append ` (2)`, ` (3)`, … before the extension.

### 8.3 Library import (`app/services/scanner.py`)
- Add module-level `library_lock = asyncio.Lock()`. `run_scan` holds it for the whole DB phase.
- `_Syncer.upsert` returns the `Track | None`.
- New `async def import_file(db: AsyncSession, rel: str) -> Track | None`: under `library_lock`, stat the
  file, `_Syncer(db, full=False)`, `await syncer.load()`, `upsert(rel, mtime, size, existing)` where
  `existing` is the Track with that path if any, commit, return the track.

### 8.4 Worker – class `DownloadManager`, module singleton `manager`
- `start()` (called from FastAPI lifespan when `settings.download_workers > 0`): reset items in
  `searching|downloading|processing` to `queued`, then start `download_workers` worker tasks.
  `stop()` cancels them (lifespan shutdown). Add a lifespan to `app/main.py` doing exactly that.
- `wake()`: sets an `asyncio.Event`; workers wait on it with a 10 s timeout between empty polls.
- `async process_one() -> bool`: claims the next item
  (`status='queued'` ordered by `created_at, position`, `FOR UPDATE SKIP LOCKED`, `LIMIT 1`), sets
  `searching`, commits, runs `_run(item)`; returns False if nothing was queued. Workers loop on it.
  Tests call it directly.
- `_run(item)`:
  1. Library check (§6.6 track matching with `meta.mb_recording_id`, `meta.artist`, `meta.title`):
     found → `status=exists`, `track_id`, done.
  2. `sources = enabled_sources(cfg)`; none → `failed`, error `"Keine Download-Quelle aktiviert"`.
  3. For each source: `find`; first non-None candidate wins. None at all →
     `failed`, `"Keine passende Quelle gefunden"`.
  4. `status=downloading`, `source`, `source_ref`; download into `downloads_dir/"resonance"/str(item.id)`
     (recreate empty). Progress is kept in an in-memory dict and written to the DB at most every 2 s.
  5. `status=processing`: `fetch_cover`, `write_tags`, move to
     `music_dir / target_relpath(meta, path.suffix)` (`shutil.move`, mkdirs), write `cover.jpg` next to
     it if a cover exists and the dir has none, `import_file`. Track gets `is_temporary =
     request.is_temporary`. `status=done`, `track_id`, `progress=1`.
  6. Always remove the working dir. Any exception → `attempts += 1`, `status=failed`,
     `error` = German short message (`f"Download fehlgeschlagen: {e}"` truncated to 500 chars), log
     with traceback. `Cancelled` → `status=cancelled`.
  7. After every status change recompute the request status (§8.5) in the same transaction.
- Cancellation: `cancel_request` marks `waiting|queued` items `cancelled` in the DB and adds ids of
  `searching|downloading` items to an in-memory `set` that `cancelled()` checks.

### 8.5 Request status (pure function `request_status(item_statuses, current) -> str`)
- current in {`pending_approval`, `rejected`} → unchanged
- any item in waiting/queued/searching/downloading/processing → `active`
- all items in done/exists → `done`
- all items cancelled → `cancelled`
- any done/exists → `partial`
- otherwise → `failed`

### 8.6 Creating requests – `async create_request(db, user, kind, mbid, temporary) -> DownloadRequest`
1. If the user already has a request with same kind+mb_id in status `pending_approval|active`, return it.
2. Metadata: track → `[await mb.recording_meta(mbid)]`; album → `mb.album(mbid)` →
   `track_meta_list(release_full)`. MB `NotFound` → 404 `"Nicht bei MusicBrainz gefunden"`;
   `MusicBrainzError` → 502 `"MusicBrainz nicht erreichbar"`.
3. Daily limit (`cfg.downloads.daily_limit_enabled` and user is not admin): count items of the user's
   requests created in the last 24 h (rolling) excluding status `exists`; if count + new items that
   are not already in the library > `daily_limit_per_user` → 429
   `f"Tageslimit erreicht ({count} von {limit} Songs in 24 Stunden)"`.
4. Approval: admin or `cfg.downloads.auto_approve_requests` → status `active`, new items `queued`;
   else request `pending_approval`, items `waiting`.
5. Items already in the library (§6.6) → `exists` + `track_id` immediately.
6. `title`/`artist`/`cover_url`: album → release-group title, artist credit, CAA release-group
   front-250; track → recording title, artist, CAA release-group front-250 of the chosen release.
   `is_temporary = temporary and user.role == admin` (the API flag only exists for admins / radio later).
7. Recompute status (§8.5), commit, `manager.wake()`.

## 9. API

### 9.1 `app/api/catalog.py` (prefix `/api/catalog`, any logged-in user)
- `GET /search?q=&types=artist,album,track&limit=10` (q 1–200 chars, limit 1–25) → `CatalogSearchOut`
  (types not requested → empty lists). Matching via §6.6.
- `GET /artists/{mbid}` → `CatalogArtistDetail` (artist and albums matched)
- `GET /albums/{mbid}` → `CatalogAlbumDetail` (album and tracks matched; tracks carry disc/track no)
- MB errors map to 404/502 as in §8.6.

### 9.2 `app/api/requests.py`
Schemas (in `app/schemas.py`):
```python
class DownloadItemOut(ORM): id, position, title, artist, duration, status, progress, source, error, track_id
class DownloadRequestOut(ORM):
    id, kind, mb_id, title, artist, cover_url, status, is_temporary, note, created_at, updated_at
    user: UserRef            # new ORM schema {id, username}
    progress: float          # mean over items: done/exists/failed/cancelled = 1, downloading = item.progress, else 0
    item_count: int; done_count: int  # done_count counts done + exists
    failed_count: int
class DownloadRequestDetail(DownloadRequestOut): items: list[DownloadItemOut]
class RequestIn(BaseModel): kind: Literal["track","album"]; mbid: str (36 chars); temporary: bool = False
class RejectIn(BaseModel): note: str | None = None (max 500)
class DownloadSummary(BaseModel): active: int; queued: int; failed: int; pending_approval: int
```
Endpoints:
- `POST /api/requests` (`RequestIn`) → 201 `DownloadRequestDetail`; existing duplicate → 200.
- `GET /api/requests?scope=mine|all&state=open|finished|all&offset&limit` →
  `Page[DownloadRequestOut]`, newest first. `scope=all` non-admin → 403 `"Nur für Admins"`.
  `open` = pending_approval|active; `finished` = the rest.
- `GET /api/requests/{id}` → `DownloadRequestDetail`; not owner and not admin → 404.
- `POST /api/requests/{id}/approve` (admin): only from `pending_approval`, else 409; items
  waiting→queued; recompute; wake. Returns detail.
- `POST /api/requests/{id}/reject` (admin, `RejectIn`): only from `pending_approval`; status
  `rejected`, items `cancelled`, `note`. Returns detail.
- `POST /api/requests/{id}/cancel` (owner or admin): §8.4 cancellation; recompute. Returns detail.
- `POST /api/requests/{id}/retry` (owner or admin): `failed` items → `queued`, `error=None`,
  `progress=0`; recompute; wake. Returns detail.
- `DELETE /api/requests/{id}` (admin): 409 if status `active`; else delete → 204.
- `GET /api/requests/summary` → `DownloadSummary`: counts of **items** (active =
  searching|downloading|processing, queued, failed) and **requests** (pending_approval); scoped to the
  user's own requests for non-admins, global for admins. Declare this route before `/{id}`.

Register both routers in `app/main.py`.

## 10. Tests – new file `tests/test_downloads.py` (no network access!)
Set `os.environ["RESONANCE_DOWNLOAD_WORKERS"] = "0"` and `RESONANCE_DOWNLOADS_DIR` in `conftest.py`
next to the other env vars. Monkeypatch `mb` methods with small hand-written JSON fixtures in
`tests/fixtures/` (one release with 2 media / 3 tracks, one recording) and `enabled_sources` with a
`FakeSource` whose `download` creates a 3 s sine `.opus` via ffmpeg; `fetch_cover` returns a tiny JPEG.
Cover these cases:
1. `score_candidate`: exact match accepted; wrong artist rejected; "Live" variant rejected; duration
   20 s off rejected; video with 3 s diff accepted with lower score than the equal song.
2. `target_relpath` incl. sanitizing, multi-disc prefix, missing year, collision suffix.
3. `request_status` table.
4. Tagger round trip for `.opus`, `.m4a`, `.mp3`, `.flac` (files generated by ffmpeg).
5. Album request by admin → 3 items queued → `process_one()` ×3 → files at expected paths, tracks in
   library, request `done`, `GET /api/albums/{id}` lists them; a second request for the same album →
   all items `exists`.
6. Non-admin with `auto_approve_requests=false` → `pending_approval`; approve → queued; reject path.
7. Daily limit 429 (limit 2, album with 3 tracks).
8. Cancel queued request; retry failed item (FakeSource raising once).
9. Permissions: other user gets 404 on detail; non-admin `scope=all` → 403.
10. Catalog search marks `library_id` for an already scanned track/album/artist.
All existing tests must still pass: `cd backend && .venv/bin/pytest -q`.

## 11. Dockerfile
yt-dlp needs a JavaScript runtime for YouTube. In the server stage add, after the ffmpeg install:
`COPY --from=docker.io/denoland/deno:bin /deno /usr/local/bin/deno`. Nothing else.

## 12. Done criteria
- `pytest -q` green, migration up/down/up works.
- Report back: list of files created/changed, anything in this spec you could not implement exactly
  and why, and any deviation (there should be none without a stated reason).
