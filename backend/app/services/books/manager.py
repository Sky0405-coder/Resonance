import asyncio
import logging
import shutil
import time
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import func, select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import Book, BookRequest, User
from app.services.books.epub import read_epub
from app.services.books.importer import (
    BookImportError,
    import_book,
    remove_empty_parents,
)
from app.services.books.select import choose_book
from app.services.books.text import BOOK_FORMATS, last_name, work_key
from app.services.server_config import load_config
from app.services.torrents import TorrentError, obtain_source, prowlarr
from app.services.torrents.qbittorrent import QBittorrent

log = logging.getLogger(__name__)


async def create_request(db: AsyncSession, user: User, body: dict) -> tuple[BookRequest, bool]:
    cfg = await load_config(db)
    if not cfg.books.enabled:
        raise HTTPException(409, "Bücher sind nicht aktiviert")
    if not cfg.downloads.torrent_enabled:
        raise HTTPException(409, "Automatische Downloads sind deaktiviert")
    key = work_key(body["title"], body["authors"])
    if await db.scalar(select(Book.id).where(Book.match_key == key)):
        raise HTTPException(409, "Das Buch ist schon in der Bibliothek")
    existing = await db.scalar(
        select(BookRequest).where(
            BookRequest.user_id == user.id,
            BookRequest.match_key == key,
            BookRequest.status.not_in(["done", "failed", "cancelled", "rejected"]),
        )
    )
    if existing is not None:
        return existing, False
    limit = cfg.books.daily_limit_per_user
    if not user.is_admin and limit > 0:
        count = (
            await db.scalar(
                select(func.count())
                .select_from(BookRequest)
                .where(
                    BookRequest.user_id == user.id,
                    BookRequest.created_at >= datetime.now(UTC) - timedelta(hours=24),
                    BookRequest.status.not_in(["rejected", "cancelled"]),
                )
            )
            or 0
        )
        if count >= limit:
            raise HTTPException(429, f"Tageslimit erreicht ({count} von {limit} Büchern in 24 Stunden)")
    values = {**body, "catalog_ref": body["ref"], "language": body["language"] or cfg.books.default_language}
    del values["ref"]
    request = BookRequest(
        **values,
        user_id=user.id,
        match_key=key,
        status="queued" if user.is_admin or cfg.downloads.auto_approve_requests else "pending_approval",
    )
    db.add(request)
    await db.commit()
    book_manager.wake()
    return request, True


class BookManager:
    def __init__(self) -> None:
        self._event = asyncio.Event()
        self._workers: list[asyncio.Task] = []
        self._guids: dict[uuid.UUID, str] = {}
        self._observed: dict[Path, tuple[int, float]] = {}
        self._processed: dict[Path, int] = {}

    def wake(self) -> None:
        self._event.set()

    async def start(self) -> None:
        for name in ("library", "import"):
            try:
                (get_settings().books_dir / name).mkdir(parents=True, exist_ok=True)
            except OSError:
                log.exception("Cannot create books %s directory", name)
        async with SessionLocal() as db:
            await db.execute(
                update(BookRequest).where(BookRequest.status.in_(["searching", "importing"])).values(status="queued")
            )
            await db.commit()
        self._workers = [asyncio.create_task(self._worker()), asyncio.create_task(self._monitor())]

    async def stop(self) -> None:
        for worker in self._workers:
            worker.cancel()
        await asyncio.gather(*self._workers, return_exceptions=True)
        self._workers.clear()

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
                log.exception("Book worker failed")
                await asyncio.sleep(10)

    async def process_one(self) -> bool:
        async with SessionLocal() as db:
            cfg = await load_config(db)
            if not cfg.books.enabled or not cfg.downloads.torrent_enabled:
                return False
            request = await db.scalar(
                select(BookRequest)
                .where(BookRequest.status == "queued")
                .order_by(BookRequest.created_at)
                .with_for_update(skip_locked=True)
                .limit(1)
            )
            if request is None:
                return False
            request.status = "searching"
            await db.commit()
        await self._start(request.id)
        return True

    async def _start(self, request_id: uuid.UUID) -> None:
        try:
            async with SessionLocal() as db:
                request = await db.get(BookRequest, request_id)
                cfg = await load_config(db)
            queries = [f"{last_name(request.authors[0])} {request.title}"] if request.authors else []
            queries.append(request.title)
            chosen = None
            for query in queries:
                results = await prowlarr.search(cfg, query, categories=[7000, 7020])
                chosen = choose_book(
                    results,
                    request.title,
                    request.authors,
                    request.language,
                    cfg.downloads.torrent_min_seeders,
                    request.exclude_guids,
                )
                if chosen is not None:
                    break
            if chosen is None:
                await self._fail(request_id, "Kein passender Download gefunden")
                return
            source = await obtain_source(chosen)
            async with SessionLocal() as db:
                request = await db.scalar(select(BookRequest).where(BookRequest.id == request_id).with_for_update())
                if request is None or request.status != "searching":
                    return
                async with QBittorrent(cfg) as qb:
                    await qb.create_category("resonance-books", "/data/downloads/books")
                    await qb.add(source, str(request.id), category="resonance-books", savepath="/data/downloads/books")
                request.status = "downloading"
                request.torrent_name = chosen["title"]
                request.torrent_hash = None
                request.progress = 0
                request.progress_at = datetime.now(UTC)
                request.attempts += 1
                self._guids[request.id] = chosen.get("guid", "")
                await db.commit()
        except TorrentError as e:
            await self._fail(request_id, str(e))

    async def _fail(self, request_id: uuid.UUID, reason: str) -> None:
        async with SessionLocal() as db:
            request = await db.scalar(select(BookRequest).where(BookRequest.id == request_id).with_for_update())
            if request is not None and request.status not in {"cancelled", "done"}:
                request.status, request.error = "failed", reason
                await db.commit()

    async def _monitor(self) -> None:
        last_cleanup, last_scan = 0.0, 0.0
        while True:
            await asyncio.sleep(10)
            try:
                async with SessionLocal() as db:
                    if not (await load_config(db)).books.enabled:
                        continue
                    ids = list(await db.scalars(select(BookRequest.id).where(BookRequest.status == "downloading")))
                for request_id in ids:
                    try:
                        await self._poll(request_id)
                    except Exception:
                        log.exception("Book torrent monitor failed: %s", request_id)
                now = time.monotonic()
                if now - last_cleanup >= 3600:
                    last_cleanup = now
                    await self.torrent_cleanup()
                if now - last_scan >= 300:
                    last_scan = now
                    await self.scan_folder()
            except Exception:
                log.exception("Book monitor failed")

    async def _poll(self, request_id: uuid.UUID) -> None:
        try:
            async with SessionLocal() as db:
                cfg = await load_config(db)
            async with QBittorrent(cfg) as qb:
                info = await qb.info(str(request_id), category="resonance-books")
            if info is None:
                await self._retry(request_id, "Torrent verschwunden")
                return
            async with SessionLocal() as db:
                request = await db.scalar(select(BookRequest).where(BookRequest.id == request_id).with_for_update())
                if request is None or request.status != "downloading":
                    return
                now = datetime.now(UTC)
                request.torrent_hash = info["hash"]
                if info["progress"] > request.progress:
                    request.progress = info["progress"]
                    request.progress_at = now
                stalled = request.progress_at is not None and now - request.progress_at >= timedelta(
                    minutes=cfg.downloads.torrent_timeout_minutes
                )
                await db.commit()
            if info["progress"] >= 1:
                await self._import_torrent(request_id, info)
            elif stalled:
                await self._retry(request_id, "Torrent ohne Fortschritt")
        except TorrentError as e:
            # qBittorrent briefly unreachable (e.g. VPN reconnecting): keep waiting, the stall timeout still applies.
            log.warning("Book torrent poll failed for %s: %s", request_id, e)

    async def _import_torrent(self, request_id: uuid.UUID, info: dict) -> None:
        try:
            async with SessionLocal() as db:
                request = await db.scalar(select(BookRequest).where(BookRequest.id == request_id).with_for_update())
                if request is None or request.status != "downloading":
                    return
                cfg = await load_config(db)
                request.status = "importing"
                await db.commit()
                async with QBittorrent(cfg) as qb:
                    files = await qb.files(info["hash"])
                candidates = []
                root = Path(info["save_path"]).resolve()
                for file in files:
                    path = (root / file["name"]).resolve()
                    ext = path.suffix.lower()[1:]
                    if path.is_relative_to(root) and path.is_file() and ext in BOOK_FORMATS:
                        candidates.append((BOOK_FORMATS[ext], file.get("size") or path.stat().st_size, path))
                if not candidates:
                    raise BookImportError("Keine Buchdatei im Download")
                path = max(candidates, key=lambda c: c[:2])[2]
                if path.suffix.lower() == ".epub" and request.language != "any":
                    language = (await asyncio.to_thread(read_epub, path)).language
                    if language and language != request.language:
                        raise BookImportError("Falsche Sprache")
                try:
                    book = await import_book(db, path, copy=True, origin="torrent", user=None, request=request)
                except BookImportError as e:
                    if e.book is None:
                        raise
                    book = e.book
                request = await db.scalar(
                    select(BookRequest)
                    .where(BookRequest.id == request_id)
                    .with_for_update()
                    .execution_options(populate_existing=True)
                )
                if request is None or request.status != "importing":
                    return
                request.status, request.book_id, request.progress, request.error = "done", book.id, 1, None
                await db.commit()
                self._guids.pop(request_id, None)
        except (BookImportError, TorrentError) as e:
            await self._retry(request_id, str(e))
        except Exception:
            log.exception("Book torrent import failed")
            await self._retry(request_id, "Import fehlgeschlagen")

    async def _delete_torrent(self, qb: QBittorrent, request: BookRequest) -> None:
        try:
            hash = request.torrent_hash
            if not hash:
                info = await qb.info(str(request.id), category="resonance-books")
                hash = info["hash"] if info else None
            if hash:
                await qb.delete(hash, True)
        except TorrentError:
            log.warning("Cannot delete book torrent: %s", request.id)

    async def _retry(self, request_id: uuid.UUID, reason: str) -> None:
        async with SessionLocal() as db:
            request = await db.scalar(select(BookRequest).where(BookRequest.id == request_id).with_for_update())
            if request is None or request.status not in {"downloading", "importing"}:
                return
            async with QBittorrent(await load_config(db)) as qb:
                await self._delete_torrent(qb, request)
            guid = self._guids.pop(request_id, None)
            if guid and guid not in request.exclude_guids:
                request.exclude_guids = [*request.exclude_guids, guid]
            request.status = "queued" if request.attempts < 3 else "failed"
            request.error = reason
            await db.commit()
        self.wake()

    async def cancel(self, db: AsyncSession, request: BookRequest) -> None:
        if request.status == "downloading":
            async with QBittorrent(await load_config(db)) as qb:
                await self._delete_torrent(qb, request)
        request.status = "cancelled"
        self._guids.pop(request.id, None)
        await db.commit()

    async def torrent_cleanup(self) -> int:
        async with SessionLocal() as db:
            cfg = await load_config(db)
            if not cfg.books.enabled or not cfg.downloads.torrent_enabled:
                return 0
            busy = {
                str(id)
                for id in await db.scalars(
                    select(BookRequest.id).where(BookRequest.status.in_(["searching", "downloading", "importing"]))
                )
            }
        deleted = 0
        cutoff = time.time() - cfg.downloads.torrent_seed_days * 86400
        async with QBittorrent(cfg) as qb:
            for torrent in await qb.all(category="resonance-books"):
                tags = {tag.strip() for tag in str(torrent.get("tags") or "").split(",")}
                completed = torrent.get("completion_on") or 0
                if torrent.get("progress", 0) < 1 or completed <= 0 or tags & busy:
                    continue
                if torrent.get("state") in {"stoppedUP", "pausedUP"} or completed <= cutoff:
                    await qb.delete(torrent["hash"], True)
                    deleted += 1
        return deleted

    async def scan_folder(self) -> None:
        root = get_settings().books_dir / "import"
        async with SessionLocal() as db:
            cfg = await load_config(db)
            if not cfg.books.enabled or not root.is_dir():
                return
            copy = cfg.library.import_mode == "copy"
            for path in sorted(root.rglob("*")):
                if not path.is_file() or any(part.startswith(".") for part in path.relative_to(root).parts):
                    continue
                if path.suffix.lower()[1:] not in BOOK_FORMATS:
                    continue
                stat = path.stat()
                if self._processed.get(path) == stat.st_mtime_ns:
                    continue
                previous = self._observed.get(path)
                if previous is None or previous[0] != stat.st_size:
                    self._observed[path] = (stat.st_size, time.monotonic())
                    continue
                if time.monotonic() - previous[1] < 60:
                    continue
                try:
                    await import_book(db, path, copy=copy, origin="folder", user=None, request=None)
                    if copy:
                        self._processed[path] = stat.st_mtime_ns
                except Exception:
                    await db.rollback()
                    log.exception("Drop-folder book import failed: %s", path)
                    if copy:
                        self._processed[path] = stat.st_mtime_ns
                    elif path.exists():
                        failed = root / ".failed" / path.relative_to(root)
                        failed.parent.mkdir(parents=True, exist_ok=True)
                        shutil.move(path, failed)
                if not copy:
                    remove_empty_parents(path.parent, root)


book_manager = BookManager()
