# Phase 4a – Admin delete, album → catalog link, sharing playlists with users (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files beyond what is listed. Where silent, choose the simplest option matching existing code.
List any deviation with a reason in the final report. Same general rules as `docs/specs/phase2a-backend.md`
§0 (only `backend/`, never `app/`/`docs/`, no git commands that modify index/HEAD/working tree, German
user-facing texts, existing style, `ruff format --line-length 120` on new/rewritten files, tests without
network – use `httpx.MockTransport` / monkeypatching). Run tests against the database `app_test` only.
The whole existing test suite must still pass.

## A. Admin: delete tracks and albums

New endpoints in `app/api/admin.py` (admin only via `AdminUser`, like the other admin routes):

- `DELETE /api/admin/library/tracks/{track_id}` → 204
- `DELETE /api/admin/library/albums/{album_id}` → 204 (deletes all tracks of the album)

Unknown id → 404 `"Nicht gefunden"`.

Put the logic in a new module `app/services/deletion.py` with
`async def delete_tracks(db: AsyncSession, track_ids: list[uuid.UUID]) -> None` used by both endpoints:

1. Load the tracks (with `album_id`, `artist_id`, `path`).
2. Delete the rows with a core `delete(Track).where(Track.id.in_(ids))` statement (FKs already cascade /
   set null at DB level: likes, playlist entries, play events, download items, import items).
3. For every affected album: if it has no tracks left, delete the album row; delete its cover cache file
   `get_settings().cover_cache_dir / album.cover_file` (missing_ok) unless another remaining album has the same
   `cover_file`.
4. For every affected artist (track artists and album artists): if no track and no album references it any
   more, delete the artist row (and its `image_path` file if that is a path inside `data_dir`; missing_ok).
5. Commit, **then** delete the files (in `asyncio.to_thread`):
   - For each track: `music_dir / track.path`, `unlink(missing_ok=True)`. Resolve the path and skip (log a
     warning) anything that is not inside `music_dir.resolve()`.
   - For each distinct parent directory of the deleted files: if it now contains no file with an extension in
     `AUDIO_EXTENSIONS` (from `app.services.tags`) and no subdirectory, delete the remaining files in it
     (covers, `.nfo`, `.cue`, `.log`, …) and the directory itself. Then walk upwards and `rmdir` every empty
     parent directory, stopping at (never deleting) `music_dir`.
   - File errors (`OSError`) are logged and ignored; the endpoint still returns 204.

Tests (`tests/test_deletion.py`): create library rows + real files in a `tmp_path` music dir (monkeypatch
`music_dir`/`data_dir` like other tests do):
- deleting one of two tracks keeps album, folder and the other file; removes the file, likes and playlist
  entries of the deleted track.
- deleting an album removes all its files, the leftover `cover.jpg`, the album folder and the then-empty
  artist folder, the album row, the artist row and the cached cover file; `music_dir` itself stays.
- an artist that still has another album is kept.
- non-admin → 403, unknown id → 404.
- after deleting, `POST /api/requests` for the same catalog album creates a new request (no dedupe against
  finished requests – verify with the existing behaviour; only fix if it blocks).

## B. Library album → catalog album

New endpoint in `app/api/library.py`:

`GET /api/library/albums/{album_id}/catalog` → `{"catalog_id": "<deezer album id as string>"}` (any logged-in
user). Lets the app open the catalog page of a library album to download missing tracks.

Algorithm:
1. Load album + album artist; unknown → 404 `"Nicht gefunden"`.
2. `results = await deezer.search_albums(f"{artist.name} {album.title}", 10)`; `DeezerError` → 502
   `"Katalog nicht erreichbar"`.
3. Among results whose `name_key(result["artist"]["name"]) == artist.name_key`, pick the first whose
   `name_key(result["title"]) == album.title_key`; otherwise the first where one of the two title keys starts
   with the other (e.g. "2001" vs "2001 (Deluxe)"); otherwise 404 `"Album nicht im Katalog gefunden"`.
   (`name_key` from `app.services.matching`.)

Tests: exact match, prefix match, artist mismatch → 404, Deezer error → 502 (monkeypatch
`deezer.search_albums`).

## C. Share playlists with specific users

Model (`app/models/collection.py`) + Alembic migration (file name pattern like the existing ones, revision
after `c84f219a7d03`):

```
class PlaylistShare(Base):
    __tablename__ = "playlist_shares"
    __table_args__ = (UniqueConstraint("playlist_id", "user_id"),)
    id: uuid pk
    playlist_id: FK playlists.id ondelete CASCADE, index
    user_id: FK users.id ondelete CASCADE, index
    created_at: server_default now()
```

Visibility: a playlist is visible to a user if `owner_id == user.id` **or** `is_public` **or** a
`PlaylistShare(playlist_id, user.id)` exists. Apply this in `_get_visible` and in `GET /api/playlists`
(list). Editing stays owner-only (unchanged).

`PlaylistOut` gets a new field `shared_with: list[ArtistRef] = []` (`{id, name}` with `name =
display_name`, sorted by name casefold). Fill it only when the requesting user is the owner; otherwise `[]`.
`playlists_out` gets the requesting user's id as a new parameter for this (update all callers).

New endpoints:
- `PUT /api/playlists/{playlist_id}/shares` body `{"user_ids": [uuid, …]}` (max 100) → replaces the share set,
  returns `PlaylistOut`. Owner only (existing `_get_owned` → 404/403). Any id that is unknown, disabled or
  the owner's own id → 400 `"Unbekannter Nutzer"` (nothing changed).
- `GET /api/users` (new file `app/api/users.py`, router registered in `main.py`) → `[{id, name}]` of all
  non-disabled users except the caller, sorted by name casefold (`name = display_name`). Any logged-in user.

Tests: share with B → B sees it in list and can open it, C cannot (404); B cannot modify (403); replacing the
set with `[]` removes access; owner's `shared_with` contains B, B's view has `[]`; invalid user id → 400;
`GET /api/users` excludes self and disabled users.

## Report
List changed/new files, test count, deviations.
