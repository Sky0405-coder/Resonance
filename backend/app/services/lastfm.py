"""Genre-only Last.fm tags; personal, mood and decade tags are deliberately ignored."""

import asyncio
import logging
import time
from datetime import UTC, datetime, timedelta

import httpx
from sqlalchemy import or_, select

from app.db import SessionLocal
from app.models import Artist
from app.services.server_config import load_config

GENRES = {
    "rock", "pop", "hip-hop", "hip hop", "rap", "german hip hop", "deutschrap", "electronic", "electronica",
    "house", "techno", "trance", "drum and bass", "dubstep", "indie", "alternative", "metal", "punk", "jazz",
    "soul", "r&b", "funk", "reggae", "country", "folk", "classical", "schlager", "hard rock", "classic rock",
    "soft rock", "pop rock", "alternative rock", "indie rock", "progressive rock", "psychedelic rock",
    "garage rock", "blues rock", "post-rock", "post-punk", "punk rock", "pop punk", "hardcore punk", "grunge",
    "shoegaze", "dream pop", "britpop", "new wave", "synthpop", "synth-pop", "electropop", "indie pop", "dance pop",
    "k-pop", "j-pop", "latin pop", "disco", "dance", "eurodance", "edm", "ambient", "downtempo", "trip-hop",
    "trip hop", "idm", "synthwave", "chillout", "deep house", "tech house", "progressive house", "acid house",
    "electro house", "minimal techno", "detroit techno", "dub techno", "hard techno", "hardstyle", "hardcore",
    "psytrance", "goa trance", "progressive trance", "breakbeat", "jungle", "liquid funk", "drum & bass", "dnb",
    "uk garage", "grime", "trap", "drill", "boom bap", "gangsta rap", "conscious hip hop", "alternative hip hop",
    "old school hip hop", "east coast hip hop", "west coast hip hop", "instrumental hip hop", "lo-fi hip hop",
    "g-funk", "heavy metal", "thrash metal", "death metal", "black metal", "doom metal", "power metal",
    "symphonic metal", "progressive metal", "folk metal", "gothic metal", "industrial metal", "nu metal",
    "metalcore", "deathcore", "stoner rock", "post-metal", "speed metal", "grindcore", "emo", "post-hardcore",
    "industrial", "ebm", "darkwave", "gothic rock", "blues", "delta blues", "chicago blues", "rhythm and blues",
    "neo soul", "neo-soul", "motown", "contemporary r&b", "smooth jazz", "jazz fusion", "bebop", "free jazz",
    "cool jazz", "swing", "big band", "vocal jazz", "bossa nova", "latin jazz", "afrobeat", "afrobeats",
    "dancehall", "dub", "ska", "roots reggae", "reggaeton", "salsa", "samba", "tango", "flamenco", "cumbia",
    "bluegrass", "americana", "alt-country", "country rock", "country pop", "folk rock", "indie folk",
    "singer-songwriter", "acoustic", "celtic", "world", "world music", "gospel", "baroque", "romantic", "opera",
    "chamber music", "orchestral", "contemporary classical", "soundtrack", "musical", "chanson", "ndw",
    "volksmusik", "neue deutsche härte", "liedermacher", "experimental", "avant-garde", "noise",
}
_NAMES = {
    "hip hop": "Hip-Hop", "hip-hop": "Hip-Hop", "r&b": "R&B", "contemporary r&b": "Contemporary R&B",
    "drum and bass": "Drum and Bass", "drum & bass": "Drum and Bass", "dnb": "Drum and Bass",
    "german hip hop": "German Hip Hop", "deutschrap": "Deutschrap", "trip hop": "Trip-Hop",
    "trip-hop": "Trip-Hop", "idm": "IDM", "edm": "EDM", "ebm": "EBM", "ndw": "NDW",
}
log = logging.getLogger(__name__)
_cache: dict[tuple[str, str], tuple[float, list[str]]] = {}
_cache_key: str | None = None
_lock = asyncio.Lock()
_last_started = 0.0


def normalize_genre(name: str) -> str:
    name = name.strip().lower()
    return _NAMES.get(name, name.title())


def _tags(data: dict) -> list[str]:
    tags = data.get("toptags", {}).get("tag") or []
    if isinstance(tags, dict):
        tags = [tags]
    accepted = []
    for tag in tags:
        name = tag.get("name", "").strip().lower()
        try:
            count = int(tag.get("count", 0))
        except (ValueError, TypeError):
            continue
        if count >= 20 and name in GENRES:
            accepted.append((count, normalize_genre(name)))
    return list(dict.fromkeys(name for _, name in sorted(accepted, key=lambda item: -item[0])))


def _client_factory() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=15, headers={"User-Agent": "Resonance/1.0"})


async def _get(client: httpx.AsyncClient, **params) -> dict:
    global _last_started
    async with _lock:
        await asyncio.sleep(max(0, 0.25 - (time.monotonic() - _last_started)))
        _last_started = time.monotonic()
        response = await client.get("https://ws.audioscrobbler.com/2.0/", params={**params, "format": "json"})
        response.raise_for_status()
    return response.json()


async def track_tags(artist: str, title: str, *, api_key: str | None = None) -> list[str]:
    global _cache_key
    if api_key is None:
        async with SessionLocal() as db:
            api_key = (await load_config(db)).library.lastfm_api_key
    if not api_key:
        return []
    if api_key != _cache_key:
        _cache.clear()
        _cache_key = api_key
    key = (artist.strip().casefold(), title.strip().casefold())
    cached = _cache.get(key)
    if cached and time.monotonic() - cached[0] < 86400:
        return list(cached[1])
    async with _client_factory() as client:
        params = {"artist": artist, "api_key": api_key, "autocorrect": 1}
        tags = []
        for method in ("track.getTopTags", "artist.getTopTags"):
            try:
                extra = {"track": title} if method.startswith("track.") else {}
                tags = _tags(await _get(client, method=method, **params, **extra))
            except (httpx.HTTPError, ValueError, TypeError):
                continue
            if tags:
                break
    _cache[key] = (time.monotonic(), tags)
    if len(_cache) > 4000:
        del _cache[next(iter(_cache))]
    return list(tags)


async def artist_tags(artist: str, *, api_key: str) -> dict[str, int]:
    """All of the artist's top tags with Last.fm's relative counts (100 = the strongest); {} for an unknown artist."""
    async with _client_factory() as client:
        data = await _get(client, method="artist.getTopTags", artist=artist, api_key=api_key, autocorrect=1)
    if "error" in data:
        return {}
    tags = data.get("toptags", {}).get("tag") or []
    if isinstance(tags, dict):
        tags = [tags]
    result: dict[str, int] = {}
    for tag in tags[:20]:
        name = str(tag.get("name", "")).strip().lower()
        try:
            count = int(tag.get("count", 0))
        except (ValueError, TypeError):
            continue
        if name and count > 0:
            result.setdefault(name, count)
    return result


_tags_task: asyncio.Task | None = None


async def run_artist_tags_once() -> int:
    """Fetches tags for up to 300 artists not checked yet (or 180 days ago); returns how many it looked up."""
    async with SessionLocal() as db:
        api_key = (await load_config(db)).library.lastfm_api_key
        if not api_key:
            return 0
        artists = list((await db.execute(
            select(Artist.id, Artist.name)
            .where(or_(
                Artist.lastfm_checked_at.is_(None),
                Artist.lastfm_checked_at < datetime.now(UTC) - timedelta(days=180),
            ))
            .order_by(Artist.lastfm_checked_at.asc().nulls_first(), Artist.id)
            .limit(300)
        )).all())
    errors = 0
    for id, name in artists:
        # About one lookup per second, well inside Last.fm's limits and next to the other lookups.
        await asyncio.sleep(1)
        try:
            tags = await artist_tags(name, api_key=api_key)
        except (httpx.HTTPError, ValueError, TypeError) as exc:
            errors += 1
            if errors >= 5:
                log.info("Last.fm artist tags unavailable: %s", exc)
                break
            continue
        errors = 0
        async with SessionLocal() as db:
            artist = await db.get(Artist, id)
            if artist is not None:
                artist.lastfm_tags = tags
                artist.lastfm_checked_at = datetime.now(UTC)
                await db.commit()
    return len(artists)


async def _tags_loop() -> None:
    await asyncio.sleep(90)
    while True:
        try:
            looked_up = await run_artist_tags_once()
        except Exception:
            log.exception("Last.fm artist tag loop failed")
            looked_up = 0
        await asyncio.sleep(60 if looked_up else 3600)


async def start() -> None:
    global _tags_task
    if _tags_task is None or _tags_task.done():
        _tags_task = asyncio.create_task(_tags_loop())


async def stop() -> None:
    global _tags_task
    if _tags_task is not None:
        _tags_task.cancel()
        await asyncio.gather(_tags_task, return_exceptions=True)
        _tags_task = None
