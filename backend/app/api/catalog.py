import asyncio

from fastapi import APIRouter, HTTPException, Path, Query

from app.deps import DB, CurrentUser
from app.schemas import (
    CatalogAlbum,
    CatalogAlbumDetail,
    CatalogArtist,
    CatalogArtistDetail,
    CatalogSearchOut,
    CatalogTrack,
)
from app.services.deezer import DeezerError, NotFound, artist_string, deezer
from app.services.matching import match_albums, match_artists, match_tracks

router = APIRouter(prefix="/api/catalog", tags=["catalog"])


def _artist(data: dict) -> CatalogArtist:
    return CatalogArtist(id=str(data["id"]), name=data["name"], picture_url=data.get("picture_medium"))


def _album(data: dict, artist: dict | None = None) -> CatalogAlbum:
    credit = data.get("artist") or artist or {}
    date = data.get("release_date")
    return CatalogAlbum(
        id=str(data["id"]),
        title=data["title"],
        artist=credit.get("name", ""),
        artist_id=str(credit["id"]) if credit.get("id") is not None else None,
        record_type=data.get("record_type"),
        year=int(date[:4]) if date and date[:4].isdigit() else None,
        cover_url=data.get("cover_medium"),
        cover_big_url=data.get("cover_big"),
    )


def _track(data: dict, album: dict | None = None) -> CatalogTrack:
    credit = data.get("artist", {})
    release = album if album is not None else data.get("album", {})
    return CatalogTrack(
        id=str(data["id"]),
        title=data["title"],
        artist=artist_string(data),
        artist_id=str(credit["id"]) if credit.get("id") is not None else None,
        album=release.get("title"),
        album_id=str(release["id"]) if release.get("id") is not None else None,
        cover_url=release.get("cover_medium"),
        duration=data.get("duration"),
        isrc=data.get("isrc"),
        preview_url=data.get("preview"),
        disc_no=data.get("disk_number") if album is not None else None,
        track_no=data.get("track_position") if album is not None else None,
    )


def _preference(item: dict) -> tuple[bool, int]:
    """Explicit editions first, then the more popular one."""
    return bool(item.get("explicit_lyrics")), item.get("fans") or 0


def _drop_censored(items: list[dict], key) -> list[dict]:
    """Drop clean duplicates of releases that are also in the list as explicit."""
    explicit = {key(item) for item in items if item.get("explicit_lyrics")}
    return [item for item in items if item.get("explicit_lyrics") or key(item) not in explicit]


@router.get("/search", response_model=CatalogSearchOut)
async def search(
    user: CurrentUser,
    db: DB,
    q: str = Query(min_length=1, max_length=200),
    types: str = "artist,album,track",
    limit: int = Query(10, ge=1, le=25),
) -> CatalogSearchOut:
    requested = set(types.split(","))
    methods = {"artist": deezer.search_artists, "album": deezer.search_albums, "track": deezer.search_tracks}
    kinds = [kind for kind in methods if kind in requested]
    try:
        results = dict(zip(kinds, await asyncio.gather(*(methods[kind](q, limit) for kind in kinds)), strict=True))
    except NotFound as e:
        raise HTTPException(404, "Nicht im Katalog gefunden") from e
    except DeezerError as e:
        raise HTTPException(502, "Katalog nicht erreichbar") from e
    artists = [_artist(a) for a in results.get("artist", [])]
    albums = [
        _album(a)
        for a in _drop_censored(
            results.get("album", []), lambda a: (a["title"].casefold(), a.get("artist", {}).get("name", "").casefold())
        )
    ]
    tracks = [
        _track(t)
        for t in _drop_censored(
            results.get("track", []), lambda t: (t["title"].casefold(), t.get("artist", {}).get("name", "").casefold())
        )
    ]
    await match_artists(db, artists)
    await match_albums(db, albums)
    await match_tracks(db, tracks)
    return CatalogSearchOut(artists=artists, albums=albums, tracks=tracks)


@router.get("/artists/{id}", response_model=CatalogArtistDetail)
async def artist(user: CurrentUser, db: DB, id: str = Path(max_length=20, pattern=r"^[0-9]+$")) -> CatalogArtistDetail:
    try:
        data, top, releases = await asyncio.gather(
            deezer.artist(id), deezer.artist_top(id, 10), deezer.artist_albums(id)
        )
    except NotFound as e:
        raise HTTPException(404, "Nicht im Katalog gefunden") from e
    except DeezerError as e:
        raise HTTPException(502, "Katalog nicht erreichbar") from e
    deduped = {}
    for release in releases:
        if release.get("record_type") == "compile":
            continue
        key = release["title"].casefold()
        if key not in deduped or _preference(release) > _preference(deduped[key]):
            deduped[key] = release
    ordered = sorted(deduped.values(), key=lambda a: a["title"])
    ordered.sort(key=lambda a: a.get("release_date") or "", reverse=True)
    detail = CatalogArtistDetail(
        artist=_artist(data), top_tracks=[_track(t) for t in top], albums=[_album(a, data) for a in ordered]
    )
    await match_artists(db, [detail.artist])
    await match_albums(db, detail.albums)
    await match_tracks(db, detail.top_tracks)
    return detail


@router.get("/albums/{id}", response_model=CatalogAlbumDetail)
async def album(user: CurrentUser, db: DB, id: str = Path(max_length=20, pattern=r"^[0-9]+$")) -> CatalogAlbumDetail:
    try:
        data, tracks = await asyncio.gather(deezer.album(id), deezer.album_tracks(id))
    except NotFound as e:
        raise HTTPException(404, "Nicht im Katalog gefunden") from e
    except DeezerError as e:
        raise HTTPException(502, "Katalog nicht erreichbar") from e
    detail = CatalogAlbumDetail(
        **_album(data).model_dump(),
        label=data.get("label"),
        genres=[g["name"] for g in data.get("genres", {}).get("data", [])],
        tracks=[_track(t, data) for t in tracks],
    )
    await match_albums(db, [detail])
    await match_tracks(db, detail.tracks)
    return detail
