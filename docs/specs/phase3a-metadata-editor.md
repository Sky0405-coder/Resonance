# Phase 3a – Manual metadata correction for admins (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files. Where silent, choose the simplest option matching existing code. List any deviation
with a reason in the final report. Same general rules as `docs/specs/phase2a-backend.md` §0 (only
`backend/`, never `app/`/`docs/`, no git commands that modify index/HEAD/working tree, German
user-facing texts, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network – use `httpx.MockTransport` / monkeypatching like the existing tests). Run tests against the
database `app_test` only.

## Context
After the automatic import some songs are wrong or unidentified (e.g. title and artist swapped, no cover).
Admins fix them from the song's "…" menu in the client: search the catalog (existing Deezer search
`GET /api/catalog/search`), pick an AcoustID match, or edit the fields by hand; change album covers; map a
whole library album onto a catalog/MusicBrainz release. Likes, playlist entries and history must survive
(the `Track` row and its id are kept; only `path`/metadata change).

## 1. New module `app/services/retag.py`

### 1.1 `async def apply_meta(db, track: Track, meta: TrackMeta, cover: bytes | None) -> Track`
1. `source = music_dir / track.path`; missing file → `ValueError("Datei nicht gefunden")`.
2. `rel = target_relpath(meta, source.suffix, unique=False)`. If `rel != track.path` and
   `music_dir / rel` exists → `rel = target_relpath(meta, source.suffix, unique=True)`.
3. `temp = (music_dir / rel).with_name(f".{Path(rel).stem}.part{Path(rel).suffix}")` (same naming as the
   importer); `mkdir(parents=True, exist_ok=True)` for the parent; `shutil.copy2(source, temp)`;
   `write_tags(temp, meta, cover, clear_missing=True)`; `os.replace(temp, music_dir / rel)`; if `rel != track.path`
   `source.unlink()`. On any exception remove `temp` if it exists and re-raise. All file operations via
   `asyncio.to_thread`.
4. If `cover` is not None: write `cover.jpg` into the new directory (overwrite).
5. If the directory changed: `prune_dir(source.parent)` (§1.4).
6. `await relocate_track(db, old_rel, rel)` when the path changed; then `await import_file(db, rel)` and
   return the refreshed track (`db.refresh` / re-select with `album` and `artist` loaded).
7. `await cleanup_orphans(db)` (§1.5).

### 1.2 `def manual_meta(tags: TrackTags, patch: ManualMetaIn) -> TrackMeta`
Start from the file's tags exactly like `identify._tag_meta(tags, AlbumCtx(album=tags.album,
album_artist=tags.album_artist, year=tags.year, disc_total=tags.disc_total))`, then apply every non-`None`
field of the patch (`title, artist, album, album_artist, year, track_no, disc_no, genre`). Identifier
clearing (compare casefolded, stripped values with the original tags):
- `title` or `artist` changed → `mb_recording_id = None`, `isrc = None`
- `artist` changed → `artist_mbid = None`
- `album` or `album_artist` changed → `mb_release_id = None`, `mb_release_group_id = None`, `label = None`,
  `track_total = None`
- `album_artist` changed → `album_artist_mbid = None`
- `year` changed → `date = str(year)`.
Empty strings for `title/artist/album/album_artist` → 422 (pydantic `min_length=1`); `album_artist`
defaults to `artist` when the file has no album artist tag.

### 1.3 `def replace_cover(path: Path, cover: bytes) -> None`
Replace the embedded front cover only (no other tag changes): MP3/ID3 → delete all `APIC` frames, add
`APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=cover)`; FLAC → `clear_pictures()` +
add `Picture` type 3; Ogg Vorbis/Opus → replace `metadata_block_picture`; MP4 → `covr`; ASF and APEv2 →
same keys `write_tags` uses. Reuse the code paths of `write_tags` (extract small helpers in `tagger.py`
if needed; `write_tags` behaviour must stay identical). Call `_strip_ogg_id3v1` first like `write_tags`.
Cover bytes are always normalised to JPEG first (§3.4).

### 1.4 `def prune_dir(directory: Path) -> None`
Walk upwards from `directory` while it is inside `music_dir` (never `music_dir` itself): if it contains no
files other than `cover.jpg`/`cover.png`/`folder.jpg`/`folder.png` and no subdirectories, delete those
files and the directory, continue with the parent; otherwise stop.

### 1.5 `async def cleanup_orphans(db)`
Take the two `delete(...)` statements for albums/artists without tracks from `scanner.run_scan` into this
function (inside `library_lock`), call it from `run_scan` instead of the inline code and from §1.1/§2.4.
Commit.

## 2. API – new router `app/api/editor.py`, prefix `/api/admin/library`, all endpoints `AdminUser`

### 2.1 `GET /tracks/{id}/file` → `TrackFileOut`
```python
class TrackFileOut(BaseModel):
    path: str
    title: str | None; artist: str | None; album: str | None; album_artist: str | None
    year: int | None; track_no: int | None; disc_no: int | None; genre: str | None
    duration: float; codec: str | None; bitrate: int | None
    mb_recording_id: str | None; mb_release_id: str | None
    query: str          # suggested catalog search: f"{artist} {title}" from the tags (artist omitted if None)
```
Values come from `read_tags` on the file (not from the DB). Unknown track → 404; unreadable file → 409
`"Audiodatei nicht lesbar"`.

### 2.2 `GET /tracks/{id}/fingerprint` → `list[FingerprintMatchOut]`
No AcoustID key → 409 `"Kein AcoustID-Schlüssel eingetragen"`. `fingerprint(file)` → `acoustid.lookup` →
`identify.candidates(...)`. Group candidates by `recording_id`, keep at most 10 recordings ordered by best
score desc. For each recording: `title` = candidate title, `artist` from the AcoustID result
(`recordings[].artists` joined with the `joinphrase`s like `identify`/`acoustid` already parse – add the
artist string to `Candidate` as `artist: str | None = None` if not present), and its releases.
```python
class FingerprintReleaseOut(BaseModel):
    release_id: str; album: str | None; year: int | None
    disc_no: int | None; track_no: int | None; release_tracks: int | None
class FingerprintMatchOut(BaseModel):
    recording_id: str; title: str | None; artist: str | None; score: float
    releases: list[FingerprintReleaseOut]   # max 15, order: year asc (None last), album
```
AcoustID / fingerprint errors → 502 `"AcoustID nicht erreichbar"`; no fingerprint → empty list.

### 2.3 `POST /tracks/{id}/match` body `TrackMatchIn` → `TrackOut`
```python
class ManualMetaIn(BaseModel):
    title: str | None = Field(None, min_length=1, max_length=512)
    artist: str | None = Field(None, min_length=1, max_length=512)
    album: str | None = Field(None, min_length=1, max_length=512)
    album_artist: str | None = Field(None, min_length=1, max_length=512)
    year: int | None = Field(None, ge=1000, le=2100)
    track_no: int | None = Field(None, ge=1, le=999)
    disc_no: int | None = Field(None, ge=1, le=99)
    genre: str | None = Field(None, max_length=256)

class TrackMatchIn(BaseModel):
    source: Literal["deezer", "musicbrainz", "manual"]
    deezer_id: str | None = None        # source == "deezer": Deezer track id
    recording_id: str | None = None     # source == "musicbrainz"
    release_id: str | None = None       # source == "musicbrainz", optional
    meta: ManualMetaIn | None = None    # source == "manual"
```
Missing required field for the chosen source → 422 `"Unvollständige Angaben"`.
- `deezer`: `meta = await resolve_track(deezer_id)`; `cover = await fetch_cover(meta)`.
- `musicbrainz` with `release_id`: `mb.track_meta_list(mb.release_full(release_id))`, pick the entry with
  `mb_recording_id == recording_id` (several → the one matching the file's `disc_no/track_no`, else the
  first); none → 422 `"Song nicht auf dieser Veröffentlichung"`. Without `release_id`:
  `mb.recording_meta(recording_id)`. `cover = await fetch_cover(meta)`.
- `manual`: `meta = manual_meta(read_tags(file), body.meta)`; `cover = None` (the existing embedded cover is
  kept because `write_tags` only touches pictures when a cover is given – verify, and keep it that way).
- Upstream `NotFound` → 404 `"Nicht gefunden"`, other `DeezerError`/`MusicBrainzError` → 502 with the
  existing German messages. Then `apply_meta(...)`.

### 2.4 `POST /albums/{id}/match` body `AlbumMatchIn` → `AlbumMatchOut`
```python
class AlbumMatchIn(BaseModel):
    source: Literal["deezer", "musicbrainz"]
    id: str                       # Deezer album id or MusicBrainz release id
class AlbumMatchOut(BaseModel):
    album: AlbumOut | None        # the library album the tracks ended up in (None if nothing matched)
    matched: int
    unmatched: list[TrackOut]     # left unchanged
```
Release metas: `deezer` → `resolve_album(id)[1]`; `musicbrainz` → `track_meta_list(release_full(id))`.
Assignment (pure function `assign_tracks(tracks: list[tuple[uuid, TrackTags]], metas) -> dict[uuid, TrackMeta]`
in `retag.py`, each meta used at most once, greedy by best score):
`title_ratio = fuzz.token_set_ratio(norm(tags.title), norm(meta.title))`;
`position_ok = (tags.disc_no or 1, tags.track_no) == (meta.disc_no or 1, meta.track_no)`;
`duration_ok = meta.duration is None or abs(tags.duration - meta.duration) <= 5`.
A pair is valid if `duration_ok and (title_ratio >= 80 or (position_ok and title_ratio >= 40))`.
Score `= title_ratio + (25 if position_ok else 0) - abs(duration diff)`. Fetch the cover once
(`fetch_cover(metas[0])`), then `apply_meta` per matched track (one by one, same transaction rules as
§1.1). Unknown album → 404. `album` = the album of the first matched track after re-import.

### 2.5 Covers
- `GET /albums/{id}/cover-options` → `list[CoverOptionOut]` with `{url: str, source: "musicbrainz"|"deezer",
  label: str}`, max 12, no downloads, just URLs:
  1. if any track of the album has `mb_release_id` (from the DB `Album.mb_release_id`):
     `https://coverartarchive.org/release/{id}/front-500`, label `"MusicBrainz"`;
  2. Deezer `search_albums(f"{album.artist.name} {album.title}", 10)` → `cover_xl` with label
     `f"{title} – {artist}"` (skip entries without `cover_xl`).
  Deezer errors → only the MusicBrainz option (no error).
- `POST /albums/{id}/cover` – either JSON `{"url": str}` or multipart field `file` (max 10 MB → 413
  `"Bild zu groß"`). URL host must end with `coverartarchive.org`, `archive.org` or `dzcdn.net`, scheme
  https, else 422 `"Bildquelle nicht erlaubt"`; download with `follow_redirects=True`, timeout 20 s; redirects
  must stay on those hosts. Bytes → `covers.store(data)`; `None` → 422 `"Kein gültiges Bild"`. Read the
  stored normalised JPEG and: write `cover.jpg` into every directory containing tracks of the album
  (overwrite, delete `cover.png`/`folder.jpg`/`folder.png` there), `replace_cover` on every track file of the
  album (update `Track.mtime`/`size` from `stat` afterwards so the next scan does not re-read them),
  `album.cover_file = stored name`; commit. Response: `AlbumOut` (with `has_cover=True`).

### 2.6 `GET /review` → `Page[ReviewTrackOut]`
Query `kind: Literal["unidentified", "no_cover"] = "unidentified"`, `offset`, `limit` (default 50, max 200).
- `unidentified`: tracks with `mb_recording_id IS NULL`, order artist name, album title, disc, track.
- `no_cover`: one row per album with `cover_file IS NULL` (use the album's first track by disc/track).
```python
class ReviewTrackOut(TrackOut):
    path: str
```
`total` is the full count for the kind.

## 3. Details
1. Register the router in `app/main.py`.
2. All library mutations run under `library_lock` exactly like the existing import code (do not hold the lock
   across network calls).
3. `TrackOut` responses must load `album` and `artist` (use the same query options as `library.py`).
4. Cover normalisation: `covers.store(bytes)` returns the cache name; the JPEG written to files/folders is
   `cover_cache_dir / name` bytes.
5. Everything German in user-facing `detail` messages; log internals in English.

## 4. Tests (`tests/test_editor.py`, no network)
- `manual_meta`: swapped title/artist fixed, identifier clearing rules, album_artist default.
- `/match` manual: file renamed to the new `Artist/Album (Year)/NN - Title.ext`, old directory pruned
  (including a leftover `cover.jpg`), track id unchanged, a like and a playlist entry still point to it,
  empty old album/artist removed, embedded cover preserved.
- `/match` deezer and musicbrainz (mock `resolve_track`, `mb.release_full`, `fetch_cover`): tags written incl.
  MBIDs, cover.jpg written; recording not on release → 422.
- Target collision → `(2)` suffix, no overwrite.
- `/albums/{id}/match`: 3 library tracks vs. 4 metas, one track with swapped position but matching title,
  one track that matches nothing → `matched=2`, `unmatched` has 1; `assign_tracks` unit tests.
- `/albums/{id}/cover`: URL allow-list (disallowed host → 422, redirect to disallowed host → 422), upload
  path, `replace_cover` on MP3, FLAC, Ogg and M4A keeps title/artist tags unchanged and changes the picture,
  `cover.jpg` written, `has_cover` true.
- `/cover-options` with mocked Deezer.
- `/fingerprint`: no key → 409; mocked `fingerprint` + `acoustid.lookup` → grouped output.
- `/review` both kinds incl. `total`.
- Non-admin → 403 on every endpoint. All existing tests stay green.

## 5. Report
Files, pytest tail, deviations (or "none").
