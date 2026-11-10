import uuid
from collections import Counter
from datetime import UTC, date, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import Blend, PlayEvent, Playlist, Track, TrackCredits, User
from app.services import blends, credits, mixes
from app.services.deezer import deezer
from app.services.musicbrainz import mb
from app.services.server_config import update_config
from tests.conftest import MUSIC_DIR, make_track
from tests.test_mixes import entries, generated, library, like, plays
from tests.test_mixes import env as env  # noqa: PLC0414


def play_at(db: AsyncSession, user_id: uuid.UUID, track: Track, when: datetime, count: int = 1, seconds=180) -> None:
    db.add_all(
        [PlayEvent(user_id=user_id, track_id=track.id, played_at=when, seconds_played=seconds) for _ in range(count)]
    )


# --- Wrapped ------------------------------------------------------------------------------------------------------


async def test_wrapped_counts_the_year_and_makes_a_top_songs_playlist(env: SimpleNamespace) -> None:
    year = date.today().year
    june = datetime(year, 6, 14, 12, tzinfo=UTC)
    async with SessionLocal() as db:
        old = await library(db, "Old Favourite", "Rock", 2)
        pop = await library(db, "Pop Star", "Pop", 3)
        rap = await library(db, "Rapper", "Hip-Hop", 2)
        # Last year: counts for the years list and makes Old Favourite no new artist.
        play_at(db, env.user_id, old[0], datetime(year - 1, 6, 1, tzinfo=UTC), 4)
        play_at(db, env.user_id, old[0], june - timedelta(days=30), 1)
        play_at(db, env.user_id, pop[0], june, 5)
        play_at(db, env.user_id, pop[1], june + timedelta(days=1), 2)
        play_at(db, env.user_id, rap[0], datetime(year, 2, 3, 22, tzinfo=UTC), 3)
        # A skip (under 30 s) adds minutes but no play.
        play_at(db, env.user_id, rap[1], june, 1, seconds=10)
        # Another user's plays stay theirs.
        play_at(db, env.other_id, rap[1], june, 50)
        await db.commit()

    response = await env.client.get("/api/me/wrapped", headers=env.headers)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data["year"] == year
    assert data["years"] == [year - 1, year]
    assert data["plays"] == 11
    assert data["songs"] == 4
    assert data["artists"] == 3
    assert data["new_artists"] == 2
    assert data["minutes"] == round((11 * 180 + 10) / 60)
    assert [item["track"]["title"] for item in data["top_tracks"]] == [
        "Pop Star 0", "Rapper 0", "Pop Star 1", "Old Favourite 0",
    ]
    assert data["top_tracks"][0]["plays"] == 5
    assert [(item["name"], item["plays"], item["songs"]) for item in data["top_artists"]] == [
        ("Pop Star", 7, 2), ("Rapper", 3, 1), ("Old Favourite", 1, 1),
    ]
    assert [genre["name"] for genre in data["top_genres"]] == ["Pop", "Hip-Hop", "Rock"]
    assert sum(genre["share"] for genre in data["top_genres"]) == pytest.approx(1, abs=0.01)
    assert len(data["months"]) == 12 and len(data["hours"]) == 24
    assert data["months"][1] == 9  # February: three plays of three minutes
    assert data["top_day"] == june.astimezone().date().isoformat()
    assert data["first_track"]["title"] == "Rapper 0"
    assert data["playlist_id"] is None

    empty = (await env.client.get(f"/api/me/wrapped?year={year - 5}", headers=env.headers)).json()
    assert empty["plays"] == 0 and empty["top_tracks"] == [] and empty["years"] == [year - 1, year]

    body = {"name": f"Deine Top-Songs {year}", "description": "Rückblick"}
    response = await env.client.put(f"/api/me/wrapped/{year}/playlist", headers=env.headers, json=body)
    assert response.status_code == 200, response.text
    playlist_id = response.json()["id"]
    assert response.json()["kind"] == "user"
    detail = (await env.client.get(f"/api/playlists/{playlist_id}", headers=env.headers)).json()
    assert [entry["track"]["title"] for entry in detail["entries"]] == [
        "Pop Star 0", "Rapper 0", "Pop Star 1", "Old Favourite 0",
    ]
    # Asked again, the same playlist is made again (no second one).
    again = await env.client.put(f"/api/me/wrapped/{year}/playlist", headers=env.headers, json=body)
    assert again.json()["id"] == playlist_id
    assert (await env.client.get("/api/me/wrapped", headers=env.headers)).json()["playlist_id"] == playlist_id
    # The daily mixes leave it alone.
    async with SessionLocal() as db:
        await mixes.generate_mixes(db, await db.get(User, env.user_id), chart_downloads=False)
        assert await db.get(Playlist, uuid.UUID(playlist_id)) is not None

    missing = await env.client.put(f"/api/me/wrapped/{year - 5}/playlist", headers=env.headers, json=body)
    assert missing.status_code == 404


# --- Blend --------------------------------------------------------------------------------------------------------


async def test_blend_mixes_both_tastes_for_both_users_until_one_leaves(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        mine = [track for i in range(10) for track in await library(db, f"Mine {i}", "Rock", 4)]
        theirs = [track for i in range(10) for track in await library(db, f"Theirs {i}", "Pop", 4)]
        shared = await library(db, "Shared", "Pop", 2)
        for track in mine:
            plays(db, env.user_id, track, 2)
        for track in theirs:
            plays(db, env.other_id, track, 2)
        for track in shared:
            like(db, env.user_id, track)
            like(db, env.other_id, track)
        await db.commit()

    itself = await env.client.post("/api/blends", headers=env.headers, json={"user_id": str(env.user_id)})
    assert itself.status_code == 400
    response = await env.client.post("/api/blends", headers=env.headers, json={"user_id": str(env.other_id)})
    assert response.status_code == 201, response.text
    blend = response.json()
    assert blend["partner"]["name"] == "mix-other"
    assert 0 < blend["match"] < 1
    # Making it again (from either side) keeps the one blend.
    again = await env.client.post("/api/blends", headers=env.other_headers, json={"user_id": str(env.user_id)})
    assert again.json()["id"] == blend["id"]
    assert again.json()["partner"]["name"] == "mix-owner"

    async with SessionLocal() as db:
        mine_lists = await generated(db, env.user_id)
        their_lists = await generated(db, env.other_id)
        own = mine_lists[f"blend:{env.other_id}"]
        other = their_lists[f"blend:{env.user_id}"]
        assert own.id == uuid.UUID(blend["playlist_id"])
        assert own.name == other.name == "mix-owner + mix-other"
        own_entries = await entries(db, own)
        assert [e.track_id for e in own_entries] == [e.track_id for e in await entries(db, other)]
        assert len(own_entries) == blends.SIZE
        ids = {e.track_id for e in own_entries}
        assert {track.id for track in shared} <= ids
        # Both tastes take turns, three songs per artist at most.
        mine_count = sum(e.track_id in {t.id for t in mine} for e in own_entries)
        assert mine_count == sum(e.track_id in {t.id for t in theirs} for e in own_entries) == 24
        tracks = {t.id: t for t in [*mine, *theirs, *shared]}
        per_artist = Counter(tracks[e.track_id].artist_id for e in own_entries)
        assert max(per_artist.values()) == blends.PER_ARTIST
        by = {e.track_id: e.added_by_id for e in own_entries}
        assert {by[track.id] for track in shared} == {None}
        assert {by[track.id] for track in mine if track.id in by} == {env.user_id}

        # The daily mixes keep blends; the daily run makes them again when due.
        await mixes.generate_mixes(db, await db.get(User, env.user_id), chart_downloads=False)
        assert f"blend:{env.other_id}" in await generated(db, env.user_id)

    detail = (await env.client.get(f"/api/playlists/{blend['playlist_id']}", headers=env.headers)).json()
    adders = {entry["added_by"]["name"] for entry in detail["entries"] if entry["added_by"]}
    assert adders == {"mix-owner", "mix-other"}
    assert not detail["editable"]
    made = (await env.client.get("/api/mixes", headers=env.other_headers)).json()["made_for_you"]
    assert made[0]["mix_key"] == f"blend:{env.user_id}"

    listed = (await env.client.get("/api/blends", headers=env.other_headers)).json()
    assert [item["id"] for item in listed] == [blend["id"]]
    other_user = await env.client.delete(f"/api/blends/{uuid.uuid4()}", headers=env.headers)
    assert other_user.status_code == 404
    assert (await env.client.delete(f"/api/blends/{blend['id']}", headers=env.other_headers)).status_code == 204
    async with SessionLocal() as db:
        assert f"blend:{env.other_id}" not in await generated(db, env.user_id)
        assert f"blend:{env.user_id}" not in await generated(db, env.other_id)
        assert await db.scalar(select(Blend)) is None


def test_taste_match_is_symmetric_and_ignores_unshared_artists() -> None:
    artist = lambda name: SimpleNamespace(name=name)
    a_ids, b_ids = [uuid.uuid4() for _ in range(3)], [uuid.uuid4() for _ in range(3)]
    a = SimpleNamespace(
        artists=dict(zip(a_ids, map(artist, ["X", "Y", "Z"]), strict=True)), artist_scores=dict.fromkeys(a_ids, 4)
    )
    b = SimpleNamespace(
        artists=dict(zip(b_ids, map(artist, ["x", "Q", "R"]), strict=True)), artist_scores=dict.fromkeys(b_ids, 4)
    )
    assert blends.taste_match(a, b) == blends.taste_match(b, a) == pytest.approx(1 / 3, abs=0.001)
    assert blends.taste_match(a, a) == 1
    assert blends.taste_match(a, SimpleNamespace(artists={}, artist_scores={})) == 0


# --- Release Radar ------------------------------------------------------------------------------------------------


@pytest.fixture
async def radar(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    today = date.today()
    env.albums = {
        "Seed": [
            {"id": 1, "title": "New Single", "release_date": (today - timedelta(days=3)).isoformat()},
            {"id": 2, "title": "New Album", "release_date": (today - timedelta(days=10)).isoformat()},
            {"id": 3, "title": "Old Album", "release_date": (today - timedelta(days=60)).isoformat()},
            {"id": 4, "title": "Announced", "release_date": (today + timedelta(days=7)).isoformat()},
        ]
    }

    def song(id: int, title: str, rank: int, isrc: str | None = None) -> dict:
        return {"id": id, "title": title, "rank": rank, "isrc": isrc, "artist": {"id": 7, "name": "Seed"}}

    env.album_tracks = {
        "1": [song(11, "Single", 5)],
        "2": [song(21, "Filler", 1), song(22, "Hit", 900), song(23, "Second", 500), song(24, "Third", 400)],
        "3": [song(31, "Old", 999)],
    }
    env.downloads = []

    async def artist_albums(id: str) -> list[dict]:
        return env.albums.get(id, [])

    async def album_tracks(id: str) -> list[dict]:
        return env.album_tracks.get(id, [])

    async def request(db, user, kind, catalog_id, *, temporary, radio) -> None:
        env.downloads.append(catalog_id)
        if catalog_id == "24":
            raise HTTPException(429, "Limit")

    monkeypatch.setattr(deezer, "artist_albums", artist_albums)
    monkeypatch.setattr(deezer, "album_tracks", album_tracks)
    monkeypatch.setattr(mixes, "create_request", request)
    monkeypatch.setattr(mixes, "_radar_checked", {})
    return env


async def test_release_radar_collects_new_releases_of_favourite_artists(radar: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        seed = await library(db, "Seed", "Pop", 2)
        seed[1].title = "Hit"
        plays(db, radar.user_id, seed[0], 5)
        await db.commit()
        user = await db.get(User, radar.user_id)
        assert mixes.release_radar_due(user.id, None)
        playlist = await mixes.generate_release_radar(db, user)
        assert playlist is not None
        assert playlist.mix_key == mixes.RELEASE_RADAR
        assert playlist.name == "Neuerscheinungen"
        # "Hit" is in the library already; the single and the album's next songs are requested (the album's
        # least popular song and the old and announced releases are not), until the daily limit.
        assert [e.track_id for e in await entries(db, playlist)] == [seed[1].id]
        assert radar.downloads == ["11", "23", "24"]
        pending = {row.deezer_id for row in await db.scalars(select(mixes.RadioPending))}
        assert pending == {"11", "23"}
        # Not again until next Friday, also when nothing was found.
        assert not mixes.release_radar_due(user.id, None)
        assert not mixes.release_radar_due(uuid.uuid4(), datetime.now(UTC))
        assert mixes.release_radar_due(uuid.uuid4(), datetime.now(UTC) - timedelta(days=8))

        await mixes.generate_mixes(db, user, chart_downloads=False)
        assert mixes.RELEASE_RADAR in await generated(db, radar.user_id)

    made = (await radar.client.get("/api/mixes", headers=radar.headers)).json()["made_for_you"]
    assert made[0]["mix_key"] == mixes.RELEASE_RADAR
    assert made[0]["name"] == "Neuerscheinungen"
    english = await radar.client.get("/api/mixes", headers={**radar.headers, "Accept-Language": "en"})
    assert english.json()["made_for_you"][0]["name"] == "Release Radar"


async def test_release_radar_without_favourites_does_not_load_the_library(
    radar: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    taste = AsyncMock(wraps=mixes._taste)
    monkeypatch.setattr(mixes, "_taste", taste)
    async with SessionLocal() as db:
        await library(db, "Unheard", "Pop", 1)
        await db.commit()
        user = await db.get(User, radar.user_id)
        assert await mixes.generate_release_radar(db, user) is None
    taste.assert_not_awaited()
    # The first plays still count right away.
    assert mixes.release_radar_due(user.id, None)


async def test_release_radar_without_new_releases_removes_the_old_one(radar: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        seed = await library(db, "Seed", "Pop", 2)
        seed[1].title = "Hit"
        plays(db, radar.user_id, seed[0], 5)
        await db.commit()
        user = await db.get(User, radar.user_id)
        assert await mixes.generate_release_radar(db, user) is not None
        radar.albums = {}
        assert await mixes.generate_release_radar(db, user) is None
        assert mixes.RELEASE_RADAR not in await generated(db, radar.user_id)
        await update_config(db, {"mixes": {"release_radar_enabled": False}})
        radar.albums = {"Seed": [{"id": 1, "release_date": date.today().isoformat()}]}
        assert await mixes.generate_release_radar(db, user) is None


# --- Credits ------------------------------------------------------------------------------------------------------


async def test_credits_from_tags_and_musicbrainz_are_cached(env: SimpleNamespace, monkeypatch) -> None:
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "music_dir", MUSIC_DIR)
    make_track(
        "credits/song.flac",
        title="Song",
        artist="Main Act",
        composer="Writer One; Writer Two",
        lyricist="Lyric Person",
        producer="Prod Person",
        label="Tag Label",
        copyright="2026 Tag Label",
    )
    calls = []

    async def get(path: str, **params) -> dict:
        calls.append(path)
        if path.startswith("isrc/"):
            return {"recordings": [{"id": "rec-1"}]}
        return {
            "relations": [
                {"target-type": "artist", "type": "producer", "artist": {"name": "prod person"}, "attributes": []},
                {"target-type": "artist", "type": "mix", "artist": {"name": "Mixer"}, "attributes": []},
                {"target-type": "artist", "type": "engineer", "artist": {"name": "Helper"}, "attributes": ["assistant"]},
                {"target-type": "artist", "type": "instrument", "artist": {"name": "Guitarist"},
                 "attributes": ["guitar"]},
                {"target-type": "artist", "type": "vocal", "artist": {"name": "Singer"}, "attributes": []},
                {"target-type": "work", "type": "performance", "work": {"relations": [
                    {"target-type": "artist", "type": "composer", "artist": {"name": "Writer One"}},
                    {"target-type": "artist", "type": "lyricist", "artist": {"name": "Writer One"}},
                ]}},
            ]
        }

    monkeypatch.setattr(mb, "_get", get)
    async with SessionLocal() as db:
        tracks = await library(db, "Main Act", "Pop", 1)
        tracks[0].path = "credits/song.flac"
        tracks[0].artist_credit = "Main Act feat. Guest One & Guest Two"
        tracks[0].isrc = "DEAAA2600001"
        await db.commit()
        track_id = tracks[0].id

    response = await env.client.get(f"/api/tracks/{track_id}/credits", headers=env.headers)
    assert response.status_code == 200, response.text
    data = response.json()
    people = lambda section: {item["name"]: item["roles"] for item in data[section]}
    assert people("performers") == {
        "Main Act": ["artist"], "Guest One": ["featured"], "Guest Two": ["featured"],
        "Guitarist": ["guitar"], "Singer": ["vocals"],
    }
    assert people("writers") == {"Writer One": ["composer", "lyricist"], "Writer Two": ["composer"],
                                 "Lyric Person": ["lyricist"]}
    assert people("producers") == {"Prod Person": ["producer"]}
    assert people("engineers") == {"Mixer": ["mix"], "Helper": ["assistant engineer"]}
    assert data["label"] == "Tag Label"
    assert data["copyright"] == "2026 Tag Label"
    assert data["sources"] == ["tags", "musicbrainz"]
    assert calls == ["isrc/DEAAA2600001", "recording/rec-1"]

    # Cached: MusicBrainz is not asked again.
    again = await env.client.get(f"/api/tracks/{track_id}/credits", headers=env.headers)
    assert again.json() == data
    assert len(calls) == 2
    async with SessionLocal() as db:
        assert (await db.get(TrackCredits, track_id)).data["musicbrainz"]["people"]

    missing = await env.client.get(f"/api/tracks/{uuid.uuid4()}/credits", headers=env.headers)
    assert missing.status_code == 404


def test_file_credits_without_a_readable_file(tmp_path) -> None:
    assert credits.file_credits(tmp_path / "missing.flac") == {"people": [], "label": None, "copyright": None}
