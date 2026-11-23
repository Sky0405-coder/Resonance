from collections.abc import AsyncIterator
from types import SimpleNamespace

import httpx
import pytest
from sqlalchemy import select

from app.db import Base, SessionLocal, engine
from app.models import Playlist, User
from tests.conftest import auth, register


@pytest.fixture
async def env(client: httpx.AsyncClient) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    owner = auth((await register(client, "owner"))["token"])
    invite = (await client.post("/api/admin/invites", headers=owner, json={})).json()["token"]
    other = auth((await register(client, "other", invite))["token"])
    public = (await client.post("/api/playlists", headers=owner, json={"name": "Roadtrip", "is_public": True})).json()
    async with SessionLocal() as db:
        owner_id = await db.scalar(select(User.id).where(User.username == "owner"))
        mix = Playlist(owner_id=owner_id, name="Daily Mix 1", kind="mix", mix_key="daily:1")
        db.add(mix)
        await db.commit()
        mix_id = str(mix.id)
    yield SimpleNamespace(client=client, owner=owner, other=other, public=public["id"], mix=mix_id)


async def _library(env: SimpleNamespace, headers: dict) -> dict[str, bool]:
    response = await env.client.get("/api/playlists", headers=headers)
    assert response.status_code == 200
    return {p["name"]: p["saved"] for p in response.json()}


async def test_saving_another_users_public_playlist(env: SimpleNamespace) -> None:
    assert "Roadtrip" not in await _library(env, env.other), "others' public playlists are found by searching"
    detail = (await env.client.get(f"/api/playlists/{env.public}", headers=env.other)).json()
    assert detail["saved"] is False
    for _ in range(2):
        assert (await env.client.put(f"/api/playlists/{env.public}/saved", headers=env.other)).status_code == 204
    assert (await _library(env, env.other))["Roadtrip"] is True
    assert (await env.client.get(f"/api/playlists/{env.public}", headers=env.other)).json()["saved"] is True
    # Only the one who saved it.
    assert (await _library(env, env.owner))["Roadtrip"] is False

    # Made private, it leaves the library; public again, it is back.
    await env.client.patch(f"/api/playlists/{env.public}", headers=env.owner, json={"is_public": False})
    assert "Roadtrip" not in await _library(env, env.other)
    assert (await env.client.put(f"/api/playlists/{env.public}/saved", headers=env.other)).status_code == 404
    await env.client.patch(f"/api/playlists/{env.public}", headers=env.owner, json={"is_public": True})
    assert (await _library(env, env.other))["Roadtrip"] is True

    assert (await env.client.delete(f"/api/playlists/{env.public}/saved", headers=env.other)).status_code == 204
    assert "Roadtrip" not in await _library(env, env.other)


async def test_saving_a_mix(env: SimpleNamespace) -> None:
    assert (await _library(env, env.owner))["Daily Mix 1"] is False
    assert (await env.client.put(f"/api/playlists/{env.mix}/saved", headers=env.owner)).status_code == 204
    assert (await _library(env, env.owner))["Daily Mix 1"] is True
    # Another user's mixes stay private.
    assert (await env.client.put(f"/api/playlists/{env.mix}/saved", headers=env.other)).status_code == 404
