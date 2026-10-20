import uuid
from collections import Counter, defaultdict
from itertools import pairwise
from pathlib import PurePosixPath

from sqlalchemy import delete, func, or_, select, tuple_, update
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
from app.services.tags import primary_artist

_LOSSLESS = {"flac", "alac", "ape", "wavpack", "wave", "wav", "aiff"}


def track_quality(track: Track) -> int:
    if (track.codec or "").casefold() in _LOSSLESS:
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
    excluded = {track.id for group in groups for track in group[1:]}
    rows = list(
        await db.execute(select(Track.id, Track.title, Track.artist_credit, Track.duration, Track.isrc, Track.album_id))
    )
    album_counts = Counter(row.album_id for row in rows)
    rows = [row for row in rows if row.id not in excluded]
    parents = {row.id: row.id for row in rows}

    def root(id: uuid.UUID) -> uuid.UUID:
        while parents[id] != id:
            parents[id] = parents[parents[id]]
            id = parents[id]
        return id

    def union(left: uuid.UUID, right: uuid.UUID) -> None:
        parents[root(left)] = root(right)

    by_isrc: dict[str, uuid.UUID] = {}
    by_name: dict[tuple[str, str], list[tuple[float, uuid.UUID]]] = defaultdict(list)
    for row in rows:
        if row.isrc:
            union(row.id, by_isrc.setdefault(row.isrc, row.id))
        title_key = name_key(row.title)
        if title_key:
            by_name[(name_key(primary_artist(row.artist_credit)), title_key)].append((row.duration, row.id))
    for matching in by_name.values():
        matching.sort()
        # Adjacent duration matches connect the same components as all matching pairs.
        for (left_duration, left), (right_duration, right) in pairwise(matching):
            if right_duration - left_duration <= 2:
                union(left, right)
    components: dict[uuid.UUID, list[uuid.UUID]] = defaultdict(list)
    component_albums: dict[uuid.UUID, set[uuid.UUID]] = defaultdict(set)
    for row in rows:
        key = root(row.id)
        components[key].append(row.id)
        component_albums[key].add(row.album_id)
    cross_ids = [ids for key, ids in components.items() if len(component_albums[key]) > 1]
    if cross_ids:
        cross_tracks = {
            track.id: track
            for track in await db.scalars(
                select(Track)
                .where(Track.id.in_([id for ids in cross_ids for id in ids]))
                .options(joinedload(Track.album).joinedload(Album.artist), joinedload(Track.artist))
            )
        }
        for ids in cross_ids:
            group = [cross_tracks[id] for id in ids]
            group.sort(
                key=lambda t: (-track_quality(t), -album_counts[t.album_id], t.is_temporary, t.created_at, t.id)
            )
            groups.append(group)
    groups.sort(
        key=lambda g: (
            g[0].album.artist.name,
            g[0].album.title,
            g[0].disc_no if g[0].disc_no is not None else 1,
            g[0].track_no if g[0].track_no is not None else 0,
        )
    )
    return groups


async def lossless_twin(db: AsyncSession, track: Track) -> Track | None:
    title_key = name_key(track.title)
    artist_key = name_key(primary_artist(track.artist_credit))
    candidates = await db.scalars(
        select(Track).where(
            Track.album_id != track.album_id,
            func.lower(Track.codec).in_(_LOSSLESS),
            or_(
                Track.isrc == track.isrc if track.isrc else False,
                Track.duration.between(track.duration - 2, track.duration + 2) if title_key else False,
            ),
        )
    )
    return next(
        (
            twin
            for twin in candidates
            if (track.isrc and twin.isrc == track.isrc)
            or (
                title_key
                and name_key(twin.title) == title_key
                and name_key(primary_artist(twin.artist_credit)) == artist_key
                and abs(twin.duration - track.duration) <= 2
            )
        ),
        None,
    )


async def merge_new_duplicates(db: AsyncSession, track: Track) -> Track:
    """Merges a freshly imported track with copies of the same song already on its album (same rule as
    `find_groups`, e.g. FLAC + MP3, "1-15" vs "15" file names, two folders of one album). Returns the track that was
    kept – the new one only when it has the better quality. Commits (via `delete_tracks`) when it merges."""
    if track.track_no is None:
        return track
    disc = track.disc_no if track.disc_no is not None else 1
    candidates = await db.scalars(
        select(Track).where(
            Track.album_id == track.album_id,
            func.coalesce(Track.disc_no, 1) == disc,
            Track.track_no == track.track_no,
            Track.id != track.id,
        )
    )
    key = name_key(track.title)
    same = [t for t in candidates if name_key(t.title) == key and abs(t.duration - track.duration) <= 5]
    if not same:
        return track
    group = sorted([track, *same], key=lambda t: (-track_quality(t), t.is_temporary, t.created_at, t.id))
    await merge_group(db, group[0], group[1:])
    return group[0]


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
