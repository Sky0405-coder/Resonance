import asyncio
import logging
import os
import shutil
import time
import uuid
from collections import defaultdict
from datetime import UTC, datetime
from pathlib import Path

from fastapi import HTTPException
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import ImportBatch, ImportFile, Job, Track, User
from app.services import acoustid
from app.services.fingerprint import fingerprint
from app.services.identify import FileInfo, album_context, assign_releases, candidates, group_key, identify_file
from app.services.library_paths import target_relpath
from app.services.lyrics import sidecar_path
from app.services.musicbrainz import TrackMeta
from app.services.scanner import _walk, import_files, relocate_track
from app.services.server_config import load_config
from app.services.tagger import fetch_cover, write_tags
from app.services.tags import TrackTags, folder_cover, read_tags

log = logging.getLogger(__name__)
_start_lock = asyncio.Lock()
_running: asyncio.Task | None = None
_auto_task: asyncio.Task | None = None
_cancelled: set[uuid.UUID] = set()
_ACTIVE = {"queued", "running"}


def quality(tags: TrackTags | None) -> int:
    if tags is None:
        return 0
    return 10_000 if tags.codec in {"flac", "alac", "ape", "wavpack", "wave", "aiff"} else (tags.bitrate or 0)


def _prune(root: Path, directories: set[Path], inplace: bool) -> None:
    leftovers = {".jpg", ".png", ".m3u", ".nfo", ".sfv", ".txt", ".cue", ".log"}
    for directory in sorted(directories, key=lambda p: len(p.parts), reverse=True):
        if directory == root or not directory.is_relative_to(root):
            continue
        try:
            children = list(directory.iterdir())
            if (
                inplace
                and children
                and all(
                    p.is_file()
                    and (p.name in {".DS_Store", "Thumbs.db", "desktop.ini"} or p.suffix.lower() in leftovers)
                    for p in children
                )
            ):
                for child in children:
                    child.unlink()
            directory.rmdir()
        except OSError:
            pass


def _source_directories(source: Path, root: Path) -> set[Path]:
    return {p for p in source.parents if p != root and p.is_relative_to(root)}


async def _place(db: AsyncSession, batch: ImportBatch, row: ImportFile, tags: TrackTags) -> bool:
    meta = TrackMeta.model_validate(row.meta)
    source = Path(batch.source_dir) / row.path
    target = target_relpath(meta, source.suffix, unique=False)
    row.target = target
    dest = get_settings().music_dir / target
    same = source.resolve() == dest.resolve()
    replace = dest.exists() and not same
    if replace and quality(tags) <= quality(await asyncio.to_thread(read_tags, dest)):
        row.status = "duplicate"
        return False
    # Two existing cleanup rows cannot share Track.path while both retaining their ids.
    if replace and batch.mode == "inplace":
        old = await db.scalar(select(Track).where(Track.path == row.path))
        existing = await db.scalar(select(Track).where(Track.path == target))
        if old is not None and existing is not None and old.id != existing.id:
            raise ValueError("Zielpfad gehört bereits zu einem anderen Bibliothekstitel")
    dest.parent.mkdir(parents=True, exist_ok=True)
    original_cover = folder_cover(source.parent)
    cover = await fetch_cover(meta) if row.method == "release" else None
    # Hidden (skipped by the scanner) and keeps the extension, which mutagen needs to sniff damaged files.
    temp = dest.with_name(f".{dest.stem}.part{dest.suffix}")
    try:
        if batch.mode == "copy":
            await asyncio.to_thread(shutil.copy2, source, temp)
            await asyncio.to_thread(write_tags, temp, meta, cover, clear_missing=True)
            await asyncio.to_thread(os.replace, temp, dest)
        elif replace:
            await asyncio.to_thread(write_tags, source, meta, cover, clear_missing=True)
            await asyncio.to_thread(shutil.copy2, source, temp)
            await asyncio.to_thread(os.replace, temp, dest)
            source.unlink()
        else:
            await asyncio.to_thread(write_tags, source, meta, cover, clear_missing=True)
            if not same:
                await asyncio.to_thread(shutil.move, str(source), str(dest))
        sidecar = await asyncio.to_thread(sidecar_path, source)
        if sidecar is not None and sidecar.resolve() != dest.with_suffix(".lrc").resolve():
            operation = shutil.copy2 if batch.mode == "copy" else shutil.move
            await asyncio.to_thread(operation, str(sidecar), str(dest.with_suffix(".lrc")))
        if cover and not (dest.parent / "cover.jpg").exists():
            (dest.parent / "cover.jpg").write_bytes(cover)
        elif row.method != "release" and folder_cover(dest.parent) is None and original_cover:
            cover_dest = dest.parent / f"cover{original_cover.suffix.lower()}"
            if original_cover.resolve() != cover_dest.resolve():
                await asyncio.to_thread(shutil.copy2, original_cover, cover_dest)
        if batch.mode == "inplace" and not same:
            await relocate_track(db, row.path, target)
        return True
    finally:
        if temp.exists():
            temp.unlink()


async def _counters(db: AsyncSession, batch: ImportBatch) -> None:
    rows = list(await db.scalars(select(ImportFile).where(ImportFile.batch_id == batch.id)))
    batch.total = len(rows)
    batch.processed = sum(r.status not in {"pending", "identified"} for r in rows)
    batch.identified = sum(r.method in {"release", "recording", "deezer"} for r in rows)
    batch.imported = sum(r.status == "imported" for r in rows)
    batch.duplicates = sum(r.status == "duplicate" for r in rows)
    batch.unidentified = sum(r.method == "tags" or r.status == "unidentified" for r in rows)
    batch.failed = sum(r.status == "failed" for r in rows)


async def run_batch(batch_id: uuid.UUID) -> None:
    try:
        async with SessionLocal() as db:
            batch = await db.get(ImportBatch, batch_id)
            if batch is None or batch.status not in _ACTIVE:
                return
            cfg = (await load_config(db)).library
            root = Path(batch.source_dir)
            if not cfg.acoustid_api_key:
                batch.message = "Kein AcoustID-Schlüssel – Erkennung nur über vorhandene Tags"
            rows = list(
                await db.scalars(select(ImportFile).where(ImportFile.batch_id == batch.id).order_by(ImportFile.path))
            )
            if not rows and batch.total == 0:
                rows = [
                    ImportFile(batch_id=batch.id, path=rel, group_key=group_key(rel), status="pending")
                    for rel, _, _ in sorted(await asyncio.to_thread(_walk, root))
                ]
                db.add_all(rows)
            batch.total = len(rows)
            batch.status = "running"
            await db.commit()
            groups: dict[str, list[ImportFile]] = defaultdict(list)
            for row in rows:
                groups[row.group_key].append(row)
            for key in sorted(groups):
                if batch_id in _cancelled:
                    break
                group = groups[key]
                pending = [r for r in group if r.status in {"pending", "identified"}]
                if not pending:
                    continue
                infos: dict[uuid.UUID, FileInfo] = {}
                placed = []
                directories: set[Path] = set()
                for row in group:
                    if row not in pending:
                        continue
                    source = root / row.path
                    # A shutdown can happen between moving the file and committing its final status.
                    if not source.exists() and row.target and (get_settings().music_dir / row.target).is_file():
                        placed.append(row)
                        directories.update(_source_directories(source, root))
                        continue
                    tags = await asyncio.to_thread(read_tags, source)
                    if tags is None:
                        row.status = "failed"
                        row.error = "Audiodatei nicht lesbar"
                    else:
                        infos[row.id] = FileInfo([], tags)
                if cfg.acoustid_api_key:
                    ids = list(infos)
                    prints = await asyncio.gather(
                        *(fingerprint(root / next(r.path for r in group if r.id == id)) for id in ids),
                        return_exceptions=True,
                    )
                    for id, value in zip(ids, prints, strict=True):
                        if not isinstance(value, str) or not value:
                            continue
                        try:
                            infos[id].candidates = candidates(
                                await acoustid.lookup(cfg.acoustid_api_key, value, infos[id].tags.duration)
                            )
                        except acoustid.AcoustIDError:
                            pass
                files = list(infos.values())
                context = album_context(files)
                assigned = assign_releases(files)
                for row in pending:
                    info = infos.get(row.id)
                    if info is None:
                        continue
                    try:
                        meta, method = await identify_file(
                            info, context[info], assigned.get(info), cfg.import_unidentified
                        )
                        row.method = method
                        row.acoustid_score = max((c.score for c in info.candidates), default=None)
                        row.meta = meta.model_dump() if meta else None
                        if meta is None:
                            row.status = "unidentified"
                            continue
                        row.status = "identified" if method != "tags" else "pending"
                        await db.flush()
                        if await _place(db, batch, row, info.tags):
                            placed.append(row)
                            if batch.mode != "copy":
                                directories.update(_source_directories(root / row.path, root))
                    except Exception as e:
                        log.exception("Import file failed: %s", row.path)
                        row.status = "failed"
                        row.error = f"Import fehlgeschlagen: {e}"
                if placed:
                    tracks = await import_files(db, [r.target for r in placed])
                    for row in placed:
                        track = tracks[row.target]
                        if track is None:
                            row.status = "failed"
                            row.error = "Audiodatei nicht importierbar"
                        else:
                            row.track_id = track.id
                            row.status = "imported"
                if batch.mode != "copy":
                    await asyncio.to_thread(_prune, root, directories, batch.mode == "inplace")
                await _counters(db, batch)
                await db.commit()
            await _counters(db, batch)
            batch.status = "cancelled" if batch_id in _cancelled else "done"
            batch.finished_at = datetime.now(UTC)
            await db.commit()
    except Exception as e:
        log.exception("Import batch failed: %s", batch_id)
        async with SessionLocal() as db:
            batch = await db.get(ImportBatch, batch_id)
            if batch:
                batch.status = "failed"
                batch.message = f"Import fehlgeschlagen: {e}"
                batch.finished_at = datetime.now(UTC)
                await db.commit()
    finally:
        _cancelled.discard(batch_id)


async def start_batch(db: AsyncSession, kind: str, user: User | None) -> ImportBatch:
    global _running
    async with _start_lock:
        active = await db.scalar(select(ImportBatch.id).where(ImportBatch.status.in_(_ACTIVE)).limit(1))
        if active is not None:
            raise HTTPException(409, "Es läuft bereits ein Import")
        cfg = (await load_config(db)).library
        root = get_settings().import_dir if kind == "import" else get_settings().music_dir
        if kind == "import" and not await asyncio.to_thread(_walk, root):
            raise HTTPException(400, "Der Import-Ordner ist leer")
        batch = ImportBatch(
            kind=kind,
            mode=cfg.import_mode if kind == "import" else "inplace",
            source_dir=str(root.resolve()),
            status="queued",
            created_by_id=user.id if user else None,
        )
        db.add(batch)
        await db.commit()
        await db.refresh(batch)
        _running = asyncio.create_task(run_batch(batch.id))
        return batch


def cancel_batch(batch: ImportBatch) -> None:
    if batch.status not in _ACTIVE:
        raise HTTPException(409, "Import läuft nicht")
    _cancelled.add(batch.id)


async def _resume(ids: list[uuid.UUID]) -> None:
    for id in ids:
        await run_batch(id)


async def _auto_import_once() -> None:
    async with SessionLocal() as db:
        cfg = (await load_config(db)).library
        if not cfg.auto_import or cfg.import_mode != "move":
            return
        if await db.scalar(select(ImportBatch.id).where(ImportBatch.status.in_(_ACTIVE)).limit(1)):
            return
        files = await asyncio.to_thread(_walk, get_settings().import_dir)
        if any(mtime < time.time() - 120 for _, mtime, _ in files):
            try:
                await start_batch(db, "import", None)
            except HTTPException as e:
                if e.status_code not in {400, 409}:
                    raise


async def _auto_import() -> None:
    while True:
        await asyncio.sleep(300)
        try:
            await _auto_import_once()
        except Exception:
            log.exception("Automatic import failed")


async def start() -> None:
    global _running, _auto_task
    async with SessionLocal() as db:
        # Background jobs (library scans) do not survive a restart.
        await db.execute(
            update(Job)
            .where(Job.status.in_(["queued", "running"]))
            .values(status="failed", message="Durch Neustart abgebrochen", finished_at=datetime.now(UTC))
        )
        await db.commit()
        ids = list(
            await db.scalars(
                select(ImportBatch.id).where(ImportBatch.status.in_(_ACTIVE)).order_by(ImportBatch.created_at)
            )
        )
    if ids and (_running is None or _running.done()):
        _running = asyncio.create_task(_resume(ids))
    if get_settings().download_workers > 0 and (_auto_task is None or _auto_task.done()):
        _auto_task = asyncio.create_task(_auto_import())


async def stop() -> None:
    global _running, _auto_task
    tasks = [t for t in (_running, _auto_task) if t is not None]
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    _running = _auto_task = None
