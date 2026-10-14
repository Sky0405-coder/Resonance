import asyncio
import json
import uuid
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import httpx
import pytest
from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.main import app
from app.models import AudiobookshelfAccount
from app.services import audiobookshelf as abs_service
from app.services.server_config import AudiobookshelfConfig, ServerConfig, update_config
from pydantic import ValidationError

from tests.conftest import auth, register


class RawStream(httpx.AsyncByteStream):
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.closed = False

    async def __aiter__(self):
        yield self.data[:2]
        yield self.data[2:]

    async def aclose(self) -> None:
        self.closed = True


def response(
    code: int = 200, *, body: bytes | None = None, data: dict | None = None, headers: dict | None = None
) -> httpx.Response:
    if data is not None:
        body = json.dumps(data, separators=(",", ":")).encode()
        headers = {"content-type": "application/json", **(headers or {})}
    return httpx.Response(code, stream=RawStream(body or b""), headers=headers)


@pytest.fixture
async def env(client, monkeypatch):
    assert engine.url.database.startswith("app_test")
    await abs_service.close()
    abs_service._refresh_locks.clear()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    admin = await register(client, "admin")
    invite = (await client.post("/api/admin/invites", json={}, headers=auth(admin["token"]))).json()["token"]
    user = await register(client, "user", invite)
    seen = []
    handler = SimpleNamespace(fn=None)

    async def dispatch(request):
        seen.append(request)
        if handler.fn is not None:
            result = handler.fn(request)
            return await result if hasattr(result, "__await__") else result
        if request.url.path == "/login":
            body = json.loads(request.content)
            return response(
                data={
                    "user": {
                        "id": "abs-" + body["username"],
                        "username": body["username"],
                        "accessToken": "access-" + body["username"],
                        "refreshToken": "refresh-" + body["username"],
                    }
                }
            )
        if request.url.path == "/auth/refresh":
            return response(data={"user": {"accessToken": "rotated-access", "refreshToken": "rotated-refresh"}})
        if request.url.path == "/status":
            return response(data={"serverVersion": "2.34.0"})
        if request.url.path == "/logout":
            return response()
        return response(
            data={"original": ["ABS", {"untouched": True}], "authorization": request.headers.get("authorization")}
        )

    factory = httpx.AsyncClient
    monkeypatch.setattr(
        abs_service,
        "_client_factory",
        lambda: factory(transport=httpx.MockTransport(dispatch), timeout=httpx.Timeout(30, connect=10, read=None)),
    )
    async with SessionLocal() as db:
        await update_config(db, {"audiobookshelf": {"enabled": True, "url": "https://abs.example/"}})
    yield SimpleNamespace(
        client=client, admin=admin, user=user, headers=auth(admin["token"]), seen=seen, handler=handler
    )
    await abs_service.close()
    abs_service._refresh_locks.clear()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)


async def link(env, user=None, username="reader"):
    user = user or env.admin
    result = await env.client.post(
        "/api/abs/login", headers=auth(user["token"]), json={"username": username, "password": "secret"}
    )
    assert result.status_code == 200, result.text
    return result


async def expire(env, user=None, *, fresh=False):
    user = user or env.admin
    async with SessionLocal() as db:
        account = await db.get(AudiobookshelfAccount, uuid.UUID(user["user"]["id"]))
        account.access_expires_at = datetime.now(UTC) + (timedelta(minutes=10) if fresh else -timedelta(minutes=1))
        await db.commit()


def test_config_validation():
    assert not ServerConfig().audiobookshelf.enabled
    assert ServerConfig().audiobookshelf.url == ""
    for url in ("https://abs.example///", "http://abs.example/"):
        assert AudiobookshelfConfig(url=url).url == url.rstrip("/")
    for url in ("ftp://abs.example", "abs.example", "javascript:alert(1)"):
        with pytest.raises(ValidationError, match="Ungültige Adresse"):
            AudiobookshelfConfig(url=url)


async def test_status_login_and_upsert(env):
    unlinked = await env.client.get("/api/abs/status", headers=env.headers)
    assert unlinked.json() == {"enabled": True, "url": "https://abs.example", "linked": False, "username": None}
    result = await link(env)
    assert result.json() == {"enabled": True, "url": "https://abs.example", "linked": True, "username": "reader"}
    assert env.seen[0].headers["x-return-tokens"] == "true"
    assert json.loads(env.seen[0].content) == {"username": "reader", "password": "secret"}
    assert env.seen[0].extensions["timeout"] == {"connect": 20, "read": 20, "write": 20, "pool": 20}
    assert "accessToken" not in result.text and "refreshToken" not in result.text
    async with SessionLocal() as db:
        account = await db.get(AudiobookshelfAccount, uuid.UUID(env.admin["user"]["id"]))
        assert (account.abs_user_id, account.refresh_token, account.access_token) == (
            "abs-reader",
            "refresh-reader",
            "access-reader",
        )
        assert (
            datetime.now(UTC) + timedelta(minutes=49)
            < account.access_expires_at
            < datetime.now(UTC) + timedelta(minutes=51)
        )
    await link(env, username="other")
    result = await env.client.get("/api/abs/status", headers=env.headers)
    assert result.json()["username"] == "other"


@pytest.mark.parametrize(
    "code,expected,message",
    [
        (401, 401, "Benutzername oder Passwort falsch"),
        (503, 502, "Audiobookshelf-Fehler (HTTP 503)"),
        (302, 502, "Audiobookshelf-Fehler (HTTP 302)"),
    ],
)
async def test_login_http_errors(env, code, expected, message):
    env.handler.fn = lambda request: response(code)
    result = await env.client.post(
        "/api/abs/login", headers=env.headers, json={"username": "reader", "password": "secret"}
    )
    assert result.status_code == expected and result.json()["detail"] == message


async def test_unreachable_and_disabled(env):
    def unreachable(request):
        raise httpx.ConnectError("offline", request=request)

    env.handler.fn = unreachable
    result = await env.client.post(
        "/api/abs/login", headers=env.headers, json={"username": "reader", "password": "secret"}
    )
    assert result.status_code == 502 and result.json()["detail"] == "Audiobookshelf nicht erreichbar"
    for patch in ({"enabled": False}, {"enabled": True, "url": ""}):
        async with SessionLocal() as db:
            await update_config(db, {"audiobookshelf": patch})
        for endpoint in ("/api/abs/login", "/api/abs/api/libraries"):
            result = await env.client.request(
                "POST" if endpoint.endswith("login") else "GET",
                endpoint,
                headers=env.headers,
                json={"username": "reader", "password": "secret"},
            )
            assert result.status_code == 409 and result.json()["detail"] == "Audiobookshelf ist nicht eingerichtet"
    result = await env.client.patch(
        "/api/admin/config", headers=env.headers, json={"audiobookshelf": {"url": "ftp://invalid"}}
    )
    assert result.status_code == 422 and "Ungültige Adresse" in result.json()["detail"]


async def test_proxy_json_queries_headers_and_isolation(env):
    unlinked = await env.client.get("/api/abs/api/libraries", headers=env.headers)
    assert unlinked.status_code == 409 and unlinked.json()["detail"] == "Kein Audiobookshelf-Konto verbunden"
    await link(env)
    raw = b'{ "libraryItems": [{"id": "x"}], "unchanged": true }'
    stream = RawStream(raw)

    def handle(request):
        assert request.url.path == "/api/libraries"
        assert request.url.params.multi_items() == [("limit", "20"), ("filter", "a"), ("filter", "b")]
        assert request.headers["authorization"] == "Bearer access-reader"
        assert "cookie" not in request.headers
        assert request.headers["if-none-match"] == '"cached"'
        # Raw bytes are streamed through without Content-Encoding, so ABS must answer uncompressed.
        assert request.headers["accept-encoding"] == "identity"
        assert request.extensions["timeout"]["connect"] == 10
        assert request.extensions["timeout"]["read"] is None
        return httpx.Response(
            200,
            stream=stream,
            headers={
                "content-type": "application/json",
                "content-length": str(len(raw)),
                "etag": '"cached"',
                "cache-control": "max-age=10",
                "last-modified": "Wed, 14 Oct 2026 00:00:00 GMT",
                "set-cookie": "abs=private",
                "x-private": "secret",
            },
        )

    env.handler.fn = handle
    result = await env.client.get(
        "/api/abs/api/libraries",
        params=[("limit", "20"), ("token", env.admin["token"]), ("filter", "a"), ("filter", "b")],
        headers={"cookie": "browser=secret", "if-none-match": '"cached"'},
    )
    assert result.status_code == 200 and result.content == raw
    assert result.headers["etag"] == '"cached"' and result.headers["content-length"] == str(len(raw))
    assert result.headers["cache-control"] == "max-age=10"
    assert "last-modified" in result.headers
    assert "set-cookie" not in result.headers and "x-private" not in result.headers
    assert stream.closed
    other = await env.client.get("/api/abs/status", headers=auth(env.user["token"]))
    assert not other.json()["linked"]
    blocked = await env.client.get("/api/abs/api/libraries", headers=auth(env.user["token"]))
    assert blocked.status_code == 409
    env.handler.fn = None
    await link(env, env.user, username="second")
    other = await env.client.get("/api/abs/api/me", headers=auth(env.user["token"]))
    assert other.json()["authorization"] == "Bearer access-second"
    own = await env.client.get("/api/abs/api/me", headers=env.headers)
    assert own.json()["authorization"] == "Bearer access-reader"


@pytest.mark.parametrize("path", ["users", "config", "items-extra", "items/x/..hidden", "items/%2E%2E/x", "%2Fitems/x"])
async def test_disallowed_paths(env, path):
    result = await env.client.get("/api/abs/api/" + path, headers=env.headers)
    assert result.status_code == 404
    assert not env.seen


@pytest.mark.parametrize(
    "path", ["libraries", "items", "me", "session", "series", "authors", "collections", "playlists", "search"]
)
async def test_allowed_paths(env, path):
    await link(env)
    result = await env.client.get("/api/abs/api/" + path, headers=env.headers)
    assert result.status_code == 200
    assert env.seen[-1].url.path == "/api/" + path


async def test_range_audio_and_cover(env):
    await link(env)
    streams = []

    def handle(request):
        if request.url.path.endswith("/cover"):
            return response(body=b"jpeg", headers={"content-type": "image/jpeg"})
        assert request.headers["range"] == "bytes=2-5"
        stream = RawStream(b"2345")
        streams.append(stream)
        return httpx.Response(
            206,
            stream=stream,
            headers={
                "content-type": "audio/mp4",
                "content-length": "4",
                "content-range": "bytes 2-5/10",
                "accept-ranges": "bytes",
            },
        )

    env.handler.fn = handle
    result = await env.client.get(
        "/api/abs/api/items/x/file/ino", params={"token": env.admin["token"]}, headers={"range": "bytes=2-5"}
    )
    assert result.status_code == 206 and result.content == b"2345"
    assert result.headers["content-range"] == "bytes 2-5/10" and result.headers["accept-ranges"] == "bytes"
    assert streams[0].closed
    cover = await env.client.get("/api/abs/api/items/x/cover", params={"token": env.admin["token"]})
    assert cover.status_code == 200 and cover.content == b"jpeg"


@pytest.mark.parametrize("method", ["POST", "PATCH", "DELETE"])
async def test_raw_body_forwarding(env, method):
    await link(env)
    raw = b'{"forceDirectPlay":true, "mediaPlayer":"resonance", "deviceInfo": {"clientName":"Resonance"}}'

    def handle(request):
        assert request.method == method
        assert request.content == raw
        assert request.headers["content-type"] == "application/json"
        assert request.headers["authorization"] == "Bearer access-reader"
        assert "cookie" not in request.headers
        return response(data={"audioTracks": [{"contentUrl": "/api/items/x/file/ino"}]})

    env.handler.fn = handle
    result = await env.client.request(
        method, "/api/abs/api/items/x/play", headers={**env.headers, "content-type": "application/json"}, content=raw
    )
    assert result.json() == {"audioTracks": [{"contentUrl": "/api/items/x/file/ino"}]}


async def test_expired_token_and_rotation(env):
    await link(env)
    await expire(env)
    result = await env.client.get("/api/abs/api/libraries", headers=env.headers)
    assert result.status_code == 200
    refresh = [r for r in env.seen if r.url.path == "/auth/refresh"]
    assert len(refresh) == 1 and refresh[0].headers["x-refresh-token"] == "refresh-reader"
    assert result.json()["authorization"] == "Bearer rotated-access"
    async with SessionLocal() as db:
        account = await db.get(AudiobookshelfAccount, uuid.UUID(env.admin["user"]["id"]))
        assert account.refresh_token == "rotated-refresh"
        assert account.access_token == "rotated-access"
    await env.client.get("/api/abs/api/libraries", headers=env.headers)
    assert len([r for r in env.seen if r.url.path == "/auth/refresh"]) == 1


async def test_access_401_forces_one_refresh_and_retry(env):
    await link(env)
    attempts = []
    streams = []

    def handle(request):
        if request.url.path == "/auth/refresh":
            return response(data={"user": {"accessToken": "new", "refreshToken": "new-refresh"}})
        attempts.append(request.headers["authorization"])
        result = response(401 if len(attempts) == 1 else 200, data={"ok": True})
        streams.append(result.stream)
        return result

    env.handler.fn = handle
    result = await env.client.get("/api/abs/api/me", headers=env.headers)
    assert result.status_code == 200 and result.json() == {"ok": True}
    assert attempts == ["Bearer access-reader", "Bearer new"]
    assert all(stream.closed for stream in streams)
    assert len([r for r in env.seen if r.url.path == "/auth/refresh"]) == 1


async def test_two_concurrent_requests_refresh_once(env):
    await link(env)
    await expire(env)
    entered = asyncio.Event()
    release = asyncio.Event()
    refreshes = []

    async def handle(request):
        if request.url.path == "/auth/refresh":
            refreshes.append(request.headers["x-refresh-token"])
            entered.set()
            await release.wait()
            return response(data={"user": {"accessToken": "new", "refreshToken": "new-refresh"}})
        assert request.headers["authorization"] == "Bearer new"
        return response(data={"ok": True})

    env.handler.fn = handle
    first = asyncio.create_task(env.client.get("/api/abs/api/me", headers=env.headers))
    await asyncio.wait_for(entered.wait(), 5)
    second = asyncio.create_task(env.client.get("/api/abs/api/libraries", headers=env.headers))
    await asyncio.sleep(0.05)
    release.set()
    results = await asyncio.wait_for(asyncio.gather(first, second), 5)
    assert all(r.status_code == 200 for r in results)
    assert refreshes == ["refresh-reader"]
    async with SessionLocal() as db:
        account = await db.get(AudiobookshelfAccount, uuid.UUID(env.admin["user"]["id"]))
        assert account.refresh_token == "new-refresh"


async def test_failed_refresh_deletes_account(env):
    await link(env)
    await expire(env)
    env.handler.fn = lambda request: response(401)
    result = await env.client.get("/api/abs/api/me", headers=env.headers)
    assert result.status_code == 401
    assert result.json()["detail"] == "Audiobookshelf-Anmeldung abgelaufen – bitte neu anmelden"
    async with SessionLocal() as db:
        assert await db.get(AudiobookshelfAccount, uuid.UUID(env.admin["user"]["id"])) is None
    result = await env.client.get("/api/abs/status", headers=env.headers)
    assert not result.json()["linked"]


async def test_401_after_retry_keeps_account(env):
    await link(env)

    def handle(request):
        if request.url.path == "/auth/refresh":
            return response(data={"user": {"accessToken": "new", "refreshToken": "new-refresh"}})
        return response(401)

    env.handler.fn = handle
    result = await env.client.get("/api/abs/api/me", headers=env.headers)
    assert result.status_code == 401
    assert result.json()["detail"] == "Audiobookshelf-Anmeldung abgelaufen – bitte neu anmelden"
    assert len([r for r in env.seen if r.url.path == "/api/me"]) == 2
    async with SessionLocal() as db:
        assert await db.get(AudiobookshelfAccount, uuid.UUID(env.admin["user"]["id"])) is not None


@pytest.mark.parametrize("unreachable", [False, True])
async def test_logout_best_effort(env, unreachable):
    await link(env)
    if unreachable:

        def handle(request):
            raise httpx.ConnectError("offline", request=request)

        env.handler.fn = handle
    result = await env.client.delete("/api/abs/login", headers=env.headers)
    assert result.status_code == 204 and not result.content
    assert env.seen[-1].url.path == "/logout"
    assert env.seen[-1].headers["x-refresh-token"] == "refresh-reader"
    assert not (await env.client.get("/api/abs/status", headers=env.headers)).json()["linked"]
    assert (await env.client.delete("/api/abs/login", headers=env.headers)).status_code == 204


async def test_admin_status(env):
    result = await env.client.get("/api/admin/abs/status", headers=env.headers)
    assert result.json() == {"ok": True, "message": "Version 2.34.0"}
    assert (await env.client.get("/api/admin/abs/status", headers=auth(env.user["token"]))).status_code == 403
    env.handler.fn = lambda request: response(503)
    result = await env.client.get("/api/admin/abs/status", headers=env.headers)
    assert result.json() == {"ok": False, "message": "Audiobookshelf nicht erreichbar"}
    async with SessionLocal() as db:
        await update_config(db, {"audiobookshelf": {"url": ""}})
    result = await env.client.get("/api/admin/abs/status", headers=env.headers)
    assert result.json() == {"ok": False, "message": "Keine Adresse eingetragen"}


async def test_user_delete_cascades_account(env):
    await link(env, env.user)
    result = await env.client.delete("/api/admin/users/" + env.user["user"]["id"], headers=env.headers)
    assert result.status_code == 204
    async with SessionLocal() as db:
        assert await db.get(AudiobookshelfAccount, uuid.UUID(env.user["user"]["id"])) is None


async def test_shutdown_closes_shared_client(env):
    await link(env)
    shared = abs_service._get_client()
    assert abs_service._get_client() is shared
    from app.services import importer

    await importer.stop()
    workers = get_settings().download_workers
    assert workers == 0
    async with app.router.lifespan_context(app):
        assert not shared.is_closed
    assert shared.is_closed
    assert abs_service._client is None
