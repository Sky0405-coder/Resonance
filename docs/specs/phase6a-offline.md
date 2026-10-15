# Phase 6a – Offline downloads (Flutter app only)

Precise implementation spec. Implement exactly what is written; no extra features, screens or settings
beyond what is listed. Where silent, choose the simplest option matching the existing code (Riverpod 3
Notifiers/Providers, go_router, existing widgets in `lib/ui/widgets`). List any deviation with a reason in
the final report.

Rules: only modify files in `app/` (never `backend/` or `docs/`). No git commands that modify the
index/HEAD/working tree. All user-visible texts via gen-l10n: add keys to **both** `lib/l10n/app_de.arb`
(template, German) and `lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`, use `context.l10n`.
`~/flutter/bin/flutter analyze` must report no issues; `~/flutter/bin/flutter build apk --release` and
`~/flutter/bin/flutter build web --release --wasm` must succeed. Do not run the release script, do not upload
anything.

## Goal
Like Spotify: the user can download **albums, playlists and the liked songs** to the device and play them
without internet. Downloaded collections stay in sync with the server. The app starts and is usable offline
(downloaded music only). Not available on web (`kIsWeb`): hide all offline UI there and never touch the
offline store.

## 1. Dependencies
Add `path_provider` and `connectivity_plus` (current versions compatible with the existing pubspec).

## 2. Offline store (`lib/offline/offline_store.dart`, new)
Directory: `<getApplicationSupportDirectory()>/offline/` with `index.json`, `tracks/`, `covers/`.

Index (JSON, written atomically via temp file + rename after every change):
```
{
  "version": 1,
  "collections": {
    "<key>": {                       // key: "album:<id>" | "playlist:<id>" | "liked"
      "kind": "album" | "playlist" | "liked",
      "id": "<id or 'liked'>",
      "name": "<display name>",
      "added_at": "<iso>",
      "synced_at": "<iso or null>",
      "data": <raw JSON of GET /api/albums/{id} | GET /api/playlists/{id} | GET /api/me/likes/tracks>
    }
  },
  "tracks": {
    "<track id>": {
      "file": "tracks/<id>.<ext>",   // relative to the offline dir; absent until downloaded
      "size": <bytes>,
      "album_id": "<album id>",
      "collections": ["<key>", ...]
    }
  }
}
```
(Check `lib/core/api.dart` for the exact endpoint paths the existing methods use and use the same ones.)

`OfflineController extends Notifier<OfflineState>` exposed as `offlineProvider`:
- `OfflineState`: `Map<String, OfflineCollection> collections`, `Map<String, OfflineTrack> tracks`,
  `int queued` (tracks waiting/downloading), `String? currentTrackId`, `bool waitingForWifi`, `bool loaded`.
  Helpers: `bool isDownloaded(String trackId)` (file present), `String? filePath(String trackId)` (absolute),
  `String? coverPath(String albumId)` (absolute, if the file exists), `CollectionStatus status(String key)` →
  `none | downloading(done, total) | downloaded`.
- `Future<void> add(String kind, String id)`: fetches the raw JSON (needs network; on failure throw the
  `ApiException`), stores the collection, links its tracks (ordered track ids from `data`), enqueues missing
  files. Name: album title / playlist name / localized "Liked Songs" text is resolved in the UI, store `"Liked"`
  for liked.
- `Future<void> remove(String key)`: unlinks the collection; tracks with no remaining collection get their
  file deleted and are removed from the index; covers of albums with no remaining tracks are deleted.
- `Future<void> sync()`: for every collection refetch `data` (skip silently when offline); diff track ids:
  new → link + enqueue, removed → unlink (+ delete orphans as in `remove`); update `name` and `synced_at`.
  Called after the session is restored (online), then every 30 minutes while the app runs, and when the user
  pulls to refresh on a downloaded collection page. A 404 for an album/playlist removes the collection.
- `Future<void> clearAll()`: deletes everything (directory) and resets the index.
- `int totalBytes`: sum of `size`.

Download worker (inside the controller): one track at a time, in collection order.
- URL: `api.streamUrl(id, format: …, bitrate: …)` by quality setting (§5): `normal` → `opus` 160,
  `high` → `opus` 256, `original` → `auto`. File extension: `opus` → `.ogg`; `auto` → from the response
  `content-type` (`audio/flac` → `.flac`, `audio/mpeg` → `.mp3`, `audio/mp4`/`audio/x-m4a`/`audio/aac` → `.m4a`,
  `audio/ogg` → `.ogg`, otherwise `.audio`).
- Download with the existing Dio instance of `ApiClient` (add a small method to `ApiClient` if needed) to
  `<file>.part`, then rename. On error: retry that track up to 3 times with 10 s pause, then skip it (stays
  not downloaded, retried on the next `sync()`).
- Before each track: if "only Wi-Fi" is on and `connectivity_plus` reports neither wifi nor ethernet, set
  `waitingForWifi = true` and wait for a connectivity change.
- Album covers: for each album id of a downloaded track, download `api.coverUrl(albumId, size: 600)` once to
  `covers/<albumId>.jpg` (ignore 404).
- The index is loaded at app start (`loaded`), before anything else uses it.

## 3. Playback (`lib/player/player.dart`)
`_source(Track t)`: if `offlineProvider` has a file for `t.id` → `AudioSource.file(path, tag: <same MediaItem,
artUri: Uri.file(coverPath) if present>)`, else the current stream source. Everything else unchanged.

## 4. Offline mode
- `SessionState` gets `bool offline` (default false). `SessionNotifier` stores the user JSON in
  SharedPreferences (`session.user`) on `signedIn` and after a successful `_restore`. When `_restore` fails with
  a non-401 error **and** a cached user exists: state = logged in with the cached user, `loading: false`,
  `offline: true`; retry `_restore` every 30 s until it succeeds (then `offline: false` and run
  `offline.sync()`). Without cached user: current behaviour. `User` needs a `toJson()` for this (add it,
  mirroring `fromJson`).
- `albumProvider`, `playlistDetailProvider`, `likedTracksProvider`, `playlistsProvider`, `homeProvider`: when
  the API call fails with an `ApiException` whose `statusCode` is null (server unreachable) and the offline
  store has the data, return it:
  - album/playlist detail/liked tracks → parse the stored `data` with the existing `fromJson`.
  - `playlistsProvider` → the downloaded playlists' `data['playlist']`-equivalent objects (check the playlist
    detail JSON shape) as `Playlist` list.
  - `homeProvider` → rethrow (the home page handles offline itself, below).
- Shell (`AppShell`): when `session.offline`, show a slim bar above the mini player: icon `cloud_off` +
  text "Offline – nur heruntergeladene Musik" / "Offline – downloaded music only".
- Home page: when offline, instead of the normal content show the heading and a list of the downloaded
  collections (cover, name, kind) opening their pages; if there are none, a hint "Lade Alben und Playlists
  herunter, um sie offline zu hören." / "Download albums and playlists to listen offline."
- Track rows of non-downloaded tracks are shown at 40 % opacity while offline (playing them still just fails
  with the existing error message).

## 5. Settings (`settings_page.dart`), new section "Downloads" (not on web)
- Quality: `normal` (default) / `high` / `original` as radio list ("Normal (Opus 160 kbit/s)",
  "Hoch (Opus 256 kbit/s)", "Original (verlustfrei, braucht viel Speicher)" and English equivalents);
  SharedPreferences key `offline.quality`. Changing it affects only future downloads.
- Switch "Nur über WLAN herunterladen" / "Download over Wi-Fi only", default on, key `offline.wifiOnly`.
- Tile showing used storage (MB/GB with one decimal) and number of downloaded songs; while downloading also
  "X Songs werden heruntergeladen". Button "Alle Downloads löschen" with a confirmation dialog → `clearAll()`.

## 6. UI on collection pages
- `ActionBar` (album page, playlist page, liked page; also radios): a download toggle button before the other
  extra buttons: `Icons.download_for_offline_outlined` (muted) when not downloaded → tap → `add`;
  while downloading a `CircularProgressIndicator` with value done/total around a small arrow; when complete
  `Icons.download_for_offline` in the accent color → tap → confirmation dialog "Download entfernen?" → `remove`.
  Errors via `showError`.
- `TrackRow`: if the track is downloaded, a small accent-colored `Icons.arrow_circle_down` (14 px) before the
  artist line (like Spotify).
- `CoverImage`: if the offline store has the cover for `albumId`, use `Image.file` instead of the network image.
- Library page: new first tab "Heruntergeladen" / "Downloaded" (not on web) listing downloaded collections
  (cover, name, kind label, status), opening their pages.

## 7. Report
Changed/new files, how you verified (analyze, builds), deviations.
