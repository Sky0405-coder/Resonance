# Phase 2c-1 – Import folder & library cleanup (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files. Where silent, choose the simplest option matching existing code. List any deviation
with a reason in the final report. Same general rules as `docs/specs/phase2a-backend.md` §0 (only
`backend/`, never `app/`/`docs/`, no git commands that modify
index/HEAD/working tree, German user-facing texts, existing style, `ruff format --line-length 120` on
new/rewritten files, tests without network).

## Goal
One identification engine, two entry points:
- **Import**: audio files in `settings.import_dir` are identified, tagged, renamed and placed into
  `music_dir` (`Artist/Album (Year)/NN - Title.ext`), then added to the library. Mode `move` (default,
  server) or `copy` (originals stay untouched – used to clean a copy of a laptop collection).
- **Cleanup**: the same for files already inside `music_dir`, in place. Track rows keep their ids
  (likes/playlists survive), only path and metadata change.

Real-world input is messy: genre folders (`POP/Male/Beck/Mutations/…`), compilations without album
artist, promo CDs that MusicBrainz doesn't know, folders of loose singles, WMA/APE/AIFF/WAV/MPC files.

## 1. Settings / config
- `Settings.import_dir: Path = Path("/data/import")` (comment: "Drop folder for new music (import).").
- New `LibraryConfig` in `server_config.py`, `ServerConfig.library: LibraryConfig = LibraryConfig()`:
  ```python
  class LibraryConfig(BaseModel):
      # Free key from https://acoustid.org/new-application – enables audio fingerprint identification.
      acoustid_api_key: str = ""
      # "move": imported files leave the import folder; "copy": originals stay untouched.
      import_mode: Literal["move", "copy"] = "move"
      # Files that cannot be identified are imported with their existing tags instead of being left behind.
      import_unidentified: bool = True
      # Periodically import new files from the import folder (only in "move" mode).
      auto_import: bool = True
  ```

## 2. Models – new file `app/models/imports.py` (export from `app/models/__init__.py`)
```python
class ImportBatch(Base):
    __tablename__ = "import_batches"
    id: uuid pk
    kind: String(16)              # "import" | "cleanup"
    mode: String(8)               # "move" | "copy" | "inplace" (cleanup)
    source_dir: Text              # absolute path that was scanned
    status: String(16), index     # queued | running | done | failed | cancelled
    total, processed, identified, imported, duplicates, unidentified, failed: int default 0
    message: Text | None
    created_by_id: FK users.id ondelete SET NULL | None
    created_at (server_default now), finished_at: DateTime(tz) | None

class ImportFile(Base):
    __tablename__ = "import_files"
    __table_args__ = (UniqueConstraint("batch_id", "path"),)
    id: uuid pk
    batch_id: FK import_batches.id ondelete CASCADE, index
    path: Text                    # relative to batch.source_dir
    group_key: Text               # see §4.1
    status: String(16), index     # pending | identified | unidentified | imported | duplicate | failed | skipped
    method: String(16) | None     # release | recording | deezer | tags
    acoustid_score: Float | None
    meta: JSONB | None            # TrackMeta.model_dump()
    target: Text | None           # path relative to music_dir
    error: Text | None
    track_id: FK tracks.id ondelete SET NULL | None
    created_at, updated_at (like DownloadItem)
```
Alembic revision via autogenerate (review; downgrade drops both tables; up/down/up on DB `app`).

## 3. Building blocks

### 3.1 Fingerprint – new file `app/services/fingerprint.py`
`async def fingerprint(path: Path) -> str | None`: run
`[ffmpeg_path, "-nostdin", "-v", "error", "-i", str(path), "-t", "120", "-ac", "2", "-f", "chromaprint",
"-fp_format", "base64", "-"]` (asyncio subprocess, stdout captured), return the stripped stdout or None
on non-zero exit / empty output. A module semaphore limits concurrent ffmpeg processes to
`max(1, (os.cpu_count() or 2) // 2)`.

### 3.2 AcoustID – new file `app/services/acoustid.py`
- `async def lookup(api_key: str, fingerprint: str, duration: float) -> list[dict]` – POST form to
  `https://api.acoustid.org/v2/lookup` with `client`, `meta="recordings releasegroups releases tracks compress"`,
  `duration=int(round(duration))`, `fingerprint`. Returns `results`.
- Rate limit: module `asyncio.Lock`, ≥ 0.34 s between request starts. HTTP 429/503: wait 2 s, retry,
  max 2 retries. JSON `status != "ok"` or other HTTP errors → `AcoustIDError(message)`.
- Response shape (verified):
  `results[] {score, recordings[] {id, title, duration, artists[{id,name,joinphrase?}],
  releasegroups[] {id, title, type, secondarytypes?, artists[], releases[] {id, country, date{year,month,day},
  medium_count, track_count, mediums[] {position, format, track_count, tracks[] {id, position, artists[]}}}}}}`.
  Any key may be missing.

### 3.3 MusicBrainz additions (`app/services/musicbrainz.py`)
`async def recording_basic(mbid) -> dict` → `GET recording/{mbid}?inc=artist-credits+isrcs+genres`, returns
`{"title", "artist" (credit string via _credit), "artist_mbid", "isrc" (first or None), "genre"
(highest-count genre title-cased or None), "length" (seconds or None)}`.

### 3.4 Tagger (`app/services/tagger.py`)
- Support additionally: `.ogg`/`.oga` (Vorbis comments, like `.opus`), `.wav`, `.aif`, `.aiff`
  (ID3v2.4 via `mutagen.wave.WAVE` / `mutagen.aiff.AIFF` `add_tags()`), `.ape`, `.mpc`, `.wv`
  (APEv2 keys `Title, Artist, Album, Album Artist, Track ("n/total"), Disc, Year, Genre, ISRC, Label,
  MUSICBRAINZ_TRACKID, MUSICBRAINZ_ALBUMID, MUSICBRAINZ_RELEASEGROUPID, MUSICBRAINZ_ARTISTID,
  MUSICBRAINZ_ALBUMARTISTID`), `.wma` (ASF: `Title, Author, WM/AlbumTitle, WM/AlbumArtist,
  WM/TrackNumber, WM/PartOfSet, WM/Year, WM/Genre, WM/ISRC, WM/Publisher, MusicBrainz/Track Id,
  MusicBrainz/Album Id, MusicBrainz/Release Group Id, MusicBrainz/Artist Id, MusicBrainz/Album Artist Id`).
  `.m4a/.mp4` already supported (also covers ALAC).
- New keyword `write_tags(path, meta, cover, clear_missing: bool = False)`: when True, the five
  MusicBrainz id tags and ISRC are **removed** from the file if the corresponding meta value is None
  (stale ids from earlier taggers must not survive). `cover=None` never removes an existing embedded cover.
- `read_tags` must read back all listed fields for every format (extend `read_tags` where needed).

### 3.5 Library paths (`app/services/library_paths.py`)
`target_relpath(meta, ext, unique: bool = True)`: with `unique=False` the collision suffix logic is
skipped (caller handles collisions). Extension is lower-cased.

### 3.6 Library DB helpers (`app/services/scanner.py`)
- `async def import_files(db, rels: list[str]) -> dict[str, Track | None]`: like `import_file` but one
  `library_lock` acquisition, one `_Syncer` + `load()` and one commit for the whole list; increments
  `_imports`. `import_file` becomes a thin wrapper around it.
- `async def relocate_track(db, old_rel: str, new_rel: str) -> None`: under `library_lock` update
  `Track.path` from old to new (no-op if no row), commit.

## 4. Identification – new file `app/services/identify.py`
All selection logic as pure, unit-testable functions.

### 4.1 Groups
`group_key(rel_path) -> str`: the parent directory (posix, relative to the source dir); if the parent's
name matches `^(cd|disc|disk)\s*\d+$` (case-insensitive) use the grandparent. Files directly in the
root: `""`.

### 4.2 Candidates
`candidates(results) -> list[Candidate]` with
```python
@dataclass
class Candidate:
    score: float; recording_id: str; release_id: str | None; release_group_id: str | None
    album: str | None             # release group title
    disc_no: int | None; track_no: int | None; release_tracks: int | None   # release track_count
    year: int | None
```
For every result with `score >= 0.8`, every recording, every release group, every release, every
medium/track of that release: one Candidate. Recordings without release groups give one Candidate with
release fields None.

### 4.3 Release choice for a group
`choose_release(files: list[FileInfo]) -> str | None` where `FileInfo` holds the file's candidates and
its existing `TrackTags`. Let `n` = number of files in the group with at least one candidate.
For every release id: `count` = number of distinct files having a candidate on it. Best release by
max of `(count, -abs(release_tracks - len(files)), -(year or 9999), release_id_reversed_for_stability)`
– i.e. most files, then track count closest to the folder size, then earliest year (use plain release id
as the last ascending tie-breaker). Accept it when `count >= 2 and count >= ceil(0.6 * n)`, or when
`len(files) == 1` and `name_key(existing album tag) == name_key(candidate.album)`. Otherwise None.

### 4.4 Album context for non-release files
`album_context(files) -> dict[file, AlbumCtx]` (`AlbumCtx`: album, album_artist, year, disc_total).
Within a group, sub-group files by `name_key(existing album tag)`; for each sub-group:
- album = most common original album tag value; files **without** album tag: album = their own title
  (treated as a single) and album_artist = their artist, year = their year.
- album_artist = most common albumartist tag if at least half of the sub-group has one; else
  `"Various Artists"` if the sub-group has ≥ 2 distinct `name_key(primary_artist(artist))`; else the artist.
- year = most common year; disc_total = max disc_no (None if none).
(The scanner's TrackTags falls back to the folder name for album and to artist for album_artist –
for this function use the **raw** tag presence: add `has_album_tag: bool` and `has_album_artist_tag: bool`
to `TrackTags`, set in `read_tags`.)

### 4.5 Per-file metadata (in this order)
1. **release** – group has a chosen release and the file has a candidate on it: `mb.release_full` →
   `mb.track_meta_list`, take the meta with matching `disc_no`/`track_no`. method `release`.
2. **recording** – file has candidates but not on the chosen release (or no release chosen): best
   candidate by score; `mb.recording_basic(recording_id)` gives title, artist, artist_mbid, isrc, genre,
   duration; album/album_artist/year/disc_total from §4.4; track_no/disc_no from existing tags;
   MB release ids None. method `recording`.
3. **deezer** – no candidates, but the file has real artist and title tags: Deezer
   `search_tracks(f'artist:"{artist}" track:"{title}"', 5)`; first result with
   `fuzz.token_set_ratio(norm(title), norm(r.title)) >= 90`, artist ratio `>= 85` (`norm` from the YouTube
   source module) and duration difference `<= 3 s` → `resolve_track(r.id)` and then, exactly like
   *recording*, keep only the track-level fields (title, artist, artist_mbid, isrc, genre, duration,
   mb_recording_id) and take album-level fields from §4.4. method `deezer`.
4. **tags** – otherwise, if `import_unidentified`: meta from existing tags + §4.4. method `tags`;
   if not `import_unidentified`: status `unidentified`, file left untouched.
Status `identified` is set for methods release/recording/deezer before placing; `tags` counts as
`unidentified` in the batch counters but is still placed (final status `imported`).
If no AcoustID key is configured, step 1/2 are skipped and the batch message says
`"Kein AcoustID-Schlüssel – Erkennung nur über vorhandene Tags"`.
MB/Deezer/AcoustID errors for one file must not stop the batch: fall through to the next method.

## 5. Placing files – `app/services/importer.py`
For each file with meta (all modes):
- `target = target_relpath(meta, ext, unique=False)`, `dest = music_dir / target`.
- **Quality**: `quality(tags) = 10_000 if codec in {flac, alac, ape, wavpack, wave, aiff} else (bitrate or 0)`.
- If `dest` exists and is not the source file itself:
  - new quality > existing quality → replace: the new file goes to `dest` (atomic `os.replace` from a
    temp file in the same directory), the existing Track row (by path) keeps its id and is re-read;
  - else → status `duplicate`, nothing is written (move mode: file stays in the import dir).
- **copy**: `shutil.copy2` to `dest.with_name(dest.name + ".part")`, `write_tags(..., clear_missing=True)` on
  the copy, `os.replace` to `dest`.
- **move**: `write_tags` on the source, then `shutil.move` to `dest`.
- **inplace** (cleanup): `write_tags` on the file, move to `dest` if different, `relocate_track(old, new)`.
- Covers: method `release` → `fetch_cover(meta)` embedded + `cover.jpg` in the target dir if missing;
  other methods: if the target dir has no cover image and the source dir has one (`tags.folder_cover`
  logic), copy it as `cover.<ext>`.
- After a group: `import_files(db, [targets…])`, store `track_id`, status `imported`.
- Move/inplace: remove directories left empty in the source tree (never the source root itself);
  directories containing only non-audio leftovers (`.DS_Store`, `Thumbs.db`, `desktop.ini`, `*.jpg`,
  `*.png`, `*.m3u`, `*.nfo`, `*.sfv`, `*.txt`, `*.cue`, `*.log`) count as empty in inplace mode only after
  all their audio files were moved and are then deleted with their leftovers.

## 6. Batch runner (`app/services/importer.py`)
- `async def start_batch(db, kind, user) -> ImportBatch`: only one batch with status queued/running at a
  time (else 409 `"Es läuft bereits ein Import"`). `import` → source `import_dir`, mode from config;
  `cleanup` → source `music_dir`, mode `inplace`. `import` with no audio files → 400
  `"Der Import-Ordner ist leer"`.
- Run as an asyncio task (like the scanner): walk the source with the scanner's `_walk` rules, insert
  `ImportFile` rows (`pending`), set `total`; process groups in sorted order: fingerprint all files of a
  group concurrently (§3.1), AcoustID lookups sequentially (rate limited), identify (§4), place (§5),
  commit, update counters, `processed`. Skip `.part` files.
- Resume: on app startup (lifespan, after the download manager) batches in `running`/`queued` continue
  with their `pending` files.
- `POST …/cancel`: sets a flag; the runner stops after the current group with status `cancelled`.
- Unexpected exception → status `failed`, message = error text (German prefix `"Import fehlgeschlagen: "`).
- Auto import: a background loop (started in lifespan when `download_workers > 0`, i.e. not in tests)
  checks every 300 s: `auto_import` and `import_mode == "move"` and no running batch and the import dir
  has audio files whose mtime is older than 120 s → `start_batch(kind="import", user=None)`.

## 7. API – new router `app/api/imports.py` (admin only, prefix `/api/admin/imports`)
- `GET /info` → `{import_dir: str, pending_files: int, acoustid_configured: bool, import_mode: str}`
  (`pending_files` = audio files currently in the import dir).
- `POST ""` body `{kind: "import" | "cleanup"}` → 201 `ImportBatchOut`.
- `GET ""` → `list[ImportBatchOut]` newest first, max 20.
- `GET /{id}` → `ImportBatchOut`; `GET /{id}/files?status=&offset=&limit=` → `Page[ImportFileOut]`
  ordered by path.
- `POST /{id}/cancel` → `ImportBatchOut` (409 `"Import läuft nicht"` if not queued/running).
Schemas (`app/schemas.py`):
```python
class ImportBatchOut(ORM): id, kind, mode, status, total, processed, identified, imported, duplicates,
    unidentified, failed, message, created_at, finished_at; progress: float (processed/total, 0 if total 0)
class ImportFileOut(ORM): id, path, status, method, acoustid_score, target, error;
    title, artist, album: str | None   # from meta
```
Register in `app/main.py`.

## 8. Tests (no network) – `tests/test_imports.py`
Monkeypatch `fingerprint`, `acoustid.lookup`, `mb.release_full`/`recording_basic`, Deezer search /
`resolve_track` with fixtures. Cover: `group_key` (CD1 folders); `candidates`; `choose_release`
(full album folder, partial album, promo compilation not in MB → None, single file with matching album
tag); `album_context` (compilation → Various Artists, files without album tag → singles, albumartist
majority); tagger round trip for `.ogg`, `.wav`, `.aiff`, `.ape`, `.wma` (create with ffmpeg; for `.ape`
and `.mpc`, if ffmpeg cannot encode them, create `.wv`/APEv2 test via mutagen on a copied file or skip
with `pytest.skip` and note it) plus `clear_missing`; import batch end-to-end in copy mode (originals
unchanged byte-for-byte, targets correct, tracks in library, counters); move mode (import dir emptied,
empty dirs removed); duplicate with lower and higher quality; cleanup in place keeps Track ids and
playlist entries while paths change; no-AcoustID-key path; API permissions (non-admin 403) and 409 on a
second batch. All existing tests stay green.

## 9. Report
Files, pytest tail, migration check, deviations (or "none").
