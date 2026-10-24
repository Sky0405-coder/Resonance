from types import SimpleNamespace

import pytest

from app.config import get_settings
from app.db import Base, engine
from app.services.sources.youtube import cookies_file
from tests.conftest import auth, register

COOKIES = (
    "# Netscape HTTP Cookie File\n"
    ".youtube.com\tTRUE\t/\tTRUE\t1893456000\tSID\tabc\n"
    "#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1893456000\tHSID\tdef\n"
)


@pytest.fixture
async def env(client, tmp_path, monkeypatch):
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    monkeypatch.setattr(get_settings(), "data_dir", tmp_path / "data")
    monkeypatch.setattr(get_settings(), "ytdlp_cookies_file", None)
    admin = await register(client, "admin")
    invite = (await client.post("/api/admin/invites", json={}, headers=auth(admin["token"]))).json()["token"]
    user = await register(client, "user", invite)
    yield SimpleNamespace(client=client, admin=auth(admin["token"]), user=auth(user["token"]))
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


async def upload(env, text: str, headers=None):
    return await env.client.put(
        "/api/admin/youtube-cookies",
        headers=headers or env.admin,
        files={"file": ("cookies.txt", text.encode(), "text/plain")},
    )


async def test_upload_status_and_delete(env) -> None:
    status = (await env.client.get("/api/admin/youtube-cookies", headers=env.admin)).json()
    assert status == {"configured": False, "from_env": False, "uploaded_at": None}
    assert cookies_file() is None
    response = await upload(env, COOKIES)
    assert response.status_code == 200 and response.json()["configured"] and response.json()["uploaded_at"]
    assert cookies_file() is not None and cookies_file().read_text() == COOKIES
    assert (cookies_file().stat().st_mode & 0o777) == 0o600
    response = await env.client.delete("/api/admin/youtube-cookies", headers=env.admin)
    assert response.json()["configured"] is False and cookies_file() is None


async def test_rejects_other_files_and_non_admins(env) -> None:
    assert (await upload(env, "hello")).status_code == 422
    assert (await upload(env, "# Netscape HTTP Cookie File\n.google.com\tTRUE\t/\tTRUE\t0\tSID\tx\n")).status_code == 422
    assert (await upload(env, COOKIES, headers=env.user)).status_code == 403
    assert (await env.client.get("/api/admin/youtube-cookies", headers=env.user)).status_code == 403
    assert cookies_file() is None


async def test_environment_file_wins(env, tmp_path, monkeypatch) -> None:
    configured = tmp_path / "env-cookies.txt"
    monkeypatch.setattr(get_settings(), "ytdlp_cookies_file", configured)
    await upload(env, COOKIES)
    assert cookies_file() == configured
    assert (await env.client.get("/api/admin/youtube-cookies", headers=env.admin)).json()["from_env"] is True
