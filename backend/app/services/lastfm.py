"""Genre-only Last.fm tags; personal, mood and decade tags are deliberately ignored."""

import asyncio
import time

import httpx

from app.db import SessionLocal
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
