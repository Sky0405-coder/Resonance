import asyncio
import json
import logging
import re
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

import httpx
from fastapi import HTTPException, Request
from rapidfuzz import fuzz
from sqlalchemy import delete, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import (
    DownloadItem,
    Playlist,
    PlaylistEntry,
    SpotifyAccount,
    SpotifyImport,
    SpotifyPending,
    SpotifyPlaylistLink,
    SpotifyTrackMap,
    Track,
    TrackLike,
    User,
)
from app.schemas import CatalogTrack
from app.services import matching
from app.services.deezer import deezer
from app.services.downloads import create_request, create_search_request
from app.services.server_config import SpotifyConfig, load_config
from app.services.sources.youtube import norm

log = logging.getLogger(__name__)
_states: dict[str, tuple[uuid.UUID, float]] = {}
_tasks: set[asyncio.Task] = set()
_loop_task: asyncio.Task | None = None


class SpotifyError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


def _client_factory() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=30)


def playlist_id_from_link(link: str) -> str | None:
    if re.fullmatch(r"[A-Za-z0-9]{22}", link):
        return link
    uri = re.fullmatch(r"spotify:playlist:([A-Za-z0-9]{22})", link)
    if uri:
        return uri[1]
    url = re.fullmatch(
        r"(?:https://)?open\.spotify\.com/(?:intl-[a-z]{2}/)?playlist/([A-Za-z0-9]{22})(?:\?[^\s#]*)?", link
    )
    return url[1] if url else None


def redirect_uri(request: Request) -> str:
    return str(request.url_for("spotify_callback"))


async def _token(client: httpx.AsyncClient, cfg: SpotifyConfig, data: dict) -> dict:
    try:
        response = await client.post(
            "https://accounts.spotify.com/api/token", data=data, auth=(cfg.client_id, cfg.client_secret)
        )
    except httpx.HTTPError as e:
        raise SpotifyError(502, "Spotify nicht erreichbar") from e
    if not response.is_success:
        raise SpotifyError(response.status_code, f"Spotify-Fehler (HTTP {response.status_code})")
    try:
        payload = response.json()
        payload["access_token"]
        payload["expires_in"]
        return payload
    except (ValueError, KeyError, TypeError) as e:
        raise SpotifyError(502, "Spotify nicht erreichbar") from e


async def exchange_code(cfg: SpotifyConfig, code: str, redirect_uri: str) -> dict:
    async with _client_factory() as client:
        return await _token(
            client, cfg, {"grant_type": "authorization_code", "code": code, "redirect_uri": redirect_uri}
        )


async def refresh(db: AsyncSession, account: SpotifyAccount) -> None:
    async with _client_factory() as client:
        await _refresh(db, account, client)


async def _refresh(db: AsyncSession, account: SpotifyAccount, client: httpx.AsyncClient) -> None:
    cfg = (await load_config(db)).spotify
    try:
        tokens = await _token(client, cfg, {"grant_type": "refresh_token", "refresh_token": account.refresh_token})
    except SpotifyError as e:
        if e.status in {400, 401}:
            if account in db:
                await db.delete(account)
            await db.commit()
            raise SpotifyError(401, "Spotify-Verbindung abgelaufen – bitte neu verbinden") from e
        raise
    account.access_token = tokens["access_token"]
    if "refresh_token" in tokens:
        account.refresh_token = tokens["refresh_token"]
    if "scope" in tokens:
        account.scope = tokens["scope"]
    account.expires_at = datetime.now(UTC) + timedelta(seconds=tokens["expires_in"] - 60)
    await db.commit()


async def _get(
    db: AsyncSession, account: SpotifyAccount, client: httpx.AsyncClient, path: str, **params: object
) -> dict:
    if account.expires_at <= datetime.now(UTC):
        await _refresh(db, account, client)
    refreshed = False
    retries = 0
    while True:
        try:
            response = await client.get(
                "https://api.spotify.com/v1/" + path,
                params=params,
                headers={"authorization": f"Bearer {account.access_token}"},
            )
        except httpx.HTTPError as e:
            raise SpotifyError(502, "Spotify nicht erreichbar") from e
        if response.status_code == 401 and not refreshed:
            await _refresh(db, account, client)
            refreshed = True
            continue
        if response.status_code == 429:
            if retries >= 5:
                raise SpotifyError(429, "Spotify-Limit erreicht – bitte später erneut versuchen")
            try:
                delay = float(response.headers.get("Retry-After", "5"))
            except ValueError:
                delay = 5
            await asyncio.sleep(max(0, min(delay, 60)))
            retries += 1
            continue
        if not response.is_success:
            raise SpotifyError(response.status_code, f"Spotify-Fehler (HTTP {response.status_code})")
        try:
            return response.json()
        except ValueError as e:
            raise SpotifyError(502, "Spotify nicht erreichbar") from e


async def _send(
    db: AsyncSession, account: SpotifyAccount, client: httpx.AsyncClient, method: str, path: str, json: dict
) -> dict:
    if account.expires_at <= datetime.now(UTC):
        await _refresh(db, account, client)
    refreshed = False
    retries = 0
    while True:
        try:
            response = await client.request(
                method,
                "https://api.spotify.com/v1/" + path,
                json=json,
                headers={"authorization": f"Bearer {account.access_token}"},
            )
        except httpx.HTTPError as e:
            raise SpotifyError(502, "Spotify nicht erreichbar") from e
        if response.status_code == 401 and not refreshed:
            await _refresh(db, account, client)
            refreshed = True
            continue
        if response.status_code == 429:
            if retries >= 5:
                raise SpotifyError(429, "Spotify-Limit erreicht – bitte später erneut versuchen")
            try:
                delay = float(response.headers.get("Retry-After", "5"))
            except ValueError:
                delay = 5
            await asyncio.sleep(max(0, min(delay, 60)))
            retries += 1
            continue
        if not response.is_success:
            raise SpotifyError(response.status_code, f"Spotify-Fehler (HTTP {response.status_code})")
        try:
            return response.json()
        except ValueError as e:
            raise SpotifyError(502, "Spotify nicht erreichbar") from e


async def fetch_playlists(db: AsyncSession, account: SpotifyAccount) -> list[dict]:
    async with _client_factory() as client:
        return await _fetch_playlists(db, account, client)


async def _fetch_playlists(db: AsyncSession, account: SpotifyAccount, client: httpx.AsyncClient) -> list[dict]:
    result = []
    offset = 0
    while True:
        page = await _get(db, account, client, "me/playlists", limit=50, offset=offset)
        for item in page["items"]:
            owner = item.get("owner", {})
            if owner.get("id") != account.spotify_user_id and not item.get("collaborative"):
                continue
            images = item.get("images") or []
            result.append(
                {
                    "id": item["id"],
                    "name": item["name"],
                    "owner": owner.get("display_name") or owner.get("id"),
                    "track_count": (item.get("items") or item.get("tracks") or {}).get("total", 0),
                    "image_url": images[0]["url"] if images else None,
                }
            )
        if not page.get("next"):
            return result
        offset += len(page["items"])


@dataclass
class SpotifyTrack:
    title: str
    artist: str
    album: str | None
    isrc: str | None
    duration: float | None
    added_at: datetime | None
    position: int
    uri: str | None = None


async def fetch_embed_playlist(id: str) -> tuple[dict, list[SpotifyTrack]]:
    try:
        async with _client_factory() as client:
            response = await client.get(
                f"https://open.spotify.com/embed/playlist/{id}",
                headers={
                    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                    "(KHTML, like Gecko) Chrome/140.0 Safari/537.36"
                },
                timeout=20,
                follow_redirects=True,
            )
    except httpx.HTTPError as e:
        raise SpotifyError(502, "Spotify nicht erreichbar") from e
    if response.status_code == 404:
        raise SpotifyError(404, "Playlist nicht gefunden oder privat")
    if not response.is_success:
        raise SpotifyError(502, "Spotify nicht erreichbar")
    script = re.search(
        r"<script\b[^>]*\bid\s*=\s*[\"']__NEXT_DATA__[\"'][^>]*>(.*?)</script\s*>",
        response.text,
        re.IGNORECASE | re.DOTALL,
    )
    try:
        if script is None:
            raise ValueError("Missing playlist JSON")
        entity = json.loads(script[1])["props"]["pageProps"]["state"]["data"]["entity"]
        sources = (entity.get("coverArt") or {}).get("sources") or []
        metadata = {
            "id": id,
            "name": entity["name"],
            "owner": entity.get("subtitle"),
            "image_url": sources[0]["url"] if sources else None,
        }
        tracks = [
            SpotifyTrack(
                title=item["title"],
                artist=item["subtitle"].replace("\u00a0", " "),
                album=None,
                isrc=None,
                duration=item["duration"] / 1000 if item.get("duration") is not None else None,
                added_at=None,
                position=index,
            )
            for index, item in enumerate(entity.get("trackList") or [])
            if item.get("entityType") == "track"
        ]
    except (ValueError, KeyError, TypeError, AttributeError) as e:
        raise SpotifyError(404, "Playlist nicht gefunden oder privat") from e
    return metadata, tracks


async def _fetch_tracks(
    db: AsyncSession, account: SpotifyAccount, client: httpx.AsyncClient, path: str, key: str, limit: int
) -> list[SpotifyTrack]:
    result = []
    offset = 0
    params = {"additional_types": "track"} if key == "item" else {}
    while True:
        try:
            page = await _get(db, account, client, path, limit=limit, offset=offset, **params)
        except SpotifyError as e:
            if e.status == 403 and key == "item":
                raise SpotifyError(403, "Spotify gibt die Songs dieser Playlist nicht frei") from e
            raise
        for index, entry in enumerate(page["items"], offset):
            item = entry.get(key)
            if item is None or item.get("type") != "track" or item.get("is_local"):
                continue
            added_at = entry.get("added_at")
            duration = item.get("duration_ms")
            isrc = (item.get("external_ids") or {}).get("isrc")
            result.append(
                SpotifyTrack(
                    title=item["name"],
                    artist=", ".join(artist["name"] for artist in item.get("artists", [])),
                    album=(item.get("album") or {}).get("name"),
                    isrc=isrc.upper() if isrc else None,
                    duration=duration / 1000 if duration is not None else None,
                    added_at=datetime.fromisoformat(added_at) if added_at else None,
                    position=index,
                    uri=item.get("uri"),
                )
            )
        if not page.get("next"):
            return result
        offset += len(page["items"])


async def fetch_liked(db: AsyncSession, account: SpotifyAccount) -> list[SpotifyTrack]:
    async with _client_factory() as client:
        return await _fetch_tracks(db, account, client, "me/tracks", "track", 50)


async def fetch_playlist_tracks(db: AsyncSession, account: SpotifyAccount, id: str) -> list[SpotifyTrack]:
    async with _client_factory() as client:
        return await _fetch_tracks(db, account, client, f"playlists/{id}/items", "item", 100)


async def match(db: AsyncSession, tracks: list[SpotifyTrack]) -> list[uuid.UUID | None]:
    catalog = [
        CatalogTrack(
            id="",
            title=track.title,
            artist=track.artist,
            duration=track.duration,
            album=track.album,
            isrc=track.isrc,
            artist_id=None,
            album_id=None,
            cover_url=None,
            preview_url=None,
        )
        for track in tracks
    ]
    for start in range(0, len(catalog), 500):
        await matching.match_tracks(db, catalog[start : start + 500])
    ids = [track.library_id for track in catalog if track.library_id]
    rows = await db.execute(select(Track.id, Track.duration, Track.isrc).where(Track.id.in_(ids)))
    library = {id: (duration, isrc) for id, duration, isrc in rows}
    result = []
    for track, source in zip(catalog, tracks, strict=True):
        id = track.library_id
        if id is not None:
            duration, isrc = library[id]
            if (
                not (track.isrc and track.isrc == isrc)
                and track.duration is not None
                and duration is not None
                and abs(track.duration - duration) > 10
            ):
                id = None
        if id is not None and source.uri:
            values = {"track_id": id, "spotify_uri": source.uri, "checked_at": datetime.now(UTC)}
            await db.execute(
                insert(SpotifyTrackMap).values(**values).on_conflict_do_update(index_elements=["track_id"], set_=values)
            )
        result.append(id)
    return result


async def _like(db: AsyncSession, user_id: uuid.UUID, track_id: uuid.UUID, added_at: datetime | None) -> None:
    values = {"user_id": user_id, "track_id": track_id}
    if added_at is not None:
        values["created_at"] = added_at
    await db.execute(insert(TrackLike).values(**values).on_conflict_do_nothing(index_elements=["user_id", "track_id"]))


def _message(batch: SpotifyImport, message: str) -> None:
    batch.message = f"{batch.message}\n{message}" if batch.message else message


async def _deezer_id(track: SpotifyTrack) -> str | None:
    if track.isrc:
        found = await deezer.track_by_isrc(track.isrc)
        if found is not None:
            return str(found["id"])
    results = await deezer.find_tracks(track.artist.split(", ")[0], track.title, 5)
    for result in results:
        if fuzz.token_set_ratio(norm(track.title), norm(result["title"])) < 90:
            continue
        duration = result.get("duration")
        if track.duration is not None and duration is not None and abs(track.duration - duration) > 5:
            continue
        return str(result["id"])
    return None


async def run_import(import_id: uuid.UUID) -> None:
    try:
        async with SessionLocal() as db, _client_factory() as client:
            batch = await db.get(SpotifyImport, import_id)
            if batch is None or batch.status not in {"queued", "running"}:
                return
            batch.status = "running"
            await db.commit()
            account = await db.get(SpotifyAccount, batch.user_id)
            if account is None and (batch.liked or batch.playlist_ids):
                raise SpotifyError(409, "Kein Spotify-Konto verbunden")
            user = await db.get(User, batch.user_id)
            request_more = batch.download_missing

            async def process(tracks: list[SpotifyTrack], source: str, playlist_id: uuid.UUID | None = None) -> None:
                nonlocal request_more
                ids = await match(db, tracks)
                for track, track_id in zip(tracks, ids, strict=True):
                    batch.total += 1
                    if track_id is not None:
                        batch.matched += 1
                        if playlist_id is None:
                            await _like(db, user.id, track_id, track.added_at)
                        else:
                            db.add(
                                PlaylistEntry(
                                    playlist_id=playlist_id, track_id=track_id, position=float(track.position)
                                )
                            )
                    else:
                        batch.missing += 1
                        if len(batch.missing_tracks) < 2000:
                            batch.missing_tracks = [
                                *batch.missing_tracks,
                                {"title": track.title, "artist": track.artist, "source": source},
                            ]
                        if request_more:
                            deezer_id = await _deezer_id(track)
                            try:
                                if deezer_id is not None:
                                    request = await create_request(db, user, "track", deezer_id, temporary=False)
                                else:
                                    request = await create_search_request(
                                        db,
                                        user,
                                        title=track.title,
                                        artist=track.artist,
                                        album=track.album,
                                        duration=track.duration,
                                        temporary=False,
                                    )
                            except HTTPException as e:
                                if e.status_code == 429:
                                    request_more = False
                                    _message(
                                        batch, "Tageslimit erreicht – weitere fehlende Songs wurden nicht angefragt"
                                    )
                            else:
                                batch.requested += 1
                                db.add(
                                    SpotifyPending(
                                        user_id=user.id,
                                        isrc=track.isrc,
                                        deezer_id=deezer_id,
                                        download_item_id=request.items[0].id if deezer_id is None else None,
                                        title=track.title,
                                        artist=track.artist,
                                        duration=track.duration,
                                        like=playlist_id is None,
                                        like_at=track.added_at if playlist_id is None else None,
                                        playlist_id=playlist_id,
                                        position=float(track.position) if playlist_id is not None else None,
                                    )
                                )
                    if batch.total % 200 == 0:
                        await db.commit()
                await db.commit()

            async def import_playlist(id: str, name: str, tracks: list[SpotifyTrack]) -> None:
                link = await db.scalar(
                    select(SpotifyPlaylistLink).where(
                        SpotifyPlaylistLink.user_id == user.id, SpotifyPlaylistLink.spotify_playlist_id == id
                    )
                )
                if link is None:
                    playlist = Playlist(
                        owner_id=user.id, name=name, description="Von Spotify importiert", is_public=False
                    )
                    db.add(playlist)
                    await db.flush()
                    db.add(SpotifyPlaylistLink(user_id=user.id, spotify_playlist_id=id, playlist_id=playlist.id))
                else:
                    playlist = await db.get(Playlist, link.playlist_id)
                    playlist.name = name
                    await db.execute(delete(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist.id))
                    await db.execute(delete(SpotifyPending).where(SpotifyPending.playlist_id == playlist.id))
                await process(tracks, name, playlist.id)

            if batch.liked:
                await process(await _fetch_tracks(db, account, client, "me/tracks", "track", 50), "Lieblingssongs")
            if batch.playlist_ids:
                playlists = {playlist["id"]: playlist for playlist in await _fetch_playlists(db, account, client)}
                for id in batch.playlist_ids:
                    metadata = playlists.get(id)
                    if metadata is None:
                        _message(batch, f"{id}: Playlist nicht verfügbar")
                        await db.commit()
                        continue
                    try:
                        tracks = await _fetch_tracks(db, account, client, f"playlists/{id}/items", "item", 100)
                    except SpotifyError as e:
                        if e.status != 403:
                            raise
                        _message(batch, f"„{metadata['name']}“: Spotify gibt die Songs dieser Playlist nicht frei")
                        await db.commit()
                        continue
                    await import_playlist(id, metadata["name"], tracks)
            for id in batch.links:
                used_embed = account is None
                if account is not None:
                    try:
                        metadata = await _get(
                            db, account, client, f"playlists/{id}", fields="name,owner(display_name,id)"
                        )
                        tracks = await _fetch_tracks(db, account, client, f"playlists/{id}/items", "item", 100)
                    except SpotifyError as e:
                        if e.status not in {403, 404}:
                            raise
                        used_embed = True
                if used_embed:
                    try:
                        metadata, tracks = await fetch_embed_playlist(id)
                    except SpotifyError as e:
                        _message(batch, f"{id}: {e.message}")
                        continue
                    if len(tracks) == 100:
                        _message(
                            batch,
                            f"„{metadata['name']}“: nur die ersten 100 Songs übernommen "
                            "(ohne verbundenes Spotify-Konto liefert Spotify nicht mehr)",
                        )
                await import_playlist(id, metadata["name"], tracks)
            batch.status = "done"
            batch.finished_at = datetime.now(UTC)
            await db.commit()
    except Exception as e:
        if not isinstance(e, SpotifyError):
            log.exception("Spotify import failed for %s", import_id)
        async with SessionLocal() as db:
            batch = await db.get(SpotifyImport, import_id)
            if batch is not None:
                batch.status = "failed"
                batch.message = e.message if isinstance(e, SpotifyError) else "Import fehlgeschlagen"
                batch.finished_at = datetime.now(UTC)
                await db.commit()


def launch_import(import_id: uuid.UUID) -> None:
    task = asyncio.create_task(run_import(import_id))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def resolve_pending(db: AsyncSession) -> int:
    resolved = 0
    cutoff = datetime.now(UTC) - timedelta(days=30)
    rows = list(await db.scalars(select(SpotifyPending).with_for_update(skip_locked=True)))
    for row in rows:
        if row.created_at < cutoff:
            await db.delete(row)
            continue
        if row.download_item_id is not None:
            track_id = await db.scalar(
                select(DownloadItem.track_id)
                .join(Track, Track.id == DownloadItem.track_id)
                .where(DownloadItem.id == row.download_item_id, Track.is_temporary.is_(False))
            )
        elif row.isrc:
            track_id = await db.scalar(
                select(Track.id).where(Track.isrc == row.isrc, Track.is_temporary.is_(False)).limit(1)
            )
        else:
            track_id = (
                await db.scalar(
                    select(DownloadItem.track_id)
                    .join(Track, Track.id == DownloadItem.track_id)
                    .where(
                        DownloadItem.meta["deezer_track_id"].astext == row.deezer_id,
                        DownloadItem.track_id.is_not(None),
                        Track.is_temporary.is_(False),
                    )
                    .order_by(DownloadItem.updated_at.desc())
                    .limit(1)
                )
                if row.deezer_id
                else None
            )
        if track_id is None:
            continue
        if row.like:
            await _like(db, row.user_id, track_id, row.like_at)
        if row.playlist_id is not None:
            existing = await db.scalar(
                select(PlaylistEntry.id).where(
                    PlaylistEntry.playlist_id == row.playlist_id,
                    PlaylistEntry.track_id == track_id,
                    PlaylistEntry.position == row.position,
                )
            )
            if existing is None:
                db.add(PlaylistEntry(playlist_id=row.playlist_id, track_id=track_id, position=row.position))
        await db.delete(row)
        resolved += 1
    await db.commit()
    return resolved


async def _resolve() -> None:
    try:
        async with SessionLocal() as db:
            await resolve_pending(db)
    except Exception:
        log.exception("Spotify pending resolution failed")


def resolve_after_download() -> None:
    task = asyncio.create_task(_resolve())
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def _resolve_loop() -> None:
    while True:
        await asyncio.sleep(60)
        await _resolve()


async def start() -> None:
    global _loop_task
    async with SessionLocal() as db:
        await db.execute(
            update(SpotifyImport)
            .where(SpotifyImport.status.in_(["queued", "running"]))
            .values(status="failed", message="Durch Neustart abgebrochen", finished_at=datetime.now(UTC))
        )
        await db.commit()
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
