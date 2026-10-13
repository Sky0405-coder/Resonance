import asyncio
import logging
import shutil
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi import HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload, selectinload

from app.config import get_settings
from app.db import SessionLocal
from app.models import DownloadItem, DownloadRequest, User
from app.schemas import CatalogTrack
from app.services import sources
from app.services.deezer import DeezerError, NotFound, artist_string, deezer
from app.services.library_paths import target_relpath
from app.services.matching import match_tracks
from app.services.musicbrainz import TrackMeta
from app.services.resolve import resolve_album, resolve_track
from app.services.scanner import import_file
from app.services.server_config import load_config
from app.services.sources.base import Cancelled
from app.services.tagger import fetch_cover, write_tags

log = logging.getLogger(__name__)

# Automatic attempts per item before it is marked failed.
MAX_ATTEMPTS = 3


def request_status(item_statuses: Iterable[str], current: str) -> str:
    statuses = list(item_statuses)
    if current in {"pending_approval", "rejected"}:
        return current
    if any(s in {"waiting", "queued", "searching", "downloading", "processing"} for s in statuses):
        return "active"
    if all(s in {"done", "exists"} for s in statuses):
        return "done"
    if all(s == "cancelled" for s in statuses):
        return "cancelled"
    if any(s in {"done", "exists"} for s in statuses):
        return "partial"
    return "failed"


async def recompute_request(db: AsyncSession, request: DownloadRequest) -> None:
    await db.flush()
    statuses = await db.scalars(select(DownloadItem.status).where(DownloadItem.request_id == request.id))
    request.status = request_status(statuses, request.status)
    request.updated_at = datetime.now(UTC)


def _catalog_track(meta: TrackMeta) -> CatalogTrack:
    return CatalogTrack(
        id=meta.deezer_track_id or "",
        title=meta.title,
        artist=meta.artist,
        artist_id=None,
        duration=meta.duration,
        album=meta.album,
        album_id=meta.deezer_album_id,
        cover_url=meta.cover_url,
        preview_url=None,
        isrc=meta.isrc,
    )


class DownloadManager:
    def __init__(self) -> None:
        self._event = asyncio.Event()
        self._workers: list[asyncio.Task] = []
        self._progress: dict[uuid.UUID, float] = {}
        self._cancelled: set[uuid.UUID] = set()

    async def start(self) -> None:
        async with SessionLocal() as db:
            rows = list(
                await db.scalars(
                    select(DownloadItem).where(DownloadItem.status.in_(["searching", "downloading", "processing"]))
                )
            )
            for item in rows:
                item.status = "queued"
            for request_id in {item.request_id for item in rows}:
                request = await db.get(DownloadRequest, request_id)
                await recompute_request(db, request)
            await db.commit()
        self._workers = [asyncio.create_task(self._worker()) for _ in range(get_settings().download_workers)]

    async def stop(self) -> None:
        for worker in self._workers:
            worker.cancel()
        await asyncio.gather(*self._workers, return_exceptions=True)
        self._workers.clear()

    def wake(self) -> None:
        self._event.set()

    async def _worker(self) -> None:
        while True:
            self._event.clear()
            try:
                if await self.process_one():
                    continue
                await asyncio.wait_for(self._event.wait(), timeout=10)
            except TimeoutError:
                pass
            except Exception:
                log.exception("Download worker failed")
                await asyncio.sleep(10)

    async def process_one(self) -> bool:
        async with SessionLocal() as db:
            item = await db.scalar(
                select(DownloadItem)
                .where(DownloadItem.status == "queued")
                .order_by(DownloadItem.created_at, DownloadItem.position)
                .with_for_update(skip_locked=True)
                .limit(1)
            )
            if item is None:
                return False
            item.status = "searching"
            # Serialize request aggregate updates across workers processing the same album.
            request = await db.scalar(
                select(DownloadRequest).where(DownloadRequest.id == item.request_id).with_for_update()
            )
            await recompute_request(db, request)
            await db.commit()
        await self._run(item)
        return True

    async def _change(self, item_id: uuid.UUID, **values: Any) -> None:
        async with SessionLocal() as db:
            item = await db.get(DownloadItem, item_id)
            request = await db.scalar(
                select(DownloadRequest).where(DownloadRequest.id == item.request_id).with_for_update()
            )
            for key, value in values.items():
                setattr(item, key, value)
            await recompute_request(db, request)
            await db.commit()

    async def _write_progress(self, item_id: uuid.UUID, finished: asyncio.Event) -> None:
        while not finished.is_set():
            try:
                await asyncio.wait_for(finished.wait(), timeout=2)
            except TimeoutError:
                async with SessionLocal() as db:
                    await db.execute(
                        update(DownloadItem)
                        .where(DownloadItem.id == item_id, DownloadItem.status == "downloading")
                        .values(progress=self._progress.get(item_id, 0))
                    )
                    await db.commit()

    async def _run(self, item: DownloadItem) -> None:
        work = get_settings().downloads_dir / "resonance" / str(item.id)
        progress_task: asyncio.Task | None = None
        finished = asyncio.Event()
        try:
            meta = TrackMeta.model_validate(item.meta)
            async with SessionLocal() as db:
                track = _catalog_track(meta)
                await match_tracks(db, [track])
                cfg = await load_config(db)
                request = await db.get(DownloadRequest, item.request_id)
                temporary = request.is_temporary
            if item.id in self._cancelled:
                raise Cancelled()
            if track.library_id:
                await self._change(item.id, status="exists", track_id=track.library_id)
                return
            enabled = sources.enabled_sources(cfg)
            if not enabled:
                await self._change(item.id, status="failed", error="Keine Download-Quelle aktiviert")
                return
            chosen = None
            for source in enabled:
                candidate = await source.find(meta)
                if item.id in self._cancelled:
                    raise Cancelled()
                if candidate is not None:
                    chosen = source, candidate
                    break
            if chosen is None:
                await self._change(item.id, status="failed", error="Keine passende Quelle gefunden")
                return
            source, candidate = chosen
            await self._change(item.id, status="downloading", source=candidate.source, source_ref=candidate.ref)
            if work.exists():
                await asyncio.to_thread(shutil.rmtree, work)
            work.mkdir(parents=True)
            self._progress[item.id] = 0
            progress_task = asyncio.create_task(self._write_progress(item.id, finished))

            def progress(value: float) -> None:
                self._progress[item.id] = min(1.0, max(0.0, value))

            path = await source.download(candidate, work, progress, lambda: item.id in self._cancelled)
            finished.set()
            await progress_task
            progress_task = None
            if item.id in self._cancelled:
                raise Cancelled()
            await self._change(item.id, status="processing")
            cover = await fetch_cover(meta)
            await asyncio.to_thread(write_tags, path, meta, cover)
            rel = target_relpath(meta, path.suffix)
            target = get_settings().music_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.move, str(path), str(target))
            if cover and not (target.parent / "cover.jpg").exists():
                (target.parent / "cover.jpg").write_bytes(cover)
            async with SessionLocal() as db:
                imported = await import_file(db, rel)
                if imported is None:
                    raise ValueError("Audiodatei nicht importierbar")
                imported.is_temporary = temporary
                await db.commit()
            await self._change(item.id, status="done", track_id=imported.id, progress=1, error=None)
        except Cancelled:
            await self._change(item.id, status="cancelled")
        except Exception as e:
            log.exception("Download failed for %s", item.id)
            attempts = item.attempts + 1
            # YouTube answers sporadic 403s; a fresh attempt usually works.
            await self._change(
                item.id,
                attempts=attempts,
                status="queued" if attempts < MAX_ATTEMPTS else "failed",
                error=f"Download fehlgeschlagen: {e}"[:500],
            )
        finally:
            finished.set()
            if progress_task is not None:
                await progress_task
            self._progress.pop(item.id, None)
            self._cancelled.discard(item.id)
            await asyncio.to_thread(shutil.rmtree, work, True)

    async def cancel_request(self, db: AsyncSession, request: DownloadRequest) -> None:
        for item in request.items:
            if item.status in {"waiting", "queued"}:
                item.status = "cancelled"
            elif item.status in {"searching", "downloading"}:
                self._cancelled.add(item.id)
        await recompute_request(db, request)
        await db.commit()


manager = DownloadManager()


async def create_request(db: AsyncSession, user: User, kind: str, catalog_id: str, temporary: bool) -> DownloadRequest:
    existing = await db.scalar(
        select(DownloadRequest)
        .options(selectinload(DownloadRequest.items), joinedload(DownloadRequest.user))
        .where(
            DownloadRequest.user_id == user.id,
            DownloadRequest.kind == kind,
            DownloadRequest.catalog_id == catalog_id,
            DownloadRequest.status.in_(["pending_approval", "active"]),
        )
    )
    if existing is not None:
        return existing
    try:
        if kind == "track":
            metas = [await resolve_track(catalog_id)]
            track = await deezer.track(catalog_id)
            album = await deezer.album(str(track["album"]["id"]))
            title, artist = track["title"], artist_string(track)
        else:
            album, metas = await resolve_album(catalog_id)
            title, artist = album["title"], album.get("artist", {}).get("name", "")
    except NotFound as e:
        raise HTTPException(404, "Nicht im Katalog gefunden") from e
    except DeezerError as e:
        raise HTTPException(502, "Katalog nicht erreichbar") from e
    tracks = [_catalog_track(meta) for meta in metas]
    await match_tracks(db, tracks)
    cfg = await load_config(db)
    if cfg.downloads.daily_limit_enabled and not user.is_admin:
        count = (
            await db.scalar(
                select(func.count())
                .select_from(DownloadItem)
                .join(DownloadRequest)
                .where(
                    DownloadRequest.user_id == user.id,
                    DownloadRequest.created_at >= datetime.now(UTC) - timedelta(hours=24),
                    DownloadItem.status != "exists",
                )
            )
            or 0
        )
        limit = cfg.downloads.daily_limit_per_user
        if count + sum(t.library_id is None for t in tracks) > limit:
            raise HTTPException(429, f"Tageslimit erreicht ({count} von {limit} Songs in 24 Stunden)")
    approved = user.is_admin or cfg.downloads.auto_approve_requests
    first = metas[0] if metas else None
    request = DownloadRequest(
        user=user,
        kind=kind,
        catalog_id=catalog_id,
        mb_id=(first.mb_recording_id if kind == "track" else first.mb_release_group_id) if first else None,
        mb_release_id=first.mb_release_id if first else None,
        title=title,
        artist=artist,
        cover_url=album.get("cover_medium"),
        status="active" if approved else "pending_approval",
        is_temporary=temporary and user.is_admin,
        items=[
            DownloadItem(
                position=i,
                title=m.title,
                artist=m.artist,
                duration=m.duration,
                meta=m.model_dump(),
                status="exists" if t.library_id else "queued" if approved else "waiting",
                track_id=t.library_id,
            )
            for i, (m, t) in enumerate(zip(metas, tracks, strict=True))
        ],
    )
    db.add(request)
    await db.flush()
    await recompute_request(db, request)
    await db.commit()
    await db.refresh(request, ["updated_at"])
    manager.wake()
    return request
