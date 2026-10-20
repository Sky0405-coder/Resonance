import asyncio
import re
import time
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import quote

import httpx
from pydantic import BaseModel, PrivateAttr

from app.services.deezer import DeezerError, artist_string, deezer
from app.services.matching import name_key
from app.services.musicbrainz import VERSION
from app.services.tags import primary_artist

BASE_URLS = (
    "https://de1.api.radio-browser.info",
    "https://de2.api.radio-browser.info",
    "https://fi1.api.radio-browser.info",
)
_cache: dict[str, tuple[float, list]] = {}
_tasks: set[asyncio.Task] = set()
_active_streams: dict[str, int] = {}
_enrichments: dict[str, tuple[str | None, str | None, int | None]] = {}


class IcyReader:
    def __init__(self, metaint: int) -> None:
        if metaint <= 0:
            raise ValueError("metaint must be positive")
        self.metaint = metaint
        self._audio_remaining = metaint
        self._metadata_remaining = 0
        self._metadata = bytearray()

    def feed(self, chunk: bytes) -> tuple[bytes, list[str]]:
        audio = bytearray()
        titles = []
        offset = 0
        while offset < len(chunk):
            if self._audio_remaining:
                size = min(self._audio_remaining, len(chunk) - offset)
                audio.extend(chunk[offset:offset + size])
                self._audio_remaining -= size
                offset += size
            elif self._metadata_remaining:
                size = min(self._metadata_remaining, len(chunk) - offset)
                self._metadata.extend(chunk[offset:offset + size])
                self._metadata_remaining -= size
                offset += size
                if not self._metadata_remaining:
                    for title in re.findall(rb"(?:^|;)\s*StreamTitle='(.*?)';", self._metadata, re.DOTALL):
                        try:
                            titles.append(title.decode("utf-8"))
                        except UnicodeDecodeError:
                            titles.append(title.decode("latin-1"))
                    self._metadata.clear()
                    self._audio_remaining = self.metaint
            else:
                self._metadata_remaining = chunk[offset] * 16
                offset += 1
                if not self._metadata_remaining:
                    self._audio_remaining = self.metaint
        return bytes(audio), titles


@dataclass
class NowPlaying:
    raw: str
    artist: str | None
    title: str | None
    year: int | None
    cover_url: str | None
    album: str | None
    since: datetime


_now_playing: dict[str, NowPlaying | None] = {}


def stream_started(id: str) -> None:
    _active_streams[id] = _active_streams.get(id, 0) + 1


def stream_stopped(id: str) -> None:
    remaining = _active_streams.get(id, 0) - 1
    if remaining > 0:
        _active_streams[id] = remaining
    else:
        _active_streams.pop(id, None)
        _now_playing.pop(id, None)


def now_playing(id: str) -> NowPlaying | None:
    entry = _now_playing.get(id)
    if not _active_streams.get(id) or (entry and datetime.now(UTC) - entry.since > timedelta(minutes=30)):
        _now_playing.pop(id, None)
        return None
    return entry


def set_now_playing(id: str, station_name: str, raw: str) -> None:
    artist, separator, title = raw.partition(" - ")
    raw = raw.strip()
    artist, title = (artist.strip() or None, title.strip()) if separator else (None, raw)
    station_key = station_name.strip().casefold()
    if not title or raw.casefold() == station_key or title.casefold() == station_key:
        _now_playing[id] = None
        return
    previous = _now_playing.get(id)
    if previous and previous.raw == raw:
        previous.since = datetime.now(UTC)
        return
    entry = NowPlaying(raw, artist, title, None, None, None, datetime.now(UTC))
    _now_playing[id] = entry
    task = asyncio.create_task(_enrich(id, entry))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def _enrich(id: str, entry: NowPlaying) -> None:
    cached = _enrichments.pop(entry.raw, None)
    if cached is None:
        album_title, cover_url, year = None, None, None
        try:
            results = await deezer.search_tracks(" ".join(filter(None, [entry.artist, entry.title])), 10)
            if results:
                track = next(
                    (
                        t for t in results
                        if entry.artist
                        and name_key(primary_artist(artist_string(t))) == name_key(primary_artist(entry.artist))
                    ),
                    results[0],
                )
                album = track.get("album") or {}
                date = album.get("release_date") or track.get("release_date")
                if not date and album.get("id") is not None:
                    album = {**album, **await deezer.album(str(album["id"]))}
                    date = album.get("release_date")
                album_title = album.get("title")
                cover_url = album.get("cover_xl") or album.get("cover_big")
                year = int(date[:4]) if date and date[:4].isdigit() else None
        except DeezerError:
            pass
        cached = (album_title, cover_url, year)
    _enrichments[entry.raw] = cached
    if len(_enrichments) > 500:
        del _enrichments[next(iter(_enrichments))]
    if _now_playing.get(id) is entry:
        entry.album, entry.cover_url, entry.year = cached


class WorldRadioError(Exception):
    pass


class Station(BaseModel):
    id: str
    name: str
    country: str
    country_code: str
    tags: list[str]
    favicon: str | None
    codec: str
    bitrate: int | None
    homepage: str | None
    _url_resolved: str = PrivateAttr(default="")

    @classmethod
    def from_directory(cls, data: dict[str, Any]) -> "Station":
        favicon = data.get("favicon") or ""
        station = cls(
            id=data["stationuuid"],
            name=data.get("name", ""),
            country=data.get("country", ""),
            country_code=data.get("countrycode", ""),
            tags=[tag.strip() for tag in data.get("tags", "").split(",") if tag.strip()][:5],
            favicon=favicon if favicon.startswith("https://") else None,
            codec=data.get("codec", ""),
            bitrate=data.get("bitrate") or None,
            homepage=data.get("homepage") or None,
        )
        station._url_resolved = data.get("url_resolved") or ""
        return station


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(headers={"User-Agent": f"Resonance/{VERSION}"}, timeout=10)


async def _get(path: str, **params: Any) -> Any:
    async with _client() as client:
        for base in BASE_URLS:
            try:
                response = await client.get(base + path, params=params)
            except httpx.RequestError:
                continue
            if response.status_code >= 500:
                continue
            try:
                response.raise_for_status()
                return response.json()
            except (httpx.HTTPError, ValueError) as exc:
                raise WorldRadioError from exc
    raise WorldRadioError


async def countries() -> list[dict[str, Any]]:
    cached = _cache.get("countries")
    if cached and time.monotonic() - cached[0] < 86400:
        return cached[1]
    try:
        result = sorted(
            [
                {"code": row["iso_3166_1"], "name": row["name"], "stations": int(row["stationcount"])}
                for row in await _get("/json/countries")
                if int(row["stationcount"]) >= 5
            ],
            key=lambda row: row["name"],
        )
    except (KeyError, TypeError, ValueError) as exc:
        raise WorldRadioError from exc
    _cache["countries"] = (time.monotonic(), result)
    return result


async def top_tags(limit: int = 40) -> list[str]:
    cached = _cache.get("tags")
    if cached and time.monotonic() - cached[0] < 86400:
        return cached[1][:limit]
    try:
        result = [
            row["name"]
            for row in await _get("/json/tags", order="stationcount", reverse="true", hidebroken="true", limit=200)
            if row["name"] and all(char.isalpha() or char in " &-" for char in row["name"])
        ]
    except (KeyError, TypeError, ValueError) as exc:
        raise WorldRadioError from exc
    _cache["tags"] = (time.monotonic(), result)
    return result[:limit]


async def search(
    country_code: str = "", tag: str = "", name: str = "", offset: int = 0, limit: int = 50
) -> list[Station]:
    data = await _get(
        "/json/stations/search",
        countrycode=country_code,
        tag=tag,
        tagExact="false",
        name=name,
        order="clickcount",
        reverse="true",
        hidebroken="true",
        offset=offset,
        limit=limit,
    )
    try:
        return [Station.from_directory(row) for row in data if row.get("hls") != 1 and row.get("url_resolved")]
    except (KeyError, TypeError, ValueError) as exc:
        raise WorldRadioError from exc


async def station(id: str) -> Station | None:
    data = await _get(f"/json/stations/byuuid/{quote(id, safe='')}")
    try:
        return Station.from_directory(data[0]) if data else None
    except (KeyError, TypeError, ValueError) as exc:
        raise WorldRadioError from exc


async def click(id: str) -> None:
    try:
        await _get(f"/json/url/{quote(id, safe='')}")
    except WorldRadioError:
        pass
