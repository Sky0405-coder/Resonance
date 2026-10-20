import asyncio
import logging
import uuid
from datetime import UTC, datetime, timedelta

from rapidfuzz import fuzz
from sqlalchemy import func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import (
    Album,
    DownloadItem,
    DownloadRequest,
    QualityUpgradeAttempt,
    Role,
    Track,
    User,
)
from app.services.deezer import NotFound, deezer
from app.services.downloads import manager
from app.services.duplicates import lossless_twin
from app.services.matching import name_key
from app.services.resolve import resolve_album
from app.services.server_config import load_config

log = logging.getLogger(__name__)
_loop_task: asyncio.Task | None = None
_run_lock = asyncio.Lock()
_LOSSLESS = {"flac", "alac", "wav", "aiff", "ape", "wavpack"}


def needs_upgrade(track: Track) -> bool:
    codec = (track.codec or "").casefold()
    return (
        not track.is_temporary
        and codec not in _LOSSLESS
        and (codec == "opus" or track.bitrate is None or track.bitrate < 256)
    )


async def _attempt(db: AsyncSession, album_id: uuid.UUID, result: str) -> None:
    attempt = await db.get(QualityUpgradeAttempt, album_id)
    if attempt is None:
        db.add(QualityUpgradeAttempt(album_id=album_id, result=result))
    else:
        attempt.tried_at = datetime.now(UTC)
        attempt.result = result
    await db.commit()


async def request_upgrade(db: AsyncSession, album: Album) -> None:
    tracks = list(
        await db.scalars(select(Track).where(Track.album_id == album.id).order_by(Track.disc_no, Track.track_no))
    )
    await db.refresh(album, ["artist"])
    metas = await db.scalars(
        select(DownloadItem.meta)
        .where(DownloadItem.status == "done", DownloadItem.track_id.in_([track.id for track in tracks]))
        .order_by(DownloadItem.created_at)
    )
    deezer_id = next((meta["deezer_album_id"] for meta in metas if meta.get("deezer_album_id")), None)
    if deezer_id is None:
        results = await deezer.search_albums(f"{album.artist.name} {album.title}", 10)
        deezer_id = next(
            (
                str(result["id"])
                for result in results
                if name_key(result["title"]) == name_key(album.title)
                and name_key(result.get("artist", {}).get("name", "")) == name_key(album.artist.name)
            ),
            None,
        )
    if deezer_id is None:
        await _attempt(db, album.id, "no_catalog")
        return
    try:
        catalog, metas = await resolve_album(str(deezer_id))
    except NotFound:
        await _attempt(db, album.id, "no_catalog")
        return
    matched = []
    for track in tracks:
        if not needs_upgrade(track) or await lossless_twin(db, track) is not None:
            continue
        meta = next(
            (
                meta
                for meta in metas
                if (
                    name_key(track.title) == name_key(meta.title)
                    or fuzz.token_set_ratio(name_key(track.title), name_key(meta.title)) >= 90
                )
                and meta.duration is not None
                and abs(track.duration - meta.duration) <= 5
            ),
            None,
        )
        if meta is not None:
            matched.append((track, meta))
    if not matched:
        await _attempt(db, album.id, "no_catalog")
        return
    admin = await db.scalar(select(User).where(User.role == Role.admin).order_by(User.created_at).limit(1))
    if admin is None:
        await _attempt(db, album.id, "failed")
        return
    db.add(
        DownloadRequest(
            kind="upgrade",
            user=admin,
            catalog_id=str(deezer_id),
            title=album.title,
            artist=album.artist.name,
            cover_url=catalog.get("cover_medium"),
            status="active",
            is_temporary=False,
            items=[
                DownloadItem(
                    position=position,
                    meta=meta.model_dump(),
                    replace_track_id=track.id,
                    status="queued",
                    title=meta.title,
                    artist=meta.artist,
                    duration=meta.duration,
                )
                for position, (track, meta) in enumerate(matched)
            ],
        )
    )
    await _attempt(db, album.id, "requested")
    manager.wake()


async def run_once() -> None:
    if _run_lock.locked():
        return
    async with _run_lock, SessionLocal() as db:
        cfg = await load_config(db)
        if not (cfg.downloads.quality_upgrade_enabled and cfg.downloads.torrent_enabled):
            return
        if await db.scalar(
            select(DownloadRequest.id)
            .where(DownloadRequest.kind == "upgrade", DownloadRequest.status == "active")
            .limit(1)
        ):
            return
        codec = func.lower(func.coalesce(Track.codec, ""))
        album_ids = list(
            await db.scalars(
                select(Album.id)
                .where(
                    Album.tracks.any(
                        ~Track.is_temporary
                        & codec.not_in(_LOSSLESS)
                        & or_(codec == "opus", Track.bitrate.is_(None), Track.bitrate < 256)
                    ),
                    ~select(QualityUpgradeAttempt.album_id)
                    .where(
                        QualityUpgradeAttempt.album_id == Album.id,
                        QualityUpgradeAttempt.tried_at >= datetime.now(UTC) - timedelta(days=30),
                    )
                    .exists(),
                )
                .order_by(Album.created_at, Album.id)
                .limit(3)
            )
        )
        for album_id in album_ids:
            try:
                album = await db.get(Album, album_id)
                if album is None:
                    continue
                await request_upgrade(db, album)
            except Exception:
                log.exception("Quality upgrade request failed for album %s", album_id)
                await db.rollback()
                await _attempt(db, album_id, "failed")


async def _upgrade_loop() -> None:
    await asyncio.sleep(600)
    while True:
        try:
            await run_once()
        except Exception:
            log.exception("Quality upgrade scheduler failed")
        await asyncio.sleep(6 * 60 * 60)


async def start() -> None:
    global _loop_task
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_upgrade_loop())


async def stop() -> None:
    global _loop_task
    if _loop_task is not None:
        _loop_task.cancel()
        await asyncio.gather(_loop_task, return_exceptions=True)
        _loop_task = None
