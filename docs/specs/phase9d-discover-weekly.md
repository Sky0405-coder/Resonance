# Phase 9d – "Mix der Woche" (Discover Weekly) (backend + small app part)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings, screens or files beyond what is listed. Where silent, choose the simplest option matching the
existing code. List any deviation with a reason in the final report.

General rules: backend like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working
tree, German user-facing texts **plus** an English entry in `app/i18n.py` for every new message (playlist
name/description too: the mixes API already translates mix names – follow that mechanism), existing style,
`ruff format --line-length 120` on new/rewritten files, tests **without network** – fake Deezer like
`tests/test_mixes.py` / `tests/test_radio.py`). Run backend tests against the database given in the task prompt
only (guards `startswith("app_test")`); the whole suite must pass. App: gen-l10n keys in **both** ARB files,
`flutter analyze` clean, `flutter test` passes, APK and web (`--wasm`) release builds succeed. Do not touch
`docs/`, no release script, no upload/deploy. No migration is expected (reuse `Playlist.kind="mix"`, `mix_key`,
`RadioPending`); if one is needed, one migration after the current head.

## Goal
Like Spotify's "Discover Weekly": every Monday each active user gets a fresh playlist of **30 songs they have
never listened to**, matching their taste – partly from the library, partly new songs that are downloaded
automatically (temporary, like radio songs).

## 1. Generation (`app/services/mixes.py`)
`async def generate_discover(db, user) -> Playlist | None`:
1. **Taste seeds**: the user's top 10 artists by score over the last 90 days (score = plays with ≥ 30 s + 3 × liked
   tracks of the artist; same data `generate_mixes` already computes – extract a helper instead of duplicating).
   No seeds → return `None` (no playlist).
2. **Deezer ids** of the seeds: `deezer.search_artists(name, 5)`, exact `name_key` match (like the existing
   related-artist lookup in `generate_mixes`; reuse its cache/helper).
3. **Candidates**: for each seed `deezer.artist_related(id, 10)`; related artists that are themselves seeds are
   skipped; per related artist `deezer.artist_top(id, 5)`. Collect candidate Deezer tracks in round-robin order over
   the seeds (seed 1's first related artist's first top track, seed 2's …), dedupe by Deezer id and by
   `(name_key(primary artist), name_key(title))`, max 2 tracks per artist. `DeezerError` on single calls → skip
   that call (like `radio._candidates`).
4. `match_tracks` against the library. A candidate is **excluded** if its matched library track has any
   `PlayEvent` of this user or is liked by the user. Library tracks the user never played are allowed (they count as
   discoveries).
5. **Selection**: the first 30 remaining candidates. Matched ones become playlist entries directly. Unmatched ones
   (not in the library): request downloads with `create_request(db, user, "track", deezer_id,
   temporary=cfg.radio.temporary_tracks_enabled, radio=True)` (429 → stop requesting, other `HTTPException` → skip
   that candidate) and add `RadioPending(playlist_id, deezer_id)` rows so `resolve_radio_pending` appends them when
   downloaded. At most `cfg.mixes.discover_downloads` downloads per user and week.
6. **Playlist**: upsert with `mix_key="discover-weekly"`, `kind="mix"`, name "Mix der Woche", description "Neue
   Songs für dich – jeden Montag neu", `generated_at=now` (same upsert code as `write` in `generate_mixes`;
   generalise `write` so it can be reused, without the "< 5 tracks → skip" rule: the playlist is created even if
   it starts with fewer entries because downloads are pending; if there are no entries **and** no pending
   downloads → do not create/update it). Entries are replaced; old `RadioPending` rows of that playlist are
   deleted first.
7. `generate_mixes` must **not** delete the `discover-weekly` playlist (its cleanup deletes mixes not produced in
   this run – exclude this key).

## 2. Schedule + config
- `ServerConfig.mixes: MixesConfig` (new group) with `discover_enabled: bool = True` and `discover_downloads: int
  = Field(20, ge=0, le=50)` (comment: "Missing songs downloaded per user and week for the 'Mix der Woche'.").
  Admin page: section "Mixes" with a `SwitchListTile` "Mix der Woche" / "Discover Weekly" (subtitle "Jeden Montag
  30 neue Songs pro Nutzer, fehlende werden heruntergeladen" / "30 new songs per user every Monday, missing ones
  are downloaded") and a `_NumberTile` "Downloads pro Woche und Nutzer" / "Downloads per week and user".
- `_generate_due` additionally (when `discover_enabled`): for every user it already iterates, generate the discover
  playlist when it does not exist or its `generated_at` is before the most recent Monday 00:00 (server local time,
  like the existing `astimezone()` usage). `GET /api/mixes` does the same check for the calling user (after the
  existing daily check), so a new user gets it on first visit.
- Temporary songs downloaded for the mix are protected from the radio cleanup while they are in a
  `discover-weekly` playlist: in `radio.cleanup` treat entries of playlists with `mix_key == "discover-weekly"` like
  `kind == "user"` playlists.

## 3. API + app
- `MixesOut` gets `discover: PlaylistOut | None` (the user's discover playlist); it is **not** part of
  `made_for_you`.
- App: `mixesProvider` returns it too (adapt the record/model). Home page: when present, a highlighted card at the
  top of the "Made for you" shelf (first item) using the normal `PlaylistCard`, but its cover is a gradient tile
  (like `LikedCover`, colours `Color(0xFF8E2DE2)` → `Color(0xFF4A00E0)`, icon `Icons.explore`) with the text "Mix
  der Woche" / "Discover Weekly" – add a `DiscoverCover` widget next to `LikedCover`. The playlist page shows the
  same cover for this playlist (`mix_key` is not in `PlaylistOut` – add `mix_key: str | None` to `PlaylistOut` and
  the app model and use it).
- While downloads are pending, the playlist page already updates through the existing radio-follow/refresh logic
  if it applies to mixes; otherwise nothing extra.

## 4. Tests (`tests/test_discover.py`)
Seed selection; related artists that are seeds skipped; played/liked tracks excluded, never-played library tracks
included; max 2 per artist; 30 limit; downloads requested up to the limit with `RadioPending` rows; regenerate only
after Monday (freeze time with a monkeypatched `datetime`/helper); `generate_mixes` keeps the discover playlist;
`radio.cleanup` keeps temporary tracks that are in the discover playlist; `discover_enabled=False` → nothing;
`GET /api/mixes` returns `discover`.

## Report
Changed/new files, backend test count, how you verified the app, deviations.
