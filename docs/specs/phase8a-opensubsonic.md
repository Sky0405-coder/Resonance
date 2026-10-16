# Phase 8a – OpenSubsonic API (backend + small app part)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: same as `docs/specs/phase2a-backend.md` §0 for the backend (no git commands that modify
index/HEAD/working tree, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network). Run backend tests against the database given in the task prompt only (guards `startswith("app_test")`);
the whole existing suite must still pass. App: all user-visible texts via gen-l10n (keys in **both**
`lib/l10n/app_de.arb` (template) and `lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`),
`~/flutter/bin/flutter analyze` without issues, `JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk
--release` and `~/flutter/bin/flutter build web --release --wasm` must succeed. Do not touch `docs/`, do not run
the release script, do not upload/deploy anything.

## Goal
Third-party music apps (Symfonium, Feishin, Substreamer, DSub, Tempo, play:Sub, Amperfy…) can use Resonance as a
Subsonic server: browse the library, stream, cover art, playlists, favourites (= likes), scrobble (= play
history), lyrics. Reference: Subsonic API 1.16.1 (http://www.subsonic.org/pages/api.jsp) plus OpenSubsonic
(https://opensubsonic.netlify.app/docs/). Responses as XML (default) **and** JSON (`f=json`).

## 1. Credentials
Subsonic clients authenticate with `md5(password + salt)`, which needs a password the server can read. Resonance only
stores argon2 hashes, so every user gets a separate **app password** for Subsonic apps.
- `User.subsonic_password: String(64) | None` (+ Alembic migration after the current head). Stored as plain
  text (it is a generated random secret only valid for the Subsonic API; document this in a code comment).
- `POST /api/me/subsonic-password` → generates `secrets.token_urlsafe(18)` (24 chars), stores it, returns
  `{"password": "…"}` (shown once in the app; generating again replaces it).
  `DELETE /api/me/subsonic-password` (204) → sets it to `None`.
  `GET /api/me` (`UserOut`) gets `has_subsonic_password: bool`.
- Disabled users (`is_disabled`) are rejected like wrong credentials.

## 2. Router (`app/api/subsonic.py`, new; helpers in `app/services/subsonic.py` if useful)
- Prefix `/rest`. Every endpoint is reachable as `/rest/<name>` **and** `/rest/<name>.view`, with **GET and
  POST** (POST with `application/x-www-form-urlencoded` body; parameters may be in query or body, merged; repeated
  parameters like `id`, `songId`, `songIdToAdd` are lists).
- Common params: `u`, `p` (plain or `enc:<hex>`), `t` + `s` (token = md5(app_password + salt), lower-case hex),
  `apiKey` (OpenSubsonic `apiKeyAuthentication`: the app password itself, without `u`), `v`, `c`, `f`
  (`xml` default, `json`; `jsonp` → treat as json).
- Response envelope: `subsonic-response` with `status="ok"|"failed"`, `version="1.16.1"`, `type="resonance"`,
  `serverVersion` = app version (as `/api/health` reports), `openSubsonic=true`. XML: namespace
  `http://subsonic.org/restapi`; JSON: `{"subsonic-response": {...}}`. Write one serializer turning nested
  dicts/lists into both formats (lists → repeated XML elements; scalars → XML attributes; booleans lower-case).
  Always HTTP 200 for API errors (Subsonic convention) with `error {code, message}`:
  10 missing parameter, 40 wrong credentials, 42 auth mechanism not supported (both apiKey and u given),
  43 multiple conflicting auth, 44 invalid apiKey, 50 not authorized, 70 not found, 0 generic.
- Binary endpoints (`stream`, `download`, `getCoverArt`) return the bytes on success and the XML/JSON error
  envelope on failure.

## 3. Ids and objects
- Ids are the existing UUIDs as strings (artists, albums, tracks, playlists are distinct tables; UUIDs do not
  collide). `getCoverArt` accepts an album id, a track id (→ its album) or a playlist id (→ album of its first
  track); `coverArt` attributes in responses are always the album id.
- **Child (song)**: `id, parent=albumId, isDir=false, title, album, artist (artist_credit), track (track_no),
  discNumber, year, genre, coverArt, size, contentType, suffix, duration (int seconds), bitRate, samplingRate,
  path (relative path), albumId, artistId, type="music", mediaType="song", isrc (list, OpenSubsonic), starred
  (ISO time of the like, only if liked), played (last play), playCount, replayGain {trackGain, albumGain}`
  (OpenSubsonic fields only when known).
- **AlbumID3**: `id, name, artist, artistId, coverArt, songCount, duration, created, year, genre, starred`
  (saved album = starred), `playCount`. **ArtistID3**: `id, name, coverArt (first album id), albumCount,
  starred` (not supported → omit). Reuse the existing view helpers / queries (`app/services/views.py`) where
  they fit; avoid N+1 queries (load aggregates in bulk).

## 4. Endpoints
System: `ping`, `getLicense` (`valid=true`), `getOpenSubsonicExtensions` (`formPost`, `songLyrics`,
`apiKeyAuthentication`, each `versions=[1]`), `getMusicFolders` (one folder id `1`, name "Resonance"),
`getUser` (own user only unless admin; roles: `streamRole`, `downloadRole`, `playlistRole`, `coverArtRole`
true; `adminRole` = is_admin; others false), `getScanStatus` (`scanning` from the current scan job, `count` =
track count).
Browsing: `getArtists` / `getIndexes` (grouped by first letter of the sort name, `ignoredArticles="The El La Los
Las Le Les Die Der Das"`), `getArtist`, `getAlbum` (songs in disc/track order), `getSong`, `getMusicDirectory`
(id = artist → its albums as directory children with `isDir=true`; id = album → its songs), `getGenres`
(`songCount`, `albumCount`), `getAlbumList` and `getAlbumList2` (`type` = random, newest, highest (= most played),
frequent, recent, alphabeticalByName, alphabeticalByArtist, starred, byYear (`fromYear`, `toYear`), byGenre
(`genre`); `size` default 10 max 500, `offset`), `getRandomSongs` (`size` default 10 max 500, `genre`,
`fromYear`, `toYear`), `getSongsByGenre` (`genre`, `count` default 10 max 500, `offset`), `getStarred` /
`getStarred2` (liked songs + saved albums), `getTopSongs` (`artist` name, `count` default 50: the artist's tracks
by play count), `getSimilarSongs2`/`getSimilarSongs` → `[]` is not allowed; return the artist's other tracks
shuffled (`count` default 50).
Search: `search3` and `search2` (`query`, `artistCount`/`albumCount`/`songCount` default 20, offsets; empty
query or `""` → everything paginated, which Symfonium uses for syncing; reuse the existing search for non-empty
queries).
Playlists (own playlists plus those shared with the user, like `GET /api/playlists`): `getPlaylists`,
`getPlaylist`, `createPlaylist` (`name` + `songId`s, or `playlistId` + `songId`s to replace), `updatePlaylist`
(`name`, `comment`, `public`, `songIdToAdd`, `songIndexToRemove`), `deletePlaylist` (owner only, else error 50).
Generated playlists (mixes) are not exposed. Reuse the playlist services/validation used by `api/playlists.py`.
Annotation: `star`/`unstar` (`id` = song → like; `albumId` = album → save album; `artistId` ignored), `scrobble`
(`id`s, `submission` default true: true → record a play like `POST /api/me/plays` with the song's full duration as
listened time and context `subsonic`; false → nothing), `setRating` → ok without effect.
Media: `stream` (`id`, `maxBitRate`, `format` (`raw` = original, `mp3`/`opus`/`aac` where the transcode service
supports it), `timeOffset` ignored; map to the existing stream implementation in `api/library.py` incl. Range
requests), `download` (original file), `getCoverArt` (`id`, `size` → existing cover service sizes),
`getLyrics` (`artist`, `title` → best library match → plain text), `getLyricsBySongId` (OpenSubsonic: structured
lyrics from `get_lyrics`, `synced`, `line[{start ms, value}]`, `lang="xxx"`, `displayArtist`, `displayTitle`).
Not implemented (return error 0 "Nicht unterstützt"): podcasts, internet radio, shares, jukebox, chat, users
admin, bookmarks, video. `getNowPlaying` → empty list. `getPlayQueue` → empty, `savePlayQueue` → ok.

## 5. Tests (`tests/test_subsonic.py`)
- Auth: token+salt ok, plain and `enc:` ok, apiKey ok, wrong → 40, no app password set → 40, disabled user → 40,
  apiKey + u → 43.
- XML and JSON envelope shape for `ping` and one list endpoint (parse the XML with `xml.etree`).
- `.view` suffix and POST form body work.
- getArtists/getArtist/getAlbum/getSong/getMusicDirectory/getAlbumList2 (several types)/search3 (empty and
  non-empty query)/getRandomSongs/getGenres on a small fixture library.
- Playlists create/update/delete incl. permission error; star/unstar → like and saved album; scrobble → play event.
- stream returns audio bytes with Range support; getCoverArt for album/track id; getLyricsBySongId with a sidecar
  `.lrc` file.

## App
### 6. Settings page (`lib/ui/pages/settings_page.dart`, section "Konto" / "Account")
`ListTile` `Icons.apps`, title "Andere Musik-Apps (Subsonic)" / "Other music apps (Subsonic)", subtitle
"Nutze Resonance in Apps wie Symfonium oder Feishin" / "Use Resonance in apps like Symfonium or Feishin". Opens a
dialog:
- Text "Server: <server URL>\nBenutzername: <username>" / "Server: …\nUsername: …" (selectable).
- If `hasSubsonicPassword`: "Ein App-Passwort ist eingerichtet." / "An app password is set up." + buttons
  "Neues Passwort erzeugen" / "Generate new password", "Entfernen" / "Remove", "Schließen" / "Close".
- Else: "Erzeuge ein App-Passwort und gib es in der anderen App als Passwort ein. Dein normales Passwort
  funktioniert dort nicht." / "Generate an app password and enter it as the password in the other app. Your
  normal password does not work there." + "Passwort erzeugen" / "Generate password", "Schließen" / "Close".
- After generating: show the password selectable in a monospace font with a copy `IconButton` (clipboard +
  `showInfo` "Kopiert" / "Copied") and the hint "Wird nur jetzt angezeigt." / "Shown only now.".
- `User.hasSubsonicPassword` in the model; refresh the session user after changes.

## Report
Changed/new files, backend test count, which endpoints you smoke-tested with a real HTTP call against a local
server if possible, deviations.
