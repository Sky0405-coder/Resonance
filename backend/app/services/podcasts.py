"""RSS podcast discovery, bounded conditional feed downloads and subscription refresh."""

import asyncio
import logging
import math
import time
import uuid
from contextlib import suppress
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime
from html.parser import HTMLParser
from urllib.parse import urlsplit
from xml.etree.ElementTree import ParseError

import httpx
from defusedxml import ElementTree
from defusedxml.common import DefusedXmlException
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models.podcasts import Podcast, PodcastEpisode, PodcastSubscription

log = logging.getLogger(__name__)
ITUNES = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"
MAX_FEED_BYTES = 10 * 1024 * 1024
_cache: dict[tuple[str, str], tuple[float, list[dict]]] = {}
_chart_cache: dict[tuple[str, int | None], tuple[float, int, list[dict]]] = {}
_genre_cache: dict[str, tuple[float, int | None]] = {}
_task: asyncio.Task | None = None


class PodcastError(Exception):
    pass


class _Text(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.hidden = 0

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in {"script", "style"}:
            self.hidden += 1
        if tag in {"br", "p", "div", "li"}:
            self.parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style"}:
            self.hidden = max(0, self.hidden - 1)
        if tag in {"p", "div", "li"}:
            self.parts.append("\n")

    def handle_data(self, data: str) -> None:
        if not self.hidden:
            self.parts.append(data)


def plain_text(value: str) -> str:
    parser = _Text()
    parser.feed(value)
    return "\n".join(line.strip() for line in "".join(parser.parts).splitlines() if line.strip())[:20000]


def duration_seconds(value: str) -> float | None:
    try:
        parts = value.strip().split(":")
        if not 1 <= len(parts) <= 3:
            return None
        result = 0.0
        for part in parts:
            number = float(part)
            if not math.isfinite(number) or number < 0:
                return None
            result = result * 60 + number
        return result
    except ValueError:
        return None


def http_url(value: str | None) -> str | None:
    if not isinstance(value, str):
        return None
    try:
        url = urlsplit(value or "")
        return value if url.scheme in {"http", "https"} and url.hostname and not url.username else None
    except ValueError:
        return None


def parse_feed(data: bytes) -> tuple[dict, list[dict]]:
    if len(data) > MAX_FEED_BYTES:
        raise PodcastError("Feed exceeds 10 MB")
    try:
        root = ElementTree.fromstring(data, forbid_dtd=True)
    except (ParseError, DefusedXmlException) as exc:
        raise PodcastError("Invalid RSS") from exc
    channel = root.find("channel")
    if root.tag != "rss" or channel is None:
        raise PodcastError("RSS channel missing")

    def text(element, tag: str) -> str:
        child = element.find(tag)
        return "" if child is None else "".join(child.itertext()).strip()

    def image(element) -> str | None:
        node = element.find(f"{ITUNES}image")
        return http_url(node.get("href")) if node is not None else http_url(text(element, "image/url"))

    podcast = {
        "title": text(channel, "title"),
        "author": text(channel, f"{ITUNES}author") or text(channel, "managingEditor") or None,
        "description": plain_text(text(channel, "description")),
        "image_url": image(channel),
        "website": http_url(text(channel, "link")),
    }
    episodes: dict[str, dict] = {}
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        audio_url = http_url(enclosure.get("url")) if enclosure is not None else None
        if not audio_url:
            continue
        published = None
        try:
            published = parsedate_to_datetime(text(item, "pubDate"))
            published = published.replace(tzinfo=UTC) if published.tzinfo is None else published.astimezone(UTC)
        except (ValueError, TypeError, OverflowError):
            pass
        guid = text(item, "guid") or audio_url
        episodes[guid] = {
            "guid": guid,
            "title": text(item, "title"),
            "description": plain_text(text(item, "description") or text(item, f"{ITUNES}summary")),
            "published_at": published,
            "duration_seconds": duration_seconds(text(item, f"{ITUNES}duration")),
            "audio_url": audio_url,
            "audio_type": enclosure.get("type"),
            "image_url": image(item),
        }
    return podcast, list(episodes.values())


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=30, follow_redirects=True, headers={"User-Agent": "Resonance/0.1.0"})


async def fetch_feed(url: str, etag: str | None = None, last_modified: str | None = None) -> tuple:
    if not http_url(url):
        raise PodcastError("Invalid feed URL")
    headers = {}
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    try:
        async with _client() as client, client.stream("GET", url, headers=headers) as response:
            if response.status_code == 304:
                return None, etag, last_modified
            response.raise_for_status()
            if int(response.headers.get("Content-Length", "0")) > MAX_FEED_BYTES:
                raise PodcastError("Feed exceeds 10 MB")
            data = bytearray()
            async for chunk in response.aiter_bytes():
                data.extend(chunk)
                if len(data) > MAX_FEED_BYTES:
                    raise PodcastError("Feed exceeds 10 MB")
            return parse_feed(bytes(data)), response.headers.get("etag"), response.headers.get("last-modified")
    except (httpx.HTTPError, ValueError) as exc:
        raise PodcastError("Feed unavailable") from exc


async def _store_episodes(db: AsyncSession, podcast_id: uuid.UUID, episodes: list[dict]) -> None:
    for episode in episodes:
        statement = insert(PodcastEpisode).values(podcast_id=podcast_id, **episode)
        await db.execute(statement.on_conflict_do_update(
            index_elements=["podcast_id", "guid"],
            set_={key: getattr(statement.excluded, key) for key in episode if key != "guid"},
        ))


async def get_or_fetch(db: AsyncSession, feed_url: str) -> Podcast:
    podcast = await db.scalar(select(Podcast).where(Podcast.feed_url == feed_url))
    if podcast is not None:
        return podcast
    data, etag, modified = await fetch_feed(feed_url)
    if data is None:
        raise PodcastError("Empty initial feed")
    metadata, episodes = data
    statement = insert(Podcast).values(
        feed_url=feed_url, **metadata, etag=etag, last_modified=modified, last_fetched_at=datetime.now(UTC)
    ).on_conflict_do_nothing(index_elements=["feed_url"]).returning(Podcast.id)
    podcast_id = await db.scalar(statement)
    podcast = await db.scalar(select(Podcast).where(Podcast.feed_url == feed_url))
    if podcast_id is not None:
        await _store_episodes(db, podcast.id, episodes)
    return podcast


async def refresh(db: AsyncSession, podcast: Podcast) -> None:
    data, etag, modified = await fetch_feed(podcast.feed_url, podcast.etag, podcast.last_modified)
    if data is not None:
        metadata, episodes = data
        for key, value in metadata.items():
            setattr(podcast, key, value)
        await _store_episodes(db, podcast.id, episodes)
    podcast.etag = etag
    podcast.last_modified = modified
    podcast.last_fetched_at = datetime.now(UTC)
    await db.commit()


def normalize_feed_url(value: str) -> str:
    normalized = value.strip().lower()
    normalized = normalized.removeprefix("http://").removeprefix("https://")
    normalized = normalized.removeprefix("www.")
    return normalized.rstrip("/")


def _apple_search_item(item: dict) -> dict | None:
    feed_url = http_url(item.get("feedUrl"))
    if item.get("collectionId") is None or not feed_url:
        return None
    return {
        "itunes_id": item["collectionId"],
        "title": item.get("collectionName", ""),
        "author": item.get("artistName", ""),
        "image_url": http_url(item.get("artworkUrl600") or item.get("artworkUrl100")),
        "feed_url": feed_url,
        "source": "apple",
    }


async def _apple_search(query: str, country: str, limit: int) -> list[dict]:
    async with _client() as client:
        response = await client.get(
            "https://itunes.apple.com/search",
            params={"media": "podcast", "limit": limit, "term": query, "country": country},
        )
        response.raise_for_status()
        results = response.json()["results"]
        return [result for item in results if (result := _apple_search_item(item)) is not None]


async def _fyyd_search(query: str) -> list[dict]:
    async with _client() as client:
        response = await client.get(
            "https://api.fyyd.de/0.2/search/podcast", params={"term": query, "count": 25}
        )
        response.raise_for_status()
        results = response.json()["data"]
        return [
            {
                "itunes_id": None,
                "title": item.get("title", ""),
                "author": item.get("author", ""),
                "image_url": http_url(item.get("imgURL")),
                "feed_url": feed_url,
                "source": "fyyd",
            }
            for item in results
            if (feed_url := http_url(item.get("xmlURL")))
        ]


async def search(query: str, country: str) -> list[dict]:
    query = query.strip()
    if not query:
        return []
    key = (country, query.casefold())
    cached = _cache.get(key)
    if cached is not None and time.monotonic() - cached[0] < 600:
        return cached[1]
    apple_result, fyyd_result = await asyncio.gather(
        _apple_search(query, country, 25), _fyyd_search(query), return_exceptions=True
    )
    if isinstance(apple_result, Exception) and isinstance(fyyd_result, Exception):
        raise PodcastError("Search unavailable") from apple_result
    result = []
    if not isinstance(apple_result, Exception):
        result.extend(apple_result)
    seen = {normalize_feed_url(item["feed_url"]) for item in result}
    if not isinstance(fyyd_result, Exception):
        for item in fyyd_result:
            normalized = normalize_feed_url(item["feed_url"])
            if normalized not in seen:
                result.append(item)
                seen.add(normalized)
    if len(_cache) >= 256:
        _cache.pop(next(iter(_cache)))
    _cache[key] = (time.monotonic(), result)
    return result


async def top_podcasts(country: str, genre_id: int | None, limit: int = 50) -> list[dict]:
    limit = min(max(limit, 1), 200)
    key = (country, genre_id)
    cached = _chart_cache.get(key)
    if cached is not None and time.monotonic() - cached[0] < 6 * 60 * 60 and cached[1] >= limit:
        return cached[2][:limit]
    path = f"{country.lower()}/rss/toppodcasts/limit={limit}"
    if genre_id is not None:
        path += f"/genre={genre_id}"
    try:
        async with _client() as client:
            response = await client.get(f"https://itunes.apple.com/{path}/json")
            response.raise_for_status()
            entries = response.json()["feed"]["entry"]
            if isinstance(entries, dict):
                entries = [entries]
            ids = [
                str(entry["id"]["attributes"]["im:id"])
                for entry in entries
                if entry.get("id", {}).get("attributes", {}).get("im:id") is not None
            ][:200]
            if not ids:
                result = []
            else:
                lookup = await client.get(
                    "https://itunes.apple.com/lookup", params={"id": ",".join(ids), "country": country}
                )
                lookup.raise_for_status()
                items = lookup.json()["results"]
                by_id = {str(item.get("collectionId")): item for item in items if item.get("collectionId")}
                result = [
                    mapped
                    for item_id in ids
                    if (item := by_id.get(item_id)) is not None
                    and (mapped := _apple_search_item(item)) is not None
                ]
    except Exception as exc:
        raise PodcastError("Charts unavailable") from exc
    if len(_chart_cache) >= 64:
        _chart_cache.pop(next(iter(_chart_cache)))
    _chart_cache[key] = (time.monotonic(), limit, result)
    return result[:limit]


async def podcast_genre(podcast: Podcast, country: str) -> int | None:
    key = str(podcast.id)
    cached = _genre_cache.get(key)
    if cached is not None and time.monotonic() - cached[0] < 7 * 24 * 60 * 60:
        return cached[1]
    genre_id = None
    try:
        async with _client() as client:
            response = await client.get(
                "https://itunes.apple.com/search",
                params={"media": "podcast", "limit": 10, "term": podcast.title, "country": country},
            )
            response.raise_for_status()
            results = response.json()["results"]
        match = next(
            (item for item in results if normalize_feed_url(item.get("feedUrl", ""))
             == normalize_feed_url(podcast.feed_url)),
            None,
        )
        if match is None:
            title = podcast.title.casefold()
            match = next((item for item in results if item.get("collectionName", "").casefold() == title), None)
        if match is not None:
            genre_id = next((int(value) for value in match.get("genreIds", []) if str(value) != "26"), None)
    except Exception:
        genre_id = None
    _genre_cache[key] = (time.monotonic(), genre_id)
    return genre_id


async def _refresh_loop() -> None:
    while True:
        try:
            async with SessionLocal() as db:
                ids = list(await db.scalars(select(Podcast.id).where(
                    select(PodcastSubscription.podcast_id)
                    .where(PodcastSubscription.podcast_id == Podcast.id).exists()
                )))
            for index, podcast_id in enumerate(ids):
                if index:
                    await asyncio.sleep(5)
                try:
                    async with SessionLocal() as db:
                        podcast = await db.get(Podcast, podcast_id)
                        if podcast is not None:
                            await refresh(db, podcast)
                except Exception:
                    log.exception("Podcast refresh failed: %s", podcast_id)
        except Exception:
            log.exception("Podcast refresh cycle failed")
        await asyncio.sleep(2 * 60 * 60)


async def start() -> None:
    global _task
    if _task is None:
        _task = asyncio.create_task(_refresh_loop())


async def stop() -> None:
    global _task
    if _task is not None:
        _task.cancel()
        with suppress(asyncio.CancelledError):
            await _task
        _task = None
