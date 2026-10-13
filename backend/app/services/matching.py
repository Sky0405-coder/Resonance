from sqlalchemy import func, or_, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.models import Album, Artist, Track
from app.schemas import CatalogAlbum, CatalogArtist, CatalogTrack
from app.services.tags import primary_artist


def name_key(value: str) -> str:
    return " ".join(value.casefold().split())


async def match_artists(db: AsyncSession, artists: list[CatalogArtist]) -> None:
    if not artists:
        return
    rows = await db.scalars(select(Artist).where(Artist.name_key.in_([name_key(a.name) for a in artists])))
    by_name = {a.name_key: a.id for a in rows}
    for artist in artists:
        artist.library_id = by_name.get(name_key(artist.name))


async def match_albums(db: AsyncSession, albums: list[CatalogAlbum]) -> None:
    if not albums:
        return
    rows = await db.execute(
        select(Album.id, Artist.name_key, Album.title_key)
        .join(Artist)
        .where(tuple_(Artist.name_key, Album.title_key).in_([(name_key(a.artist), name_key(a.title)) for a in albums]))
    )
    matches = {(artist, title): id for id, artist, title in rows}
    for album in albums:
        album.library_id = matches.get((name_key(album.artist), name_key(album.title)))


async def match_tracks(db: AsyncSession, tracks: list[CatalogTrack]) -> None:
    if not tracks:
        return
    album_artist = aliased(Artist)
    pairs = [(name_key(primary_artist(t.artist)), t.title.casefold()) for t in tracks]
    rows = await db.execute(
        select(Track.id, Track.isrc, func.lower(Track.title), Artist.name_key, album_artist.name_key)
        .join(Artist, Artist.id == Track.artist_id)
        .join(Album, Album.id == Track.album_id)
        .join(album_artist, album_artist.id == Album.artist_id)
        .where(
            or_(
                Track.isrc.in_([t.isrc for t in tracks if t.isrc]),
                tuple_(Artist.name_key, func.lower(Track.title)).in_(pairs),
                tuple_(album_artist.name_key, func.lower(Track.title)).in_(pairs),
            )
        )
        .order_by(Track.id)
    )
    by_isrc = {}
    by_name = {}
    for id, isrc, title, artist, album_credit in rows:
        if isrc:
            by_isrc.setdefault(isrc, id)
        by_name.setdefault((artist, title), id)
        by_name.setdefault((album_credit, title), id)
    for track in tracks:
        track.library_id = by_isrc.get(track.isrc) or by_name.get(
            (name_key(primary_artist(track.artist)), track.title.casefold())
        )
