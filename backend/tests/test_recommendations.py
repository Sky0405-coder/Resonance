import random
import uuid
from collections import Counter
from types import SimpleNamespace

import pytest

from app.db import Base, SessionLocal, engine
from app.models import Album, TrackLike
from app.services import recommendations
from app.services.deezer import DeezerError, deezer
from tests.conftest import auth, register
from tests.test_radio import library_track


@pytest.fixture
async def env(client, monkeypatch, tmp_path):
    async def reset():
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)

    await reset()
    from app.config import get_settings

    monkeypatch.setattr(get_settings(), "music_dir", tmp_path)
    account = await register(client, "recommendations")
    state = SimpleNamespace(
        client=client, headers=auth(account["token"]), user_id=uuid.UUID(account["user"]["id"]), calls=[]
    )
    recommendations._related_cache.clear()

    async def by_isrc(isrc):
        state.calls.append(("isrc", isrc))
        return {"artist": {"id": 1}}

    async def artists(query, limit):
        state.calls.append(("search", query, limit))
        return [{"id": 9, "name": "Wrong"}, {"id": 1, "name": query.upper()}]

    async def related(artist_id, limit):
        state.calls.append(("related", artist_id, limit))
        return [{"id": 2, "name": "Related"}]

    monkeypatch.setattr(deezer, "track_by_isrc", by_isrc)
    monkeypatch.setattr(deezer, "search_artists", artists)
    monkeypatch.setattr(deezer, "artist_related", related)
    yield state
    recommendations._related_cache.clear()
    await reset()


async def request(env, seeds, **body):
    response = await env.client.post(
        "/api/recommendations", headers=env.headers, json={"track_ids": [str(t.id) for t in seeds], **body}
    )
    assert response.status_code == 200, response.text
    return response.json()


async def test_weighting_exclusions_cap_limit_and_track_shape(env, monkeypatch):
    class FixedRandom(random.Random):
        def random(self):
            return 0.5

    monkeypatch.setattr(recommendations.random, "Random", FixedRandom)
    async with SessionLocal() as db:
        seed = await library_track(db, isrc="SEED")
        for i in range(3):
            await library_track(db, f"Own {i}")
        related = [await library_track(db, f"Related {i}", artist_name="Related") for i in range(4)]
        db.add_all([TrackLike(user_id=env.user_id, track_id=track.id) for track in related])
        await db.commit()
    result = await request(env, [seed], exclude_ids=[str(related[0].id)], limit=4)
    assert len(result) == 4
    assert {row["id"] for row in result}.isdisjoint({str(seed.id), str(related[0].id)})
    assert [row["artist"]["name"] for row in result] == ["Related", "Related", "Seed Artist", "Seed Artist"]
    assert max(Counter(row["artist"]["name"] for row in result).values()) == 2
    track = result[0]
    library = await env.client.get(f"/api/tracks/{track['id']}", headers=env.headers)
    assert library.status_code == 200 and track == library.json()
    assert track["liked"]
    assert ("isrc", "SEED") in env.calls and ("related", "1", 10) in env.calls


async def test_fill_likes_before_random_and_cap_applies_to_all_stages(env):
    async with SessionLocal() as db:
        seed = await library_track(db)
        liked = [await library_track(db, f"Liked {i}", artist_name="Favourite") for i in range(3)]
        other = await library_track(db, "Other", artist_name="Other")
        db.add_all([TrackLike(user_id=env.user_id, track_id=track.id) for track in liked])
        await db.commit()
    result = await request(env, [seed], limit=10, exclude_ids=[str(liked[0].id)])
    assert len(result) == 3
    assert {row["id"] for row in result[:2]} == {str(track.id) for track in liked[1:]}
    assert result[-1]["id"] == str(other.id)
    excluded = [str(liked[0].id), *[row["id"] for row in result]]
    assert await request(env, [seed], limit=10, exclude_ids=excluded) == []


async def test_genres_require_two_seeds_and_use_album_fallback(env):
    async with SessionLocal() as db:
        first = await library_track(db, "First")
        second = await library_track(db, "Second", artist_name="Second")
        first.genre = "Rock"
        (await db.get(Album, second.album_id)).genre = "rock"
        match = await library_track(db, "Genre", artist_name="Genre")
        match.genre = "Rock; Pop"
        liked = await library_track(db, "Liked", artist_name="Favourite")
        db.add(TrackLike(user_id=env.user_id, track_id=liked.id))
        await db.commit()
    assert (await request(env, [first, second], limit=1))[0]["id"] == str(match.id)
    assert (await request(env, [first], limit=1))[0]["id"] == str(liked.id)


async def test_daily_order_and_cache_are_stable_and_cache_expires(env, monkeypatch):
    async with SessionLocal() as db:
        seed = await library_track(db)
        for i in range(12):
            await library_track(db, f"Song {i}", artist_name=f"Artist {i}")
        await db.commit()
    first = await request(env, [seed])
    calls = list(env.calls)
    assert await request(env, [seed, seed]) == first
    assert env.calls == calls
    assert ("search", "Seed Artist", 5) in calls
    cached_at, keys = recommendations._related_cache["seed artist"]
    recommendations._related_cache["seed artist"] = (cached_at - 24 * 3600, keys)
    await request(env, [seed])
    assert env.calls == calls * 2


async def test_top_five_seed_artists_are_weighted_by_occurrence(env):
    async with SessionLocal() as db:
        seeds = [await library_track(db, f"Seed {i}", artist_name=f"Artist {i}") for i in range(6)]
        seeds.append(await library_track(db, "Another", artist_name="Artist 5"))
        await db.commit()
    await request(env, seeds)
    searches = [call[1] for call in env.calls if call[0] == "search"]
    assert searches == ["Artist 5", "Artist 0", "Artist 1", "Artist 2", "Artist 3"]


@pytest.mark.parametrize("method", ["track_by_isrc", "search_artists", "artist_related"])
async def test_deezer_errors_still_fill_from_library(env, monkeypatch, method):
    async def fail(*args):
        raise DeezerError("offline")

    monkeypatch.setattr(deezer, method, fail)
    async with SessionLocal() as db:
        seed = await library_track(db, isrc="SEED" if method == "track_by_isrc" else None)
        other = await library_track(db, "Other", artist_name="Other")
        await db.commit()
    assert [row["id"] for row in await request(env, [seed])] == [str(other.id)]


async def test_auth_and_validation(env):
    valid = {"track_ids": [str(uuid.uuid4())]}
    assert (await env.client.post("/api/recommendations", json=valid)).status_code == 401
    for patch in (
        {"track_ids": []}, {"track_ids": valid["track_ids"] * 501}, {"track_ids": ["bad"]},
        {"limit": 0}, {"limit": 101}, {"exclude_ids": valid["track_ids"] * 2001},
    ):
        response = await env.client.post("/api/recommendations", json={**valid, **patch}, headers=env.headers)
        assert response.status_code == 422
