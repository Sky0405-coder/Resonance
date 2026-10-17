import uuid
from collections import defaultdict
from pathlib import PurePosixPath

from sqlalchemy import delete, func, select, tuple_, update
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.models import (
    Album,
    DownloadItem,
    DownloadRequest,
    ImportFile,
    PlayEvent,
    PlaylistEntry,
    Track,
    TrackLike,
    TrackLyrics,
)
from app.services.deletion import delete_tracks
from app.services.matching import name_key


def track_quality(track: Track) -> int:
    if (track.codec or "").casefold() in {"flac", "alac", "ape", "wavpack", "wave", "wav", "aiff"}:
        return 10_000
    return track.bitrate or 0


async def _same_stem_track(db: AsyncSession, target: str, exclude_path: str | None = None) -> Track | None:
    path = PurePosixPath(target)
    stem = str(path.with_suffix("")).casefold()
    # Narrow down in SQL ("<stem>.<anything>", lower() like PostgreSQL); the exact comparison stays in Python.
    escaped = str(path.with_suffix("")).lower().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
    query = select(Track).where(func.lower(Track.path).like(escaped + ".%", escape="\\"))
    if exclude_path is not None:
        query = query.where(Track.path != exclude_path)
    matches = [
        track
        for track in await db.scalars(query)
        if str(PurePosixPath(track.path).with_suffix("")).casefold() == stem
        and PurePosixPath(track.path).suffix.casefold() != path.suffix.casefold()
    ]
    return max(matches, key=track_quality, default=None)


async def find_groups(db: AsyncSession) -> list[list[Track]]:
    disc = func.coalesce(Track.disc_no, 1)
    candidates = (
        select(Track.album_id, disc, Track.track_no)
        .where(Track.track_no.is_not(None))
        .group_by(Track.album_id, disc, Track.track_no)
        .having(func.count() > 1)
    )
    tracks = await db.scalars(
        select(Track)
        .where(tuple_(Track.album_id, disc, Track.track_no).in_(candidates))
        .options(joinedload(Track.album).joinedload(Album.artist), joinedload(Track.artist))
    )
    keyed: dict[tuple[uuid.UUID, int, int, str], list[Track]] = defaultdict(list)
    for track in tracks:
        keyed[
            (track.album_id, track.disc_no if track.disc_no is not None else 1, track.track_no, name_key(track.title))
        ].append(track)
    groups: list[list[Track]] = []
    for matching in keyed.values():
        group: list[Track] = []
        for track in sorted(matching, key=lambda t: (t.duration, t.id)):
            if group and track.duration - group[0].duration > 5:
                if len(group) >= 2:
                    groups.append(group)
                group = []
            group.append(track)
        if len(group) >= 2:
            groups.append(group)
    for group in groups:
        group.sort(key=lambda t: (-track_quality(t), t.is_temporary, t.created_at, t.id))
    groups.sort(
        key=lambda g: (
            g[0].album.artist.name,
            g[0].album.title,
            g[0].disc_no if g[0].disc_no is not None else 1,
            g[0].track_no,
        )
    )
    return groups


async def merge_group(db: AsyncSession, keeper: Track, losers: list[Track]) -> None:
    keeper_likes = set(await db.scalars(select(TrackLike.user_id).where(TrackLike.track_id == keeper.id)))
    has_lyrics = await db.get(TrackLyrics, keeper.id) is not None
    for loser in losers:
        if not loser.is_temporary:
            keeper.is_temporary = False
        if loser.reviewed:
            keeper.reviewed = True
        for column in (
            PlaylistEntry.track_id,
            PlayEvent.track_id,
            DownloadItem.track_id,
            DownloadItem.replace_track_id,
            DownloadRequest.replace_track_id,
            ImportFile.track_id,
        ):
            await db.execute(update(column.class_).where(column == loser.id).values({column: keeper.id}))
        likes = list(await db.scalars(select(TrackLike).where(TrackLike.track_id == loser.id)))
        for like in likes:
            if like.user_id in keeper_likes:
                await db.execute(delete(TrackLike).where(TrackLike.id == like.id))
            else:
                like.track_id = keeper.id
                keeper_likes.add(like.user_id)
        if not has_lyrics and await db.get(TrackLyrics, loser.id) is not None:
            await db.execute(update(TrackLyrics).where(TrackLyrics.track_id == loser.id).values(track_id=keeper.id))
            has_lyrics = True
    await delete_tracks(db, [loser.id for loser in losers])
