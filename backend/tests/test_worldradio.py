import asyncio
import socket

import httpx
import pytest

from app.api import worldradio as api
from app.db import Base, engine
from app.services import worldradio as radio
from tests.conftest import auth, register


def station_data(id: str = "station-1", **overrides: object) -> dict:
    return {
        "stationuuid": id,
        "name": "Radio One",
        "country": "Germany",
        "countrycode": "DE",
        "tags": " rock, pop, , jazz , news, soul, extra",
        "favicon": "https://images.example/icon.png",
        "codec": "MP3",
        "bitrate": 128,
        "homepage": "https://radio.example",
        "hls": 0,
        "url_resolved": "http://stream.example/live",
        **overrides,
    }


@pytest.fixture
async def directory(monkeypatch: pytest.MonkeyPatch) -> list[httpx.Request]:
    requests: list[httpx.Request] = []
    radio._cache.clear()

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        path = request.url.path
        if path == "/json/countries":
            data = [
                {"iso_3166_1": "US", "name": "United States", "stationcount": 12},
                {"iso_3166_1": "DE", "name": "Germany", "stationcount": 5},
                {"iso_3166_1": "XX", "name": "Small", "stationcount": 4},
            ]
        elif path == "/json/tags":
            data = [{"name": tag} for tag in ["rock", "80s", "R&B", "hip-hop", "électronique", "bad!", ""]]
        elif path == "/json/stations/search":
            data = [station_data(), station_data(hls=1), station_data(url_resolved="")]
        elif path.startswith("/json/stations/byuuid/"):
            id = path.rsplit("/", 1)[1]
            data = [] if id == "missing" else [station_data(id)]
        else:
            data = {"ok": True}
        return httpx.Response(200, json=data)

    original = httpx.AsyncClient
    monkeypatch.setattr(
        radio,
        "_client",
        lambda: original(transport=httpx.MockTransport(handler), headers={"User-Agent": "Resonance/0.1.0"}, timeout=10),
    )
    yield requests
    radio._cache.clear()


async def test_parsing_filtering_and_search(directory: list[httpx.Request]) -> None:
    parsed = radio.Station.from_directory(station_data(favicon="http://image.example/icon", bitrate=0, homepage=""))
    assert parsed.favicon is None and parsed.bitrate is None and parsed.homepage is None
    assert parsed.tags == ["rock", "pop", "jazz", "news", "soul"]
    assert "url_resolved" not in parsed.model_dump()
    stations = await radio.search("DE", "rock", "Radio", 50, 100)
    assert len(stations) == 1 and stations[0].favicon == "https://images.example/icon.png"
    assert dict(directory[-1].url.params) == {
        "countrycode": "DE",
        "tag": "rock",
        "tagExact": "false",
        "name": "Radio",
        "order": "clickcount",
        "reverse": "true",
        "hidebroken": "true",
        "offset": "50",
        "limit": "100",
    }
    assert await radio.station("missing") is None


async def test_caching_and_expiry(directory: list[httpx.Request], monkeypatch: pytest.MonkeyPatch) -> None:
    assert await radio.countries() == [
        {"code": "DE", "name": "Germany", "stations": 5},
        {"code": "US", "name": "United States", "stations": 12},
    ]
    await radio.countries()
    assert await radio.top_tags(2) == ["rock", "R&B"]
    assert await radio.top_tags() == ["rock", "R&B", "hip-hop", "électronique"]
    assert len(directory) == 2
    now = radio.time.monotonic()
    monkeypatch.setattr(radio.time, "monotonic", lambda: now + 86401)
    await radio.countries()
    await radio.top_tags()
    assert len(directory) == 4


@pytest.mark.parametrize("failure", [503, "network"])
async def test_server_fallback(monkeypatch: pytest.MonkeyPatch, failure: int | str) -> None:
    hosts: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        hosts.append(request.url.host)
        assert request.headers["user-agent"] == "Resonance/0.1.0"
        if len(hosts) < 3:
            if failure == "network":
                raise httpx.ConnectError("offline", request=request)
            return httpx.Response(failure)
        return httpx.Response(200, json=[])

    original = httpx.AsyncClient
    monkeypatch.setattr(
        radio,
        "_client",
        lambda: original(transport=httpx.MockTransport(handler), headers={"User-Agent": "Resonance/0.1.0"}),
    )
    assert await radio.station("missing") is None
    assert hosts == [httpx.URL(base).host for base in radio.BASE_URLS]


@pytest.fixture
async def radio_auth(client: httpx.AsyncClient) -> dict[str, str]:
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    admin = auth((await register(client, "worldradio-admin"))["token"])
    await client.patch("/api/admin/config", headers=admin, json={"registration": {"mode": "public"}})
    return auth((await register(client, "worldradio-user"))["token"])


async def test_api_favorites_crud(client: httpx.AsyncClient, radio_auth: dict, directory: list) -> None:
    headers = radio_auth
    assert (await client.get("/api/worldradio/countries", headers=headers)).status_code == 200
    assert (await client.get("/api/worldradio/tags", headers=headers)).json() == [
        "rock",
        "R&B",
        "hip-hop",
        "électronique",
    ]
    assert len((await client.get("/api/worldradio/stations", headers=headers)).json()) == 1
    assert (await client.get("/api/worldradio/stations?limit=101", headers=headers)).status_code == 422
    assert (await client.get("/api/worldradio/favorites", headers=headers)).json() == []
    for id in ["first", "second", "second"]:
        assert (await client.put(f"/api/worldradio/favorites/{id}", headers=headers)).status_code == 204
    assert [s["id"] for s in (await client.get("/api/worldradio/favorites", headers=headers)).json()] == [
        "second",
        "first",
    ]
    assert (await client.delete("/api/worldradio/favorites/second", headers=headers)).status_code == 204
    assert [s["id"] for s in (await client.get("/api/worldradio/favorites", headers=headers)).json()] == ["first"]
    assert (await client.delete("/api/worldradio/favorites/second", headers=headers)).status_code == 204
    other = auth((await register(client, "worldradio-other"))["token"])
    assert (await client.get("/api/worldradio/favorites", headers=other)).json() == []
    assert (await client.get("/api/worldradio/favorites")).status_code == 401


async def test_not_found(client: httpx.AsyncClient, radio_auth: dict, directory: list) -> None:
    for path, method in [("stations/missing", "get"), ("stations/missing/stream", "get"), ("favorites/missing", "put")]:
        response = await getattr(client, method)(f"/api/worldradio/{path}", headers=radio_auth)
        assert response.status_code == 404 and response.json()["detail"] == "Sender nicht gefunden"


@pytest.fixture
async def public_dns(monkeypatch: pytest.MonkeyPatch) -> None:
    async def resolve(host: str, port: int | None, **kwargs: object) -> list:
        ip = "127.0.0.1" if host == "private.example" else host if host[0].isdigit() or ":" in host else "93.184.216.34"
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (ip, port or 80))]

    monkeypatch.setattr(asyncio.get_running_loop(), "getaddrinfo", resolve)


async def test_stream_bytes_and_redirect(
    client: httpx.AsyncClient, radio_auth: dict, directory: list, public_dns: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    requests: list[httpx.Request] = []
    closed: list[bool] = []

    class Audio(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b"live-"
            yield b"audio"

        async def aclose(self) -> None:
            closed.append(True)

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        assert request.headers["icy-metadata"] == "1"
        if request.url.path == "/live":
            return httpx.Response(302, headers={"Location": "https://other.example/audio"})
        return httpx.Response(200, headers={"Content-Type": "audio/mpeg"}, stream=Audio())

    original = httpx.AsyncClient
    monkeypatch.setattr(
        api,
        "_stream_client",
        lambda: original(
            transport=httpx.MockTransport(handler),
            follow_redirects=True,
            timeout=httpx.Timeout(10, read=None),
            event_hooks={"request": [api._validate_url]},
        ),
    )
    token = radio_auth["Authorization"].removeprefix("Bearer ")
    response = await client.get(f"/api/worldradio/stations/station-1/stream?token={token}")
    assert response.status_code == 200 and response.content == b"live-audio"
    assert response.headers["content-type"] == "audio/mpeg" and response.headers["cache-control"] == "no-store"
    assert len(requests) == 2 and closed
    assert any(request.url.path == "/json/url/station-1" for request in directory)


@pytest.mark.parametrize(
    "url",
    [
        "http://127.0.0.1/live",
        "http://10.0.0.1/live",
        "http://169.254.169.254/live",
        "http://224.0.0.1/live",
        "http://[::1]/live",
        "file:///etc/passwd",
        "http://private.example/live",
    ],
)
async def test_private_address_rejected(url: str, public_dns: None) -> None:
    with pytest.raises(api.HTTPException) as exc:
        await api._validate_url(httpx.Request("GET", url))
    assert exc.value.status_code == 502


@pytest.mark.parametrize("status", [302, 503, "network"])
async def test_stream_errors(
    client: httpx.AsyncClient,
    radio_auth: dict,
    directory: list,
    public_dns: None,
    monkeypatch: pytest.MonkeyPatch,
    status: int | str,
) -> None:
    connected: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        connected.append(request.url.host)
        if status == "network":
            raise httpx.ConnectError("offline", request=request)
        return httpx.Response(status, headers={"Location": "http://private.example/live"})

    original = httpx.AsyncClient
    monkeypatch.setattr(
        api,
        "_stream_client",
        lambda: original(
            transport=httpx.MockTransport(handler), follow_redirects=True, event_hooks={"request": [api._validate_url]}
        ),
    )
    response = await client.get("/api/worldradio/stations/station-1/stream", headers=radio_auth)
    assert response.status_code == 502 and response.json()["detail"] == "Sender nicht erreichbar"
    assert connected == ["stream.example"]


async def test_directory_errors(client: httpx.AsyncClient, radio_auth: dict, monkeypatch: pytest.MonkeyPatch) -> None:
    original = httpx.AsyncClient
    monkeypatch.setattr(
        radio, "_client", lambda: original(transport=httpx.MockTransport(lambda _: httpx.Response(503)))
    )
    radio._cache.clear()
    for path in ["countries", "tags", "stations", "stations/id", "stations/id/stream"]:
        response = await client.get(f"/api/worldradio/{path}", headers=radio_auth)
        assert response.status_code == 502 and response.json()["detail"] == "Radiosender-Verzeichnis nicht erreichbar"
    await radio.click("ignored")


async def test_stream_disconnect_closes_upstream(
    directory: list, public_dns: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    closed: list[bool] = []
    waiting = asyncio.Event()

    class Audio(httpx.AsyncByteStream):
        async def __aiter__(self):
            yield b"first"
            waiting.set()
            await asyncio.Event().wait()

        async def aclose(self) -> None:
            closed.append(True)

    original = httpx.AsyncClient
    monkeypatch.setattr(
        api,
        "_stream_client",
        lambda: original(
            transport=httpx.MockTransport(lambda _: httpx.Response(200, stream=Audio())),
            event_hooks={"request": [api._validate_url]},
        ),
    )
    response = await api.stream("station-1", user=None)
    assert radio._active_streams["station-1"] == 1
    assert await anext(response.body_iterator) == b"first"
    pending = asyncio.create_task(anext(response.body_iterator))
    await waiting.wait()
    pending.cancel()
    with pytest.raises(asyncio.CancelledError):
        await pending
    assert closed
    assert "station-1" not in radio._active_streams
    await response.background()
