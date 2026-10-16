import io
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from PIL import Image

from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import Playlist
from tests.conftest import auth, register


def image() -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (80, 80), "blue").save(buf, "PNG")
    return buf.getvalue()


@pytest.fixture
async def env(
    client: httpx.AsyncClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    monkeypatch.setattr(get_settings(), "data_dir", tmp_path)
    owner = await register(client, "owner")
    headers = auth(owner["token"])
    invite = (await client.post("/api/admin/invites", headers=headers, json={})).json()["token"]
    shared = await register(client, "shared", invite)
    invite = (await client.post("/api/admin/invites", headers=headers, json={})).json()["token"]
    other = await register(client, "other", invite)
    playlist = (await client.post("/api/playlists", headers=headers, json={"name": "Cover"})).json()
    yield SimpleNamespace(
        client=client,
        owner=owner,
        headers=headers,
        shared=shared,
        other=other,
        id=playlist["id"],
        url=f"/api/playlists/{playlist['id']}/cover",
    )
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)


async def test_upload_visibility_and_delete(env: SimpleNamespace) -> None:
    result = await env.client.put(env.url, headers=env.headers, files={"file": ("cover.png", image(), "image/png")})
    assert result.status_code == 200, result.text
    key = result.json()["cover_key"]
    assert key.endswith(".jpg")
    assert (await env.client.get("/api/playlists", headers=env.headers)).json()[0]["cover_key"] == key
    detail = await env.client.get(f"/api/playlists/{env.id}", headers=env.headers)
    assert detail.json()["cover_key"] == key
    result = await env.client.put(
        f"/api/playlists/{env.id}/shares", headers=env.headers, json={"user_ids": [env.shared["user"]["id"]]}
    )
    assert result.status_code == 200
    for user in (env.owner, env.shared):
        result = await env.client.get(env.url, params={"size": 64}, headers=auth(user["token"]))
        assert result.status_code == 200
        assert result.headers["content-type"] == "image/jpeg"
        assert result.headers["cache-control"] == "private, max-age=604800"
        with Image.open(io.BytesIO(result.content)) as cover:
            assert cover.format == "JPEG" and cover.size == (64, 64)
    assert (await env.client.get(env.url, headers=auth(env.other["token"]))).status_code == 404
    await env.client.patch(f"/api/playlists/{env.id}", headers=env.headers, json={"is_public": True})
    assert (await env.client.get(env.url, headers=auth(env.other["token"]))).status_code == 200
    assert (await env.client.delete(env.url, headers=env.headers)).status_code == 204
    assert (await env.client.get(env.url, headers=env.headers)).status_code == 404
    assert (await env.client.get(f"/api/playlists/{env.id}", headers=env.headers)).json()["cover_key"] is None


@pytest.mark.parametrize(
    "data,code,detail",
    [(b"bad image", 422, "Kein gültiges Bild"), (b"x" * (10 * 1024 * 1024 + 1), 413, "Bild zu groß")],
    ids=["garbage", "oversized"],
)
async def test_invalid_upload(env: SimpleNamespace, data: bytes, code: int, detail: str) -> None:
    result = await env.client.put(env.url, headers=env.headers, files={"file": ("image", data)})
    assert result.status_code == code and result.json()["detail"] == detail
    assert (await env.client.get(env.url, headers=env.headers)).status_code == 404


@pytest.mark.parametrize("kind", ["mix", "radio"])
async def test_generated_playlist(env: SimpleNamespace, kind: str) -> None:
    async with SessionLocal() as db:
        playlist = await db.get(Playlist, uuid.UUID(env.id))
        playlist.kind = kind
        await db.commit()
    result = await env.client.put(env.url, headers=env.headers, files={"file": ("cover.png", image())})
    assert result.status_code == 409 and result.json()["detail"] == "Nur eigene Playlists können ein Cover haben"
    result = await env.client.put(
        env.url, headers={**env.headers, "Accept-Language": "en"}, files={"file": ("cover.png", image())}
    )
    assert result.json()["detail"] == "Only user playlists can have a cover"


@pytest.mark.parametrize("visibility", ["private", "shared", "public"])
async def test_non_owner_cannot_change_cover(env: SimpleNamespace, visibility: str) -> None:
    if visibility == "shared":
        await env.client.put(
            f"/api/playlists/{env.id}/shares", headers=env.headers, json={"user_ids": [env.shared["user"]["id"]]}
        )
    elif visibility == "public":
        await env.client.patch(f"/api/playlists/{env.id}", headers=env.headers, json={"is_public": True})
    headers = auth(env.shared["token"])
    result = await env.client.put(env.url, headers=headers, files={"file": ("cover.png", image())})
    assert result.status_code == 404
    assert (await env.client.delete(env.url, headers=headers)).status_code == 404


async def test_subsonic_custom_cover(env: SimpleNamespace) -> None:
    await env.client.put(env.url, headers=env.headers, files={"file": ("cover.png", image())})
    password = (await env.client.post("/api/me/subsonic-password", headers=env.headers)).json()["password"]
    params = {"u": "owner", "p": password, "v": "1.16.1", "c": "test", "f": "json", "id": env.id}
    result = await env.client.get("/rest/getCoverArt", params={**params, "size": 64})
    assert result.status_code == 200 and result.headers["content-type"] == "image/jpeg"
    assert result.content == (await env.client.get(env.url, headers=env.headers, params={"size": 64})).content
    result = await env.client.get("/rest/getPlaylist", params=params)
    assert result.json()["subsonic-response"]["playlist"]["coverArt"] == env.id
