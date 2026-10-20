"""Artist biographies and cached images, refreshed at most 50 artists per hour."""

import asyncio
import logging
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import httpx
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import Artist
from app.services import covers
from app.services.matching import name_key
from app.services.server_config import load_config

log = logging.getLogger(__name__)
_loop_task: asyncio.Task | None = None


@dataclass
class ArtistInfo:
    image_url: str | None = None
    bio_de: str | None = None
    bio_en: str | None = None


def _client_factory() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=20, follow_redirects=True, headers={"User-Agent": "Resonance/1.0"})


def _text(value: str | None) -> str | None:
    return value.strip() or None if value else None


async def fetch(artist_name: str, mbid: str | None = None) -> ArtistInfo:
    info = ArtistInfo()
    async with _client_factory() as client:
        try:
            response = await client.get(
                "https://www.theaudiodb.com/api/v1/json/123/search.php", params={"s": artist_name}
            )
            response.raise_for_status()
            artist = next(
                (
                    a for a in response.json().get("artists") or []
                    if name_key(a.get("strArtist", "")) == name_key(artist_name)
                ),
                None,
            )
            if artist:
                info = ArtistInfo(
                    image_url=_text(artist.get("strArtistThumb")) or _text(artist.get("strArtistFanart")),
                    bio_de=_text(artist.get("strBiographyDE")),
                    bio_en=_text(artist.get("strBiographyEN")),
                )
        except (httpx.HTTPError, ValueError, TypeError):
            log.debug("TheAudioDB lookup failed")
        if not info.image_url and mbid:
            async with SessionLocal() as db:
                key = (await load_config(db)).library.fanarttv_api_key
            if key:
                try:
                    response = await client.get(
                        f"https://webservice.fanart.tv/v3/music/{mbid}", params={"api_key": key}
                    )
                    response.raise_for_status()
                    thumbs = response.json().get("artistthumb") or []
                    if thumbs:
                        info.image_url = thumbs[0].get("url")
                except (httpx.HTTPError, ValueError, TypeError):
                    log.debug("fanart.tv lookup failed")
    return info


def biography(artist: Artist, lang: str) -> str | None:
    return (artist.bio_de or artist.bio_en) if lang == "de" else (artist.bio_en or artist.bio_de)


async def update_artist(db: AsyncSession, artist: Artist) -> None:
    info = await fetch(artist.name, artist.mb_artist_id)
    image = None
    if not artist.image_path and info.image_url:
        try:
            async with _client_factory() as client:
                response = await client.get(info.image_url)
                response.raise_for_status()
                image = await asyncio.to_thread(covers.store, response.content)
        except (httpx.HTTPError, OSError, ValueError):
            log.debug("Artist image download failed")
    # Re-read after HTTP so an image filled in the meantime is preserved.
    await db.refresh(artist)
    if not artist.image_path and image:
        artist.image_path = f"covers/{image}"
    artist.bio_de = info.bio_de or artist.bio_de
    artist.bio_en = info.bio_en or artist.bio_en
    artist.info_checked_at = datetime.now(UTC)
    await db.commit()


async def run_once() -> None:
    async with SessionLocal() as db:
        ids = list(await db.scalars(
            select(Artist.id)
            .where(or_(
                Artist.info_checked_at.is_(None), Artist.info_checked_at < datetime.now(UTC) - timedelta(days=90)
            ))
            .order_by(Artist.info_checked_at.asc().nulls_first(), Artist.id)
            .limit(50)
        ))
    for id in ids:
        try:
            async with SessionLocal() as db:
                artist = await db.get(Artist, id)
                if artist:
                    await update_artist(db, artist)
        except Exception:
            log.exception("Artist info update failed for %s", id)


async def _loop() -> None:
    await asyncio.sleep(60)
    while True:
        try:
            await run_once()
        except Exception:
            log.exception("Artist info loop failed")
        await asyncio.sleep(3600)


async def start() -> None:
    global _loop_task
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_loop())


async def stop() -> None:
    global _loop_task
    if _loop_task is not None:
        _loop_task.cancel()
        await asyncio.gather(_loop_task, return_exceptions=True)
        _loop_task = None
