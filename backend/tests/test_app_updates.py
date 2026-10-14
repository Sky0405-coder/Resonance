import io
import zipfile
from types import SimpleNamespace

import pytest

from app.config import get_settings
from app.db import Base, engine
from tests.conftest import auth, register


@pytest.fixture
async def env(client, tmp_path, monkeypatch):
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    monkeypatch.setattr(get_settings(), "data_dir", tmp_path / "data")
    admin = await register(client, "admin")
    invite = (await client.post("/api/admin/invites", json={}, headers=auth(admin["token"]))).json()["token"]
    user = await register(client, "user", invite)
    yield SimpleNamespace(client=client, admin=auth(admin["token"]), user=auth(user["token"]), token=user["token"])
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


def apk() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("AndroidManifest.xml", "x")
    return buf.getvalue()


async def upload(env, data: bytes, code: int = 2, headers=None):
    return await env.client.put(
        "/api/admin/app/android",
        headers=headers or env.admin,
        data={"version_name": "1.0.1", "version_code": str(code)},
        files={"file": ("app.apk", data, "application/vnd.android.package-archive")},
    )


async def test_android_release_flow(env):
    assert (await env.client.get("/api/app/android", headers=env.user)).status_code == 404
    assert (await env.client.get("/api/app/android/apk", headers=env.user)).status_code == 404
    assert (await upload(env, apk(), headers=env.user)).status_code == 403
    assert (await upload(env, b"not an apk")).status_code == 422

    response = await upload(env, apk(), code=7)
    assert response.status_code == 200
    assert response.json()["version_code"] == 7

    info = (await env.client.get("/api/app/android", headers=env.user)).json()
    assert info["version_name"] == "1.0.1" and info["version_code"] == 7 and info["size"] == len(apk())
    # The app downloads with the token in the query string (no headers in the installer download).
    download = await env.client.get(f"/api/app/android/apk?token={env.token}")
    assert download.status_code == 200
    assert download.content == apk()
    assert download.headers["content-type"] == "application/vnd.android.package-archive"
    assert (await env.client.get("/api/app/android")).status_code == 401
