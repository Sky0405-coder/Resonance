import asyncio
import uuid
from datetime import UTC, datetime, timedelta
from typing import Literal

from fastapi import APIRouter, HTTPException, Query, status
from fastapi.responses import FileResponse, Response, StreamingResponse
from sqlalchemy import func, or_, select

from app.api.catalog import _track as catalog_track
from app.deps import DB, CurrentUser
from app.models import Album, Artist, PlayEvent, Playlist, SavedAlbum, Track
from app.schemas import (
    AlbumDetail,
    AlbumOut,
    ArtistDetail,
    ArtistOut,
    HomeOut,
    MissingTracksOut,
    Page,
    SearchResult,
    TrackOut,
)
from app.services import covers, transcode
from app.services.deezer import DeezerError, deezer
from app.services.matching import match_tracks, name_key
from app.services.views import (
    album_options,
    albums_out,
    artists_out,
    playlists_out,
    track_options,
    tracks_out,
)

router = APIRouter(prefix="/api", tags=["library"])


def _track_order():
    return (Track.disc_no.nulls_first(), Track.track_no.nulls_last(), Track.title)


@router.get("/home", response_model=HomeOut)
async def home(user: CurrentUser, db: DB) -> HomeOut:
    recent_album_ids = (
        await db.execute(
            select(Track.album_id, func.max(PlayEvent.played_at).label("last"))
            .join(PlayEvent, PlayEvent.track_id == Track.id)
            .where(PlayEvent.user_id == user.id)
            .group_by(Track.album_id)
            .order_by(func.max(PlayEvent.played_at).desc())
            .limit(12)
        )
    ).all()
    ids = [r[0] for r in recent_album_ids]
    by_id = {a.id: a for a in await db.scalars(select(Album).options(*album_options()).where(Album.id.in_(ids)))}
    recently_played = [by_id[i] for i in ids if i in by_id]

    recently_added = list(
        await db.scalars(select(Album).options(*album_options()).order_by(Album.created_at.desc()).limit(12))
    )

    playlists = list(
        await db.scalars(
            select(Playlist)
            .where(Playlist.owner_id == user.id, Playlist.kind == "user")
            .order_by(Playlist.updated_at.desc())
            .limit(12)
        )
    )

    since = datetime.now(UTC) - timedelta(days=30)
    top_ids = [
        r[0]
        for r in (
            await db.execute(
                select(PlayEvent.track_id)
                .where(PlayEvent.user_id == user.id, PlayEvent.played_at >= since)
                .group_by(PlayEvent.track_id)
                .order_by(func.count().desc())
                .limit(10)
            )
        ).all()
    ]
    tracks_by_id = {
        t.id: t for t in await db.scalars(select(Track).options(*track_options()).where(Track.id.in_(top_ids)))
    }

    return HomeOut(
        recently_played=await albums_out(db, recently_played),
        recently_added=await albums_out(db, recently_added),
        playlists=await playlists_out(db, playlists, user.id),
        most_played=await tracks_out(db, user, [tracks_by_id[i] for i in top_ids if i in tracks_by_id]),
    )


# --- artists ----------------------------------------------------------------


@router.get("/artists", response_model=Page[ArtistOut])
async def list_artists(
    user: CurrentUser,
    db: DB,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=500),
) -> Page[ArtistOut]:
    total = await db.scalar(select(func.count()).select_from(Artist)) or 0
    rows = await db.scalars(
        select(Artist).order_by(func.coalesce(Artist.sort_name, Artist.name)).offset(offset).limit(limit)
    )
    return Page(items=await artists_out(db, list(rows)), total=total, offset=offset, limit=limit)


@router.get("/artists/{artist_id}", response_model=ArtistDetail)
async def get_artist(artist_id: uuid.UUID, user: CurrentUser, db: DB) -> ArtistDetail:
    artist = await db.get(Artist, artist_id)
    if artist is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Artist not found")
    albums = list(
        await db.scalars(
            select(Album)
            .options(*album_options())
            .where(Album.artist_id == artist_id)
            .order_by(Album.year.desc().nulls_last(), Album.title)
        )
    )
    # "Popular" = most played by everyone on this server; fall back to album order.
    plays = func.count(PlayEvent.id)
    top = list(
        await db.scalars(
            select(Track)
            .options(*track_options())
            .outerjoin(PlayEvent, PlayEvent.track_id == Track.id)
            .where(Track.artist_id == artist_id)
            .group_by(Track.id)
            .order_by(plays.desc(), Track.title)
            .limit(10)
        )
    )
    detail = ArtistDetail.model_validate((await artists_out(db, [artist]))[0].model_dump())
    detail.albums = await albums_out(db, albums)
    detail.top_tracks = await tracks_out(db, user, top)
    return detail


# --- albums -----------------------------------------------------------------


@router.get("/albums", response_model=Page[AlbumOut])
async def list_albums(
    user: CurrentUser,
    db: DB,
    sort: Literal["recent", "title", "year", "artist"] = "recent",
    saved: bool = False,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=500),
) -> Page[AlbumOut]:
    query = select(Album).options(*album_options())
    count_query = select(func.count()).select_from(Album)
    if saved:
        query = query.join(SavedAlbum, SavedAlbum.album_id == Album.id).where(SavedAlbum.user_id == user.id)
        count_query = count_query.join(SavedAlbum, SavedAlbum.album_id == Album.id).where(SavedAlbum.user_id == user.id)
    order = {
        "recent": (Album.created_at.desc(),),
        "title": (Album.title,),
        "year": (Album.year.desc().nulls_last(), Album.title),
        "artist": (Artist.name, Album.year),
    }[sort]
    if sort == "artist":
        query = query.join(Artist, Artist.id == Album.artist_id)
    rows = await db.scalars(query.order_by(*order).offset(offset).limit(limit))
    total = await db.scalar(count_query) or 0
    return Page(items=await albums_out(db, list(rows)), total=total, offset=offset, limit=limit)


@router.get("/albums/{album_id}", response_model=AlbumDetail)
async def get_album(album_id: uuid.UUID, user: CurrentUser, db: DB) -> AlbumDetail:
    album = await db.scalar(select(Album).options(*album_options()).where(Album.id == album_id))
    if album is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Album not found")
    tracks = list(
        await db.scalars(
            select(Track).options(*track_options()).where(Track.album_id == album_id).order_by(*_track_order())
        )
    )
    detail = AlbumDetail.model_validate((await albums_out(db, [album]))[0].model_dump())
    detail.tracks = await tracks_out(db, user, tracks)
    detail.duration = sum(t.duration for t in tracks)
    detail.saved = (
        await db.scalar(select(SavedAlbum.id).where(SavedAlbum.user_id == user.id, SavedAlbum.album_id == album_id))
    ) is not None
    return detail


async def _catalog_album_id(db: DB, album_id: uuid.UUID) -> tuple[Album, str]:
    """Find the catalog (Deezer) album matching a library album."""
    album = await db.scalar(select(Album).options(*album_options()).where(Album.id == album_id))
    if album is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nicht gefunden")
    try:
        results = await deezer.search_albums(f"{album.artist.name} {album.title}", 10)
    except DeezerError as e:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "Katalog nicht erreichbar") from e
    candidates = [result for result in results if name_key(result["artist"]["name"]) == album.artist.name_key]
    for result in candidates:
        if name_key(result["title"]) == album.title_key:
            return album, str(result["id"])
    for result in candidates:
        title_key = name_key(result["title"])
        if title_key.startswith(album.title_key) or album.title_key.startswith(title_key):
            return album, str(result["id"])
    raise HTTPException(status.HTTP_404_NOT_FOUND, "Album nicht im Katalog gefunden")


@router.get("/library/albums/{album_id}/catalog")
async def album_catalog(album_id: uuid.UUID, user: CurrentUser, db: DB) -> dict[str, str]:
    _, catalog_id = await _catalog_album_id(db, album_id)
    return {"catalog_id": catalog_id}


@router.get("/library/albums/{album_id}/missing", response_model=MissingTracksOut)
async def album_missing(album_id: uuid.UUID, user: CurrentUser, db: DB) -> MissingTracksOut:
    """Songs of the matching catalog album that are not in the library (shown greyed out on the album page).

    A catalog song counts as present if it matches any library track (ISRC / artist + title) or if the library
    album already has a song at the same disc/track position (tag variants like "Remastered")."""
    album, catalog_id = await _catalog_album_id(db, album_id)
    try:
        data, raw = await asyncio.gather(deezer.album(catalog_id), deezer.album_tracks(catalog_id))
    except DeezerError as e:
        raise HTTPException(status.HTTP_502_BAD_GATEWAY, "Katalog nicht erreichbar") from e
    tracks = [catalog_track(t, data) for t in raw]
    await match_tracks(db, tracks)
    taken = set((await db.execute(select(Track.disc_no, Track.track_no).where(Track.album_id == album.id))).all())
    missing = [
        t
        for t in tracks
        if t.library_id is None and (t.disc_no or 1, t.track_no) not in {(d or 1, n) for d, n in taken}
    ]
    return MissingTracksOut(catalog_id=catalog_id, tracks=missing)


@router.get("/albums/{album_id}/cover")
async def album_cover(
    album_id: uuid.UUID,
    user: CurrentUser,
    db: DB,
    size: int | None = Query(None, ge=32, le=2000),
) -> Response:
    album = await db.get(Album, album_id)
    if album is None or album.cover_file is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No cover")
    path = covers.resized(album.cover_file, size)
    if path is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No cover")
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=604800"})


# --- tracks -----------------------------------------------------------------


@router.get("/tracks/{track_id}", response_model=TrackOut)
async def get_track(track_id: uuid.UUID, user: CurrentUser, db: DB) -> TrackOut:
    track = await db.scalar(select(Track).options(*track_options()).where(Track.id == track_id))
    if track is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Track not found")
    return (await tracks_out(db, user, [track]))[0]


@router.get("/tracks/{track_id}/stream")
async def stream_track(
    track_id: uuid.UUID,
    user: CurrentUser,
    db: DB,
    format: Literal["auto", "raw", "opus", "mp3"] = "auto",
    bitrate: int | None = Query(None, ge=32, le=320),
) -> Response:
    track = await db.get(Track, track_id)
    if track is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Track not found")
    path = transcode.resolve_path(track.path)
    if not path.is_file():
        raise HTTPException(status.HTTP_410_GONE, "File missing on disk")
    if format == "auto":
        # Pass through what clients can play; WMA/APE/AIFF/ALAC/... become high-bitrate Opus.
        if track.codec in transcode.NATIVE_CODECS:
            format = "raw"
        else:
            format, bitrate = "opus", bitrate or 256
    if format == "raw":
        # FileResponse handles HTTP Range requests, which players need for seeking.
        return FileResponse(path, media_type=transcode.media_type(path))
    return StreamingResponse(
        transcode.stream(path, format, bitrate or 160),
        media_type=transcode.FORMAT_MEDIA_TYPES[format],
    )


# --- search -----------------------------------------------------------------


@router.get("/search", response_model=SearchResult)
async def search(
    user: CurrentUser,
    db: DB,
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(20, ge=1, le=100),
) -> SearchResult:
    pattern = f"%{q.strip()}%"
    artists = list(
        await db.scalars(select(Artist).where(Artist.name.ilike(pattern)).order_by(Artist.name).limit(limit))
    )
    albums = list(
        await db.scalars(
            select(Album).options(*album_options()).where(Album.title.ilike(pattern)).order_by(Album.title).limit(limit)
        )
    )
    tracks = list(
        await db.scalars(
            select(Track)
            .options(*track_options())
            .where(or_(Track.title.ilike(pattern), Track.artist_credit.ilike(pattern)))
            .order_by(Track.title)
            .limit(limit)
        )
    )
    return SearchResult(
        artists=await artists_out(db, artists),
        albums=await albums_out(db, albums),
        tracks=await tracks_out(db, user, tracks),
    )
