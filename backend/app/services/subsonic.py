"""Subsonic parameter, authentication, serialization and bulk object helpers."""

import hashlib
import secrets
import uuid
from collections.abc import Sequence
from pathlib import Path
from typing import Any
from xml.etree import ElementTree as ET

from fastapi import Request
from fastapi.responses import JSONResponse, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import (
    Album,
    Artist,
    PlayEvent,
    Playlist,
    PlaylistEntry,
    SavedAlbum,
    Track,
    TrackLike,
    User,
)
from app.services import transcode
from app.services.views import playlists_out


class SubsonicError(Exception):
    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


class Params:
    def __init__(self, pairs: Sequence[tuple[str, str]]) -> None:
        self.values: dict[str, list[str]] = {}
        for key, value in pairs:
            self.values.setdefault(key, []).append(value)

    @classmethod
    async def read(cls, request: Request) -> "Params":
        pairs = list(request.query_params.multi_items())
        if request.method == "POST":
            form = await request.form()
            pairs.extend((key, str(value)) for key, value in form.multi_items())
        return cls(pairs)

    def all(self, name: str) -> list[str]:
        return self.values.get(name, [])

    def has(self, name: str) -> bool:
        return name in self.values

    def get(self, name: str, default: str = "") -> str:
        values = self.all(name)
        return values[-1] if values else default

    def require(self, name: str) -> str:
        value = self.get(name)
        if not value:
            raise SubsonicError(10, f"Parameter fehlt: {name}")
        return value

    def integer(self, name: str, default: int, maximum: int | None = None) -> int:
        try:
            value = int(self.get(name, str(default)))
        except ValueError as exc:
            raise SubsonicError(0, f"Ungültiger Parameter: {name}") from exc
        if value < 0:
            raise SubsonicError(0, f"Ungültiger Parameter: {name}")
        return min(value, maximum) if maximum is not None else value

    def boolean(self, name: str, default: bool = False) -> bool:
        value = self.get(name, str(default).lower()).lower()
        if value not in {"true", "false", "1", "0"}:
            raise SubsonicError(0, f"Ungültiger Parameter: {name}")
        return value in {"true", "1"}

    def ids(self, name: str) -> list[uuid.UUID]:
        return [parse_id(value) for value in self.all(name)]


def parse_id(value: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise SubsonicError(70, "Nicht gefunden") from exc


async def authenticate(db: AsyncSession, params: Params) -> User:
    auth_names = ("u", "p", "t", "s", "apiKey")
    if any(len(set(params.all(name))) > 1 for name in auth_names):
        raise SubsonicError(43, "Widersprüchliche Authentifizierung")
    if params.has("apiKey"):
        if any(params.has(name) for name in ("u", "p", "t", "s")):
            raise SubsonicError(43, "Widersprüchliche Authentifizierung")
        key = params.require("apiKey")
        user = await db.scalar(select(User).where(User.subsonic_password == key))
        if user is None:
            raise SubsonicError(44, "Ungültiger API-Schlüssel")
    else:
        username = params.require("u")
        if params.has("p") and (params.has("t") or params.has("s")):
            raise SubsonicError(43, "Widersprüchliche Authentifizierung")
        if params.has("p"):
            password = params.require("p")
            if password.startswith("enc:"):
                try:
                    password = bytes.fromhex(password[4:]).decode("utf-8")
                except (ValueError, UnicodeDecodeError) as exc:
                    raise SubsonicError(40, "Benutzername oder Passwort falsch") from exc
        else:
            params.require("t")
            params.require("s")
            password = None
        user = await db.scalar(select(User).where(func.lower(User.username) == username.lower()))
        if user is None or not user.subsonic_password:
            raise SubsonicError(40, "Benutzername oder Passwort falsch")
        expected = (
            user.subsonic_password
            if password is not None
            else hashlib.md5((user.subsonic_password + params.get("s")).encode()).hexdigest()
        )
        if not secrets.compare_digest(
            expected.encode(), (password if password is not None else params.get("t")).encode()
        ):
            raise SubsonicError(40, "Benutzername oder Passwort falsch")
    if user.is_disabled:
        raise SubsonicError(40, "Benutzername oder Passwort falsch")
    params.require("v")
    params.require("c")
    return user


def _scalar(value: Any) -> str:
    return str(value).lower() if isinstance(value, bool) else str(value)


def _xml(element: ET.Element, value: Any) -> None:
    if not isinstance(value, dict):
        element.text = _scalar(value)
        return
    for key, item in value.items():
        if item is None:
            continue
        if isinstance(item, list):
            for child in item:
                _xml(ET.SubElement(element, key), child)
        elif isinstance(item, dict):
            _xml(ET.SubElement(element, key), item)
        elif key == "value":
            # Subsonic represents element text as `value` in JSON (genres and lyrics).
            element.text = _scalar(item)
        else:
            element.set(key, _scalar(item))


def response(params: Params, version: str, payload: dict[str, Any], error: SubsonicError | None = None) -> Response:
    envelope = {
        "status": "failed" if error else "ok",
        "version": "1.16.1",
        "type": "resonance",
        "serverVersion": version,
        "openSubsonic": True,
        **({"error": {"code": error.code, "message": error.message}} if error else payload),
    }
    if params.get("f").lower() in {"json", "jsonp"}:
        return JSONResponse({"subsonic-response": envelope})
    root = ET.Element("subsonic-response", xmlns="http://subsonic.org/restapi")
    _xml(root, envelope)
    return Response(ET.tostring(root, encoding="utf-8", xml_declaration=True), media_type="application/xml")


def _known(values: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in values.items() if value is not None}


async def songs(db: AsyncSession, user: User, tracks: Sequence[Track]) -> list[dict[str, Any]]:
    if not tracks:
        return []
    ids = [track.id for track in tracks]
    likes = dict(
        (
            await db.execute(
                select(TrackLike.track_id, TrackLike.created_at).where(
                    TrackLike.user_id == user.id, TrackLike.track_id.in_(ids)
                )
            )
        ).all()
    )
    plays = {
        track_id: (count, last)
        for track_id, count, last in await db.execute(
            select(PlayEvent.track_id, func.count(), func.max(PlayEvent.played_at))
            .where(PlayEvent.user_id == user.id, PlayEvent.track_id.in_(ids))
            .group_by(PlayEvent.track_id)
        )
    }
    out = []
    for track in tracks:
        count, last = plays.get(track.id, (0, None))
        path = Path(track.path)
        if path.is_absolute():
            path = (
                path.relative_to(get_settings().music_dir)
                if path.is_relative_to(get_settings().music_dir)
                else Path(path.name)
            )
        gain = _known({"trackGain": track.replaygain_track_gain, "albumGain": track.replaygain_album_gain})
        out.append(
            _known(
                {
                    "id": str(track.id),
                    "parent": str(track.album_id),
                    "isDir": False,
                    "title": track.title,
                    "album": track.album.title,
                    "artist": track.artist_credit,
                    "track": track.track_no,
                    "discNumber": track.disc_no,
                    "year": track.year,
                    "genre": track.genre,
                    "coverArt": str(track.album_id),
                    "size": track.size,
                    "contentType": transcode.media_type(path),
                    "suffix": path.suffix.lstrip("."),
                    "duration": int(track.duration),
                    "bitRate": track.bitrate,
                    "samplingRate": track.sample_rate,
                    "path": str(path),
                    "albumId": str(track.album_id),
                    "artistId": str(track.artist_id),
                    "type": "music",
                    "mediaType": "song",
                    "isrc": [track.isrc] if track.isrc else None,
                    "starred": likes[track.id].isoformat() if track.id in likes else None,
                    "played": last.isoformat() if last else None,
                    "playCount": count,
                    "replayGain": gain or None,
                }
            )
        )
    return out


async def albums(db: AsyncSession, user: User, rows: Sequence[Album]) -> list[dict[str, Any]]:
    if not rows:
        return []
    ids = [album.id for album in rows]
    stats = {
        album_id: (count, duration or 0)
        for album_id, count, duration in await db.execute(
            select(Track.album_id, func.count(), func.sum(Track.duration))
            .where(Track.album_id.in_(ids))
            .group_by(Track.album_id)
        )
    }
    saved = dict(
        (
            await db.execute(
                select(SavedAlbum.album_id, SavedAlbum.created_at).where(
                    SavedAlbum.user_id == user.id, SavedAlbum.album_id.in_(ids)
                )
            )
        ).all()
    )
    plays = dict(
        (
            await db.execute(
                select(Track.album_id, func.count(PlayEvent.id))
                .join(PlayEvent, PlayEvent.track_id == Track.id)
                .where(PlayEvent.user_id == user.id, Track.album_id.in_(ids))
                .group_by(Track.album_id)
            )
        ).all()
    )
    return [
        _known(
            {
                "id": str(album.id),
                "name": album.title,
                "artist": album.artist.name,
                "artistId": str(album.artist_id),
                "coverArt": str(album.id),
                "songCount": stats.get(album.id, (0, 0))[0],
                "duration": int(stats.get(album.id, (0, 0))[1]),
                "created": album.created_at.isoformat(),
                "year": album.year,
                "genre": album.genre,
                "starred": saved[album.id].isoformat() if album.id in saved else None,
                "playCount": plays.get(album.id, 0),
            }
        )
        for album in rows
    ]


async def artists(db: AsyncSession, rows: Sequence[Artist]) -> list[dict[str, Any]]:
    if not rows:
        return []
    ids = [artist.id for artist in rows]
    counts = dict(
        (
            await db.execute(
                select(Album.artist_id, func.count()).where(Album.artist_id.in_(ids)).group_by(Album.artist_id)
            )
        ).all()
    )
    covers: dict[uuid.UUID, uuid.UUID] = {}
    for artist_id, album_id in await db.execute(
        select(Album.artist_id, Album.id).where(Album.artist_id.in_(ids)).order_by(Album.created_at, Album.id)
    ):
        covers.setdefault(artist_id, album_id)
    return [
        _known(
            {
                "id": str(artist.id),
                "name": artist.name,
                "coverArt": str(covers[artist.id]) if artist.id in covers else None,
                "albumCount": counts.get(artist.id, 0),
            }
        )
        for artist in rows
    ]


async def playlists(db: AsyncSession, user: User, rows: Sequence[Playlist]) -> list[dict[str, Any]]:
    if not rows:
        return []
    views = await playlists_out(db, rows, user.id)
    owners = dict(
        (await db.execute(select(User.id, User.username).where(User.id.in_({row.owner_id for row in rows})))).all()
    )
    first_albums: dict[uuid.UUID, uuid.UUID] = {}
    for playlist_id, album_id in await db.execute(
        select(PlaylistEntry.playlist_id, Track.album_id)
        .join(Track, Track.id == PlaylistEntry.track_id)
        .where(PlaylistEntry.playlist_id.in_([row.id for row in rows]))
        .order_by(PlaylistEntry.position, PlaylistEntry.id)
    ):
        first_albums.setdefault(playlist_id, album_id)
    return [
        _known(
            {
                "id": str(row.id),
                "name": row.name,
                "comment": row.description,
                "owner": owners[row.owner_id],
                "public": row.is_public,
                "songCount": view.track_count,
                "duration": int(view.duration),
                "created": row.created_at.isoformat(),
                "changed": row.updated_at.isoformat(),
                "coverArt": str(first_albums[row.id]) if row.id in first_albums else None,
            }
        )
        for row, view in zip(rows, views, strict=True)
    ]
