import asyncio
from datetime import UTC, datetime, timedelta

import httpx
import pytest

from app.api import worldradio as api
from app.services import worldradio as radio
from app.services.deezer import DeezerError
from tests.test_worldradio import directory as directory  # noqa: PLC0414
from tests.test_worldradio import public_dns as public_dns  # noqa: PLC0414
from tests.test_worldradio import radio_auth as radio_auth  # noqa: PLC0414


def metadata(title: str, encoding: str = "utf-8") -> bytes:
    data = f"StreamTitle='{title}';StreamUrl='https://radio.example';".encode(encoding)
    size = (len(data) + 15) // 16
    return bytes([size]) + data.ljust(size * 16, b"\0")


@pytest.fixture(autouse=True)
async def clean_state():
    radio._now_playing.clear()
    radio._active_streams.clear()
    radio._enrichments.clear()
    yield
    for task in list(radio._tasks):
        task.cancel()
    await asyncio.gather(*radio._tasks, return_exceptions=True)
    radio._now_playing.clear()
    radio._active_streams.clear()
    radio._enrichments.clear()


@pytest.mark.parametrize("size", [1, 7, 10000])
def test_icy_chunk_boundaries(size: int) -> None:
    stream = (
        b"a" * 16 + metadata("Artist - Tïtle") + b"b" * 16 + b"\0"
        + b"c" * 16 + metadata("Björk - Jóga", "latin-1") + b"d" * 16 + metadata("") + b"end"
    )
    reader = radio.IcyReader(16)
    audio, titles = bytearray(), []
    assert reader.feed(b"") == (b"", [])
    for offset in range(0, len(stream), size):
        chunk_audio, chunk_titles = reader.feed(stream[offset:offset + size])
        audio.extend(chunk_audio)
        titles.extend(chunk_titles)
    assert audio == b"a" * 16 + b"b" * 16 + b"c" * 16 + b"d" * 16 + b"end"
    assert titles == ["Artist - Tïtle", "Björk - Jóga", ""]


def test_icy_empty_metadata_blocks() -> None:
    assert radio.IcyReader(16).feed((b"a" * 16 + b"\0") * 3) == (b"a" * 48, [])
    with pytest.raises(ValueError):
        radio.IcyReader(0)


def test_icy_decodes_title_independently_of_other_metadata() -> None:
    data = "StreamTitle='Björk - Jóga';".encode() + b"StreamUrl='http://radio.example/\xff';"
    size = (len(data) + 15) // 16
    assert radio.IcyReader(16).feed(b"a" * 16 + bytes([size]) + data.ljust(size * 16, b"\0")) == (
        b"a" * 16, ["Björk - Jóga"],
    )


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (" Artist - Title - Remix ", ("Artist", "Title - Remix")),
        (" Title ", (None, "Title")),
        ("Björk - Jóga", ("Björk", "Jóga")),
        ("", None),
        ("  ", None),
        ("Artist - ", None),
        ("rAdIo OnE", None),
        ("Artist - RADIO ONE", None),
    ],
)
async def test_title_parsing(raw: str, expected: tuple | None, monkeypatch: pytest.MonkeyPatch) -> None:
    async def enrich(id: str, entry: radio.NowPlaying) -> None:
        pass

    monkeypatch.setattr(radio, "_enrich", enrich)
    radio.stream_started("one")
    radio.set_now_playing("one", "Radio One", "Previous")
    radio.set_now_playing("one", "Radio One", raw)
    entry = radio.now_playing("one")
    assert ((entry.artist, entry.title) if entry else None) == expected


def test_station_name_with_dash_clears_metadata() -> None:
    radio.stream_started("one")
    radio.set_now_playing("one", "Radio - One", "radio - one")
    assert radio.now_playing("one") is None


async def test_now_endpoint(client: httpx.AsyncClient, radio_auth: dict, monkeypatch: pytest.MonkeyPatch) -> None:
    async def enrich(id: str, entry: radio.NowPlaying) -> None:
        pass

    monkeypatch.setattr(radio, "_enrich", enrich)
    path = "/api/worldradio/stations/one/now"
    assert (await client.get(path)).status_code == 401
    assert (await client.get(path, headers=radio_auth)).json() is None
    radio.stream_started("one")
    radio.set_now_playing("one", "Radio One", "Artist - Title")
    response = await client.get(path, headers=radio_auth)
    assert response.status_code == 200
    assert response.json() == {
        "raw": "Artist - Title", "artist": "Artist", "title": "Title", "album": None, "year": None, "cover_url": None,
    }
    radio._now_playing["one"].since -= timedelta(minutes=31)
    assert (await client.get(path, headers=radio_auth)).json() is None
    radio.set_now_playing("one", "Radio One", "Artist - Title")
    radio.stream_started("one")
    radio.stream_stopped("one")
    assert radio.now_playing("one") is not None
    radio.stream_stopped("one")
    assert (await client.get(path, headers=radio_auth)).json() is None
    assert "one" not in radio._now_playing
    radio.set_now_playing("one", "Radio One", "Artist - Title")
    assert (await client.get(path, headers=radio_auth)).json() is None


@pytest.mark.parametrize("date_in_track", [False, True])
async def test_enrichment_and_cache(date_in_track: bool, monkeypatch: pytest.MonkeyPatch) -> None:
    searches, albums = [], []

    async def search(q: str, limit: int) -> list[dict]:
        searches.append(q)
        return [
            {"artist": {"name": "Other"}, "album": {"title": "Wrong"}},
            {
                "artist": {"name": "Björk"},
                "album": {"id": 1, "title": "Homogenic", "cover_big": "https://cover.example/big"},
                **({"release_date": "1997-09-22"} if date_in_track else {}),
            },
        ]

    async def album(id: str) -> dict:
        albums.append(id)
        return {"title": "Homogenic", "release_date": "1997-09-22", "cover_xl": "https://cover.example/xl"}

    monkeypatch.setattr(radio.deezer, "search_tracks", search)
    monkeypatch.setattr(radio.deezer, "album", album)
    radio.stream_started("one")
    radio.set_now_playing("one", "Radio One", "BJÖRK - Jóga")
    await asyncio.gather(*radio._tasks)
    entry = radio.now_playing("one")
    assert (entry.album, entry.year) == ("Homogenic", 1997)
    assert entry.cover_url == f"https://cover.example/{'big' if date_in_track else 'xl'}"
    assert albums == ([] if date_in_track else ["1"])
    entry.since = datetime.now(UTC) - timedelta(minutes=29)
    radio.set_now_playing("one", "Radio One", entry.raw)
    assert datetime.now(UTC) - entry.since < timedelta(seconds=1)
    radio.set_now_playing("two", "Radio Two", entry.raw)
    await asyncio.gather(*radio._tasks)
    assert radio._now_playing["two"].year == 1997
    assert searches == ["BJÖRK Jóga"]


async def test_enrichment_fallback_error_and_stale_result(monkeypatch: pytest.MonkeyPatch) -> None:
    pending = asyncio.Event()

    async def search(q: str, limit: int) -> list[dict]:
        if q == "Artist Error":
            raise DeezerError("unavailable")
        await pending.wait()
        return [{"album": {"title": "First result", "release_date": "1987-01-01"}}]

    monkeypatch.setattr(radio.deezer, "search_tracks", search)
    radio.stream_started("one")
    radio.set_now_playing("one", "Radio One", "Artist - Old")
    await asyncio.sleep(0)
    radio.set_now_playing("one", "Radio One", "Artist - Error")
    pending.set()
    await asyncio.gather(*radio._tasks)
    entry = radio.now_playing("one")
    assert (entry.title, entry.album, entry.cover_url, entry.year) == ("Error", None, None, None)
    radio.set_now_playing("one", "Radio One", "Unknown - Song")
    await asyncio.gather(*radio._tasks)
    assert radio.now_playing("one").album == "First result"
    radio.set_now_playing("one", "Radio One", "Unknown - Late")
    radio.stream_stopped("one")
    await asyncio.gather(*radio._tasks)
    assert "one" not in radio._now_playing


async def test_proxy_strips_metadata_and_cleans_up(
    directory: list, public_dns: None, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def search(q: str, limit: int) -> list[dict]:
        return []

    class Audio(httpx.AsyncByteStream):
        async def __aiter__(self):
            for byte in b"a" * 16 + metadata("Artist - Title") + b"b" * 16 + b"\0":
                yield bytes([byte])

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.headers["icy-metadata"] == "1"
        return httpx.Response(200, headers={"icy-metaint": "16", "Content-Type": "audio/mpeg"}, stream=Audio())

    original = httpx.AsyncClient
    monkeypatch.setattr(radio.deezer, "search_tracks", search)
    monkeypatch.setattr(api, "_stream_client", lambda: original(transport=httpx.MockTransport(handler)))
    response = await api.stream("station-1", user=None)
    assert "icy-metaint" not in response.headers
    audio = bytearray()
    async for chunk in response.body_iterator:
        audio.extend(chunk)
        if len(audio) == 17:
            assert radio.now_playing("station-1").title == "Title"
    assert audio == b"a" * 16 + b"b" * 16
    assert radio.now_playing("station-1") is None
    await response.background()
    assert not radio._active_streams


async def test_title_slash_artist_format(monkeypatch) -> None:
    async def no_enrichment(*_) -> None:
        return None

    monkeypatch.setattr(radio, "_enrich", no_enrichment)
    radio._active_streams["swr"] = 1
    try:
        radio.set_now_playing("swr", "SWR3", "You are not alone / Michael Jackson")
        entry = radio.now_playing("swr")
        assert (entry.title, entry.artist) == ("You are not alone", "Michael Jackson")
        radio.set_now_playing("swr", "SWR3", "AC/DC - Thunderstruck")
        entry = radio.now_playing("swr")
        assert (entry.title, entry.artist) == ("Thunderstruck", "AC/DC")
    finally:
        radio._active_streams.pop("swr", None)
        radio._now_playing.pop("swr", None)
