# Phase 7d – Import any Spotify playlist by link (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: same as `docs/specs/phase2a-backend.md` §0 for the backend (no git commands that modify
index/HEAD/working tree, German user-facing texts, existing style, `ruff format --line-length 120` on
new/rewritten files, tests without network – monkeypatch HTTP). Run backend tests against the database
`app_test` only (guards `startswith("app_test")`); the whole existing suite must still pass. App: all
user-visible texts via gen-l10n (keys in **both** `lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run
`~/flutter/bin/flutter gen-l10n`), `~/flutter/bin/flutter analyze` without issues,
`JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk --release` and
`~/flutter/bin/flutter build web --release --wasm` must succeed. Do not touch `docs/`, do not run the release
script, do not upload/deploy anything.

## Goal
Today the Spotify import only offers the user's own playlists and needs a connected Spotify account (OAuth, which
also needs a Spotify developer app configured by the admin). New: every user can paste links to **any public
Spotify playlist** (also Spotify's own editorial playlists like "Today's Top Hits"); the playlist is imported into
Resonance like the existing import (matching against the library, optionally requesting downloads for missing
songs, re-import updates the same Resonance playlist).

Sources for a link:
1. If the user has a connected Spotify account: the Web API (`playlists/{id}` for the name, then the existing
   `_fetch_tracks(..., f"playlists/{id}/items", "item", 100)` – full list with ISRCs).
2. Otherwise, or when the Web API answers 403/404 (Spotify blocks editorial playlists for third-party apps): the
   public embed page `https://open.spotify.com/embed/playlist/{id}` (no login). It contains
   `<script id="__NEXT_DATA__" type="application/json">…</script>`; the JSON has the playlist at
   `props.pageProps.state.data.entity` with `name`, `subtitle` (owner), `coverArt.sources[].url` and `trackList[]`
   items `{uri: "spotify:track:<id>", title, subtitle: "Artist A, Artist B", duration: <ms>, entityType}`.
   **The embed page contains at most 100 tracks.** No ISRCs (matching uses title/artist/duration, which
   `match`/`_deezer_id` already support).

## Backend

### 1. Link parsing (`app/services/spotify.py`)
`def playlist_id_from_link(link: str) -> str | None`: accepts `https://open.spotify.com/playlist/<id>`,
`https://open.spotify.com/intl-de/playlist/<id>` (any `intl-xx`), with or without query string (`?si=…`),
`open.spotify.com/playlist/<id>` without scheme, `spotify:playlist:<id>` and a bare 22-char id. `<id>` =
`[A-Za-z0-9]{22}`. Everything else → `None`.

### 2. Embed fetch (`app/services/spotify.py`)
`async def fetch_embed_playlist(id: str) -> tuple[dict, list[SpotifyTrack]]`: GET the embed page with a normal
browser `User-Agent` header (e.g. `Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko)
Chrome/140.0 Safari/537.36`), timeout 20 s, `follow_redirects=True`. Parse the `__NEXT_DATA__` JSON. Returns
metadata `{"id", "name", "owner": subtitle, "image_url": first coverArt source url or None}` and
`SpotifyTrack`s (`title`, `artist` = subtitle with ` ` replaced by a space and ", " kept, `album=None`,
`isrc=None`, `duration=ms/1000`, `added_at=None`, `position=index`) for entries with `entityType == "track"`
(skip others). 404 / missing JSON / missing entity → `SpotifyError(404, "Playlist nicht gefunden oder privat")`;
other HTTP errors / network errors → `SpotifyError(502, "Spotify nicht erreichbar")`. Use `_client_factory()`
so tests can monkeypatch it (like the existing code).

### 3. Model + migration
`SpotifyImport.links: JSONB list[str]`, `nullable=False`, `server_default '[]'`, python default `list`. One
Alembic migration after the current head.

### 4. API (`app/api/spotify.py`)
- `SpotifyImportIn` gets `links: list[str] = Field(default=[], max_length=50)`; `playlist_ids` gets a default
  `[]` and `liked` a default `False`, `download_missing` default `False`.
- `create_import`: "Nichts ausgewählt" if no liked, no ids and no links. Every link must parse
  (`playlist_id_from_link`), else `422` with `"Ungültiger Spotify-Link: <link>"`. Store the **parsed ids** in
  `links` (deduplicated, order kept). A connected account is required only if `liked` or `playlist_ids` are set
  (current `_account` check moves into that condition). Links do not need the Spotify developer app to be
  configured.
- `SpotifyImportOut` gets `links: list[str]`.
- `GET /api/spotify/status` unchanged.

### 5. Import (`run_import`)
- `account` may be `None` when only links are given (keep the 409 error when liked/playlist_ids need it).
- After the existing playlist loop, for each id in `batch.links`:
  - If an account exists: try `_get(db, account, client, f"playlists/{id}", fields="name,owner(display_name,id)")`
    for the name and the existing `_fetch_tracks` for the items. `SpotifyError` with status 403 or 404 → fall back
    to the embed page. Other errors propagate like now.
  - Without account: embed page.
  - Embed `SpotifyError` → `_message(batch, f"{id}: {e.message}")`, continue with the next link.
  - If the embed page was used and it returned exactly 100 tracks: `_message(batch, f"„{name}“: nur die ersten 100
    Songs übernommen (ohne verbundenes Spotify-Konto liefert Spotify nicht mehr)")`.
  - Then exactly the same playlist create/update logic as for `playlist_ids` (`SpotifyPlaylistLink` keyed by the
    Spotify id, description "Von Spotify importiert", re-import replaces entries and pending rows) and
    `process(tracks, name, playlist.id)`. Extract the shared part into a local helper instead of duplicating it.
- The Spotify developer app config (`cfg.spotify`) is not needed for link imports.

### 6. Tests (`tests/test_spotify.py`, extend)
- `playlist_id_from_link` table test (all accepted forms, rejects other hosts, album/track links, wrong length).
- Embed parsing from a small fixture HTML string (inline in the test) → metadata + tracks; skips non-track entries;
  404 and missing JSON → errors.
- Import with links and **no account**: playlist created with matched entries, missing songs requested when
  `download_missing`, re-import updates the same playlist, 100-track message.
- Import with account where the Web API returns 404 for the playlist → embed fallback used.
- API: invalid link → 422; links without account accepted; liked without account → 409.

## App

### 7. API
`ApiClient.spotifyImport(...)` (existing method that posts to `/api/spotify/imports`) gets an optional
`List<String> links = const []` parameter and sends `links`.

### 8. Spotify page (`lib/ui/pages/spotify_page.dart`)
- New widget `_LinkImport` shown in **every** state of the page above the existing content: when not
  configured (instead of only the `_Message`, show `_LinkImport` and below it the message), when not connected
  (above `_Connect`), and when connected (at the top of `_Picker`'s list, below the "connected as" tile).
  Use a `ListView` where needed so it scrolls.
- `_LinkImport`: heading "Playlist per Link importieren" / "Import a playlist by link"; muted hint "Füge Links zu
  öffentlichen Spotify-Playlists ein, einen pro Zeile. Ohne verbundenes Spotify-Konto werden höchstens 100 Songs
  pro Playlist übernommen." / "Paste links to public Spotify playlists, one per line. Without a connected Spotify
  account at most 100 songs per playlist are imported."; multi-line `TextField` (3–6 lines, hint
  "https://open.spotify.com/playlist/…"); `SwitchListTile` "Fehlende Songs herunterladen" (reuse the existing
  `spotifyDownloadMissing` / hint strings); `FilledButton.icon` "Importieren" / "Import" (`Icons.link`),
  disabled while busy, while an import is running, or when the field is empty. On press: split by whitespace,
  drop empty parts, call the API with `liked: false, playlistIds: [], links: …`; API errors → existing error
  snackbar helper; success → clear the field, `showInfo` "Import gestartet" / "Import started", invalidate the
  imports provider.
- The import history list (`_ImportTile`s) must also be visible when the account is not connected or Spotify is
  not configured (move it so it is shown below `_LinkImport` in all states; it already polls while running).

## Report
Changed/new files, backend test count, how you verified the app (analyze, builds), deviations.
