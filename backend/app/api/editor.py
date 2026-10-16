import asyncio
import uuid
from collections import defaultdict
from typing import Literal
from urllib.parse import urlparse

import httpx
from fastapi import APIRouter, HTTPException, Query, Request
from pydantic import BaseModel, ValidationError
from sqlalchemy import func, select

from app.config import get_settings
from app.deps import DB, AdminUser
from app.models import Album, Artist, Track
from app.schemas import (
    AlbumMatchIn,
    AlbumMatchOut,
    AlbumOut,
    CoverOptionOut,
    FingerprintMatchOut,
    FingerprintReleaseOut,
    Page,
    ReviewTrackOut,
    TrackFileOut,
    TrackMatchIn,
    TrackOut,
)
from app.services import acoustid, covers, identify
from app.services.deezer import DeezerError, deezer
from app.services.deezer import NotFound as DeezerNotFound
from app.services.fingerprint import fingerprint
from app.services.musicbrainz import MusicBrainzError, mb
from app.services.musicbrainz import NotFound as MBNotFound
from app.services.resolve import resolve_album, resolve_track
from app.services.retag import (
    apply_meta,
    assign_tracks,
    cleanup_orphans,
    manual_meta,
    replace_cover,
)
from app.services.scanner import library_lock
from app.services.server_config import load_config
from app.services.tagger import fetch_cover
from app.services.tags import TrackTags, read_tags
from app.services.views import album_options, albums_out, track_options, tracks_out

router = APIRouter(prefix="/api/admin/library", tags=["editor"])
editor_router = APIRouter(prefix="/api/editor", tags=["editor"])


async def _track(db: DB, track_id: uuid.UUID) -> Track:
    track = await db.scalar(select(Track).where(Track.id == track_id).options(*track_options()))
    if track is None:
        raise HTTPException(404, "Song nicht gefunden")
    return track


async def _album(db: DB, album_id: uuid.UUID) -> Album:
    album = await db.scalar(select(Album).where(Album.id == album_id).options(*album_options()))
    if album is None:
        raise HTTPException(404, "Album nicht gefunden")
    return album


async def _tags(track: Track) -> TrackTags:
    tags = await asyncio.to_thread(read_tags, get_settings().music_dir / track.path)
    if tags is None:
        raise HTTPException(409, "Audiodatei nicht lesbar")
    return tags


async def _normalise(cover: bytes | None) -> bytes | None:
    if cover is None:
        return None
    name = await asyncio.to_thread(covers.store, cover)
    if name is None:
        raise HTTPException(422, "Kein gültiges Bild")
    return await asyncio.to_thread((get_settings().cover_cache_dir / name).read_bytes)


@router.get("/tracks/{id}/file", response_model=TrackFileOut)
async def track_file(id: uuid.UUID, admin: AdminUser, db: DB) -> TrackFileOut:
    track = await _track(db, id)
    tags = await _tags(track)
    return TrackFileOut(
        path=track.path,
        **{
            key: getattr(tags, key)
            for key in (
                "title",
                "artist",
                "album",
                "album_artist",
                "year",
                "track_no",
                "disc_no",
                "genre",
                "duration",
                "codec",
                "bitrate",
                "mb_recording_id",
            )
        },
        mb_release_id=tags.mb_album_id,
        query=" ".join(value for value in (tags.artist, tags.title) if value),
    )


@router.get("/tracks/{id}/fingerprint", response_model=list[FingerprintMatchOut])
async def track_fingerprint(id: uuid.UUID, admin: AdminUser, db: DB) -> list[FingerprintMatchOut]:
    track = await _track(db, id)
    key = (await load_config(db)).library.acoustid_api_key
    if not key:
        raise HTTPException(409, "Kein AcoustID-Schlüssel eingetragen")
    try:
        value = await fingerprint(get_settings().music_dir / track.path)
        if not value:
            return []
        tags = await _tags(track)
        candidates = identify.candidates(await acoustid.lookup(key, value, tags.duration))
    except HTTPException:
        raise
    except Exception as e:
        raise HTTPException(502, "AcoustID nicht erreichbar") from e
    grouped = defaultdict(list)
    for candidate in candidates:
        grouped[candidate.recording_id].append(candidate)
    out = []
    for recording_id, group in sorted(grouped.items(), key=lambda pair: -max(c.score for c in pair[1]))[:10]:
        best = max(group, key=lambda c: c.score)
        releases = {}
        for c in sorted(group, key=lambda c: (c.year is None, c.year or 0, c.album or "")):
            if c.release_id:
                releases.setdefault(
                    c.release_id,
                    FingerprintReleaseOut(
                        release_id=c.release_id,
                        album=c.album,
                        year=c.year,
                        disc_no=c.disc_no,
                        track_no=c.track_no,
                        release_tracks=c.release_tracks,
                    ),
                )
        out.append(
            FingerprintMatchOut(
                recording_id=recording_id,
                title=best.title,
                artist=best.artist,
                score=best.score,
                releases=list(releases.values())[:15],
            )
        )
    return out


@router.post("/tracks/{id}/match", response_model=TrackOut)
async def match_track(id: uuid.UUID, body: TrackMatchIn, admin: AdminUser, db: DB) -> TrackOut:
    track = await _track(db, id)
    required = {"deezer": body.deezer_id, "musicbrainz": body.recording_id, "manual": body.meta}
    if required[body.source] is None or required[body.source] == "":
        raise HTTPException(422, "Unvollständige Angaben")
    try:
        if body.source == "manual":
            meta = manual_meta(await _tags(track), body.meta)
            cover = None
        else:
            if body.source == "deezer":
                meta = await resolve_track(body.deezer_id)
            elif body.release_id:
                metas = await mb.track_meta_list(await mb.release_full(body.release_id))
                matches = [m for m in metas if m.mb_recording_id == body.recording_id]
                if not matches:
                    raise HTTPException(422, "Song nicht auf dieser Veröffentlichung")
                tags = await _tags(track)
                meta = next(
                    (m for m in matches if (m.disc_no, m.track_no) == (tags.disc_no, tags.track_no)), matches[0]
                )
            else:
                meta = await mb.recording_meta(body.recording_id)
            cover = await _normalise(await fetch_cover(meta))
    except (DeezerNotFound, MBNotFound) as e:
        raise HTTPException(404, "Nicht gefunden") from e
    except DeezerError as e:
        raise HTTPException(502, "Katalog nicht erreichbar") from e
    except MusicBrainzError as e:
        raise HTTPException(502, "MusicBrainz nicht erreichbar") from e
    try:
        track = await apply_meta(db, track, meta, cover)
    except ValueError as e:
        raise HTTPException(409, str(e)) from e
    if body.source == "manual":
        track.reviewed = True
        await db.commit()
    return (await tracks_out(db, admin, [track]))[0]


@router.post("/albums/{id}/match", response_model=AlbumMatchOut)
async def match_album(id: uuid.UUID, body: AlbumMatchIn, admin: AdminUser, db: DB) -> AlbumMatchOut:
    await _album(db, id)
    tracks = list(
        await db.scalars(
            select(Track).where(Track.album_id == id).options(*track_options()).order_by(Track.disc_no, Track.track_no)
        )
    )
    try:
        metas = (
            (await resolve_album(body.id))[1]
            if body.source == "deezer"
            else await mb.track_meta_list(await mb.release_full(body.id))
        )
        cover = await _normalise(await fetch_cover(metas[0])) if metas else None
    except (DeezerNotFound, MBNotFound) as e:
        raise HTTPException(404, "Nicht gefunden") from e
    except DeezerError as e:
        raise HTTPException(502, "Katalog nicht erreichbar") from e
    except MusicBrainzError as e:
        raise HTTPException(502, "MusicBrainz nicht erreichbar") from e
    assignments = assign_tracks([(t.id, await _tags(t)) for t in tracks], metas)
    first_album = None
    for track in tracks:
        if track.id in assignments:
            try:
                refreshed = await apply_meta(db, track, assignments[track.id], cover)
            except ValueError as e:
                raise HTTPException(409, str(e)) from e
            if first_album is None:
                first_album = refreshed.album_id
    await cleanup_orphans(db)
    album = (await albums_out(db, [await _album(db, first_album)]))[0] if first_album else None
    return AlbumMatchOut(
        album=album,
        matched=len(assignments),
        unmatched=await tracks_out(db, admin, [t for t in tracks if t.id not in assignments]),
    )


@router.get("/albums/{id}/cover-options", response_model=list[CoverOptionOut])
async def cover_options(id: uuid.UUID, admin: AdminUser, db: DB) -> list[CoverOptionOut]:
    album = await _album(db, id)
    out = []
    if album.mb_release_id:
        out.append(
            CoverOptionOut(
                url=f"https://coverartarchive.org/release/{album.mb_release_id}/front-500",
                source="musicbrainz",
                label="MusicBrainz",
            )
        )
    try:
        for item in await deezer.search_albums(f"{album.artist.name} {album.title}", 10):
            if item.get("cover_xl"):
                out.append(
                    CoverOptionOut(
                        url=item["cover_xl"],
                        source="deezer",
                        label=f"{item['title']} – {item.get('artist', {}).get('name', '')}",
                    )
                )
    except DeezerError:
        pass
    return out[:12]


class _CoverIn(BaseModel):
    url: str


def _allowed_cover(url: str) -> None:
    try:
        parsed = urlparse(url)
        host = (parsed.hostname or "").lower()
    except ValueError as e:
        raise HTTPException(422, "Bildquelle nicht erlaubt") from e
    if parsed.scheme != "https" or not any(
        host == domain or host.endswith("." + domain) for domain in ("coverartarchive.org", "archive.org", "dzcdn.net")
    ):
        raise HTTPException(422, "Bildquelle nicht erlaubt")


@router.post("/albums/{id}/cover", response_model=AlbumOut)
async def album_cover(id: uuid.UUID, request: Request, admin: AdminUser, db: DB) -> AlbumOut:
    album = await _album(db, id)
    if request.headers.get("content-type", "").startswith("multipart/form-data"):
        form = await request.form()
        file = form.get("file")
        if file is None or not hasattr(file, "read"):
            raise HTTPException(422, "Kein gültiges Bild")
        data = await file.read(10 * 1024 * 1024 + 1)
    else:
        try:
            url = _CoverIn.model_validate(await request.json()).url
        except (ValidationError, ValueError) as e:
            raise HTTPException(422, "Kein gültiges Bild") from e
        _allowed_cover(url)

        async def validate_request(outgoing: httpx.Request) -> None:
            _allowed_cover(str(outgoing.url))

        try:
            async with httpx.AsyncClient(
                follow_redirects=True, timeout=20, event_hooks={"request": [validate_request]}
            ) as client:
                response = await client.get(url)
                response.raise_for_status()
                data = response.content
        except httpx.HTTPError as e:
            raise HTTPException(502, "Bildquelle nicht erreichbar") from e
    if len(data) > 10 * 1024 * 1024:
        raise HTTPException(413, "Bild zu groß")
    name = await asyncio.to_thread(covers.store, data)
    if name is None:
        raise HTTPException(422, "Kein gültiges Bild")
    cover = await asyncio.to_thread((get_settings().cover_cache_dir / name).read_bytes)
    async with library_lock:
        tracks = list(await db.scalars(select(Track).where(Track.album_id == id)))
        paths = [get_settings().music_dir / t.path for t in tracks]
        for directory in dict.fromkeys(path.parent for path in paths):
            await asyncio.to_thread((directory / "cover.jpg").write_bytes, cover)
            for leftover in ("cover.png", "folder.jpg", "folder.png"):
                await asyncio.to_thread((directory / leftover).unlink, missing_ok=True)
        for track, path in zip(tracks, paths, strict=True):
            await asyncio.to_thread(replace_cover, path, cover)
            stat = await asyncio.to_thread(path.stat)
            track.mtime, track.size = stat.st_mtime, stat.st_size
        album.cover_file = name
        await db.commit()
    return (await albums_out(db, [album]))[0]


@editor_router.post("/tracks/{id}/reviewed", status_code=204)
async def mark_reviewed(id: uuid.UUID, admin: AdminUser, db: DB) -> None:
    track = await _track(db, id)
    track.reviewed = True
    await db.commit()


@editor_router.get("/review", response_model=Page[ReviewTrackOut])
@router.get("/review", response_model=Page[ReviewTrackOut])
async def review(
    admin: AdminUser,
    db: DB,
    kind: Literal["unidentified", "no_cover"] = "unidentified",
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
) -> Page[ReviewTrackOut]:
    query = select(Track).join(Track.artist).join(Track.album)
    if kind == "unidentified":
        query = query.where(Track.mb_recording_id.is_(None), Track.reviewed.is_(False))
    else:
        first = (
            select(Track.id)
            .where(Track.album_id == Album.id)
            .order_by(Track.disc_no, Track.track_no, Track.id)
            .limit(1)
            .correlate(Album)
            .scalar_subquery()
        )
        query = query.where(Album.cover_file.is_(None), Track.id == first)
    total = await db.scalar(select(func.count()).select_from(query.subquery())) or 0
    tracks = list(
        await db.scalars(
            query.options(*track_options())
            .order_by(Artist.name, Album.title, Track.disc_no, Track.track_no)
            .offset(offset)
            .limit(limit)
        )
    )
    items = [
        ReviewTrackOut(**out.model_dump(), path=track.path)
        for track, out in zip(tracks, await tracks_out(db, admin, tracks), strict=True)
    ]
    return Page(items=items, total=total, offset=offset, limit=limit)
