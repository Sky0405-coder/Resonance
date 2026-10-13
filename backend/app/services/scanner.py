"""Library scanner: walks the music dir and syncs files into the database.

Incremental by default (unchanged mtime+size are skipped). Runs as an
in-process background task for now; it moves to the worker together with the
download pipeline.
"""

import asyncio
import logging
import os
import uuid
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import Album, Artist, Job, Track
from app.services import covers
from app.services.matching import name_key
from app.services.tags import AUDIO_EXTENSIONS, TrackTags, embedded_cover, folder_cover, read_tags

log = logging.getLogger(__name__)

BATCH = 200
_running: asyncio.Task | None = None
library_lock = asyncio.Lock()
_imports = 0


def _walk(root: Path) -> list[tuple[str, float, int]]:
    out = []
    for dirpath, dirs, files in os.walk(root, followlinks=True):
        # Skip hidden/metadata dirs such as macOS ".AppleDouble" or Synology "@eaDir".
        dirs[:] = [d for d in dirs if not d.startswith((".", "@"))]
        for name in files:
            if name.startswith(".") or os.path.splitext(name)[1].lower() not in AUDIO_EXTENSIONS:
                continue
            full = os.path.join(dirpath, name)
            try:
                st = os.stat(full)
            except OSError:
                continue
            out.append((os.path.relpath(full, root), st.st_mtime, st.st_size))
    return out


def _find_cover(path: Path) -> str | None:
    data: bytes | None = None
    folder = folder_cover(path.parent)
    if folder is not None:
        try:
            data = folder.read_bytes()
        except OSError:
            data = None
    if data is None:
        data = embedded_cover(path)
    return covers.store(data) if data else None


class _Syncer:
    def __init__(self, db: AsyncSession, full: bool):
        self.db = db
        self.full = full
        self.artists_by_key: dict[str, Artist] = {}
        self.artists_by_mbid: dict[str, Artist] = {}
        self.albums: dict[tuple[uuid.UUID, str], Album] = {}
        self.cover_checked: set[uuid.UUID] = set()

    async def load(self) -> None:
        self.artists_by_key.clear()
        self.artists_by_mbid.clear()
        self.albums.clear()
        for a in await self.db.scalars(select(Artist).execution_options(populate_existing=True)):
            self.artists_by_key[a.name_key] = a
            if a.mb_artist_id:
                self.artists_by_mbid[a.mb_artist_id] = a
        for al in await self.db.scalars(select(Album).execution_options(populate_existing=True)):
            self.albums[(al.artist_id, al.title_key)] = al

    async def artist(self, name: str, mbid: str | None, sort_name: str | None) -> Artist:
        found = (self.artists_by_mbid.get(mbid) if mbid else None) or self.artists_by_key.get(name_key(name))
        if found is None:
            found = Artist(id=uuid.uuid4(), name=name, name_key=name_key(name), mb_artist_id=mbid, sort_name=sort_name)
            self.db.add(found)
            self.artists_by_key[found.name_key] = found
        elif mbid and not found.mb_artist_id:
            found.mb_artist_id = mbid
        if mbid:
            self.artists_by_mbid[mbid] = found
        return found

    async def album(self, tags: TrackTags, artist: Artist, abs_path: Path) -> Album:
        key = (artist.id, name_key(tags.album))
        album = self.albums.get(key)
        if album is None:
            album = Album(
                id=uuid.uuid4(),
                title=tags.album,
                title_key=key[1],
                artist_id=artist.id,
                year=tags.year,
                genre=tags.genre,
                mb_release_id=tags.mb_album_id,
            )
            self.db.add(album)
            self.albums[key] = album
        else:
            album.year = album.year or tags.year
            album.genre = album.genre or tags.genre
            album.mb_release_id = album.mb_release_id or tags.mb_album_id
        if album.id not in self.cover_checked and (album.cover_file is None or self.full):
            self.cover_checked.add(album.id)
            album.cover_file = await asyncio.to_thread(_find_cover, abs_path) or album.cover_file
        return album

    async def upsert(self, rel: str, mtime: float, size: int, existing: Track | None) -> Track | None:
        abs_path = get_settings().music_dir / rel
        tags = await asyncio.to_thread(read_tags, abs_path)
        if tags is None:
            log.warning("Unreadable audio file: %s", rel)
            return
        album_artist = await self.artist(tags.album_artist, tags.mb_album_artist_id, tags.album_artist_sort)
        track_artist = (
            album_artist
            if name_key(tags.artist) == album_artist.name_key
            else await self.artist(tags.artist, tags.mb_artist_id, tags.artist_sort)
        )
        album = await self.album(tags, album_artist, abs_path)
        track = existing or Track(id=uuid.uuid4(), path=rel)
        track.title = tags.title
        track.album_id = album.id
        track.artist_id = track_artist.id
        track.artist_credit = tags.artist_credit
        track.track_no = tags.track_no
        track.disc_no = tags.disc_no
        track.duration = tags.duration
        track.year = tags.year
        track.genre = tags.genre
        track.codec = tags.codec
        track.bitrate = tags.bitrate
        track.sample_rate = tags.sample_rate
        track.size = size
        track.mtime = mtime
        track.mb_recording_id = tags.mb_recording_id
        track.isrc = tags.isrc
        track.replaygain_track_gain = tags.replaygain_track_gain
        track.replaygain_album_gain = tags.replaygain_album_gain
        if existing is None:
            self.db.add(track)
        return track


async def _set_job(job_id: uuid.UUID, **values) -> None:
    async with SessionLocal() as db:
        job = await db.get(Job, job_id)
        if job:
            for k, v in values.items():
                setattr(job, k, v)
            await db.commit()


async def run_scan(job_id: uuid.UUID, full: bool = False) -> None:
    root = get_settings().music_dir
    try:
        await _set_job(job_id, status="running", message=f"Durchsuche {root} …")
        files = await asyncio.to_thread(_walk, root)
        async with SessionLocal() as db:
            existing = {t.path: t for t in await db.scalars(select(Track))}
            syncer = _Syncer(db, full)
            loaded_imports = -1

            changed = [
                f
                for f in files
                if full or f[0] not in existing or (existing[f[0]].mtime, existing[f[0]].size) != (f[1], f[2])
            ]
            seen = {f[0] for f in files}
            total = max(len(changed), 1)
            for offset in range(0, len(changed), BATCH):
                batch = changed[offset : offset + BATCH]
                async with library_lock:
                    if loaded_imports != _imports:
                        await syncer.load()
                        if loaded_imports != -1 or _imports:
                            rows = await db.scalars(select(Track).execution_options(populate_existing=True))
                            existing.update({t.path: t for t in rows if t.path in seen})
                        loaded_imports = _imports
                    for rel, mtime, size in batch:
                        await syncer.upsert(rel, mtime, size, existing.get(rel))
                    await db.commit()
                i = offset + len(batch)
                await _set_job(job_id, progress=i / total, message=f"{i}/{len(changed)} Dateien verarbeitet")

            async with library_lock:
                gone = [t.id for p, t in existing.items() if p not in seen]
                # Chunked: Postgres allows at most 32767 bind parameters per statement.
                for i in range(0, len(gone), 5000):
                    await db.execute(delete(Track).where(Track.id.in_(gone[i : i + 5000])))
                # Drop albums/artists that no longer have any tracks.
                await db.execute(delete(Album).where(~Album.id.in_(select(Track.album_id).distinct())))
                await db.execute(
                    delete(Artist).where(
                        ~Artist.id.in_(select(Track.artist_id).distinct()),
                        ~Artist.id.in_(select(Album.artist_id).distinct()),
                    )
                )
                await db.commit()
        await _set_job(
            job_id,
            status="done",
            progress=1,
            finished_at=datetime.now(UTC),
            message=f"{len(files)} Dateien, {len(changed)} neu/geändert, {len(gone)} entfernt",
        )
    except Exception as e:
        log.exception("Library scan failed")
        await _set_job(job_id, status="failed", finished_at=datetime.now(UTC), message=str(e))


async def start_scan(db: AsyncSession, full: bool = False) -> Job:
    global _running
    if _running is not None and not _running.done():
        job = await db.scalar(select(Job).where(Job.kind == "library_scan").order_by(Job.created_at.desc()))
        assert job is not None
        return job
    job = Job(kind="library_scan", status="queued", message="Vollständiger Scan" if full else "Schneller Scan")
    db.add(job)
    await db.commit()
    await db.refresh(job)
    _running = asyncio.create_task(run_scan(job.id, full))
    return job


async def import_files(db: AsyncSession, rels: list[str]) -> dict[str, Track | None]:
    global _imports
    async with library_lock:
        syncer = _Syncer(db, full=False)
        await syncer.load()
        out = {}
        for rel in dict.fromkeys(rels):
            stat = (get_settings().music_dir / rel).stat()
            existing = await db.scalar(select(Track).where(Track.path == rel))
            out[rel] = await syncer.upsert(rel, stat.st_mtime, stat.st_size, existing)
        await db.commit()
        _imports += 1
        return out


async def import_file(db: AsyncSession, rel: str) -> Track | None:
    return (await import_files(db, [rel]))[rel]


async def relocate_track(db: AsyncSession, old_rel: str, new_rel: str) -> None:
    async with library_lock:
        track = await db.scalar(select(Track).where(Track.path == old_rel))
        if track is not None:
            track.path = new_rel
        await db.commit()
