import asyncio
import os
import shutil
import uuid
from pathlib import Path

import mutagen
from mutagen.id3 import ID3
from rapidfuzz import fuzz
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Album, Artist, Track
from app.schemas import ManualMetaIn
from app.services.identify import AlbumCtx, _tag_meta
from app.services.library_paths import target_relpath
from app.services.musicbrainz import TrackMeta
from app.services.scanner import import_file, library_lock, relocate_track
from app.services.sources.youtube import norm
from app.services.tagger import _set_cover, _strip_ogg_id3v1, write_tags
from app.services.tags import TrackTags
from app.services.views import track_options


async def apply_meta(db: AsyncSession, track: Track, meta: TrackMeta, cover: bytes | None) -> Track:
    old_rel = track.path
    async with library_lock:
        source = get_settings().music_dir / old_rel
        if not await asyncio.to_thread(source.is_file):
            raise ValueError("Datei nicht gefunden")
        rel = await asyncio.to_thread(target_relpath, meta, source.suffix, unique=False)
        if rel != old_rel and await asyncio.to_thread((get_settings().music_dir / rel).exists):
            rel = await asyncio.to_thread(target_relpath, meta, source.suffix, unique=True)
        dest = get_settings().music_dir / rel
        temp = dest.with_name(f".{Path(rel).stem}.part{Path(rel).suffix}")
        try:
            await asyncio.to_thread(temp.parent.mkdir, parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.copy2, source, temp)
            await asyncio.to_thread(write_tags, temp, meta, cover, clear_missing=True)
            await asyncio.to_thread(os.replace, temp, dest)
            if rel != old_rel:
                await asyncio.to_thread(source.unlink)
        except BaseException:
            await asyncio.to_thread(temp.unlink, missing_ok=True)
            raise
        if cover is not None:
            await asyncio.to_thread((dest.parent / "cover.jpg").write_bytes, cover)
        if source.parent != dest.parent:
            await asyncio.to_thread(prune_dir, source.parent)
    if rel != old_rel:
        await relocate_track(db, old_rel, rel)
    await import_file(db, rel)
    await cleanup_orphans(db)
    return await db.scalar(
        select(Track).where(Track.id == track.id).options(*track_options()).execution_options(populate_existing=True)
    )


def manual_meta(tags: TrackTags, patch: ManualMetaIn) -> TrackMeta:
    meta = _tag_meta(tags, AlbumCtx(tags.album, tags.album_artist or tags.artist, tags.year, tags.disc_total))
    changes = patch.model_dump(exclude_none=True)
    for key, value in changes.items():
        setattr(meta, key, value)

    def changed(key: str) -> bool:
        return key in changes and str(changes[key]).strip().casefold() != str(getattr(tags, key)).strip().casefold()

    if changed("title") or changed("artist"):
        meta.mb_recording_id = meta.isrc = None
    if changed("artist"):
        meta.artist_mbid = None
    if changed("album") or changed("album_artist"):
        meta.mb_release_id = meta.mb_release_group_id = meta.label = meta.track_total = None
    if changed("album_artist"):
        meta.album_artist_mbid = None
    if changed("year"):
        meta.date = str(meta.year)
    return meta


def replace_cover(path: Path, cover: bytes) -> None:
    _strip_ogg_id3v1(path)
    audio = mutagen.File(path)
    if audio is None:
        raise ValueError("Audiodatei nicht lesbar")
    if audio.tags is None:
        audio.add_tags()
    if isinstance(audio.tags, ID3):
        audio.tags.delall("APIC")
    _set_cover(audio, cover)
    if isinstance(audio.tags, ID3):
        audio.save(v2_version=4)
    else:
        audio.save()


def prune_dir(directory: Path) -> None:
    root = get_settings().music_dir.resolve()
    directory = directory.resolve()
    while directory != root and directory.is_relative_to(root):
        children = list(directory.iterdir())
        if any(
            not p.is_file() or p.name not in {"cover.jpg", "cover.png", "folder.jpg", "folder.png"} for p in children
        ):
            break
        for child in children:
            child.unlink()
        directory.rmdir()
        directory = directory.parent


async def cleanup_orphans(db: AsyncSession) -> None:
    async with library_lock:
        await db.execute(delete(Album).where(~Album.id.in_(select(Track.album_id).distinct())))
        await db.execute(
            delete(Artist).where(
                ~Artist.id.in_(select(Track.artist_id).distinct()),
                ~Artist.id.in_(select(Album.artist_id).distinct()),
            )
        )
        await db.commit()


def assign_tracks(tracks: list[tuple[uuid.UUID, TrackTags]], metas: list[TrackMeta]) -> dict[uuid.UUID, TrackMeta]:
    pairs = []
    for track_id, tags in tracks:
        for index, meta in enumerate(metas):
            ratio = fuzz.token_set_ratio(norm(tags.title), norm(meta.title))
            position_ok = (tags.disc_no or 1, tags.track_no) == (meta.disc_no or 1, meta.track_no)
            diff = abs(tags.duration - meta.duration) if meta.duration is not None else 0
            if diff <= 5 and (ratio >= 80 or (position_ok and ratio >= 40)):
                pairs.append((ratio + (25 if position_ok else 0) - diff, track_id, index))
    pairs.sort(key=lambda pair: pair[0], reverse=True)
    out = {}
    used = set()
    for _, track_id, index in pairs:
        if track_id not in out and index not in used:
            out[track_id] = metas[index]
            used.add(index)
    return out
