"""Best-effort genre enrichment and the admin's bounded genre fill job."""

import asyncio
import logging
import uuid
from datetime import UTC, datetime

from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import Album, Job, Track
from app.services import lastfm
from app.services.identify import AlbumCtx, _tag_meta
from app.services.musicbrainz import TrackMeta, mb
from app.services.scanner import library_lock
from app.services.server_config import LibraryConfig, load_config
from app.services.tagger import write_tags
from app.services.tags import read_tags
from app.services.views import track_options

log = logging.getLogger(__name__)
_task: asyncio.Task | None = None
_start_lock = asyncio.Lock()


async def enrich(meta: TrackMeta, cfg: LibraryConfig) -> None:
    if meta.genre and meta.genre.strip():
        return
    if cfg.lastfm_api_key:
        try:
            tags = await lastfm.track_tags(meta.artist, meta.title, api_key=cfg.lastfm_api_key)
            if tags:
                meta.genre = tags[0]
                return
        except Exception:  # noqa: BLE001 - optional enrichment must never block a match
            log.debug("Last.fm genre lookup failed")
    if meta.mb_recording_id or meta.mb_release_group_id or meta.mb_release_id:
        try:
            group_id = meta.mb_release_group_id
            meta.genre = await mb.genre(meta.mb_recording_id, group_id)
            if not meta.genre and not group_id and meta.mb_release_id:
                release = await mb.release_full(meta.mb_release_id)
                group_id = (release.get("release-group") or {}).get("id")
                meta.genre = await mb.genre(None, group_id)
        except Exception:  # noqa: BLE001 - optional enrichment must never block a match
            log.debug("MusicBrainz genre lookup failed")


async def _fill_track(db: AsyncSession, track_id: uuid.UUID, cfg: LibraryConfig) -> None:
    track = await db.scalar(select(Track).where(Track.id == track_id).options(*track_options()))
    if track is None or (track.genre and track.genre.strip()):
        return
    path = get_settings().music_dir / track.path
    tags = await asyncio.to_thread(read_tags, path)
    if tags is None:
        return
    meta = _tag_meta(tags, AlbumCtx(tags.album, tags.album_artist or tags.artist, tags.year, tags.disc_total))
    meta.artist, meta.title = track.artist_credit, track.title
    meta.mb_recording_id = meta.mb_recording_id or track.mb_recording_id
    meta.mb_release_id = meta.mb_release_id or track.album.mb_release_id
    # A tag already on disk must be preserved too, even when the DB was missing it.
    await enrich(meta, cfg)
    if not meta.genre:
        return
    async with library_lock:
        await db.refresh(track)
        if track.genre and track.genre.strip():
            return
        if path != get_settings().music_dir / track.path:
            return
        current = await asyncio.to_thread(read_tags, path)
        if current is None:
            return
        updated = _tag_meta(
            current, AlbumCtx(current.album, current.album_artist or current.artist, current.year, current.disc_total)
        )
        updated.genre = current.genre if current.genre and current.genre.strip() else meta.genre
        await asyncio.to_thread(write_tags, path, updated, None)
        stat = await asyncio.to_thread(path.stat)
        track.genre, track.mtime, track.size = updated.genre, stat.st_mtime, stat.st_size
        album = await db.get(Album, track.album_id, populate_existing=True)
        if album and not (album.genre and album.genre.strip()):
            album.genre = updated.genre
        await db.commit()


async def _run(job_id: uuid.UUID, ids: list[uuid.UUID], cfg: LibraryConfig) -> None:
    try:
        async with SessionLocal() as db:
            job = await db.get(Job, job_id)
            job.status = "running"
            await db.commit()
            for done, track_id in enumerate(ids, 1):
                try:
                    async with SessionLocal() as track_db:
                        await _fill_track(track_db, track_id, cfg)
                except Exception:
                    log.exception("Genre fill failed for track %s", track_id)
                job.progress = done / len(ids)
                job.message = f"{done} / {len(ids)}"
                await db.commit()
            job.status, job.progress = "done", 1
            job.finished_at = datetime.now(UTC)
            await db.commit()
    except Exception:
        log.exception("Genre fill job failed")
        async with SessionLocal() as db:
            job = await db.get(Job, job_id)
            job.status, job.message = "failed", "Genres konnten nicht ergänzt werden"
            job.finished_at = datetime.now(UTC)
            await db.commit()


async def start_fill(db: AsyncSession) -> Job:
    global _task
    async with _start_lock:
        active = await db.scalar(select(Job).where(Job.kind == "genres", Job.status.in_(["queued", "running"])))
        if active:
            return active
        cfg = (await load_config(db)).library
        if not cfg.lastfm_api_key:
            raise HTTPException(409, "Kein Last.fm-Schlüssel eingetragen")
        ids = list(await db.scalars(
            select(Track.id).where(func.coalesce(func.trim(Track.genre), "") == "").order_by(Track.id).limit(2000)
        ))
        job = Job(kind="genres", status="queued", progress=0, message=f"0 / {len(ids)}")
        db.add(job)
        await db.commit()
        await db.refresh(job)
        _task = asyncio.create_task(_run(job.id, ids, cfg))
        return job


async def start() -> None:
    async with SessionLocal() as db:
        for job in await db.scalars(select(Job).where(Job.kind == "genres", Job.status.in_(["queued", "running"]))):
            job.status, job.message = "failed", "Durch Neustart abgebrochen"
            job.finished_at = datetime.now(UTC)
        await db.commit()


async def stop() -> None:
    global _task
    if _task is not None:
        _task.cancel()
        await asyncio.gather(_task, return_exceptions=True)
        _task = None
