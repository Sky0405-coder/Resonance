import asyncio
import logging
import os
import shutil
import tempfile
import time
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from fastapi import HTTPException
from rapidfuzz import fuzz
from sqlalchemy import delete, func, select, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload, selectinload

from app.config import get_settings
from app.db import SessionLocal
from app.models import Album, DownloadItem, DownloadRequest, QualityUpgradeAttempt, Track, TrackLyrics, User
from app.schemas import CatalogTrack
from app.services import scanner, sources
from app.services.deezer import DeezerError, NotFound, artist_string, deezer
from app.services.duplicates import _same_stem_track, merge_group, merge_new_duplicates, track_quality
from app.services.importer import quality
from app.services.library_paths import target_relpath
from app.services.lyrics import sidecar_path
from app.services.matching import match_tracks, name_key
from app.services.musicbrainz import TrackMeta
from app.services.resolve import explicit_album_id, explicit_track_id, resolve_album, resolve_track
from app.services.scanner import AUDIO_EXTENSIONS, import_file, import_files
from app.services.server_config import load_config
from app.services.sources.base import Cancelled
from app.services.sources.soundcloud import track_url
from app.services.sources.youtube import norm, video_id
from app.services.tagger import fetch_cover, write_tags
from app.services.tags import TrackTags, embedded_cover, read_tags
from app.services.torrents import TorrentError, obtain_source, prowlarr
from app.services.torrents.qbittorrent import QBittorrent
from app.services.torrents.select import choose, search_query

log = logging.getLogger(__name__)

# Automatic attempts per item before it is marked failed.
MAX_ATTEMPTS = 3
# YouTube's "Sign in to confirm you're not a bot" is a temporary IP block after many downloads: pause instead of failing.
BOT_CHECK = "confirm you’re not a bot"
BOT_PAUSE_SECONDS = 1800
BOT_PAUSED = "YouTube blockiert gerade – neuer Versuch in 30 Minuten"


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
        self._paused_until = 0.0

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
        if time.monotonic() < self._paused_until:
            return False
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
            if request.kind == "upgrade" and not cfg.downloads.torrent_enabled:
                await db.commit()
                await self._torrent_fallback(request.id, "Torrents sind deaktiviert")
                return True
            torrent = cfg.downloads.torrent_enabled and (
                request.kind == "upgrade" or (request.kind == "album" and request.torrent_status is None)
            )
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
            source = await obtain_source(chosen)
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
            upgrade = request.kind == "upgrade"
            await db.execute(
                update(DownloadItem)
                .where(
                    DownloadItem.request_id == request_id,
                    DownloadItem.status.in_(["queued", "searching", "downloading", "processing"])
                    if upgrade
                    else DownloadItem.status.in_(["searching", "downloading"]),
                )
                .values(
                    status="failed" if upgrade else "queued",
                    source=None,
                    progress=0,
                    **({"error": error} if upgrade else {}),
                )
            )
            if upgrade:
                attempt = await self._upgrade_attempt(db, request_id)
                if attempt is not None:
                    attempt.result = "no_torrent" if error == "Kein passender Torrent gefunden" else "failed"
            await recompute_request(db, request)
            await db.commit()
        self.wake()

    async def _upgrade_attempt(self, db: AsyncSession, request_id: uuid.UUID) -> QualityUpgradeAttempt | None:
        return await db.scalar(
            select(QualityUpgradeAttempt)
            .join(Track, Track.album_id == QualityUpgradeAttempt.album_id)
            .join(DownloadItem, DownloadItem.replace_track_id == Track.id)
            .where(DownloadItem.request_id == request_id)
            .limit(1)
        )

    async def _torrent_monitor(self) -> None:
        last_cleanup: float | None = None
        while True:
            await asyncio.sleep(10)
            if last_cleanup is None or time.monotonic() - last_cleanup >= 3600:
                last_cleanup = time.monotonic()
                try:
                    await self.torrent_cleanup()
                except Exception:
                    log.exception("Torrent cleanup failed")
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

    async def torrent_cleanup(self) -> int:
        """Delete finished torrents (and their files) once they seeded long enough; the library has its own copies."""
        async with SessionLocal() as db:
            cfg = await load_config(db)
            if not cfg.downloads.torrent_enabled:
                return 0
            busy = {
                str(i)
                for i in await db.scalars(
                    select(DownloadRequest.id).where(
                        DownloadRequest.torrent_status.in_(["searching", "downloading", "importing"])
                    )
                )
            }
        cutoff = time.time() - cfg.downloads.torrent_seed_days * 86400
        deleted = 0
        async with QBittorrent(cfg) as qb:
            for torrent in await qb.all():
                tags = {t.strip() for t in str(torrent.get("tags") or "").split(",")}
                completed = torrent.get("completion_on") or 0
                if tags & busy:
                    continue
                added = torrent.get("added_on") or 0
                if torrent.get("progress", 0) < 1:
                    # Left behind by a failed/cancelled request: it would block a download slot forever.
                    if 0 < added <= time.time() - 3600:
                        await qb.delete(torrent["hash"], True)
                        deleted += 1
                    continue
                if completed <= 0:
                    continue
                if torrent.get("state") in {"stoppedUP", "pausedUP"} or completed <= cutoff:
                    await qb.delete(torrent["hash"], True)
                    deleted += 1
        return deleted

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
            # qBittorrent briefly unreachable (VPN reconnect, redeploy): keep waiting, the stall timeout still applies.
            async with SessionLocal() as db:
                request = await db.get(DownloadRequest, request_id)
                cfg = await load_config(db)
            since = request.torrent_progress_at if request is not None else None
            timeout = timedelta(minutes=cfg.downloads.torrent_timeout_minutes)
            if since is not None and datetime.now(UTC) - since < timeout:
                log.warning("Torrent poll failed for %s: %s", request_id, e)
                return
            await self._torrent_fallback(request_id, str(e))
        except Exception as e:
            async with SessionLocal() as db:
                request = await db.get(DownloadRequest, request_id)
                if request is None or request.kind != "upgrade":
                    raise
            log.exception("Quality upgrade torrent failed for %s", request_id)
            await self._torrent_fallback(request_id, f"Download fehlgeschlagen: {e}"[:500])

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
            attempt = await self._upgrade_attempt(db, request.id) if request.kind == "upgrade" else None
            attempt_album_id = attempt.album_id if attempt is not None else None
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
        upgraded = False
        for item in items:
            if item.id not in matched:
                if request.kind == "upgrade":
                    await self._change(item.id, status="failed", error="Nicht im Torrent enthalten")
                else:
                    await self._change(item.id, status="queued", source=None, progress=0)
                continue
            path = audio[matched[item.id]][0]
            meta = metas[item.id]
            if request.kind == "upgrade":
                async with SessionLocal() as db:
                    track = await db.get(Track, item.replace_track_id) if item.replace_track_id else None
                if track is None:
                    await self._change(item.id, status="failed", error="Song wurde gelöscht")
                    continue
                current = await asyncio.to_thread(read_tags, get_settings().music_dir / track.path)
                if quality(audio[matched[item.id]][1]) <= quality(current):
                    await self._change(item.id, status="exists", track_id=track.id, progress=1, error=None)
                    continue
                imported = await self._replace(track.id, path, meta, copy=True)
                if imported is None:
                    await self._change(item.id, status="failed", error="Song wurde gelöscht")
                    continue
                upgraded = True
                await self._change(
                    item.id, status="done", source="torrent", track_id=imported.id, progress=1, error=None
                )
                continue
            rel = target_relpath(meta, path.suffix)
            target = get_settings().music_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.copy2, path, target)
            sidecar = await asyncio.to_thread(sidecar_path, path)
            if sidecar is not None:
                await asyncio.to_thread(shutil.copy2, sidecar, target.with_suffix(".lrc"))
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
            if attempt_album_id is not None:
                attempt = await db.get(QualityUpgradeAttempt, attempt_album_id)
                if attempt is not None:
                    attempt.result = "upgraded" if upgraded else "not_better"
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
        if values.get("status") == "done":
            from app.services import radio, spotify

            spotify.resolve_after_download()
            radio.resolve_after_download()

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

    async def _replace(
        self, track_id: uuid.UUID | None, path: Path, meta: TrackMeta, *, copy: bool = False
    ) -> Track | None:
        async with scanner.library_lock, SessionLocal() as db:
            track = await db.get(Track, track_id, with_for_update=True) if track_id else None
            if track is None:
                return None
            old = get_settings().music_dir / track.path
            new_rel = str(Path(track.path).with_suffix(path.suffix))
            target = get_settings().music_dir / new_rel

            def replace() -> None:
                cover = embedded_cover(old)
                folder_cover = old.parent / "cover.jpg"
                if cover is None and folder_cover.is_file():
                    cover = folder_cover.read_bytes()
                if not copy:
                    write_tags(path, meta, cover)
                with tempfile.NamedTemporaryFile(
                    dir=target.parent, prefix=".redownload-", suffix=path.suffix if copy else "", delete=False
                ) as temp:
                    staged = Path(temp.name)
                try:
                    if copy:
                        shutil.copy2(path, staged)
                        write_tags(staged, meta, cover)
                    else:
                        shutil.move(str(path), str(staged))
                    os.replace(staged, target)
                finally:
                    staged.unlink(missing_ok=True)
                if new_rel != track.path:
                    sidecar = sidecar_path(old)
                    if sidecar is not None and sidecar != target.with_suffix(".lrc"):
                        os.replace(sidecar, target.with_suffix(".lrc"))
                    old.unlink(missing_ok=True)

            await asyncio.to_thread(replace)
            track.path = new_rel
            await db.execute(delete(TrackLyrics).where(TrackLyrics.track_id == track.id))
            imported = (await import_files(db, [new_rel], locked=True))[new_rel]
            if imported is None:
                raise ValueError("Audiodatei nicht importierbar")
            return imported

    async def _run(self, item: DownloadItem) -> None:
        work = get_settings().downloads_dir / "resonance" / str(item.id)
        progress_task: asyncio.Task | None = None
        finished = asyncio.Event()
        try:
            meta = TrackMeta.model_validate(item.meta)
            async with SessionLocal() as db:
                cfg = await load_config(db)
                request = await db.get(DownloadRequest, item.request_id)
                redownload = request.kind == "redownload"
                temporary = request.is_temporary
                track = _catalog_track(meta)
                if not redownload:
                    await match_tracks(db, [track])
                replacement_exists = not redownload or (
                    request.replace_track_id is not None and await db.get(Track, request.replace_track_id) is not None
                )
            if item.id in self._cancelled:
                raise Cancelled()
            if not replacement_exists:
                await self._change(item.id, status="failed", error="Song wurde gelöscht")
                return
            if track.library_id:
                await self._change(item.id, status="exists", track_id=track.library_id)
                return
            enabled = sources.enabled_sources(cfg)
            forced = item.source in {"youtube", "soundcloud"} and item.source_ref and (redownload or item.source_pinned)
            if forced:
                enabled = [source for source in enabled if source.name == item.source]
            if not enabled:
                await self._change(item.id, status="failed", error="Keine Download-Quelle aktiviert")
                return
            chosen = None
            for source in enabled:
                if forced:
                    candidate = source.candidate(item.source_ref)
                elif redownload:
                    candidate = await source.find(meta, frozenset(item.exclude_refs))
                else:
                    candidate = await source.find(meta)
                if item.id in self._cancelled:
                    raise Cancelled()
                if candidate is not None:
                    chosen = source, candidate
                    break
            if chosen is None:
                await self._change(
                    item.id,
                    status="failed",
                    error="Keine andere Version gefunden" if redownload else "Keine passende Quelle gefunden",
                )
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
            if redownload:
                imported = await self._replace(request.replace_track_id, path, meta)
                if imported is None:
                    await self._change(item.id, status="failed", error="Song wurde gelöscht")
                    return
                await self._change(item.id, status="done", track_id=imported.id, progress=1, error=None)
                return
            cover = await fetch_cover(meta)
            await asyncio.to_thread(write_tags, path, meta, cover)
            rel = target_relpath(meta, path.suffix, unique=False)
            async with SessionLocal() as db:
                existing = await _same_stem_track(db, rel)
                if existing is not None and track_quality(existing) >= quality(
                    await asyncio.to_thread(read_tags, path)
                ):
                    if not temporary:
                        existing.is_temporary = False
                    await db.commit()
                    path.unlink()
                    await self._change(item.id, status="done", track_id=existing.id, progress=1, error=None)
                    return
            rel = target_relpath(meta, path.suffix)
            target = get_settings().music_dir / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.move, str(path), str(target))
            sidecar = await asyncio.to_thread(sidecar_path, path)
            if sidecar is not None:
                await asyncio.to_thread(shutil.move, str(sidecar), str(target.with_suffix(".lrc")))
            if cover and not (target.parent / "cover.jpg").exists():
                (target.parent / "cover.jpg").write_bytes(cover)
            async with SessionLocal() as db:
                imported = await import_file(db, rel)
                if imported is None:
                    raise ValueError("Audiodatei nicht importierbar")
                imported.is_temporary = temporary
                if existing is not None:
                    await merge_group(db, imported, [existing])
                imported = await merge_new_duplicates(db, imported)
                await db.commit()
            await self._change(item.id, status="done", track_id=imported.id, progress=1, error=None)
        except Cancelled:
            await self._change(item.id, status="cancelled")
        except Exception as e:
            if BOT_CHECK in str(e).replace("'", "’"):
                log.warning("YouTube bot check, pausing downloads for %s s", BOT_PAUSE_SECONDS)
                self._paused_until = time.monotonic() + BOT_PAUSE_SECONDS
                await self._change(item.id, status="queued", error=BOT_PAUSED)
                return
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


def parse_source_url(url: str) -> tuple[str, str]:
    """A YouTube (also plain youtube.com videos, audio only) or SoundCloud link → (source, ref)."""
    if ref := video_id(url):
        return "youtube", ref
    if ref := track_url(url):
        return "soundcloud", ref
    raise HTTPException(422, "Kein gültiger YouTube- oder SoundCloud-Link")


async def set_item_source(db: AsyncSession, request: DownloadRequest, item: DownloadItem, url: str) -> None:
    """Retries a failed song with a link the user picked instead of searching."""
    if item.status != "failed" or request.status == "rejected":
        raise HTTPException(409, "Nur fehlgeschlagene Songs können eine eigene Quelle bekommen")
    item.source, item.source_ref = parse_source_url(url)
    item.source_pinned = True
    item.status = "queued"
    item.error = None
    item.progress = 0
    item.attempts = 0
    await recompute_request(db, request)


async def create_redownload(db: AsyncSession, user: User, track: Track, youtube_url: str | None) -> DownloadRequest:
    source, ref = parse_source_url(youtube_url) if youtube_url is not None else (None, None)
    existing = await db.scalar(
        select(DownloadRequest)
        .options(selectinload(DownloadRequest.items), joinedload(DownloadRequest.user))
        .where(
            DownloadRequest.user_id == user.id,
            DownloadRequest.kind == "redownload",
            DownloadRequest.replace_track_id == track.id,
            DownloadRequest.status.in_(["pending_approval", "active"]),
        )
    )
    if existing is not None:
        return existing
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
        if count + 1 > limit:
            raise HTTPException(429, f"Tageslimit erreicht ({count} von {limit} Songs in 24 Stunden)")
    album = await db.scalar(select(Album).options(joinedload(Album.artist)).where(Album.id == track.album_id))
    meta = TrackMeta(
        title=track.title,
        artist=track.artist_credit,
        artist_mbid=None,
        album=album.title,
        album_artist=album.artist.name,
        album_artist_mbid=None,
        track_no=track.track_no,
        track_total=None,
        disc_no=track.disc_no,
        disc_total=None,
        year=track.year,
        date=None,
        duration=track.duration,
        isrc=track.isrc,
        genre=track.genre,
        label=None,
        mb_recording_id=track.mb_recording_id,
        mb_release_id=None,
        mb_release_group_id=None,
        cover_url=None,
    )
    refs = await db.scalars(
        select(DownloadItem.source_ref)
        .where(DownloadItem.source == "youtube", DownloadItem.track_id == track.id)
        .order_by(DownloadItem.created_at)
    )
    approved = user.is_admin or cfg.downloads.auto_approve_requests
    request = DownloadRequest(
        user=user,
        kind="redownload",
        catalog_id=None,
        replace_track_id=track.id,
        title=track.title,
        artist=track.artist_credit,
        cover_url=None,
        status="active" if approved else "pending_approval",
        is_temporary=False,
        items=[
            DownloadItem(
                position=0,
                title=track.title,
                artist=track.artist_credit,
                duration=track.duration,
                meta=meta.model_dump(),
                exclude_refs=[] if ref else list(dict.fromkeys(r for r in refs if r)),
                source=source,
                source_ref=ref,
                status="queued" if approved else "waiting",
                track_id=None,
            )
        ],
    )
    db.add(request)
    await db.commit()
    manager.wake()
    return request


async def _active_request(db: AsyncSession, user: User, kind: str, catalog_id: str) -> DownloadRequest | None:
    return await db.scalar(
        select(DownloadRequest)
        .options(selectinload(DownloadRequest.items), joinedload(DownloadRequest.user))
        .where(
            DownloadRequest.user_id == user.id,
            DownloadRequest.kind == kind,
            DownloadRequest.catalog_id == catalog_id,
            DownloadRequest.status.in_(["pending_approval", "active"]),
        )
    )


async def _create_request(
    db: AsyncSession,
    user: User,
    *,
    kind: str,
    catalog_id: str,
    title: str,
    artist: str,
    cover_url: str | None,
    metas: list[TrackMeta],
    temporary: bool,
    radio: bool = False,
) -> DownloadRequest:
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
        cover_url=cover_url,
        status="active" if approved else "pending_approval",
        is_temporary=temporary and (user.is_admin or radio),
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


async def create_request(
    db: AsyncSession, user: User, kind: str, catalog_id: str, temporary: bool, *, radio: bool = False
) -> DownloadRequest:
    existing = await _active_request(db, user, kind, catalog_id)
    if existing is not None:
        return existing
    try:
        # Censored releases sound wrong; always fetch the explicit original when Deezer has one.
        catalog_id = await (explicit_track_id if kind == "track" else explicit_album_id)(catalog_id)
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
    return await _create_request(
        db,
        user,
        kind=kind,
        catalog_id=catalog_id,
        title=title,
        artist=artist,
        cover_url=album.get("cover_medium"),
        metas=metas,
        temporary=temporary,
        radio=radio,
    )


async def create_search_request(
    db: AsyncSession,
    user: User,
    *,
    title: str,
    artist: str,
    album: str | None,
    duration: float | None,
    temporary: bool,
) -> DownloadRequest:
    catalog_id = f"search:{name_key(artist)}:{name_key(title)}"[:64]
    existing = await _active_request(db, user, "search", catalog_id)
    if existing is not None:
        return existing
    first_artist = artist.split(", ")[0]
    meta = TrackMeta(
        title=title,
        artist=first_artist,
        artist_mbid=None,
        album=album or title,
        album_artist=first_artist,
        album_artist_mbid=None,
        track_no=1,
        track_total=1,
        disc_no=1,
        disc_total=1,
        year=None,
        date=None,
        duration=duration,
        isrc=None,
        genre=None,
        label=None,
        mb_recording_id=None,
        mb_release_id=None,
        mb_release_group_id=None,
    )
    return await _create_request(
        db,
        user,
        kind="search",
        catalog_id=catalog_id,
        title=title,
        artist=artist,
        cover_url=None,
        metas=[meta],
        temporary=temporary,
    )
