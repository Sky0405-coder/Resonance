# Phase 9a – Menus as bottom sheets, playlist covers, review "looks good" (backend + Flutter app)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: backend like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working
tree, German user-facing texts **plus** an English entry in `app/i18n.py` `_EXACT` for every new message,
existing style, `ruff format --line-length 120` on new/rewritten files, tests without network). Run backend tests
against the database given in the task prompt only (guards `startswith("app_test")`); the whole suite must pass.
App: all user-visible texts via gen-l10n (keys in **both** `lib/l10n/app_de.arb` (template) and
`lib/l10n/app_en.arb`, run `~/flutter/bin/flutter gen-l10n`), `~/flutter/bin/flutter analyze` without issues,
`~/flutter/bin/flutter test` passes, `JAVA_HOME=~/Android/jdk21 ~/flutter/bin/flutter build apk --release` and
`~/flutter/bin/flutter build web --release --wasm` must succeed. Do not touch `docs/`, no release script, no
upload/deploy. One Alembic migration for all model changes, after the current head.

## 1. Bottom-sheet menus (app)
The album page and playlist page still use Flutter's `PopupMenuButton` (looks like a stock Material menu). The
track menu (`showTrackMenu` in `lib/ui/widgets/track_list.dart`) already uses the Spotify-like bottom sheet.
- New `lib/ui/widgets/action_sheet.dart`:
  `class SheetAction { const SheetAction({required this.icon, required this.label, required this.onSelected}); final IconData icon; final String label; final VoidCallback onSelected; }`
  and `Future<void> showActionSheet(BuildContext context, {required Widget header, required List<SheetAction> actions})`
  with exactly the styling of `showTrackMenu` (`useRootNavigator: true`, `isScrollControlled: true`,
  `backgroundColor: Color(0xFF282828)`, `showDragHandle: true`, `SafeArea` + `SingleChildScrollView` + `Column`,
  header, `Divider`, one `ListTile(leading: Icon, title: Text)` per action; tapping pops the sheet first, then
  calls `onSelected`).
- `showTrackMenu` uses `showActionSheet` internally (same items, same order, same behaviour).
- Album page (`collection_pages.dart`, the `PopupMenuButton<String>` in the album `ActionBar`): replace with an
  `IconButton(icon: Icon(Icons.more_horiz), iconSize: 28, color: Palette.textMuted)` that opens the sheet. Header:
  `ListTile(leading: SizedBox(width: 48, child: CoverImage(albumId: id, size: 64)), title: album title, subtitle:
  album artist)`. Actions and order unchanged (radio, find missing, admin: match, change cover, delete), same
  icons/labels and the same handlers as today.
- Playlist page (the `PopupMenuButton<String>` shown when `d.editable`): same replacement. Header with
  `PlaylistCover` (see §2) + playlist name + owner name. Actions with icons, same conditions/order as today:
  keep (mix: `Icons.bookmark_add`, label `mixSave`; radio: `Icons.bookmark_add`, `radioKeep`), rename
  (`Icons.edit`), public/private (`Icons.public` / `Icons.lock`), share with users (`Icons.group_add`), **new**
  change cover (`Icons.image`, "Cover ändern" / "Change cover", only for `kind == 'user'` playlists), **new**
  remove cover (`Icons.hide_image`, "Cover entfernen" / "Remove cover", only when the playlist has a custom cover),
  delete (`Icons.delete_outline`).
- Do not change other `PopupMenuButton`s (audiobooks, player bar, admin).

## 2. Custom playlist covers
Backend:
- `Playlist.cover_file: String(64) | None` (file name in the cover cache, like `Album.cover_file`).
- `PUT /api/playlists/{id}/cover` (multipart field `file`): only the owner, only `kind == "user"` (else 404 for
  foreign/invisible playlists like the other playlist endpoints, 409 "Nur eigene Playlists können ein Cover haben"
  for mix/radio). Read at most 10 MB + 1 byte → 413 "Bild zu groß"; `covers.store(data)` → `None` → 422 "Kein
  gültiges Bild". Store the name in `cover_file`, commit, return `PlaylistOut` (same shape as `GET` of the playlist
  list items).
- `DELETE /api/playlists/{id}/cover` (owner) → `cover_file = None`, 204.
- `GET /api/playlists/{id}/cover?size=` – every user who may view the playlist (same visibility rule as
  `GET /api/playlists/{id}`), implementation like `album_cover` in `api/library.py` (`covers.resized`, 404 "No
  cover", same `Cache-Control`).
- `PlaylistOut` gets `cover_key: str | None` (= `cover_file`, used by clients for cache busting).
- OpenSubsonic `getCoverArt` with a playlist id: if the playlist has `cover_file`, return that image.
- Tests (`tests/test_playlist_cover.py`): upload (PNG generated with Pillow) → `cover_key` set, GET returns JPEG
  for owner and for a user the playlist is shared with, 404 for others; too big → 413; garbage → 422; mix → 409;
  delete → 204 and GET 404; non-owner upload → 404.

App:
- `Playlist` model: `coverKey` (`String?`). `ApiClient.playlistCoverUrl(String id, String key, {int size = 300})`
  → `'$baseUrl/api/playlists/$id/cover?size=$size&v=$key&token=$token'`; `uploadPlaylistCover(id, bytes,
  filename)` and `deletePlaylistCover(id)`.
- `PlaylistCover` gets optional `playlistId` and `coverKey`; when both are set and the app is online, show the
  image (`CachedNetworkImage`, same placeholder/error handling and radius as `CoverImage`) instead of the collage.
  Pass them at every `PlaylistCover(...)` call site that has a `Playlist`. Offline (`offline.dart`) keeps the
  collage.
- Picking the image: same picker/code path as the "Bild hochladen" button of the album cover picker
  (`metadata_editor.dart` `_CoverPicker`). After upload/remove: invalidate `playlistDetailProvider(id)` and
  `playlistsProvider`, `showInfo` "Cover gespeichert" / "Cover saved" (reuse `editorCoverSaved` if it exists with
  that meaning) or "Cover entfernt" / "Cover removed"; errors via `showError`.
- Android Auto (`audio_handler.dart`): `artUri` of a playlist uses the custom cover URL when `coverKey` is set.

## 3. Review: "looks good"
Some songs are too niche for MusicBrainz/Deezer and stay in Admin → Review → "Unidentified" forever.
- `Track.reviewed: bool`, `server_default false`, python default `False`.
- `GET /api/editor/review?kind=unidentified` additionally filters `Track.reviewed.is_(False)`.
- `POST /api/editor/tracks/{id}/reviewed` (admin) → `reviewed = True`, 204; 404 "Song nicht gefunden".
- Saving metadata manually (the endpoint the editor's "Bearbeiten"/"Edit" tab uses) also sets `reviewed = True`.
- App, `ReviewTab` (`metadata_editor.dart`) in the "unidentified" list: every row gets a trailing
  `IconButton(Icons.check, tooltip: "Passt so" / "Looks good")` → API call, remove the row, decrement the
  total; errors via `showError`. After the track editor closes with a manual save, the row disappears on the next
  load (no extra work).
- Tests: review list excludes reviewed tracks; endpoint 204/404/403 for non-admin; manual edit sets the flag.

## Report
Changed/new files, migration revision, backend test count, how you verified the app, deviations.
