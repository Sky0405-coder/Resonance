import httpx
import pytest

from app.api import key_checks
from app.db import Base, engine
from tests.conftest import auth, register


@pytest.fixture
async def admin(client, monkeypatch):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    seen: list[httpx.Request] = []

    def dispatch(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        valid = "good" in str(request.url) or "good" in request.headers.get("Authorization", "")
        if request.url.host == "api.acoustid.org":
            if valid:
                return httpx.Response(200, json={"status": "ok", "results": []})
            return httpx.Response(400, json={"status": "error", "error": {"code": 4, "message": "invalid API key"}})
        if request.url.host == "ws.audioscrobbler.com":
            if valid:
                return httpx.Response(200, json={"artist": {"name": "Radiohead"}})
            return httpx.Response(403, json={"error": 10, "message": "Invalid API key"})
        if request.url.host == "accounts.spotify.com":
            return httpx.Response(200 if request.headers["Authorization"] == "Basic Z29vZDpnb29k" else 400, json={})
        if request.url.host == "discord.com":
            return httpx.Response(500)
        return httpx.Response(200 if valid else 401, json={})

    monkeypatch.setattr(
        key_checks, "_client_factory", lambda: httpx.AsyncClient(transport=httpx.MockTransport(dispatch))
    )
    user = await register(client, "admin")
    return auth(user["token"]), seen


async def test_keys_are_checked_against_their_services(client, admin):
    headers, seen = admin

    async def check(service: str, lang: str = "de") -> dict:
        r = await client.get(f"/api/admin/keys/{service}/check", headers={**headers, "Accept-Language": lang})
        assert r.status_code == 200, r.text
        return r.json()

    assert await check("lastfm") == {"ok": False, "message": "Kein Schlüssel eingetragen"}
    assert seen == []

    await client.patch("/api/admin/config", headers=headers, json={
        "library": {"acoustid_api_key": "good", "discogs_token": "bad", "lastfm_api_key": "bad",
                    "fanarttv_api_key": "good"},
        "spotify": {"client_id": "good", "client_secret": "good"},
        "integrations": {"discord_client_id": "123"},
    })
    assert await check("acoustid") == {"ok": True, "message": "Schlüssel gültig"}
    assert await check("discogs") == {"ok": False, "message": "Schlüssel ungültig"}
    assert seen[-1].headers["Authorization"] == "Discogs token=bad"
    assert await check("lastfm", "en") == {"ok": False, "message": "Key is invalid"}
    assert await check("fanarttv") == {"ok": True, "message": "Schlüssel gültig"}
    assert await check("spotify") == {"ok": True, "message": "Schlüssel gültig"}
    assert await check("discord") == {"ok": False, "message": "Dienst nicht erreichbar"}
    assert (await client.get("/api/admin/keys/unknown/check", headers=headers)).status_code == 422

    invite = (await client.post("/api/admin/invites", json={}, headers=headers)).json()["token"]
    user = await register(client, "user-without-rights", invite)
    assert (await client.get("/api/admin/keys/lastfm/check", headers=auth(user["token"]))).status_code in (401, 403)
