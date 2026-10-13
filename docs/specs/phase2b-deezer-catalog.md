# Phase 2b – Deezer catalog, MusicBrainz resolution, finer scan lock (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files. Where silent, choose the simplest option matching existing code. List any deviation
with a reason in the final report.

Same rules as phase 2a (`docs/specs/phase2a-backend.md` §0): only `backend/`, never `app/` or `docs/`,
no git commands that modify index/HEAD/working tree, German user-facing messages, existing style,
tests without network. Keep all current uncommitted changes (several files were edited after your
previous task, e.g. `musicbrainz.py` artist-credit choice in `track_meta_list` and chunked deletes in
`scanner.py`).

## Why
MusicBrainz free-text search has no popularity ranking ("get lucky" returns covers and remixes first).
Search/browse moves to the public Deezer API (no key). MusicBrainz stays the source of canonical tags:
a Deezer track is resolved via its ISRC, a Deezer album via its UPC barcode. If MusicBrainz has no
match, tags are built from Deezer data.

## 1. Deezer client – new file `app/services/deezer.py`

- Module singleton `deezer = DeezerClient()`; `httpx.AsyncClient(base_url="https://api.deezer.com/", timeout=15)`
  created lazily.
- Rate limit: `asyncio.Lock`, ≥ 0.1 s between request starts.
- Deezer returns HTTP 200 with `{"error": {"code": …, "message": …}}` on errors:
  code 800 → raise `NotFound` (own class in this module); code 4 (quota) → sleep 1 s and retry, at most
  3 retries, then `DeezerError`; any other error object, HTTP error or network error → `DeezerError(str)`.
- TTL cache identical to the MusicBrainz client (3600 s, 2000 entries).
- Methods returning raw JSON dicts/lists:
  `search_tracks(q, limit)` → `search/track?q=&limit=`, `search_albums` → `search/album`,
  `search_artists` → `search/artist` (return `data` list);
  `track(id)` → `track/{id}`; `album(id)` → `album/{id}`; `album_tracks(id)` → `album/{id}/tracks?limit=500`
  (`data`); `artist(id)` → `artist/{id}`; `artist_top(id, limit=10)` → `artist/{id}/top?limit=` (`data`);
  `artist_albums(id)` → `artist/{id}/albums?limit=100` (`data`).

Relevant Deezer fields (verified):
- search track / top track: `id, title, duration, rank, preview, artist{id,name}, album{id,title,cover_medium,cover_big,cover_xl}`
  (top tracks additionally `contributors`).
- `track/{id}`: additionally `isrc, track_position, disk_number, release_date, contributors[{id,name,role}]`.
- `album/{id}`: `id, title, upc, label, nb_tracks, release_date, record_type (album|ep|single|compile),
  genres{data[{name}]}, artist{id,name}, cover_medium, cover_big, cover_xl`.
- `album/{id}/tracks`: `id, title, duration, isrc, track_position, disk_number, preview, artist{id,name}`.
- `artist/{id}`: `id, name, picture_medium, picture_big, nb_album, nb_fan`.
- `artist/{id}/albums`: `id, title, release_date, record_type, fans, cover_medium, cover_big`.

## 2. Catalog schemas (replace the phase-2a catalog schemas in `app/schemas.py`)

All catalog ids are Deezer ids **as strings**.
```python
class CatalogArtist(BaseModel):
    id: str; name: str
    picture_url: str | None          # picture_medium
    library_id: uuid.UUID | None

class CatalogAlbum(BaseModel):
    id: str; title: str; artist: str; artist_id: str | None
    record_type: str | None          # album | ep | single | compile
    year: int | None                 # from release_date
    cover_url: str | None            # cover_medium
    cover_big_url: str | None        # cover_big
    library_id: uuid.UUID | None

class CatalogTrack(BaseModel):
    id: str; title: str
    artist: str                      # see §2.1
    artist_id: str | None
    album: str | None; album_id: str | None
    cover_url: str | None            # album.cover_medium (album pages: the album's cover_medium)
    duration: float | None
    isrc: str | None
    preview_url: str | None          # Deezer 30 s MP3 preview
    disc_no: int | None; track_no: int | None   # only on album pages
    library_id: uuid.UUID | None

class CatalogArtistDetail(BaseModel):
    artist: CatalogArtist
    top_tracks: list[CatalogTrack]
    albums: list[CatalogAlbum]

class CatalogAlbumDetail(CatalogAlbum):
    label: str | None
    genres: list[str]
    tracks: list[CatalogTrack]

class CatalogSearchOut(BaseModel):
    artists: list[CatalogArtist]; albums: list[CatalogAlbum]; tracks: list[CatalogTrack]
```
### 2.1 Artist string
If `contributors` is present: names of contributors with role "Main" in order; first name, then
`" feat. "` + remaining names joined with `", "` and the last two joined with `" & "`
(e.g. "Daft Punk feat. Pharrell Williams & Nile Rodgers"). Otherwise `artist.name`.

### 2.2 Artist detail
`artist`, `top_tracks` (`artist_top(id, 10)`), `albums` from `artist_albums`: drop `record_type == "compile"`;
deduplicate by casefolded title keeping the item with the highest `fans`; sort by `release_date` desc,
then title. Requests to Deezer may run concurrently (`asyncio.gather`).

## 3. Catalog API (`app/api/catalog.py`, replace the MusicBrainz-based implementation)
- `GET /api/catalog/search?q=&types=artist,album,track&limit=10` (q 1–200, limit 1–25): the requested
  Deezer searches concurrently → `CatalogSearchOut`.
- `GET /api/catalog/artists/{id}` → `CatalogArtistDetail`; `GET /api/catalog/albums/{id}` →
  `CatalogAlbumDetail` (`album` + `album_tracks`; `disc_no`=`disk_number`, `track_no`=`track_position`).
- `{id}` must be digits only (≤ 20 chars) else 422.
- Deezer `NotFound` → 404 `"Nicht im Katalog gefunden"`; `DeezerError` → 502 `"Katalog nicht erreichbar"`.
- Library matching (§4) on every response.

## 4. Matching (`app/services/matching.py`)
- `match_tracks`: first `Track.isrc == isrc` (if the catalog track has an ISRC), then the existing
  name-based rules. Add `isrc: str | None = None` handling; keep one query per helper where practical
  (two queries – ISRC and names – are acceptable).
- Artists and albums: existing name-key rules (MB-id rules are dropped for catalog entities).

## 5. TrackMeta changes (`app/services/musicbrainz.py`)
- `mb_recording_id`, `mb_release_id`, `mb_release_group_id` become `str | None`.
- New fields: `cover_url: str | None = None` (Deezer `cover_xl`), `deezer_track_id: str | None = None`,
  `deezer_album_id: str | None = None`.
- `tagger.write_tags` skips tags whose value is None (already true for other fields – make sure).
- `fetch_cover(meta)`: if `mb_release_id` → CAA as before (cache `caa/{mb_release_id}.jpg`); if that
  yields nothing and `meta.cover_url` → download it (cache `caa/dz-{deezer_album_id}.jpg`).
- Remove now unused MusicBrainz code: `search_artists`, `search_albums`, `search_tracks`, `artist`,
  `album` and the MB catalog schemas. Keep `release_full`, `track_meta_list`, `recording_meta`, release choice.
- `recording_meta(mbid, prefer_album: str | None = None)`: when `prefer_album` is given, releases whose
  `name_key(title) == name_key(prefer_album)` sort before all others (prepend `0/1` to the §6.4 tuple).
- New `isrc_recordings(isrc) -> list[dict]`: `GET isrc/{isrc}` → `recordings` (empty list on 404).
- New `release_by_barcode(barcode, track_count) -> str | None`: `GET release?query=barcode:{barcode}&limit=5`;
  return the id of the first release whose `track-count` (sum over `media[].track-count`, or top-level
  `track-count`) equals `track_count`, else None.

## 6. Resolution – new file `app/services/resolve.py`
```python
async def resolve_track(deezer_id: str) -> TrackMeta
async def resolve_album(deezer_id: str) -> tuple[dict, list[TrackMeta]]   # (deezer album json, metas)
def meta_from_deezer(track: dict, album: dict, disc_total: int, track_total: int | None) -> TrackMeta
```
- `resolve_track`: `t = deezer.track(id)`, `a = deezer.album(t.album.id)`. If `t.isrc`:
  `recs = mb.isrc_recordings(isrc)`; choose the recording with the smallest `|length/1000 − t.duration|`
  (recordings without length last); `meta = mb.recording_meta(rec_id, prefer_album=a.title)`.
  Any MB `NotFound`/`MusicBrainzError` or no recordings → `meta_from_deezer(t, a, …)` (disc_total =
  1, track_total = `a.nb_tracks`). Always set `deezer_track_id`, `deezer_album_id`, `cover_url`
  (`a.cover_xl`) on the result; if MB gave no ISRC, use Deezer's.
- `resolve_album`: `a = deezer.album(id)`, `tracks = deezer.album_tracks(id)`. If `a.upc`: try barcodes
  `[upc, upc.lstrip("0"), "0" + upc]` (deduplicated, in that order) with `mb.release_by_barcode(b, len(tracks))`;
  first hit → `mb.track_meta_list(mb.release_full(release_id))`. If metas count == len(tracks), pair them
  by position and set `deezer_track_id`/`deezer_album_id`/`cover_url` on each. Otherwise (no UPC, no
  hit, count mismatch, MB errors) → `meta_from_deezer` for every Deezer track with
  `disc_total = max(disk_number)`, `track_total = number of tracks with the same disk_number`.
- `meta_from_deezer`: title = track `title`; artist = §2.1 string; artist_mbid None; album = album
  `title`; album_artist = album `artist.name`; track_no = `track_position`; disc_no = `disk_number`;
  year/date from album `release_date`; duration; isrc; genre = first album genre name; label; MB ids None;
  `deezer_*` ids, `cover_url = album.cover_xl`.

## 7. Requests
- Model `DownloadRequest`: add `catalog_id: String(32)`, nullable, indexed (Deezer id);
  `mb_id` becomes nullable. New alembic revision (autogenerate, review, up/down/up test).
- `RequestIn`: `kind: Literal["track","album"]`, `id: str` (digits, ≤ 20 chars), `temporary: bool = False`.
- `create_request(db, user, kind, catalog_id, temporary)`: duplicates by (user, kind, catalog_id) in
  `pending_approval|active`; metadata via `resolve_track` / `resolve_album`; Deezer `NotFound` → 404
  `"Nicht im Katalog gefunden"`, `DeezerError` → 502 `"Katalog nicht erreichbar"` (MB errors no longer
  surface – resolution falls back). `title`/`artist`/`cover_url`: from Deezer (track: title, §2.1 artist,
  album `cover_medium`; album: title, `artist.name`, `cover_medium`). `mb_id` = resolved recording id
  (track) or release-group id of the first meta (album), else None; `mb_release_id` likewise.
  Matching for "exists" uses `match_tracks` with the ISRC (§4). Everything else (limits, approval,
  statuses) unchanged.
- `DownloadRequestOut` gets `catalog_id: str | None`.

## 8. Scanner lock granularity (`app/services/scanner.py`)
`run_scan` must not hold `library_lock` for the whole scan (downloads waited minutes). Hold it around
each batch (the upserts of one `BATCH` plus its commit) and around the final delete phase plus commit.
Before each batch, re-load the syncer caches only if an import happened in between – simplest correct
way: track a module-level counter `_imports` incremented by `import_file`; if it changed since the last
batch, call `syncer.load()` again.

## 9. Tests (no network)
Replace the MB-catalog fixtures/tests with Deezer fixtures in `tests/fixtures/` (search track/album/artist,
`track`, `album`, `album_tracks`, `artist`, `artist_top`, `artist_albums`) and MB fixtures for
`isrc_recordings` and `release_by_barcode`. Cover: §2.1 artist string; artist detail dedupe/sort/compile
filter; catalog search + library_id via ISRC; `resolve_track` with MB match and with fallback;
`resolve_album` via barcode match and via Deezer fallback (multi-disc track_total/disc_total);
album request end-to-end with `process_one()` still producing correct paths/tags (fallback case: no MB
ids written); duplicate detection by catalog_id; scan + concurrent `import_file` (a batch boundary
must allow an import in between – test with `BATCH` monkeypatched small). All tests green.

## 10. Report
Files changed/created, pytest tail, migration check, deviations (or "none").
