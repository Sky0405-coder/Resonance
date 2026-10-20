"""Optional Discogs release metadata for the library editor."""

import asyncio
import re
from datetime import UTC, datetime
from email.utils import parsedate_to_datetime

import httpx

from app.db import SessionLocal
from app.services.musicbrainz import TrackMeta
from app.services.server_config import load_config


class DiscogsError(Exception):
    pass


def _client_factory(token: str) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url="https://api.discogs.com/",
        timeout=20,
        headers={"User-Agent": "Resonance/1.0", "Authorization": f"Discogs token={token}"},
    )


def _retry_after(value: str) -> float:
    try:
        delay = float(value)
    except ValueError:
        try:
            delay = (parsedate_to_datetime(value) - datetime.now(UTC)).total_seconds()
        except (ValueError, TypeError, OverflowError):
            delay = 1
    return max(0, min(delay, 5))


async def _get(path: str, **params) -> dict:
    async with SessionLocal() as db:
        token = (await load_config(db)).library.discogs_token
    if not token:
        raise DiscogsError("Kein Discogs-Token eingetragen")
    try:
        async with _client_factory(token) as client:
            for attempt in range(2):
                response = await client.get(path, params=params or None)
                if response.status_code == 429 and attempt == 0:
                    await asyncio.sleep(_retry_after(response.headers.get("Retry-After", "1")))
                    continue
                response.raise_for_status()
                return response.json()
    except (httpx.HTTPError, ValueError) as e:
        raise DiscogsError("Discogs nicht erreichbar") from e
    raise DiscogsError("Discogs nicht erreichbar")


async def search_releases(artist: str, album: str, limit: int = 8) -> list[dict]:
    params = {"type": "release", "per_page": limit}
    if artist:
        params["artist"] = artist
        params["release_title"] = album
    else:
        params["q"] = album
    return (await _get("database/search", **params)).get("results") or []


async def release(id: str) -> dict:
    return await _get(f"releases/{id}")


def primary_image(data: dict) -> str | None:
    images = data.get("images") or []
    image = next((i for i in images if i.get("type") == "primary"), images[0] if images else {})
    return image.get("uri")


def position_numbers(position: str) -> tuple[int | None, int | None]:
    value = position.strip()
    if match := re.fullmatch(r"(\d+)[.-](\d+)", value):
        return int(match[1]), int(match[2])
    if match := re.fullmatch(r"([A-Za-z])(\d+)", value):
        # A/B are the two sides of disc one, C/D of disc two, etc.
        return (ord(match[1].upper()) - ord("A")) // 2 + 1, int(match[2])
    if value.isdigit():
        return 1, int(value)
    return None, None


def _credit(artists: list[dict]) -> str:
    return " ".join(
        f"{re.sub(r' \(\d+\)$', '', a.get('name', ''))} {a.get('join', '')}".strip() for a in artists
    ).strip()


async def release_metas(id: str) -> list[TrackMeta]:
    data = await release(id)
    album_artist = _credit(data.get("artists") or [])
    genres = data.get("styles") or data.get("genres") or []
    tracks = [t for t in data.get("tracklist", []) if t.get("type_", "track") == "track" and t.get("position")]
    metas = []
    for track in tracks:
        disc_no, track_no = position_numbers(track["position"])
        duration = None
        if re.fullmatch(r"\d+:\d{2}", track.get("duration") or ""):
            minutes, seconds = track["duration"].split(":")
            duration = int(minutes) * 60 + int(seconds)
        metas.append(
            TrackMeta(
                title=track["title"],
                artist=_credit(track.get("artists") or []) or album_artist,
                artist_mbid=None,
                album=data["title"],
                album_artist=album_artist,
                album_artist_mbid=None,
                track_no=track_no,
                track_total=None,
                disc_no=disc_no,
                disc_total=None,
                year=data.get("year") or None,
                date=None,
                duration=duration,
                isrc=None,
                genre=genres[0] if genres else None,
                label=next((l["name"] for l in data.get("labels", []) if l.get("name")), None),
                mb_recording_id=None,
                mb_release_id=None,
                mb_release_group_id=None,
                cover_url=primary_image(data),
            )
        )
    for meta in metas:
        meta.disc_total = max((m.disc_no or 1 for m in metas), default=1)
        meta.track_total = sum(m.disc_no == meta.disc_no for m in metas)
    return metas
