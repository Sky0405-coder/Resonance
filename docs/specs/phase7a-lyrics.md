# Phase 7a – Lyrics (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: same as `docs/specs/phase2a-backend.md` §0 for the backend (no git commands that modify
index/HEAD/working tree, German user-facing texts, existing style, `ruff format --line-length 120` on
new/rewritten files, tests without network – monkeypatch the HTTP call). Run backend tests against the database
`app_test` only (guards `startswith("app_test")`); the whole existing suite must still pass. App: all
user-visible texts via gen-l10n (keys in **both** `lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run
`~/flutter/bin/flutter gen-l10n`), `~/flutter/bin/flutter analyze` without issues,
`~/flutter/bin/flutter build apk --release` and `~/flutter/bin/flutter build web --release --wasm` must
succeed. Do not touch `docs/`, do not run the release script, do not upload/deploy anything.

## Goal
Like Spotify: the full player shows the song's lyrics; synced lyrics (LRC) highlight and follow the current
line, tapping a line seeks there. Sources in this order: sidecar `.lrc` file next to the audio file, lyrics
embedded in the audio tags, the free online database LRCLIB (https://lrclib.net, no API key).

## Backend

### 1. Config (`app/services/server_config.py`, `LibraryConfig`)
```
# Look up lyrics on lrclib.net when a song has no local lyrics.
lyrics_online: bool = True
```

### 2. Model + migration
New model `TrackLyrics` (in the module where `Track` lives), one Alembic migration after the current head:
```
__tablename__ = "track_lyrics"
track_id: uuid pk, FK tracks.id ondelete CASCADE
synced: Text | None      # LRC text with [mm:ss.xx] timestamps
plain: Text | None       # plain text
instrumental: bool = False
source: String(16)       # "lrclib" | "none"
fetched_at: DateTime(tz), server_default now()
```
Only **online** results are cached here (local sources are read on every request – they are cheap and may
change). `source="none"` = LRCLIB had nothing; such rows are retried after 30 days. Rows with lyrics never expire.

### 3. Service `app/services/lyrics.py` (new)
- `def parse_lrc(text: str) -> list[tuple[int | None, str]]`: lines `[mm:ss]`, `[mm:ss.x]`, `[mm:ss.xx]`,
  `[mm:ss.xxx]` (also `[m:ss…]`, several timestamps before one text → one entry per timestamp) → `(ms, text)`;
  metadata tags like `[ar:…]`, `[ti:…]`, `[al:…]`, `[by:…]`, `[length:…]`, `[offset:±ms]` are dropped, but `offset`
  is applied (LRC semantics: positive offset = lyrics earlier, i.e. `ms - offset`, min 0). If at least one timed line
  exists, untimed lines are dropped and the result is sorted by time (stable); otherwise every line (empty lines
  kept as `""`, leading/trailing empty lines stripped) is returned with `None`.
  Strip trailing `\r`/whitespace of texts; enhanced word timestamps `<mm:ss.xx>` inside the text are removed.
- `def local_lyrics(path: Path) -> str | None`: (1) sidecar `path.with_suffix(".lrc")` if it is a file (read as
  UTF-8, `errors="replace"`, BOM stripped); else (2) embedded: mutagen – ID3 `USLT` frames (first non-empty text) and
  `SYLT` ignored; Vorbis/FLAC/Opus comments `LYRICS`, then `UNSYNCEDLYRICS`, then `SYNCEDLYRICS` (case-insensitive
  keys); MP4 `©lyr`. Returns the raw text or `None`. All exceptions → `None`.
- `async def lrclib_lookup(artist: str, title: str, album: str, duration: float) -> dict | None`:
  `GET https://lrclib.net/api/get` with params `artist_name`, `track_name`, `album_name`, `duration` (rounded int),
  header `User-Agent: Resonance/<VERSION> (https://github.com/Sky0405-coder/Resonance)` (`VERSION` as used in
  `musicbrainz.py`), timeout 10 s. 200 → the JSON; 404 → then once `GET https://lrclib.net/api/search` with
  `artist_name` + `track_name` and take the first result whose `duration` differs ≤ 3 s from ours (else `None`).
  Network errors / other statuses raise `LyricsError` (new exception class in this module; then nothing is cached).
  Use a module-level `httpx.AsyncClient` created lazily (like `deezer.py`) and an `asyncio.Semaphore(4)`.
- `async def get_lyrics(db, track) -> LyricsOut`:
  1. `local_lyrics(music_dir / track.path)` (in a thread) → if found: `source="file"` if the sidecar exists else
     `"embedded"`.
  2. Else cached `TrackLyrics` row (respecting the 30-day retry for `"none"`).
  3. Else if `cfg.library.lyrics_online`: LRCLIB lookup with `primary_artist(track.artist_credit)`, `track.title`,
     album title, `track.duration`; store a row (`synced=syncedLyrics`, `plain=plainLyrics`,
     `instrumental=instrumental`, `source="lrclib"` if any of them is set/true else `"none"`); commit. On
     `LyricsError` return "not found" without caching.
  4. Result: synced text if present (parsed), else plain (parsed → untimed lines).

### 4. API (`app/api/library.py`)
`GET /api/tracks/{track_id}/lyrics` → `LyricsOut` (any logged-in user; unknown track → 404 like the other track
endpoints):
```
class LyricLine(BaseModel): time_ms: int | None; text: str
class LyricsOut(BaseModel):
    synced: bool          # True if all lines have time_ms
    instrumental: bool
    source: str | None    # "file" | "embedded" | "lrclib" | None (nothing found)
    lines: list[LyricLine]
```
Nothing found → `200` with `lines=[]`, `source=None`. Response header `Cache-Control: private, max-age=3600`.

### 5. Sidecar files follow the audio file
- Importer `_place` (`app/services/importer.py`): if `source.with_suffix(".lrc")` exists, put it next to the
  target as `dest.with_suffix(".lrc")` – copy in `copy` mode, move otherwise (overwrite an existing one only if the
  audio file was imported/replaced, i.e. not for duplicates). Do the same for `.LRC` (case-insensitive suffix match
  in the same directory, same stem).
- Download post-processing (`app/services/downloads.py`, where downloaded files are moved into the library): same
  rule if a sidecar exists.
- Metadata editor relocation (`app/services/retag.py` `apply_meta`): when the path changes, move an existing
  sidecar `.lrc` along.
- Deletion (`app/services/deletion.py`): delete the sidecar `.lrc` of deleted tracks.
- The scanner ignores `.lrc` files (already the case: not an audio extension).

### 6. Tests (`tests/test_lyrics.py`)
- `parse_lrc`: formats, multiple timestamps, metadata + offset, enhanced word timestamps, plain text.
- `local_lyrics`: sidecar wins over embedded; embedded FLAC `LYRICS` and MP3 `USLT` (create small files with the
  helpers the existing tests use to create audio files).
- API: local file → `source="file"`, no HTTP call; LRCLIB monkeypatched: hit is cached (second call without HTTP),
  404 + search fallback with duration tolerance, `"none"` cached and retried after 30 days, `LyricsError` not
  cached, `lyrics_online=False` → no call.
- Importer moves the sidecar; deletion removes it.

## App

### 7. API + model
`ApiClient.lyrics(String trackId) → Future<Lyrics>`; model `Lyrics {bool synced, bool instrumental, String? source,
List<LyricLine> lines}`, `LyricLine {int? timeMs, String text}` with `fromJson`/`toJson`.
`lyricsProvider = FutureProvider.family<Lyrics, String>` (track id) in `lib/core/library.dart` (keep alive is
fine; it's small). Offline: when the offline store has lyrics for the track (§10) use them first, without a request.

### 8. Full player (`now_playing_page.dart`, music only – not for audiobooks)
- In the bottom row (next to sleep timer and queue) add an `IconButton` `Icons.lyrics_outlined`, tooltip
  "Songtext" / "Lyrics", opening the lyrics page (§9).
- Below the player controls the page becomes scrollable (keep the current layout for the first screen: wrap in
  a `CustomScrollView`/`ListView` where the first child has the height of the viewport) and, if the track has
  lyrics, shows a **lyrics card** like Spotify: rounded (12) container in a darker variant of the accent color
  (`Color.alphaBlend(Colors.black.withValues(alpha: 0.55), accent)`), heading "Songtext" / "Lyrics" and a button
  "Vollbild" / "Expand" opening §9, and up to 8 lines: for synced lyrics the current line and the following 7
  (current line white, others white 55 %), for plain lyrics the first 8 lines. Tapping the card opens §9. No card
  while loading, on error or without lines.

### 9. Lyrics page (`lib/ui/pages/lyrics_page.dart`, new; top-level route `/lyrics` like `/queue`)
- Background: the same darkened accent as the card, full screen; top bar with a down-arrow close button, title
  and artist of the current track (follows track changes).
- Synced: `ListView` of the lines (font size 26, weight w800, line spacing 1.3, padding 24 horizontal, 14 between
  lines). Current line = last line with `timeMs <= position`; it and previous lines white, upcoming lines white 50 %.
  Auto-scrolls so that the current line sits at ~35 % of the viewport height, animated (300 ms, easeOut); when the
  user scrolls manually, auto-scroll pauses for 4 s. Tapping a line seeks to its `timeMs` (and resumes playback if
  paused). Empty-text lines are shown as "♪".
- Plain: same style, all lines white, no highlighting/auto-scroll, a small muted hint at the top "Diese Songtexte
  sind nicht synchronisiert." / "These lyrics aren't synced.".
- Instrumental: centered "Instrumental"; nothing found: centered "Für diesen Song gibt es keinen Songtext." /
  "No lyrics available for this song."; loading: spinner; error: the existing error widget with retry.
- Bottom: small `SeekBar` and play/pause button (reuse existing widgets).
- Footer below the last line, muted, small: "Songtext von LRCLIB" / "Lyrics from LRCLIB" when `source=="lrclib"`.
- Position: use the existing `positionProvider`.

### 10. Offline (`lib/offline/offline_store.dart`)
When a track file has been downloaded, also fetch `api.lyrics(id)` and store it as `lyrics/<trackId>.json`
(ignore errors; tracks without lines are stored too, so they show "no lyrics" offline). Delete it together with
the track file and in `clearAll()`. Expose `Lyrics? lyrics(String trackId)` (read synchronously from an in-memory
map loaded with the index, or async – your choice, but `lyricsProvider` must use it first).

### 11. Admin page
In the library/import settings group add a `SwitchListTile` "Songtexte online suchen (LRCLIB)" / "Look up lyrics
online (LRCLIB)" with subtitle "Für Songs ohne eigene Songtexte werden synchronisierte Texte von lrclib.net
geladen." / "Songs without their own lyrics get synced lyrics from lrclib.net.", bound to `library.lyrics_online`.

## Report
Changed/new files, backend test count, how you verified the app (analyze, builds), deviations.
