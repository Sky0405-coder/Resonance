"""Helpers that turn ORM rows into API schemas (with per-user flags and aggregates)."""

import uuid
from collections.abc import Sequence

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.i18n import translate
from app.models import (
    Album,
    Artist,
    Playlist,
    PlaylistEntry,
    PlaylistShare,
    Track,
    TrackLike,
    User,
)
from app.schemas import AlbumOut, ArtistOut, ArtistRef, PlaylistOut, TrackOut


def track_options():
    return (joinedload(Track.artist), joinedload(Track.album))


def album_options():
    return (joinedload(Album.artist),)


async def tracks_out(db: AsyncSession, user: User, tracks: Sequence[Track]) -> list[TrackOut]:
    if not tracks:
        return []
    liked = set(
        await db.scalars(
            select(TrackLike.track_id).where(
                TrackLike.user_id == user.id, TrackLike.track_id.in_([t.id for t in tracks])
            )
        )
    )
    out = []
    for t in tracks:
        item = TrackOut.model_validate(t)
        item.liked = t.id in liked
        out.append(item)
    return out


async def albums_out(db: AsyncSession, albums: Sequence[Album]) -> list[AlbumOut]:
    if not albums:
        return []
    counts = dict(
        (
            await db.execute(
                select(Track.album_id, func.count())
                .where(Track.album_id.in_([a.id for a in albums]))
                .group_by(Track.album_id)
            )
        ).all()
    )
    out = []
    for a in albums:
        item = AlbumOut.model_validate(a)
        item.has_cover = a.cover_file is not None
        item.track_count = counts.get(a.id, 0)
        out.append(item)
    return out


async def artists_out(db: AsyncSession, artists: Sequence[Artist], lang: str = "de") -> list[ArtistOut]:
    from app.services.artist_info import biography

    if not artists:
        return []
    ids = [a.id for a in artists]
    counts = dict(
        (
            await db.execute(
                select(Album.artist_id, func.count()).where(Album.artist_id.in_(ids)).group_by(Album.artist_id)
            )
        ).all()
    )
    # Album art remains the fallback for artists without a cached image.
    covers: dict[uuid.UUID, uuid.UUID] = {}
    rows = await db.execute(
        select(Album.artist_id, Album.id)
        .where(Album.artist_id.in_(ids), Album.cover_file.is_not(None))
        .order_by(Album.artist_id, Album.year.desc().nulls_last())
    )
    for artist_id, album_id in rows:
        covers.setdefault(artist_id, album_id)
    out = []
    for a in artists:
        item = ArtistOut.model_validate(a)
        item.has_image = bool(a.image_path)
        item.bio = biography(a, lang)
        item.album_count = counts.get(a.id, 0)
        item.cover_album_id = covers.get(a.id)
        out.append(item)
    return out


async def playlists_out(
    db: AsyncSession, playlists: Sequence[Playlist], user_id: uuid.UUID, lang: str = "de"
) -> list[PlaylistOut]:
    if not playlists:
        return []
    ids = [p.id for p in playlists]
    stats = {
        pid: (count, duration or 0)
        for pid, count, duration in await db.execute(
            select(PlaylistEntry.playlist_id, func.count(), func.sum(Track.duration))
            .join(Track, Track.id == PlaylistEntry.track_id)
            .where(PlaylistEntry.playlist_id.in_(ids))
            .group_by(PlaylistEntry.playlist_id)
        )
    }
    covers: dict[uuid.UUID, list[uuid.UUID]] = {}
    rows = await db.execute(
        select(PlaylistEntry.playlist_id, Album.id)
        .join(Track, Track.id == PlaylistEntry.track_id)
        .join(Album, Album.id == Track.album_id)
        .where(PlaylistEntry.playlist_id.in_(ids), Album.cover_file.is_not(None))
        .order_by(PlaylistEntry.playlist_id, PlaylistEntry.position)
    )
    for pid, album_id in rows:
        lst = covers.setdefault(pid, [])
        if album_id not in lst and len(lst) < 4:
            lst.append(album_id)
    owners = {u.id: u for u in await db.scalars(select(User).where(User.id.in_({p.owner_id for p in playlists})))}
    shared_with: dict[uuid.UUID, list[ArtistRef]] = {}
    rows = await db.execute(
        select(PlaylistShare.playlist_id, User.id, User.display_name)
        .join(User, User.id == PlaylistShare.user_id)
        .where(PlaylistShare.playlist_id.in_([p.id for p in playlists if p.owner_id == user_id]))
    )
    for playlist_id, shared_user_id, name in rows:
        shared_with.setdefault(playlist_id, []).append(ArtistRef(id=shared_user_id, name=name))
    for shares in shared_with.values():
        shares.sort(key=lambda share: share.name.casefold())
    out = []
    for p in playlists:
        owner = owners[p.owner_id]
        count, duration = stats.get(p.id, (0, 0))
        out.append(
            PlaylistOut(
                id=p.id,
                name=translate(p.name, lang) if p.kind == "mix" else p.name,
                description=translate(p.description, lang)
                if p.kind == "mix" and p.description is not None
                else p.description,
                is_public=p.is_public,
                kind=p.kind,
                mix_key=p.mix_key,
                owner=ArtistRef(id=owner.id, name=owner.display_name),
                shared_with=shared_with.get(p.id, []),
                track_count=count,
                duration=duration,
                cover_album_ids=covers.get(p.id, []),
                cover_key=p.cover_file,
                updated_at=p.updated_at,
            )
        )
    return out
