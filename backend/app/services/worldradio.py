import time
from typing import Any
from urllib.parse import quote

import httpx
from pydantic import BaseModel, PrivateAttr

from app.services.musicbrainz import VERSION

BASE_URLS = (
    "https://de1.api.radio-browser.info",
    "https://de2.api.radio-browser.info",
    "https://fi1.api.radio-browser.info",
)
_cache: dict[str, tuple[float, list]] = {}


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
