import asyncio
import uuid
from collections import Counter
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import pytest
from fastapi import HTTPException
from pydantic import ValidationError
from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api import mixes as mixes_api
from app.db import Base, SessionLocal, engine
from app.main import app
from app.models import (
    Album,
    Artist,
    DownloadItem,
    DownloadRequest,
    PlayEvent,
    Playlist,
    PlaylistEntry,
    PlaylistShare,
    RadioPending,
    Track,
    TrackLike,
    User,
)
from app.services import editorial, mixes, radio
from app.services.deezer import DeezerError, deezer
from app.services.matching import name_key
from app.services.server_config import ServerConfig, update_config
from tests.conftest import auth, register


@pytest.fixture
async def env(client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")
    await mixes.stop()
    monkeypatch.setattr(mixes, "_chart_cache", {})
    monkeypatch.setattr(mixes, "_chart_requested", {})
    monkeypatch.setattr(editorial, "_refs", {})
    monkeypatch.setattr(editorial, "_cache", {})
    monkeypatch.setattr(editorial, "resolve", AsyncMock(return_value=None))

    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)

    await reset()
    owner = await register(client, "mix-owner")
    response = await client.post("/api/admin/invites", json={}, headers=auth(owner["token"]))
    other = await register(client, "mix-other", response.json()["token"])
    state = SimpleNamespace(
        client=client,
        user_id=uuid.UUID(owner["user"]["id"]),
        other_id=uuid.UUID(other["user"]["id"]),
        headers=auth(owner["token"]),
        other_headers=auth(other["token"]),
        related=[],
        calls=[],
        failures=set(),
        charts={},
        chart_calls=[],
    )

    async def search(q: str, limit: int) -> list[dict]:
        state.calls.append(("search", q, limit))
        if "search" in state.failures:
            raise DeezerError("offline")
        if "no_match" in state.failures:
            return [{"id": "wrong", "name": "Wrong"}]
        return [{"id": "wrong", "name": "Wrong"}, {"id": q, "name": f"  {q.upper()}  "}]

    async def related(id: str, limit: int) -> list[dict]:
        state.calls.append(("related", id, limit))
        if "related" in state.failures:
            raise DeezerError("offline")
        return state.related

    async def playlist_tracks(id: str, limit: int = 100) -> list[dict]:
        state.chart_calls.append((id, limit))
        if "charts" in state.failures:
            raise DeezerError("offline")
        return state.charts.get(id, [])

    monkeypatch.setattr(deezer, "search_artists", search)
    monkeypatch.setattr(deezer, "artist_related", related)
    monkeypatch.setattr(deezer, "playlist_tracks", playlist_tracks)
    try:
        yield state
    finally:
        await mixes.stop()
        await reset()


async def library(
    db: AsyncSession,
    name: str,
    genre: str | None,
    count: int = 8,
    *,
    album_genre: str | None = None,
    temporary: bool = False,
) -> list[Track]:
    artist = Artist(name=name, name_key=name_key(name))
    db.add(artist)
    await db.flush()
    album = Album(title=name, title_key=name_key(name), artist_id=artist.id, genre=album_genre)
    db.add(album)
    await db.flush()
    tracks = [
        Track(
            path=f"{name}/{i}.flac",
            title=f"{name} {i}",
            album_id=album.id,
            artist_id=artist.id,
            artist_credit=name,
            genre=genre,
            is_temporary=temporary,
            duration=180,
        )
        for i in range(count)
    ]
    db.add_all(tracks)
    await db.flush()
    return tracks


def plays(
    db: AsyncSession, user_id: uuid.UUID, track: Track, count: int = 1, *, days: int = 1, seconds: float = 30
) -> None:
    db.add_all(
        [
            PlayEvent(
                user_id=user_id,
                track_id=track.id,
                seconds_played=seconds,
                played_at=datetime.now(UTC) - timedelta(days=days),
            )
            for _ in range(count)
        ]
    )


def like(db: AsyncSession, user_id: uuid.UUID, track: Track, *, days: int = 1) -> None:
    db.add(TrackLike(user_id=user_id, track_id=track.id, created_at=datetime.now(UTC) - timedelta(days=days)))


async def generated(db: AsyncSession, user_id: uuid.UUID) -> dict[str, Playlist]:
    return {
        row.mix_key: row
        for row in await db.scalars(select(Playlist).where(Playlist.owner_id == user_id, Playlist.kind == "mix"))
    }


async def entries(db: AsyncSession, playlist: Playlist) -> list[PlaylistEntry]:
    return list(
        await db.scalars(
            select(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist.id).order_by(PlaylistEntry.position)
        )
    )


@pytest.mark.parametrize(
    "raw,expected",
    [
        (None, []),
        ("", []),
        ("unknown; Other, MISC / | & ", []),
        (" Jazz ; Rock,Pop/Folk|EDM & Soul ", ["jazz", "rock", "pop", "folk", "edm", "soul"]),
        ("HIP-HOP;hiphop;Rap;hip hop rap", ["hip hop"]),
        (" R&B / RnB / R and B ", ["r&b"]),
        ("Electronica, Electro", ["electronic"]),
        ("ROCK & ROLL;rock n roll;rock", ["rock"]),
        ("rock  &  roll / POP", ["rock", "pop"]),
        ("  Alternative__ROCK ; Deep   House ", ["alternative rock", "deep house"]),
    ],
)
def test_genre_keys(raw: str | None, expected: list[str]) -> None:
    assert mixes.genre_keys(raw) == expected


def test_genre_mix_leaves_out_compilation_songs_of_artists_from_other_genres() -> None:
    lounge, house, bee_gees, newcomer = (uuid.uuid4() for _ in range(4))
    sampler = uuid.uuid4()

    def song(artist_id: uuid.UUID, album_artist_id: uuid.UUID = sampler) -> SimpleNamespace:
        return SimpleNamespace(artist_id=artist_id, album=SimpleNamespace(artist_id=album_artist_id))

    own_genres = {lounge: {"downtempo", "acid jazz"}, house: {"electronic", "house"}, bee_gees: {"pop"}}
    deep_house = [song(lounge), song(house), song(newcomer), *[song(house, house) for _ in range(30)]]
    fitting = mixes.fitting_genre_tracks("deep house", deep_house, own_genres)
    # The lounge artist is out; house and umbrella-only artists stay, as do artists without own releases.
    assert deep_house[0] not in fitting and deep_house[1] in fitting and deep_house[2] in fitting
    assert len(fitting) == 32
    # Few fitting songs: the genre keeps its whole pool rather than shrinking below a mix.
    assert mixes.fitting_genre_tracks("deep house", deep_house[:3], own_genres) == deep_house[:3]
    disco = [song(bee_gees), *[song(house, house) for _ in range(30)]]
    assert disco[0] in mixes.fitting_genre_tracks("disco", disco, own_genres)
    assert mixes.genres_related("house", "deep house") and not mixes.genres_related("deep house", "tech house")


def test_genre_mix_follows_the_artists_lastfm_tags() -> None:
    lounge, deep, bee_gees, unknown = (uuid.uuid4() for _ in range(4))

    def song(artist_id: uuid.UUID) -> SimpleNamespace:
        return SimpleNamespace(artist_id=artist_id, album=SimpleNamespace(artist_id=artist_id))

    lastfm = {
        artist_id: mixes.artist_lastfm_genres(tags) for artist_id, tags in {
            lounge: {"acid jazz": 100, "chillout": 87, "deep house": 9, "french": 40},
            deep: {"deep house": 100, "house": 79, "female vocalists": 30},
            bee_gees: {"disco": 100, "pop": 81, "70s": 47},
        }.items()
    }
    known = {"deep house", "house", "acid jazz", "chillout", "disco", "pop", "jazz", "electronic"}
    pool = [song(lounge), song(deep), song(unknown), *[song(deep) for _ in range(30)]]
    # Own releases too: Last.fm decides once it knows the artist; a tag under 15 % does not count.
    fitting = mixes.fitting_genre_tracks("deep house", pool, {}, lastfm, known)
    assert pool[0] not in fitting and pool[1] in fitting and pool[2] in fitting
    assert pool[0] in mixes.fitting_genre_tracks("jazz", pool, {}, lastfm, known)
    assert pool[0] in mixes.fitting_genre_tracks("electronic", pool, {}, lastfm, known)
    disco = [song(deep), *[song(bee_gees) for _ in range(30)]]
    assert mixes.fitting_genre_tracks("disco", disco, {}, lastfm, known) == disco[1:]
    assert mixes.lastfm_supports("house", "deep house") and not mixes.lastfm_supports("deep house", "house")
    assert not mixes.lastfm_supports("disco", "disco house") and mixes.lastfm_supports("alternative rock", "alternative")
    assert mixes.lastfm_supports("hip hop", "deutschrap") and not mixes.lastfm_supports("jazz", "jazz hop")


async def test_daily_groups_related_library_limits_and_priority(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        groups = []
        selected = set()
        for rank, genre in enumerate(("Rock", "Rap", "Jazz", "Pop")):
            group = []
            for index in range(2):
                tracks = await library(db, f"{genre} favourite {index}", genre)
                like(db, env.user_id, tracks[-1])
                plays(db, env.user_id, tracks[-2], 8 - rank * 2)
                selected.update((tracks[-1].id, tracks[-2].id))
                group.append(tracks)
            groups.append(group)
        related = [await library(db, f"Related {i}", "Other", 5) for i in range(10)]
        temporary = await library(db, "Temporary", "Rock", temporary=True)
        like(db, env.user_id, temporary[0])
        await db.commit()
        env.related = [{"name": f"  RELATED {i} ", "id": i} for i in range(10)] + [
            {"name": "Not in library", "id": 100},
            {"name": "Related 0", "id": 0},
        ]
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        assert {key for key in result if key.startswith("daily:")} == {"daily:1", "daily:2", "daily:3"}
        related_ids = {track.id for group in related[:8] for track in group}
        for index, group in enumerate(groups[:3], 1):
            playlist = result[f"daily:{index}"]
            rows = await entries(db, playlist)
            ids = {row.track_id for row in rows}
            own_ids = {track.id for artist_tracks in group for track in artist_tracks}
            assert len(rows) == len(ids) == 36
            assert ids <= own_ids | related_ids
            assert selected & own_ids <= ids
            assert len(ids & own_ids) == 12
            assert len(ids & related_ids) == 24
            assert playlist.description == f"{group[0][0].artist_credit}, {group[1][0].artist_credit} und mehr"
            assert not playlist.is_public and playlist.generated_at is not None
            assert [row.position for row in rows] == list(range(1, 37))
        assert all(call[2] == (5 if call[0] == "search" else 10) for call in env.calls)
        assert not any(call[1] == "wrong" for call in env.calls if call[0] == "related")


async def test_daily_fallback_uses_all_favourites_and_dominant_genre_ties(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        a = await library(db, "A", "Rock;EDM", 6)
        b = await library(db, "B", "EDM", 6)
        c = await library(db, "C", None, 6, album_genre="Jazz")
        for tracks in (a, b, c):
            like(db, env.user_id, tracks[0])
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        assert [key for key in result if key.startswith("daily:")] == ["daily:1"]
        assert {row.track_id for row in await entries(db, result["daily:1"])} == {track.id for track in [*a, *b, *c]}
        d = await library(db, "D", "Jazz", 6)
        like(db, env.user_id, d[0])
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        assert result["daily:1"].description == "A, B und mehr"
        assert result["daily:2"].description == "C, D und mehr"


@pytest.mark.parametrize("failure", ["search", "related", "no_match"])
async def test_deezer_failure_keeps_daily_library_tracks(env: SimpleNamespace, failure: str) -> None:
    env.failures.add(failure)
    async with SessionLocal() as db:
        tracks = await library(db, "Favourite", None, 6)
        like(db, env.user_id, tracks[0])
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        assert {key for key in result if key.startswith("daily:")} == {"daily:1"}
        assert {row.track_id for row in await entries(db, result["daily:1"])} == {track.id for track in tracks}


async def test_scoring_uses_recent_qualified_plays_likes_and_top_30(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        favourites = []
        for i in range(32):
            tracks = await library(db, f"Favourite {i:02}", "Rock", 6)
            plays(db, env.user_id, tracks[0], 32 - i)
            favourites.append(tracks)
        old = await library(db, "Old plays", "Rock", 6)
        plays(db, env.user_id, old[0], 50, days=91)
        short = await library(db, "Short plays", "Rock", 6)
        plays(db, env.user_id, short[0], 50, seconds=29)
        foreign = await library(db, "Other user's favourite", "Rock", 6)
        like(db, env.other_id, foreign[0])
        liked = await library(db, "Liked", "Rock", 6)
        like(db, env.user_id, liked[0])
        plays(db, env.user_id, liked[0], 31)
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        daily = result["daily:1"]
        assert daily.description == "Liked, Favourite 00, Favourite 01 und mehr"
        ids = {row.track_id for row in await entries(db, daily)}
        assert len(ids) == 50
        assert ids <= {track.id for tracks in [liked, *favourites[:29]] for track in tracks}
        searches = [call[1] for call in env.calls if call[0] == "search"]
        assert searches == ["Liked", *[f"Favourite {i:02}" for i in range(9)]]


async def test_discover_never_played_not_liked_and_genre_fill(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        seed = await library(db, "Seed", "Rock", 6)
        like(db, env.user_id, seed[0])
        related = [await library(db, f"Related {i}", "Jazz", 5) for i in range(3)]
        fill = await library(db, "Genre fill", None, 5, album_genre="Rock")
        unrelated = await library(db, "Unrelated", "EDM", 6)
        temporary = await library(db, "Temporary related", "Rock", 6, temporary=True)
        for tracks in related:
            plays(db, env.user_id, tracks[0], seconds=1)
            plays(db, env.user_id, tracks[1], days=300, seconds=1)
            like(db, env.user_id, tracks[2], days=300)
        env.related = [{"id": i, "name": f"Related {i}"} for i in range(3)] + [{"id": 5, "name": "Temporary related"}]
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        rows = await entries(db, result["discover"])
        ids = {row.track_id for row in rows}
        assert {track.id for tracks in related for track in tracks[3:]} <= ids
        assert len(ids) == len(rows) == 8
        assert ids <= {track.id for tracks in [*related, fill] for track in tracks}
        counts = Counter([(await db.get(Track, row.track_id)).artist_id for row in rows])
        assert max(counts.values()) == 2
        assert ids.isdisjoint({track.id for track in [*unrelated, *temporary]})


async def test_discover_caps_at_30_with_related_before_fill(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        seed = await library(db, "Seed", "Rock", 6)
        like(db, env.user_id, seed[0])
        related = [await library(db, f"Related {i}", "Jazz", 4) for i in range(16)]
        await library(db, "Fill", "Rock", 8)
        env.related = [{"id": i, "name": f"Related {i}"} for i in range(16)]
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        rows = await entries(db, result["discover"])
        assert len(rows) == len({row.track_id for row in rows}) == 30
        assert {row.track_id for row in rows} <= {track.id for tracks in related for track in tracks}
        assert max(Counter([(await db.get(Track, row.track_id)).artist_id for row in rows]).values()) == 2


async def test_rewind_old_likes_frequent_plays_and_60_day_rules(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Rewind", None, 14)
        for track in tracks[:5]:
            like(db, env.user_id, track, days=61)
        plays(db, env.user_id, tracks[5], 3, days=61)
        plays(db, env.user_id, tracks[6], 2, days=100)
        like(db, env.user_id, tracks[7], days=59)
        like(db, env.user_id, tracks[8], days=100)
        plays(db, env.user_id, tracks[8], days=59, seconds=1)
        plays(db, env.user_id, tracks[9], 3, days=59)
        plays(db, env.other_id, tracks[10], 5, days=100)
        like(db, env.other_id, tracks[11], days=100)
        plays(db, env.user_id, tracks[12], 3, days=100)
        plays(db, env.user_id, tracks[12], days=1)
        like(db, env.user_id, tracks[13], days=100)
        tracks[13].is_temporary = True
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        assert result["rewind"].description == "Songs, die du lange nicht gehört hast"
        assert {row.track_id for row in await entries(db, result["rewind"])} == {track.id for track in tracks[:6]}


async def test_genre_threshold_cap_album_fallback_and_display_names(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await library(db, "Too small", "Small", 14)
        await library(db, "Temporary threshold", "Temporary", 14)
        await library(db, "Temporary extra", "Temporary", 3, temporary=True)
        expected = {}
        for i, genre in enumerate(("Rap", "RNB", "EDM", "Electro", *[f"Genre {i}" for i in range(9)])):
            tracks = await library(db, f"Artist {i}", None, 15 + i, album_genre=genre)
            expected[f"genre:{mixes.genre_keys(genre)[0]}"] = min(len(tracks), 50)
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        expected.pop("genre:hip hop")
        assert set(result) == set(expected)
        assert len(result) == 12
        assert result["genre:r&b"].name == "R&B Mix"
        assert result["genre:edm"].name == "EDM Mix"
        assert result["genre:electronic"].description == "Das Beste aus Electronic in deiner Bibliothek"
        assert env.calls == []
        for key, count in expected.items():
            assert len(await entries(db, result[key])) == count


async def test_genre_favourites_first_up_to_15_then_random_and_max_50(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Rap artist", "Hip_Hop", 70)
        for track in tracks[:20]:
            like(db, env.user_id, track)
        plays(db, env.user_id, tracks[19], 10)
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        playlist = result["genre:hip hop"]
        rows = await entries(db, playlist)
        assert playlist.name == "Hip-Hop Mix"
        assert len(rows) == len({row.track_id for row in rows}) == 50
        assert rows[0].track_id == tracks[19].id
        assert {row.track_id for row in rows[:15]} <= {track.id for track in tracks[:20]}


async def test_regeneration_ids_entries_determinism_obsolete_and_small_mixes(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Favourite", "Rock", 8)
        like(db, env.user_id, tracks[0])
        obsolete = Playlist(owner_id=env.user_id, name="Obsolete", kind="mix", mix_key="genre:obsolete")
        null_key = Playlist(owner_id=env.user_id, name="Null key", kind="mix")
        foreign = Playlist(owner_id=env.other_id, name="Foreign", kind="mix", mix_key="daily:1")
        normal = Playlist(owner_id=env.user_id, name="Normal")
        db.add_all([obsolete, null_key, foreign, normal])
        await db.commit()
        commit = AsyncMock(wraps=db.commit)
        monkeypatch.setattr(db, "commit", commit)
        user = await db.get(User, env.user_id)
        await mixes.generate_mixes(db, user)
        commit.assert_awaited_once()
        result = await generated(db, env.user_id)
        daily = result["daily:1"]
        first = await entries(db, daily)
        assert await db.get(Playlist, obsolete.id) is None
        assert await db.get(Playlist, null_key.id) is None
        await mixes.generate_mixes(db, user)
        again = (await generated(db, env.user_id))["daily:1"]
        second = await entries(db, again)
        assert daily.id == again.id
        assert [row.track_id for row in first] == [row.track_id for row in second]
        assert {row.id for row in first}.isdisjoint({row.id for row in second})
        old_ids = {row.track_id for row in first}
        await db.execute(update(Track).where(Track.id.in_(old_ids)).values(is_temporary=True))
        replacements = await library(db, "Replacement", None, 6)
        like(db, env.user_id, replacements[0])
        await db.commit()
        await mixes.generate_mixes(db, user)
        replacement = (await generated(db, env.user_id))["daily:1"]
        assert replacement.id == daily.id
        assert {row.track_id for row in await entries(db, replacement)}.isdisjoint(old_ids)
        await db.execute(update(Track).where(Track.artist_id == replacements[0].artist_id).values(is_temporary=True))
        await db.execute(update(Track).where(Track.artist_id == tracks[0].artist_id).values(is_temporary=True))
        # Four eligible tracks cannot produce a mix, even for a favourite artist.
        await db.execute(
            update(Track).where(Track.id.in_([track.id for track in tracks[:4]])).values(is_temporary=False)
        )
        await db.commit()
        await mixes.generate_mixes(db, user)
        assert await generated(db, env.user_id) == {}
        assert await db.get(Playlist, daily.id) is None
        assert await db.get(Playlist, foreign.id) is not None
        assert await db.get(Playlist, normal.id) is not None


async def test_owner_mix_key_partial_unique_index(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        db.add_all(
            [
                Playlist(owner_id=env.user_id, name="User A"),
                Playlist(owner_id=env.user_id, name="User B"),
                Playlist(owner_id=env.user_id, name="Mix", kind="mix", mix_key="daily:1"),
                Playlist(owner_id=env.other_id, name="Other mix", kind="mix", mix_key="daily:1"),
            ]
        )
        await db.commit()
        db.add(Playlist(owner_id=env.user_id, name="Duplicate", kind="mix", mix_key="daily:1"))
        with pytest.raises(IntegrityError):
            await db.commit()
        await db.rollback()


async def test_mix_privacy_immutable_entries_dated_keep_and_home(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Favourite", "Rock", 6)
        like(db, env.user_id, tracks[0])
        normal = Playlist(owner_id=env.user_id, name="Normal")
        db.add(normal)
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        playlist = (await generated(db, env.user_id))["daily:1"]
        original = [row.track_id for row in await entries(db, playlist)]
        playlist.is_public = True
        db.add(PlaylistShare(playlist_id=playlist.id, user_id=env.other_id))
        await db.commit()
    url = f"/api/playlists/{playlist.id}"
    assert (await env.client.get(url, headers=env.other_headers)).status_code == 404
    response = await env.client.get("/api/playlists", headers=env.other_headers)
    assert str(playlist.id) not in {row["id"] for row in response.json()}
    response = await env.client.get("/api/mixes", headers=env.other_headers)
    assert response.json() == {"made_for_you": [], "genres": [], "discover": None, "decades": [], "charts": []}
    response = await env.client.get("/api/playlists", headers=env.headers)
    assert {row["kind"] for row in response.json()} == {"mix", "user"}
    detail = (await env.client.get(url, headers=env.headers)).json()
    assert not detail["editable"]
    entry_id = detail["entries"][0]["entry_id"]
    for method, suffix, body in (
        ("patch", "", {"is_public": True}),
        ("put", "/shares", {"user_ids": [str(env.other_id)]}),
        ("put", "/shares", {"user_ids": []}),
    ):
        response = await env.client.request(method, url + suffix, json=body, headers=env.headers)
        assert response.status_code == 400
        assert response.json()["detail"] == "Radios und Mixe können nicht geteilt werden"
    for method, suffix, body in (
        ("post", "/tracks", {"track_ids": [str(tracks[0].id)]}),
        ("post", "/move", {"entry_id": entry_id}),
        ("delete", f"/entries/{entry_id}", None),
    ):
        response = await env.client.request(method, url + suffix, json=body, headers=env.headers)
        assert response.status_code == 400
        assert response.json()["detail"] == "Mixe werden automatisch erstellt"
    assert (await env.client.post(url + "/keep", headers=env.other_headers)).status_code == 404
    response = await env.client.post(url + "/keep", headers=env.headers)
    assert response.status_code == 200
    saved = response.json()
    assert saved["id"] != str(playlist.id)
    assert saved["kind"] == "user" and not saved["is_public"]
    assert saved["name"] == f"Daily Mix 1 ({date.today():%d.%m.%Y})"
    async with SessionLocal() as db:
        copied = await db.get(Playlist, uuid.UUID(saved["id"]))
        assert [row.track_id for row in await entries(db, copied)] == original
        assert copied.mix_key is None and copied.generated_at is None
        assert (await db.get(Playlist, playlist.id)).kind == "mix"
    home = (await env.client.get("/api/home", headers=env.headers)).json()
    assert {row["id"] for row in home["playlists"]} == {str(normal.id), saved["id"]}


async def test_get_generates_once_per_day_refresh_order_and_auth(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    async with SessionLocal() as db:
        for i, genre in enumerate(("Rock", "Jazz", "Pop")):
            for j in range(2):
                tracks = await library(db, f"{genre} {j}", genre, 8 + i)
                like(db, env.user_id, tracks[0])
        old = await library(db, "Old likes", None, 6)
        for track in old:
            like(db, env.user_id, track, days=100)
        for i in range(3):
            await library(db, f"Discover {i}", "Rock", 3)
        await db.commit()
    generate = AsyncMock(wraps=mixes.generate_mixes)
    monkeypatch.setattr(mixes_api, "generate_mixes", generate)
    assert (await env.client.get("/api/mixes")).status_code == 401
    assert (await env.client.post("/api/mixes/refresh")).status_code == 401
    response = await env.client.get("/api/mixes", headers=env.headers)
    assert response.status_code == 200, response.text
    first = response.json()
    generate.assert_awaited_once()
    assert [row["name"] for row in first["made_for_you"]] == [
        "Daily Mix 1",
        "Daily Mix 2",
        "Daily Mix 3",
        "Neu für dich",
        "Deine Favoriten",
        "Neuheiten-Mix",
        "Lange nicht gehört",
    ]
    assert [row["track_count"] for row in first["genres"]] == sorted(
        [row["track_count"] for row in first["genres"]], reverse=True
    )
    assert (await env.client.get("/api/mixes", headers=env.headers)).json() == first
    assert generate.await_count == 1
    async with SessionLocal() as db:
        await db.execute(
            update(Playlist).where(Playlist.kind == "mix").values(generated_at=datetime.now(UTC) - timedelta(days=1))
        )
        await db.commit()
    response = await env.client.get("/api/mixes", headers=env.headers)
    assert response.status_code == 200 and generate.await_count == 2
    response = await env.client.post("/api/mixes/refresh", headers=env.headers)
    assert response.status_code == 200 and generate.await_count == 3
    assert [row["id"] for row in response.json()["made_for_you"]] == [row["id"] for row in first["made_for_you"]]


async def test_no_history_only_genre_mixes_and_too_small_library(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await library(db, "Rock", "Rock", 15)
        await db.commit()
    response = await env.client.get("/api/mixes", headers=env.headers)
    assert response.status_code == 200
    assert response.json()["made_for_you"] == []
    assert [row["name"] for row in response.json()["genres"]] == ["Rock Mix"]
    assert env.calls == []
    async with SessionLocal() as db:
        await db.execute(delete(Track))
        await db.commit()
    response = await env.client.post("/api/mixes/refresh", headers=env.headers)
    assert response.json() == {"made_for_you": [], "genres": [], "discover": None, "decades": [], "charts": []}


async def test_scheduler_selects_due_active_users_and_isolates_errors(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    now = datetime.now(UTC)
    async with SessionLocal() as db:
        await db.execute(delete(Playlist))
        await db.execute(update(User).values(is_disabled=True))
        users = []
        for i in range(7):
            user = User(
                username=f"scheduled-{i}",
                display_name=f"User {i}",
                password_hash="unused",
                last_seen_at=now - timedelta(days=1 if i < 3 else 15),
                is_disabled=i == 6,
            )
            db.add(user)
            users.append(user)
        await db.flush()
        for i in (0, 1, 2, 3, 6):
            db.add(
                Playlist(
                    owner_id=users[i].id,
                    kind="mix",
                    name="Mix",
                    mix_key="daily:1",
                    generated_at=now - timedelta(days=1),
                )
            )
        db.add(Playlist(owner_id=users[2].id, kind="mix", name="Newer", mix_key="rewind", generated_at=now))
        users[5].last_seen_at = None
        await db.commit()
    seen = []

    async def generate(db: AsyncSession, user: User, *, chart_downloads: bool = True) -> None:
        assert not chart_downloads
        seen.append(user.id)
        if user.id == users[0].id:
            raise RuntimeError("failed user")

    monkeypatch.setattr(mixes, "generate_mixes", generate)
    await mixes._generate_due()
    assert set(seen) == {users[i].id for i in (0, 1, 4, 5)}


async def test_scheduler_interval_recovery_start_stop_and_lifespan(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    waits = []

    async def sleep(seconds: float) -> None:
        waits.append(seconds)
        if len(waits) == 3:
            raise asyncio.CancelledError

    generate = AsyncMock(side_effect=[RuntimeError("first pass failed"), None])
    with monkeypatch.context() as patch:
        patch.setattr(mixes.asyncio, "sleep", sleep)
        patch.setattr(mixes, "_generate_due", generate)
        with pytest.raises(asyncio.CancelledError):
            await mixes._generate_loop()
    assert waits == [600, 600, 600]
    assert generate.await_count == 2
    await mixes.start()
    task = mixes._loop_task
    await mixes.start()
    assert mixes._loop_task is task
    await mixes.stop()
    assert task.cancelled() and mixes._loop_task is None
    async with app.router.lifespan_context(app):
        assert mixes._loop_task is not None and not mixes._loop_task.done()
    assert mixes._loop_task is None


async def test_decade_favourites_and_new_music_mixes(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        eighties = await library(db, "Eighties", None, 16)
        for i, track in enumerate(eighties):
            track.year = 1980 + i % 10
        noughties = await library(db, "Noughties", None, 15)
        (await db.get(Album, noughties[0].album_id)).year = 2004
        few = await library(db, "Few", None, 14)
        for track in few:
            track.year = 1975
        fresh = await library(db, "Fresh", None, 6)
        for track in fresh:
            track.year = datetime.now(UTC).year
            like(db, env.user_id, track)
        for track in eighties[:5]:
            plays(db, env.user_id, track, 3)
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        assert {key for key in result if key.startswith("decade:")} == {"decade:1980", "decade:2000"}
        assert (result["decade:1980"].name, result["decade:2000"].name) == ("80er Mix", "2000er Mix")
        assert result["decade:1980"].description == "Das Beste aus den 80ern in deiner Bibliothek"
        assert len(await entries(db, result["decade:1980"])) == 16
        favourites = {row.track_id for row in await entries(db, result["favourites"])}
        assert favourites == {track.id for track in [*fresh, *eighties[:5]]}
        # Songs played three times already are not new any more.
        new_music = {row.track_id for row in await entries(db, result["new-music"])}
        assert {track.id for track in fresh} <= new_music
        assert not new_music & {track.id for track in eighties[:5]}
    response = await env.client.get("/api/mixes", headers={**env.headers, "Accept-Language": "en"})
    body = response.json()
    assert [row["name"] for row in body["decades"]] == ["80s Mix", "2000s Mix"]
    assert body["decades"][0]["description"] == "The best of the 80s in your library"
    assert {"Favourites Mix", "New Music Mix"} <= {row["name"] for row in body["made_for_you"]}


@pytest.mark.parametrize(
    ("decade", "label", "terms"),
    [(1980, "80er", ["1980", "1980s", "80s", "80er", "achtziger", "eighties"]), (2010, "2010er", ["2010", "2010s"])],
)
def test_decade_label_and_search_terms(decade: int, label: str, terms: list[str]) -> None:
    assert mixes.decade_label(decade) == label
    assert set(terms) <= set(mixes.mix_search_terms(f"decade:{decade}"))
    assert mixes.mix_search_terms("genre:rock") == []


async def test_search_finds_mixes_and_playlists(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Eighties", "Rock", 16)
        for track in tracks:
            track.year = 1985
        db.add(Playlist(owner_id=env.other_id, name="Party 80s", kind="user", is_public=True))
        db.add(Playlist(owner_id=env.other_id, name="Secret 80s", kind="user", is_public=False))
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
    for q, expected in [
        ("80s", ["80er Mix", "Party 80s"]),
        ("achtziger", ["80er Mix"]),
        ("rock", ["Rock Mix"]),
        ("best of rock", []),
    ]:
        response = await env.client.get("/api/search", params={"q": q}, headers=env.headers)
        assert response.status_code == 200, response.text
        assert [row["name"] for row in response.json()["playlists"]] == expected, q
    response = await env.client.get("/api/search", params={"q": "80s"}, headers={**env.headers, "Accept-Language": "en"})
    assert [row["name"] for row in response.json()["playlists"]] == ["80s Mix", "Party 80s"]


async def test_era_artist_and_on_repeat_mixes(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        rap90 = await library(db, "Rapper", "Hip-Hop", 16)
        rap10 = await library(db, "New Rapper", "Hip-Hop", 16)
        rock90 = await library(db, "Rocker", "Rock", 20)
        for track in rap90 + rock90:
            track.year = 1995
        for track in rap10:
            track.year = 2015
        for track in rap90[:3]:
            plays(db, env.user_id, track, 2, days=3)
        plays(db, env.user_id, rap90[3], 1, days=3)
        plays(db, env.user_id, rap90[4], 5, days=40)
        like(db, env.user_id, rap90[5])
        await db.commit()
        env.related = [{"id": "New Rapper", "name": "New Rapper"}]
        # Keep the weekly mix (Deezer top tracks) out of this test.
        await update_config(db, {"mixes": {"discover_enabled": False}})
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        # The 90s rock is all of the rock, so no extra "90er Rock".
        assert {key for key in result if key.startswith("era:")} == {"era:1990:hip hop", "era:2010:hip hop"}
        era = result["era:1990:hip hop"]
        assert (era.name, era.description) == ("90er Hip-Hop", "Hip-Hop aus den 90ern in deiner Bibliothek")
        assert {row.track_id for row in await entries(db, era)} == {track.id for track in rap90}
        # Only songs played at least twice in the last 30 days, most played first.
        assert result.get("on-repeat") is None
        plays(db, env.user_id, rap90[6], 3, days=1)
        plays(db, env.user_id, rap90[7], 2, days=1)
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, env.user_id))
        result = await generated(db, env.user_id)
        on_repeat = [row.track_id for row in await entries(db, result["on-repeat"])]
        assert on_repeat[0] == rap90[6].id and set(on_repeat) == {t.id for t in [*rap90[:3], rap90[6], rap90[7]]}
        rapper = await db.scalar(select(Track.artist_id).where(Track.id == rap90[0].id))
        artist_mix = result[f"artist:{rapper}"]
        assert (artist_mix.name, artist_mix.description) == ("Rapper Mix", "Rapper und ähnliche Künstler")
        ids = {row.track_id for row in await entries(db, artist_mix)}
        assert {t.id for t in rap90} <= ids and len(ids & {t.id for t in rap10}) == 3
    body = (await env.client.get("/api/mixes", headers={**env.headers, "Accept-Language": "en"})).json()
    names = [row["name"] for row in body["decades"]]
    assert "90s Hip-Hop" in names and "2010s Hip-Hop" in names
    assert "On Repeat" in [row["name"] for row in body["made_for_you"]]
    response = await env.client.get("/api/search", params={"q": "90s hip hop"}, headers=env.headers)
    assert [row["name"] for row in response.json()["playlists"]] == ["90er Hip-Hop"]


@pytest.fixture
def charts(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    env.downloads = []
    env.download_errors = {}

    async def request(
        db: AsyncSession, user: User, kind: str, catalog_id: str, *, temporary: bool, radio: bool
    ) -> None:
        env.downloads.append((catalog_id, user.id, temporary, radio))
        if catalog_id in env.download_errors:
            raise HTTPException(env.download_errors[catalog_id], "Nicht gefunden")
        db.add(
            DownloadRequest(
                user_id=user.id, kind=kind, catalog_id=catalog_id, title=catalog_id, artist="Chart", status="active",
                is_temporary=temporary,
                items=[
                    DownloadItem(
                        position=0, title=catalog_id, artist="Chart", meta={"deezer_track_id": catalog_id},
                        status="queued",
                    )
                ],
            )
        )
        await db.commit()

    monkeypatch.setattr(mixes, "create_request", request)
    return env


def chart_candidate(id: str, title: str | None = None) -> dict:
    return {"id": id, "title": title or id, "artist": {"id": "chart", "name": "Chart"}, "duration": 180}


async def chart_pending(db: AsyncSession, playlist: Playlist) -> list[tuple[str, float | None]]:
    rows = await db.scalars(
        select(RadioPending).where(RadioPending.playlist_id == playlist.id).order_by(RadioPending.position)
    )
    return [(row.deezer_id, row.position) for row in rows]


@pytest.mark.parametrize("temporary", [False, True])
async def test_charts_order_positions_and_downloads_shared_daily(charts: SimpleNamespace, temporary: bool) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Chart", None, 3)
        charts.charts = {
            "1111143121": [
                chart_candidate("103", tracks[2].title), chart_candidate("201"),
                chart_candidate("101", tracks[0].title), chart_candidate("103", tracks[2].title),
                chart_candidate("202"), chart_candidate("102", tracks[1].title),
            ],
            "3155776842": [chart_candidate("201"), chart_candidate("102", tracks[1].title), chart_candidate("203")],
        }
        await update_config(
            db, {"mixes": {"charts_downloads": 2}, "radio": {"temporary_tracks_enabled": temporary}}
        )
        for user_id in (charts.user_id, charts.other_id, charts.user_id):
            await mixes.generate_mixes(db, await db.get(User, user_id))
            result = await generated(db, user_id)
            assert set(result) == set(mixes.CHARTS)
            de = result["chart:de"]
            assert [(row.track_id, row.position) for row in await entries(db, de)] == [
                (tracks[2].id, 1), (tracks[0].id, 3), (tracks[1].id, 6),
            ]
            assert await chart_pending(db, de) == [("201", 2), ("202", 5)]
            assert await chart_pending(db, result["chart:global"]) == [("201", 1), ("203", 3)]
            assert de.kind == "mix" and not de.is_public
            assert de.description == "Die aktuellen Charts – täglich aktualisiert"
        assert charts.downloads == [(id, charts.user_id, temporary, True) for id in ("201", "202", "203")]
        assert charts.chart_calls == [("1111143121", 100), ("3155776842", 100)]
        assert mixes._chart_requested == dict.fromkeys(mixes.CHARTS, date.today())


async def test_chart_pending_resolves_at_chart_rank(charts: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Chart", None, 2)
        charts.charts["1111143121"] = [
            chart_candidate("101", tracks[0].title), chart_candidate("201"), chart_candidate("102", tracks[1].title),
        ]
        await db.commit()
        await mixes.generate_mixes(db, await db.get(User, charts.user_id))
        playlist = (await generated(db, charts.user_id))["chart:de"]
        assert await chart_pending(db, playlist) == [("201", 2)]
        downloaded = (await library(db, "Downloaded", None, 1, temporary=True))[0]
        item = await db.scalar(select(DownloadItem).where(DownloadItem.meta["deezer_track_id"].astext == "201"))
        item.track_id = downloaded.id
        item.status = "done"
        await db.commit()
        assert await radio.resolve_radio_pending(db) == 1
        assert [(row.track_id, row.position) for row in await entries(db, playlist)] == [
            (tracks[0].id, 1), (downloaded.id, 2), (tracks[1].id, 3),
        ]
        assert await chart_pending(db, playlist) == []


async def test_chart_cache_daily_refresh_and_deezer_failure(env: SimpleNamespace) -> None:
    first = [chart_candidate("101")]
    env.charts["1111143121"] = first
    assert await mixes.chart_tracks("chart:de") is first
    assert await mixes.chart_tracks("chart:de") is first
    assert len(env.chart_calls) == 1
    yesterday = date.today() - timedelta(days=1)
    mixes._chart_cache["chart:de"] = (yesterday, first)
    second = [chart_candidate("102")]
    env.charts["1111143121"] = second
    assert await mixes.chart_tracks("chart:de") is second
    assert mixes._chart_cache["chart:de"] == (date.today(), second)
    mixes._chart_cache["chart:de"] = (yesterday, second)
    env.failures.add("charts")
    assert await mixes.chart_tracks("chart:de") is second
    assert mixes._chart_cache["chart:de"][0] == yesterday
    assert await mixes.chart_tracks("chart:global") is None


async def test_chart_deezer_failure_keeps_yesterdays_playlist(env: SimpleNamespace) -> None:
    yesterday = datetime.now(UTC) - timedelta(days=1)
    env.failures.add("charts")
    async with SessionLocal() as db:
        track = (await library(db, "Chart", None, 1))[0]
        user = await db.get(User, env.user_id)
        playlist = await mixes._write(
            db, user, "chart:de", "Top 100 Deutschland", "Die aktuellen Charts – täglich aktualisiert",
            [track.id], yesterday, ["201"], pending_positions={"201": 2},
        )
        await db.commit()
        await mixes.generate_mixes(db, user)
        result = await generated(db, env.user_id)
        assert set(result) == {"chart:de"}
        assert result["chart:de"].id == playlist.id
        assert result["chart:de"].generated_at == yesterday
        assert [(row.track_id, row.position) for row in await entries(db, playlist)] == [(track.id, 1)]
        assert await chart_pending(db, playlist) == [("201", 2)]


async def test_charts_disabled_deletes_existing_playlists(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        track = (await library(db, "Chart", None, 1))[0]
        for _, id in mixes.CHARTS.values():
            env.charts[id] = [chart_candidate("101", track.title)]
        await db.commit()
        user = await db.get(User, env.user_id)
        await mixes.generate_mixes(db, user)
        assert set(await generated(db, user.id)) == set(mixes.CHARTS)
        await update_config(db, {"mixes": {"charts_enabled": False}})
        await mixes.generate_mixes(db, user)
        assert await generated(db, user.id) == {}
        await mixes.generate_mixes(db, await db.get(User, env.other_id))
        assert await generated(db, env.other_id) == {}
        assert len(env.chart_calls) == 2


async def test_charts_api_english_names_and_search(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        track = (await library(db, "Chart", None, 1))[0]
        for _, id in mixes.CHARTS.values():
            env.charts[id] = [chart_candidate("101", track.title)]
        await db.commit()
    headers = {**env.headers, "Accept-Language": "en"}
    response = await env.client.get("/api/mixes", headers=headers)
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["made_for_you"] == []
    assert [row["name"] for row in body["charts"]] == ["Top 100 Germany", "Top 100 Global"]
    assert all(row["description"] == "The current charts – updated daily" for row in body["charts"])
    response = await env.client.get("/api/search", params={"q": "charts"}, headers=headers)
    assert response.status_code == 200, response.text
    assert {row["name"] for row in response.json()["playlists"]} == {"Top 100 Germany", "Top 100 Global"}
    assert mixes.mix_search_terms("chart:de") == ["charts", "top 100", "top 100 germany", "deutschland charts"]
    assert mixes.mix_search_terms("chart:global") == ["charts", "top 100", "top 100 global", "world", "weltweit"]


@pytest.mark.parametrize("limit", [0, 1])
async def test_chart_downloads_recent_nonfailed_items_and_limit(charts: SimpleNamespace, limit: int) -> None:
    async with SessionLocal() as db:
        user = await db.get(User, charts.user_id)
        for id in ("201", "202", "203"):
            await mixes.create_request(db, user, "track", id, temporary=False, radio=True)
        failed = await db.scalar(select(DownloadItem).where(DownloadItem.meta["deezer_track_id"].astext == "202"))
        failed.status = "failed"
        old = await db.scalar(select(DownloadItem).where(DownloadItem.meta["deezer_track_id"].astext == "203"))
        old.created_at = datetime.now(UTC) - timedelta(days=8)
        await update_config(db, {"mixes": {"charts_downloads": limit}})
        charts.downloads.clear()
        charts.charts["1111143121"] = [chart_candidate(id) for id in ("201", "202", "203", "204")]
        await mixes.generate_mixes(db, user)
        playlist = (await generated(db, user.id))["chart:de"]
        assert await entries(db, playlist) == []
        assert await chart_pending(db, playlist) == ([("201", 1), ("202", 2)] if limit else [("201", 1)])
        assert [call[0] for call in charts.downloads] == (["202"] if limit else [])
        if limit:
            mixes._chart_requested["chart:de"] = date.today() - timedelta(days=1)
            await mixes.generate_mixes(db, user)
            assert [call[0] for call in charts.downloads] == ["202", "203"]
        else:
            assert mixes._chart_requested == {}


@pytest.mark.parametrize("status", [429, 502])
async def test_chart_download_errors_and_empty_taste(charts: SimpleNamespace, status: int) -> None:
    charts.charts["1111143121"] = [chart_candidate(id) for id in ("201", "202", "203")]
    charts.download_errors["201"] = status
    async with SessionLocal() as db:
        for user_id in (charts.user_id, charts.other_id):
            await mixes.generate_mixes(db, await db.get(User, user_id))
            result = await generated(db, user_id)
            if status == 429:
                assert result == {}
            else:
                assert set(result) == {"chart:de"}
                assert await chart_pending(db, result["chart:de"]) == [("202", 2), ("203", 3)]
        assert [call[0] for call in charts.downloads] == (["201"] if status == 429 else ["201", "202", "203"])
        assert mixes._chart_requested["chart:de"] == date.today()


@pytest.mark.parametrize("limit", [-1, 101])
def test_charts_config_download_bounds(limit: int) -> None:
    assert ServerConfig().mixes.charts_enabled
    assert ServerConfig().mixes.charts_downloads == 100
    with pytest.raises(ValidationError):
        ServerConfig.model_validate({"mixes": {"charts_downloads": limit}})


async def test_app_requests_leave_chart_downloads_to_the_scheduler(charts: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        charts.charts = {id: [chart_candidate("201")] for _, id in mixes.CHARTS.values()}
        await db.commit()
    response = await charts.client.get("/api/mixes", headers=charts.headers)
    assert response.status_code == 200, response.text
    assert charts.downloads == [] and mixes._chart_requested == {}
    async with SessionLocal() as db:
        await mixes.generate_mixes(db, await db.get(User, charts.user_id))
    assert [download[0] for download in charts.downloads] == ["201"]


async def test_chart_playlist_entries_carry_their_rank(charts: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Chart", None, 2)
        charts.charts = {
            id: [chart_candidate("101", tracks[1].title), chart_candidate("201"), chart_candidate("102", tracks[0].title)]
            for _, id in mixes.CHARTS.values()
        }
        await mixes.generate_mixes(db, await db.get(User, charts.user_id))
        chart_id = (await generated(db, charts.user_id))["chart:de"].id
    response = await charts.client.get(f"/api/playlists/{chart_id}", headers=charts.headers)
    assert response.status_code == 200, response.text
    assert [(row["track"]["title"], row["rank"]) for row in response.json()["entries"]] == [
        (tracks[1].title, 1),
        (tracks[0].title, 3),
    ]


async def test_scheduler_requests_chart_songs_after_the_app_built_the_mixes(charts: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Chart", None, 1)
        charts.charts = {
            id: [chart_candidate("101", tracks[0].title), chart_candidate("201"), chart_candidate("202")]
            for _, id in mixes.CHARTS.values()
        }
        await db.commit()
    # The app built today's mixes first: nothing requested, nothing pending.
    assert (await charts.client.get("/api/mixes", headers=charts.headers)).status_code == 200
    assert charts.downloads == []
    await mixes.refresh_chart_downloads()
    assert sorted(download[0] for download in charts.downloads) == ["201", "202"]
    assert {download[1] for download in charts.downloads} == {charts.user_id}
    async with SessionLocal() as db:
        de = (await generated(db, charts.user_id))["chart:de"]
        assert await chart_pending(db, de) == [("201", 2), ("202", 3)]
    # Once per day; pending rows are not duplicated.
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 2
    async with SessionLocal() as db:
        assert len(await chart_pending(db, (await generated(db, charts.user_id))["chart:de"])) == 2
