# Phase 5b – Generated playlists: personal mixes and genre mixes (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields,
settings or files beyond what is listed. Where silent, choose the simplest option matching existing code
(especially `app/services/radio.py`). List any deviation with a reason in the final report. Same general rules
as `docs/specs/phase2a-backend.md` §0 (only `backend/`, never `app/`/`docs/`, no git commands that modify
index/HEAD/working tree, German user-facing texts, existing style, `ruff format --line-length 120` on
new/rewritten files, tests without network – monkeypatch `deezer.*`). Run tests against the database
`app_test` only (guards: `startswith("app_test")`). The whole existing test suite must still pass.

## Context
Every user gets automatically generated playlists, rebuilt once per day from the **library only** (never
triggers downloads):
- **Daily Mix 1–3**: groups of the user's favourite artists by genre, with related artists from the library.
- **Neu für dich**: library songs the user has never played, from artists related to their favourites.
- **Lange nicht gehört**: songs the user liked or played often but not in the last 60 days.
- **Genre mixes**: one playlist per frequent genre of the library (e.g. "Hip-Hop Mix").

They are playlists of `kind = "mix"`, owned by the user, invisible to others, regenerated daily (entries
replaced, playlist id stays the same, so the app's offline downloads can sync them).

## 1. Model + migration
`Playlist` gets `mix_key: Mapped[str | None] = mapped_column(String(128))` and
`generated_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))`; unique index on
`(owner_id, mix_key)` where `mix_key IS NOT NULL` (partial unique index). Migration after the current head.

`kind` values are now `"user" | "radio" | "mix"`.

## 2. Visibility / API rules for `kind != "user"`
Everywhere the code currently special-cases `kind == "radio"` for visibility, sharing, publishing and
`/api/home`, apply the same rule to **every** `kind != "user"` (radios and mixes are private, never public or
shared; 400 `"Radios und Mixe können nicht geteilt werden"` replaces the radio-only text; home lists only
`kind == "user"`). Adding tracks to a mix via the API is rejected with 400 `"Mixe werden automatisch
erstellt"`; removing/moving entries likewise. `POST /api/playlists/{id}/keep` also accepts mixes: it creates a
**new** playlist of kind `user` named like the mix with today's date appended (`"Daily Mix 1 (15.10.2026)"`)
containing the mix entries (the mix itself stays); for radios the behaviour is unchanged.

## 3. Genre normalisation (`app/services/mixes.py`, new)
`def genre_keys(raw: str | None) -> list[str]`: split on `;`, `,`, `/`, `|` and ` & `; strip; casefold;
replace `-` and `_` by space; collapse whitespace; drop empty and `"unknown"`, `"other"`, `"misc"`. Aliases
(after normalisation): `"hip hop"`, `"hiphop"`, `"rap"`, `"hip hop rap"` → `"hip hop"`; `"r&b"`, `"rnb"`,
`"r and b"` → `"r&b"`; `"electronica"`, `"electro"` → `"electronic"`; `"rock & roll"`, `"rock n roll"` →
`"rock"`. Display name: `GENRE_NAMES = {"hip hop": "Hip-Hop", "r&b": "R&B", "edm": "EDM"}`, otherwise
`key.title()`.
A track's genres: `genre_keys(track.genre)` or, if empty, `genre_keys(album.genre)`.

## 4. Generation (`app/services/mixes.py`)
`async def generate_mixes(db, user) -> None` — all randomness via
`random.Random(f"{user.id}:{date.today()}:{mix_key}")`; every mix max 50 entries, no duplicates; temporary
tracks (`is_temporary`) are never used.

Scores: `score(track) = plays in the last 90 days (PlayEvent with seconds_played ≥ 30) + 3 if liked`.
Artist score = sum over the artist's tracks (by `Track.artist_id`). **Favourite artists** = top 30 by score
with score > 0.

1. **Daily mixes** (`mix_key = "daily:1" … "daily:3"`, name `"Daily Mix 1"`…): each favourite artist's
   dominant genre = most frequent genre key over their library tracks (ties: alphabetical; none → `"other"`).
   Group favourites by dominant genre, order groups by total score, take up to 3 groups with ≥ 2 artists (if
   there are fewer than 2 such groups, use one group containing all favourites as `daily:1`). Content per group:
   for each artist up to 6 tracks (liked first, then most played, then random), plus related artists: for the
   top 5 artists of the group `deezer.search_artists(name, 5)` → exact `name_key` match → `artist_related(id,
   10)`; related artist names present in the library (`Artist.name_key`) contribute up to 3 random tracks each
   (max 8 related artists per mix). Deezer errors are ignored (mix without related artists). Shuffle.
   Description: the first 3 artist names of the group joined with ", " + `" und mehr"`.
2. **Neu für dich** (`"discover"`): library tracks of related artists (collected as in 1 for the top 10
   favourites) and, to fill up, of other library artists sharing a dominant genre with a favourite artist; only
   tracks the user never played and did not like; max 2 per artist; 30 entries; shuffled. Description
   `"Songs aus deiner Bibliothek, die du noch nicht gehört hast"`.
3. **Lange nicht gehört** (`"rewind"`): tracks liked or played ≥ 3 times ever, whose last play (if any) is
   older than 60 days and that were liked/first played more than 60 days ago; shuffled. Description
   `"Songs, die du lange nicht gehört hast"`.
4. **Genre mixes** (`"genre:<key>"`, name `"<Display> Mix"`): genre keys with ≥ 15 library tracks, the 12
   largest; content 50 random tracks of that genre, but the user's tracks of that genre with score > 0 first
   (up to 15, then random). Description `"Das Beste aus <Display> in deiner Bibliothek"`.

A mix with fewer than 5 tracks is not created (and deleted if it exists). For users without any plays/likes
only the genre mixes exist.

Writing: for each mix upsert the playlist by `(owner_id, mix_key)` (`kind="mix"`, `is_public=False`), replace
all entries (positions 1..n), set `name`, `description`, `generated_at=now()`. Delete the user's mix playlists
whose `mix_key` was not produced this run. One commit at the end.

## 5. Scheduling
In `app/services/mixes.py`: `start()`/`stop()` (registered in the app lifespan like the radio loop) run a loop
every 10 minutes that regenerates mixes for every active (non-disabled) user whose newest mix
`generated_at` is not from today (local server date) and who was seen (`User.last_seen_at`) in the last 14
days or has no mixes yet. Errors per user are logged and do not stop the loop.

## 6. API (`app/api/mixes.py`, new router in `main.py`)
`GET /api/mixes` → `MixesOut {made_for_you: list[PlaylistOut], genres: list[PlaylistOut]}` for the current
user. If the user has no mix generated today, generate synchronously first. Order: daily 1–3, discover,
rewind; genres by track count desc. `POST /api/mixes/refresh` → regenerates now and returns the same.

## 7. Tests (`tests/test_mixes.py`)
With fixtures building a small library (artists with genres, tracks, plays, likes) and monkeypatched Deezer:
- `genre_keys` normalisation and aliases.
- daily mixes grouped by genre, contain favourites' tracks + related library artists; Deezer failure tolerated.
- discover only contains never-played, not-liked tracks; rewind rules (60 days).
- genre mixes: threshold 15, max 12, user's favourites first.
- regeneration keeps playlist ids and replaces entries; obsolete mixes deleted; < 5 tracks → not created.
- mixes invisible to other users, not shareable/public (400), adding tracks → 400, keep creates a dated user
  copy, home excludes mixes; `GET /api/mixes` generates once per day.

## Report
List changed/new files, test count, deviations.
