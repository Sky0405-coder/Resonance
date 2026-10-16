import asyncio
import logging
import random
import time
import uuid
from datetime import UTC, date, datetime, timedelta
from itertools import zip_longest
from typing import Literal

from fastapi import HTTPException
from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.api.catalog import _track
from app.db import SessionLocal
from app.models import (
    Album,
    Artist,
    DownloadItem,
    Playlist,
    PlaylistEntry,
    RadioPending,
    Track,
    TrackLike,
    User,
)
from app.services.deezer import DeezerError, artist_string, deezer
from app.services.deletion import delete_tracks
from app.services.downloads import create_request
from app.services.matching import match_tracks, name_key
from app.services.server_config import load_config
from app.services.tags import primary_artist

log = logging.getLogger(__name__)
_tasks: set[asyncio.Task] = set()
_loop_task: asyncio.Task | None = None


async def _candidates(artist_id: str) -> list[dict]:
    # The Deezer requests run concurrently; a failing one only drops its own list.
    async def safe(coro) -> list:
        try:
            return await coro
        except DeezerError:
            log.debug("Radio candidate request failed", exc_info=True)
            return []

    async def fetch_related_tops() -> list[list[dict]]:
        related = await safe(deezer.artist_related(artist_id, 10))
        return list(await asyncio.gather(*(safe(deezer.artist_top(str(a["id"]), 5)) for a in related[:8])))

    radio, own, related_tops = await asyncio.gather(
        safe(deezer.artist_radio(artist_id)), safe(deezer.artist_top(artist_id, 10)), fetch_related_tops()
    )
    candidates: list[dict] = []
    ids: set[str] = set()
    names: set[tuple[str, str]] = set()
    artist_counts: dict[str, int] = {}
    for group in zip_longest(radio, own, *related_tops):
        for track in group:
            if track is None:
                continue
            track_id = str(track["id"])
            artist_key = name_key(primary_artist(artist_string(track)))
            key = (artist_key, name_key(track["title"]))
            if track_id in ids or key in names or artist_counts.get(artist_key, 0) >= 3:
                continue
            candidates.append(track)
            ids.add(track_id)
            names.add(key)
            artist_counts[artist_key] = artist_counts.get(artist_key, 0) + 1
            if len(candidates) == 80:
                return candidates
    return candidates


async def build_radio(
    db: AsyncSession, user: User, seed_type: Literal["track", "album"], seed_id: uuid.UUID
) -> tuple[Playlist, int]:
    if seed_type == "track":
        seed = await db.scalar(
            select(Track).options(joinedload(Track.album), joinedload(Track.artist)).where(Track.id == seed_id)
        )
    else:
        seed = await db.scalar(select(Album).options(joinedload(Album.artist)).where(Album.id == seed_id))
    if seed is None:
        raise HTTPException(404, "Nicht gefunden")
    seed_artist_name = primary_artist(seed.artist_credit) if isinstance(seed, Track) else seed.artist.name
    now = datetime.now(UTC)
    radio_seed = f"{seed_type}:{seed_id}"
    previous = await db.scalar(
        select(Playlist).where(
            Playlist.owner_id == user.id, Playlist.kind == "radio", Playlist.radio_seed == radio_seed
        )
    )
    if previous is not None:
        if previous.created_at > now - timedelta(hours=24):
            previous.last_used_at = now
            await db.commit()
            await db.refresh(previous)
            return previous, 0
        await db.delete(previous)
        await db.flush()

    artist_id: str | None = None
    try:
        if isinstance(seed, Track) and seed.isrc:
            track = await deezer.track_by_isrc(seed.isrc)
            if track is not None:
                artist_id = str(track["artist"]["id"])
        if artist_id is None:
            artists = await deezer.search_artists(seed_artist_name, 5)
            artist_id = next((str(a["id"]) for a in artists if name_key(a["name"]) == name_key(seed_artist_name)), None)
    except DeezerError:
        log.debug("Radio seed artist lookup failed", exc_info=True)
    candidates = await _candidates(artist_id) if artist_id is not None else []
    catalog = [_track(track) for track in candidates]
    await match_tracks(db, catalog)

    first = (
        [seed.id]
        if isinstance(seed, Track)
        else list(await db.scalars(select(Track.id).where(Track.album_id == seed.id).order_by(func.random()).limit(3)))
    )
    chosen = dict.fromkeys([*first, *(track.library_id for track in catalog if track.library_id is not None)])
    artist_keys = dict.fromkeys(name_key(primary_artist(artist_string(track))) for track in candidates)
    for artist_key in artist_keys:
        chosen.update(
            dict.fromkeys(
                await db.scalars(
                    select(Track.id)
                    .join(Artist, Artist.id == Track.artist_id)
                    .where(Artist.name_key == artist_key, Track.id.not_in(chosen))
                    .order_by(func.random())
                    .limit(3)
                )
            )
        )
    chosen.update(
        dict.fromkeys(
            await db.scalars(
                select(Track.id)
                .join(Artist, Artist.id == Track.artist_id)
                .where(Artist.name_key == name_key(seed_artist_name), Track.id.not_in(chosen))
                .order_by(func.random())
                .limit(5)
            )
        )
    )
    remaining = [track_id for track_id in chosen if track_id not in first]
    random.Random(f"{user.id}:{seed_type}:{seed_id}:{date.today()}").shuffle(remaining)
    ordered = [*first, *remaining][:100]
    playlist = Playlist(
        owner_id=user.id,
        kind="radio",
        radio_seed=radio_seed,
        name=f"{seed.title} Radio",
        is_public=False,
        last_used_at=now,
        entries=[PlaylistEntry(track_id=track_id, position=i) for i, track_id in enumerate(ordered, 1)],
    )
    db.add(playlist)
    await db.flush()
    cfg = await load_config(db)
    requested = 0
    if cfg.radio.auto_download_enabled and cfg.radio.max_downloads_per_radio > 0:
        for track, matched in zip(candidates, catalog, strict=True):
            if matched.library_id is not None:
                continue
            try:
                await create_request(
                    db,
                    user,
                    "track",
                    str(track["id"]),
                    temporary=cfg.radio.temporary_tracks_enabled,
                    radio=True,
                )
            except HTTPException as exc:
                if exc.status_code == 429:
                    break
                continue
            db.add(RadioPending(playlist_id=playlist.id, deezer_id=str(track["id"])))
            requested += 1
            if requested == cfg.radio.max_downloads_per_radio:
                break
    await db.commit()
    return playlist, requested


async def resolve_radio_pending(db: AsyncSession) -> int:
    resolved = 0
    cutoff = datetime.now(UTC) - timedelta(days=7)
    rows = list(await db.scalars(select(RadioPending).with_for_update(skip_locked=True)))
    for row in rows:
        if row.created_at < cutoff:
            await db.delete(row)
            continue
        track_id = await db.scalar(
            select(DownloadItem.track_id)
            .where(DownloadItem.meta["deezer_track_id"].astext == row.deezer_id, DownloadItem.track_id.is_not(None))
            .order_by(DownloadItem.updated_at.desc())
            .limit(1)
        )
        if track_id is None:
            continue
        existing = await db.scalar(
            select(PlaylistEntry.id).where(
                PlaylistEntry.playlist_id == row.playlist_id, PlaylistEntry.track_id == track_id
            )
        )
        if existing is None:
            position = await db.scalar(
                select(func.max(PlaylistEntry.position)).where(PlaylistEntry.playlist_id == row.playlist_id)
            )
            db.add(PlaylistEntry(playlist_id=row.playlist_id, track_id=track_id, position=(position or 0) + 1))
        await db.delete(row)
        resolved += 1
    await db.commit()
    return resolved


async def cleanup(db: AsyncSession) -> tuple[int, int]:
    cfg = await load_config(db)
    now = datetime.now(UTC)
    deleted_radios = 0
    if cfg.radio.playlist_retention_days > 0:
        deleted_radios = len(
            list(
                await db.scalars(
                    delete(Playlist)
                    .where(
                        Playlist.kind == "radio",
                        func.coalesce(Playlist.last_used_at, Playlist.created_at)
                        < now - timedelta(days=cfg.radio.playlist_retention_days),
                    )
                    .returning(Playlist.id)
                )
            )
        )
    track_ids = list(
        await db.scalars(
            select(Track.id).where(
                Track.is_temporary,
                Track.created_at < now - timedelta(days=cfg.radio.temporary_retention_days),
                ~select(TrackLike.id).where(TrackLike.track_id == Track.id).exists(),
                ~select(PlaylistEntry.id)
                .join(Playlist, Playlist.id == PlaylistEntry.playlist_id)
                .where(
                    PlaylistEntry.track_id == Track.id,
                    (Playlist.kind == "user") | (Playlist.mix_key == "discover-weekly"),
                )
                .exists(),
            )
        )
    )
    if track_ids:
        await delete_tracks(db, track_ids)
    else:
        await db.commit()
    return deleted_radios, len(track_ids)


async def _resolve() -> None:
    try:
        async with SessionLocal() as db:
            await resolve_radio_pending(db)
    except Exception:
        log.exception("Radio pending resolution failed")


def resolve_after_download() -> None:
    task = asyncio.create_task(_resolve())
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def _resolve_loop() -> None:
    last_cleanup: float | None = None
    while True:
        await asyncio.sleep(60)
        await _resolve()
        if last_cleanup is None or time.monotonic() - last_cleanup >= 3600:
            last_cleanup = time.monotonic()
            try:
                async with SessionLocal() as db:
                    await cleanup(db)
            except Exception:
                log.exception("Radio cleanup failed")


async def start() -> None:
    global _loop_task
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_resolve_loop())


async def stop() -> None:
    global _loop_task
    tasks = [*_tasks, *([_loop_task] if _loop_task is not None else [])]
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    _tasks.clear()
    _loop_task = None
