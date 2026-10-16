import asyncio
import logging
import uuid
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Album, Artist, Track
from app.services.lyrics import sidecar_path
from app.services.tags import AUDIO_EXTENSIONS

logger = logging.getLogger(__name__)


async def _delete_orphans(
    db: AsyncSession, album_ids: set[uuid.UUID], artist_ids: set[uuid.UUID]
) -> tuple[list[str], list[str]]:
    albums = list(
        await db.scalars(
            select(Album).where(Album.id.in_(album_ids), ~select(Track.id).where(Track.album_id == Album.id).exists())
        )
    )
    artist_ids.update(album.artist_id for album in albums)
    await db.execute(delete(Album).where(Album.id.in_([album.id for album in albums])))
    cover_files = {album.cover_file for album in albums if album.cover_file is not None}
    used_covers = set(await db.scalars(select(Album.cover_file).where(Album.cover_file.in_(cover_files))))
    artists = list(
        await db.scalars(
            select(Artist).where(
                Artist.id.in_(artist_ids),
                ~select(Track.id).where(Track.artist_id == Artist.id).exists(),
                ~select(Album.id).where(Album.artist_id == Artist.id).exists(),
            )
        )
    )
    image_paths = [artist.image_path for artist in artists if artist.image_path is not None]
    await db.execute(delete(Artist).where(Artist.id.in_([artist.id for artist in artists])))
    return list(cover_files - used_covers), image_paths


def _delete_files(track_paths: list[str], cover_files: list[str], image_paths: list[str]) -> None:
    settings = get_settings()
    try:
        root = settings.music_dir.resolve()
    except OSError:
        logger.warning("Could not resolve music directory: %s", settings.music_dir, exc_info=True)
        return
    parents: set[Path] = set()
    for relative in track_paths:
        path = settings.music_dir / relative
        try:
            resolved = path.resolve()
            if not resolved.is_relative_to(root) or resolved == root:
                logger.warning("Skipping track path outside music directory: %s", path)
                continue
            parents.add(path.parent.resolve())
            path.unlink(missing_ok=True)
            sidecar = sidecar_path(path)
            if sidecar is not None:
                sidecar.unlink(missing_ok=True)
        except OSError:
            logger.warning("Could not delete track file: %s", path, exc_info=True)

    for directory in sorted(parents, key=lambda path: len(path.parts), reverse=True):
        if directory == root or not directory.is_relative_to(root):
            continue
        try:
            if not directory.exists():
                continue
            entries = list(directory.iterdir())
            if any(entry.is_dir() or entry.suffix.lower() in AUDIO_EXTENSIONS for entry in entries):
                continue
            for entry in entries:
                entry.unlink(missing_ok=True)
            directory.rmdir()
            parent = directory.parent
            while parent != root and not any(parent.iterdir()):
                parent.rmdir()
                parent = parent.parent
        except OSError:
            logger.warning("Could not clean music directory: %s", directory, exc_info=True)

    for cover_file in cover_files:
        path = settings.cover_cache_dir / cover_file
        try:
            path.unlink(missing_ok=True)
        except OSError:
            logger.warning("Could not delete cover cache file: %s", path, exc_info=True)
    for image_path in image_paths:
        path = settings.data_dir / image_path
        try:
            if path.resolve().is_relative_to(settings.data_dir.resolve()):
                path.unlink(missing_ok=True)
        except OSError:
            logger.warning("Could not delete artist image: %s", path, exc_info=True)


async def delete_tracks(db: AsyncSession, track_ids: list[uuid.UUID]) -> None:
    tracks = (
        await db.execute(select(Track.album_id, Track.artist_id, Track.path).where(Track.id.in_(track_ids)))
    ).all()
    album_ids = {track.album_id for track in tracks}
    artist_ids = {track.artist_id for track in tracks}
    artist_ids.update(await db.scalars(select(Album.artist_id).where(Album.id.in_(album_ids))))
    await db.execute(delete(Track).where(Track.id.in_(track_ids)))
    cover_files, image_paths = await _delete_orphans(db, album_ids, artist_ids)
    await db.commit()
    await asyncio.to_thread(_delete_files, [track.path for track in tracks], cover_files, image_paths)


async def delete_empty_album(db: AsyncSession, album: Album) -> None:
    cover_files, image_paths = await _delete_orphans(db, {album.id}, {album.artist_id})
    await db.commit()
    await asyncio.to_thread(_delete_files, [], cover_files, image_paths)
