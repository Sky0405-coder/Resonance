import asyncio
import logging
import shutil
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

import httpx
from fastapi import HTTPException
from rapidfuzz import fuzz
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload, selectinload

from app.config import get_settings
from app.db import SessionLocal
from app.models import DownloadItem, DownloadRequest, User
from app.schemas import CatalogTrack
from app.services import sources
from app.services.deezer import DeezerError, NotFound, artist_string, deezer
from app.services.importer import quality
from app.services.library_paths import target_relpath
from app.services.matching import match_tracks
from app.services.musicbrainz import TrackMeta
from app.services.resolve import resolve_album, resolve_track
from app.services.scanner import AUDIO_EXTENSIONS, import_file, import_files
from app.services.server_config import load_config
from app.services.sources.base import Cancelled
from app.services.sources.youtube import norm
from app.services.tagger import fetch_cover, write_tags
from app.services.tags import TrackTags, read_tags
from app.services.torrents import TorrentError, prowlarr
from app.services.torrents.qbittorrent import QBittorrent
from app.services.torrents.select import choose, search_query

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
            retry_requests = list(
                await db.scalars(
                    select(DownloadRequest).where(DownloadRequest.torrent_status.in_(["searching", "importing"]))
                )
            )
            changed = {request.id for request in retry_requests}
            for request in retry_requests:
                request.torrent_status = None
                await db.execute(
                    update(DownloadItem).where(DownloadItem.request_id == request.id).values(status="queued")
                )
            rows = list(
                await db.scalars(
                    select(DownloadItem)
                    .join(DownloadRequest)
                    .where(
                        DownloadItem.status.in_(["searching", "downloading", "processing"]),
                        DownloadRequest.torrent_status.is_distinct_from("downloading"),
                    )
                )
            )
            for item in rows:
                item.status = "queued"
            for request_id in changed | {item.request_id for item in rows}:
                request = await db.get(DownloadRequest, request_id)
                await recompute_request(db, request)
            await db.commit()
        self._workers = [asyncio.create_task(self._worker()) for _ in range(get_settings().download_workers)]
        self._workers.append(asyncio.create_task(self._torrent_monitor()))

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
            cfg = await load_config(db)
            item = await db.scalar(
                select(DownloadItem)
                .join(DownloadRequest)
                .where(DownloadItem.status == "queued")
                .order_by(DownloadItem.created_at, DownloadItem.position)
                .with_for_update(
                    skip_locked=True,
                    of=(DownloadItem, DownloadRequest) if cfg.downloads.torrent_enabled else DownloadItem,
                )
                .limit(1)
            )
            if item is None:
                return False
            item.status = "searching"
            # Serialize request aggregate updates across workers processing the same album.
            request = await db.scalar(
                select(DownloadRequest).where(DownloadRequest.id == item.request_id).with_for_update()
            )
            torrent = cfg.downloads.torrent_enabled and request.kind == "album" and request.torrent_status is None
            if torrent:
                request.torrent_status = "searching"
                await db.execute(
                    update(DownloadItem)
                    .where(DownloadItem.request_id == request.id, DownloadItem.status == "queued")
                    .values(status="searching")
                )
            await recompute_request(db, request)
            await db.commit()
        if torrent:
            await self._torrent_start(request.id)
        else:
            await self._run(item)
        return True

    async def _torrent_start(self, request_id: uuid.UUID) -> None:
        try:
            async with SessionLocal() as db:
                request = await db.scalar(
                    select(DownloadRequest)
                    .options(selectinload(DownloadRequest.items))
                    .where(DownloadRequest.id == request_id)
                )
                cfg = await load_config(db)
                metas = [TrackMeta.model_validate(item.meta) for item in request.items]
            meta = metas[0]
            results = await prowlarr.search(cfg, search_query(meta.album_artist, meta.album))
            chosen = choose(
                results,
                meta.album_artist,
                meta.album,
                sum(m.duration or 0 for m in metas),
                cfg.downloads.torrent_min_seeders,
            )
            if chosen is None:
                await self._torrent_fallback(request_id, "Kein passender Torrent gefunden")
                return
            source = chosen.get("magnetUrl") or ""
            if not source.startswith("magnet:"):
                url = chosen.get("downloadUrl")
                if not url:
                    raise TorrentError("Torrent-Downloadadresse fehlt")
                try:
                    async with httpx.AsyncClient(timeout=60, follow_redirects=False) as client:
                        for _ in range(20):
                            response = await client.get(url)
                            location = response.headers.get("Location", "")
                            if location.startswith("magnet:"):
                                source = location
                                break
                            if response.is_redirect and location:
                                url = urljoin(str(response.url), location)
                                continue
                            response.raise_for_status()
                            if response.status_code != 200:
                                raise TorrentError("Torrent-Download fehlgeschlagen")
                            source = response.content
                            break
                        else:
                            raise TorrentError("Zu viele Torrent-Weiterleitungen")
                except httpx.HTTPError as e:
                    raise TorrentError("Torrent-Download fehlgeschlagen") from e
            async with SessionLocal() as db:
                request = await db.scalar(
                    select(DownloadRequest).where(DownloadRequest.id == request_id).with_for_update()
                )
                if request.torrent_status != "searching" or request.status == "cancelled":
                    return
                async with QBittorrent(cfg) as qb:
                    await qb.add(source, str(request.id))
                request.torrent_status = "downloading"
                request.torrent_name = chosen["title"]
                request.torrent_progress = 0
                request.torrent_progress_at = datetime.now(UTC)
                await db.execute(
                    update(DownloadItem)
                    .where(DownloadItem.request_id == request_id, DownloadItem.status == "searching")
                    .values(status="downloading", source="torrent")
                )
                await recompute_request(db, request)
                await db.commit()
        except TorrentError as e:
            await self._torrent_fallback(request_id, str(e))

    async def _torrent_fallback(self, request_id: uuid.UUID, error: str) -> None:
        async with SessionLocal() as db:
            request = await db.scalar(select(DownloadRequest).where(DownloadRequest.id == request_id).with_for_update())
            if request is None or request.status == "cancelled":
                return
            request.torrent_status = "failed"
            request.torrent_error = error
            await db.execute(
                update(DownloadItem)
                .where(DownloadItem.request_id == request_id, DownloadItem.status.in_(["searching", "downloading"]))
                .values(status="queued", source=None, progress=0)
            )
            await recompute_request(db, request)
            await db.commit()
        self.wake()

    async def _torrent_monitor(self) -> None:
        while True:
            await asyncio.sleep(10)
            try:
                async with SessionLocal() as db:
                    ids = list(
                        await db.scalars(
                            select(DownloadRequest.id).where(DownloadRequest.torrent_status == "downloading")
                        )
                    )
                for request_id in ids:
                    await self._torrent_poll(request_id)
            except Exception:
                log.exception("Torrent monitor failed")

    async def _torrent_poll(self, request_id: uuid.UUID) -> None:
        try:
            async with SessionLocal() as db:
                cfg = await load_config(db)
            async with QBittorrent(cfg) as qb:
                info = await qb.info(str(request_id))
                if info is None:
                    await self._torrent_fallback(request_id, "Torrent verschwunden")
                    return
                async with SessionLocal() as db:
                    request = await db.scalar(
                        select(DownloadRequest).where(DownloadRequest.id == request_id).with_for_update()
                    )
                    if request is None or request.torrent_status != "downloading":
                        return
                    progress = info["progress"]
                    now = datetime.now(UTC)
                    if progress > request.torrent_progress:
                        request.torrent_progress_at = now
                    request.torrent_progress = progress
                    await db.execute(
                        update(DownloadItem)
                        .where(DownloadItem.request_id == request_id, DownloadItem.status == "downloading")
                        .values(progress=progress)
                    )
                    stalled = (
                        request.torrent_progress_at is not None
                        and now - request.torrent_progress_at
                        >= timedelta(minutes=cfg.downloads.torrent_timeout_minutes)
                    )
                    await db.commit()
                if progress >= 1:
                    await self._torrent_import(request)
                elif stalled:
                    await qb.delete(info["hash"], True)
                    await self._torrent_fallback(request_id, "Torrent ohne Fortschritt")
        except TorrentError as e:
            await self._torrent_fallback(request_id, str(e))

    async def _torrent_import(self, request: DownloadRequest) -> None:
        async with SessionLocal() as db:
            request = await db.scalar(
                select(DownloadRequest)
                .options(selectinload(DownloadRequest.items))
                .where(DownloadRequest.id == request.id)
                .with_for_update()
            )
            if request.torrent_status != "downloading":
                return
            cfg = await load_config(db)
            async with QBittorrent(cfg) as qb:
                info = await qb.info(str(request.id))
                if info is None:
                    raise TorrentError("Torrent verschwunden")
                files = await qb.files(info["hash"])
            request.torrent_status = "importing"
            items = [item for item in request.items if item.status == "downloading"]
            for item in items:
                item.status = "processing"
            await recompute_request(db, request)
            await db.commit()
        audio: list[tuple[Path, TrackTags]] = []
        for file in files:
            path = Path(info["save_path"]) / file["name"]
            if path.suffix.lower() in AUDIO_EXTENSIONS:
                tags = await asyncio.to_thread(read_tags, path)
                if tags is not None:
                    audio.append((path, tags))
        candidates: dict[uuid.UUID, list[tuple[int, float, int]]] = {}
        metas = {item.id: TrackMeta.model_validate(item.meta) for item in items}
        for item in items:
            meta = metas[item.id]
            pairs = []
            for index, (_, tags) in enumerate(audio):
                ratio = fuzz.token_set_ratio(norm(meta.title), norm(tags.title))
                diff = abs(meta.duration - tags.duration) if meta.duration is not None and tags.duration else None
                if ratio < 85 or (diff is not None and diff > 5):
                    continue
                duration_score = 50 if diff is None else 100 if diff <= 2 else 100 * (15 - diff) / 13
                pairs.append((quality(tags), 0.6 * ratio + 0.4 * duration_score, index))
            candidates[item.id] = sorted(pairs, reverse=True)
        matched: dict[uuid.UUID, int] = {}
        used: set[int] = set()
        while candidates:
            best = []
            for item_id, pairs in candidates.items():
                available = next((pair for pair in pairs if pair[2] not in used), None)
                if available is not None:
                    best.append((item_id, available))
            if not best:
                break
            item_id, pair = max(best, key=lambda candidate: candidate[1][1])
            matched[item_id] = pair[2]
            used.add(pair[2])
            del candidates[item_id]
        for item in items:
            if item.id not in matched:
                await self._change(item.id, status="queued", source=None, progress=0)
                continue
            path = audio[matched[item.id]][0]
            meta = metas[item.id]
            rel = target_relpath(meta, path.suffix)
            target = get_settings().music_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.copy2, path, target)
            cover = await fetch_cover(meta)
            await asyncio.to_thread(write_tags, target, meta, cover, clear_missing=True)
            if cover and not (target.parent / "cover.jpg").exists():
                (target.parent / "cover.jpg").write_bytes(cover)
            async with SessionLocal() as db:
                imported = (await import_files(db, [rel]))[rel]
                if imported is None:
                    raise ValueError("Audiodatei nicht importierbar")
                imported.is_temporary = request.is_temporary
                await db.commit()
            await self._change(item.id, status="done", source="torrent", track_id=imported.id, progress=1, error=None)
        async with SessionLocal() as db:
            request = await db.scalar(select(DownloadRequest).where(DownloadRequest.id == request.id).with_for_update())
            request.torrent_status = "done"
            await recompute_request(db, request)
            await db.commit()
        self.wake()

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
        torrent_active = request.torrent_status in {"searching", "downloading"}
        if request.torrent_status == "downloading":
            try:
                async with QBittorrent(await load_config(db)) as qb:
                    info = await qb.info(str(request.id))
                    if info is not None:
                        await qb.delete(info["hash"], True)
            except Exception:
                log.debug("Torrent cancellation cleanup failed", exc_info=True)
            request.torrent_status = "failed"
            request.torrent_error = "Abgebrochen"
        for item in request.items:
            if item.status in {"waiting", "queued"} or (torrent_active and item.status in {"searching", "downloading"}):
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
