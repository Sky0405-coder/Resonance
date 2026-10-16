# Phase 9c – World radio: live internet radio stations (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: backend like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working
tree, German user-facing texts **plus** an English entry in `app/i18n.py` for every new message, existing style,
`ruff format --line-length 120` on new/rewritten files, tests **without network** – fake radio-browser and stream
servers with `httpx.MockTransport`). Run backend tests against the database given in the task prompt only (guards
`startswith("app_test")`); the whole suite must pass. App: gen-l10n keys in **both** ARB files,
`~/flutter/bin/flutter gen-l10n`, `flutter analyze` clean, `flutter test` passes, APK and web (`--wasm`) release
builds succeed. Do not touch `docs/`, no release script, no upload/deploy. One Alembic migration after the current
head.

## Goal
Like radio.garden: browse and play live radio stations from all over the world (by country, genre or name), mark
favourites. Station data comes from the free community database **radio-browser.info** (no API key).

## Backend

### 1. Client (`app/services/worldradio.py`, new)
- Base URLs: try in order `https://de1.api.radio-browser.info`, `https://de2.api.radio-browser.info`,
  `https://fi1.api.radio-browser.info` (next one on network error/5xx). Header
  `User-Agent: Resonance/<app version>`. Timeout 10 s.
- `Station` (pydantic): `id` (= `stationuuid`), `name`, `country`, `country_code`, `tags: list[str]` (split
  `tags` on ",", stripped, empty dropped, max 5), `favicon: str | None` (empty → None; only `https://` URLs,
  others → None), `codec`, `bitrate: int | None` (0 → None), `homepage: str | None`.
- Functions: `countries()` (`/json/countries`, only entries with `stationcount >= 5`, sorted by name; cached 24 h
  in memory), `top_tags(limit=40)` (`/json/tags?order=stationcount&reverse=true&hidebroken=true&limit=200`, keep
  tags with only letters/spaces/`&`/`-`, first `limit`; cached 24 h), `search(country_code, tag, name, offset,
  limit)` (`/json/stations/search` with `countrycode`, `tag`, `tagExact=false`, `name`, `order=clickcount`,
  `reverse=true`, `hidebroken=true`, `offset`, `limit`; drop stations with `hls == 1` or empty `url_resolved`),
  `station(id)` (`/json/stations/byuuid/{id}`; missing → `None`), `click(id)` (`/json/url/{id}`, errors ignored).
- Errors → `WorldRadioError` → HTTP 502 "Radiosender-Verzeichnis nicht erreichbar".

### 2. API (`app/api/worldradio.py`, new, prefix `/api/worldradio`, any logged-in user)
- `GET /countries` → `[{code, name, stations}]`; `GET /tags` → `[str]`;
  `GET /stations?country=&tag=&q=&offset=0&limit=50` (limit ≤ 100) → `[Station]`;
  `GET /stations/{id}` → `Station` or 404 "Sender nicht gefunden".
- Favourites: model `RadioStationFavorite` (table `radio_station_favorites`: `user_id` FK users CASCADE,
  `station_id: String(64)`, `data: JSONB` (the `Station` snapshot), `created_at`; primary key `(user_id,
  station_id)`). `GET /favorites` → `[Station]` newest first; `PUT /favorites/{id}` → fetches the station
  (404 if unknown), upserts the snapshot, 204; `DELETE /favorites/{id}` → 204.
- Stream proxy `GET /stations/{id}/stream` (auth like the track stream – token in the query is accepted the same
  way): look up the station (404), call `click(id)` in the background, then proxy `url_resolved` with
  `httpx.AsyncClient(follow_redirects=True, timeout=httpx.Timeout(10, read=None))` as a `StreamingResponse`
  (forward `Content-Type`, send `Cache-Control: no-store`, do **not** request ICY metadata). Before connecting and
  for every redirect: the URL must be `http`/`https` and its host must resolve only to public addresses
  (reject private, loopback, link-local, multicast, reserved – `ipaddress` module) → 502 "Sender nicht erreichbar".
  Upstream errors/non-2xx → 502 "Sender nicht erreichbar". Close the upstream when the client disconnects.
  Reason for the proxy: web app over https cannot play http streams (mixed content) and many stations lack CORS.
- Tests (`tests/test_worldradio.py`): parsing/filtering (hls, empty urls, favicon http → None, tags), server
  fallback on 5xx, caching, favourites CRUD, stream proxy passes bytes + content type, private-address and
  redirect-to-private rejection, 404s.

## App

### 3. Models + API client
`Station` model (`fromJson`), `ApiClient`: `worldRadioCountries()`, `worldRadioTags()`, `worldRadioStations({country,
tag, q, offset})`, `worldRadioFavorites()`, `addWorldRadioFavorite(id)`, `removeWorldRadioFavorite(id)`,
`stationStreamUrl(id)` (`'$baseUrl/api/worldradio/stations/$id/stream?token=$token'`).

### 4. Playback (`lib/player/player.dart`)
- Like the audiobook mode: `PlayerView.station` (`Station?`), set while a station plays (queue empty, `book` null).
  `PlayerController.playStation(Station s)` uses `_switch` like `playBook`, one `AudioSource.uri(streamUrl)`,
  context `'station:<id>'`. Switching to music/audiobook clears it.
- While a station plays: no seek, next/previous disabled, shuffle/repeat hidden, progress bar replaced by a small
  "LIVE" badge (player bar and now-playing page), title = station name, subtitle = "Weltradio · <country>" /
  "World radio · <country>", artwork = favicon (fallback `Icons.radio`). Not counted as a play (`/api/me/plays` not
  called), no Discord presence update other than clearing it, sleep timer works.
- Stream drops (player error while live): retry once after 3 s, then `showError` "Sender nicht erreichbar" /
  "Station unavailable" and stop.
- Media session / notification (`audio_handler.dart`): station name + "Weltradio", favicon art, controls only
  play/pause/stop. Android Auto: root node "Weltradio" / "World radio" listing the user's favourites (playable).

### 5. UI
- New page `lib/ui/pages/world_radio_page.dart`, route `/world-radio` inside the shell.
  - App bar title "Weltradio" / "World radio". Search field (hint "Sender suchen" / "Search stations"; debounce
    400 ms).
  - Row of `ChoiceChip`s: "Favoriten" / "Favourites", country selector chip (opens a searchable bottom sheet of
    countries with flag emoji from the code + name + station count; default = device locale country if present,
    else "DE"), then the top tags as chips (horizontal scroll). Exactly one of favourites / tag can be active; the
    country applies to search and tag lists (not to favourites).
  - List of stations: favicon (`CachedNetworkImage`, 48 px, rounded 6, fallback `Icons.radio`), name, subtitle
    "<country> · <tags joined by ', '>" and "<codec> <bitrate> kbps" when known, trailing heart `IconButton`
    (favourite toggle). Tap → `playStation`. Infinite scroll (50 per page). Empty → `commonNothingFound`.
- Entry points: Search page – a tile/card "Weltradio" (icon `Icons.public`) above the browse content that opens
  `/world-radio`; Home – shelf "Deine Radiosender" / "Your radio stations" with favourite stations (cards with
  favicon, tap plays), only when there are favourites.
- Tests: `test/world_radio_test.dart` – `Station.fromJson`, the flag-emoji helper, the playback state transitions
  that are unit-testable (station → track clears station) with the existing fakes if available.

## Report
Changed/new files, migration revision, backend test count, how you verified playback (emulator if possible),
deviations.
