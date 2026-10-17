import asyncio
import logging
import re
import uuid
from datetime import UTC, datetime, timedelta

import httpx
from fastapi import HTTPException
from rapidfuzz import fuzz
from sqlalchemy import delete, func, select, update
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import (
    PlaylistEntry,
    SpotifyAccount,
    SpotifyPending,
    SpotifySync,
    SpotifyTrackMap,
    Track,
    User,
)
from app.services import spotify
from app.services.downloads import create_request, create_search_request
from app.services.sources.youtube import norm

log = logging.getLogger(__name__)
_running: set[uuid.UUID] = set()
_tasks: set[asyncio.Task] = set()
_loop_task: asyncio.Task | None = None


async def spotify_uri(db: AsyncSession, account: SpotifyAccount, client: httpx.AsyncClient, track: Track) -> str | None:
    now = datetime.now(UTC)
    cached = await db.get(SpotifyTrackMap, track.id)
    if cached is not None and (cached.spotify_uri is not None or cached.checked_at > now - timedelta(days=7)):
        return cached.spotify_uri

    async def search(query: str) -> list[dict]:
        result = await spotify._get(db, account, client, "search", q=query, type="track", limit=10)
        return result["tracks"]["items"]

    def duration_diff(candidate: dict) -> float | None:
        duration = candidate.get("duration_ms")
        if track.duration is None or duration is None:
            return None
        return abs(track.duration - duration / 1000)

    uri = None
    if track.isrc:
        for candidate in await search(f"isrc:{track.isrc}"):
            diff = duration_diff(candidate)
            if diff is None or diff <= 10:
                uri = candidate.get("uri")
                break
    if uri is None:
        artist = re.split(
            r", | & | feat\. | ft\. | featuring | x ", track.artist_credit, maxsplit=1, flags=re.IGNORECASE
        )[0]
        title_query, artist_query = track.title.replace('"', ""), artist.replace('"', "")
        best = None
        for candidate in await search(f'track:"{title_query}" artist:"{artist_query}"'):
            title_ratio = fuzz.token_set_ratio(norm(track.title), norm(candidate["name"]))
            artist_ratio = max(
                (fuzz.token_set_ratio(norm(artist), norm(a["name"])) for a in candidate.get("artists", [])), default=0
            )
            diff = duration_diff(candidate)
            if title_ratio < 85 or artist_ratio < 70 or (diff is not None and diff > 10):
                continue
            score = (title_ratio + artist_ratio, -(diff if diff is not None else 0))
            if best is None or score > best:
                best = score
                uri = candidate.get("uri")
    values = {"track_id": track.id, "spotify_uri": uri, "checked_at": now}
    await db.execute(
        insert(SpotifyTrackMap).values(**values).on_conflict_do_update(index_elements=["track_id"], set_=values)
    )
    if cached is not None:
        db.expire(cached)
    return uri


async def _sync(db: AsyncSession, client: httpx.AsyncClient, sync: SpotifySync, *, pull: bool) -> None:
    account = await db.get(SpotifyAccount, sync.user_id)
    if account is None:
        raise spotify.SpotifyError(409, "Kein Spotify-Konto verbunden")
    path = f"playlists/{sync.spotify_playlist_id}/items"
    try:
        tracks = await spotify._fetch_tracks(db, account, client, path, "item", 100)
    except spotify.SpotifyError as e:
        if e.status == 404:
            raise spotify.SpotifyError(404, "Spotify-Playlist nicht gefunden – Verknüpfung bitte neu anlegen") from e
        raise
    tracks = [track for track in tracks if track.uri and not track.uri.startswith("spotify:local:")]
    spotify_set = {track.uri for track in tracks}
    spotify_before_removals = spotify_set.copy()
    spotify_prev = set(sync.prev_spotify)
    entries = list(
        await db.scalars(
            select(PlaylistEntry).where(PlaylistEntry.playlist_id == sync.playlist_id).order_by(PlaylistEntry.position)
        )
    )
    resonance_now = list(dict.fromkeys(entry.track_id for entry in entries))
    resonance_set = {str(track_id) for track_id in resonance_now}
    resonance_prev = set(sync.prev_tracks)

    async def write(method: str, uris: list[str]) -> None:
        for start in range(0, len(uris), 100):
            chunk = uris[start : start + 100]
            body = {"uris": chunk} if method == "POST" else {"items": [{"uri": uri} for uri in chunk]}
            try:
                await spotify._send(db, account, client, method, path, body)
            except spotify.SpotifyError as e:
                if e.status == 403:
                    raise spotify.SpotifyError(
                        403, "Spotify-Schreibrechte fehlen – bitte Spotify in den Einstellungen neu verbinden"
                    ) from e
                if e.status == 404:
                    raise spotify.SpotifyError(
                        404, "Spotify-Playlist nicht gefunden – Verknüpfung bitte neu anlegen"
                    ) from e
                raise

    if pull:
        removed_ids = [uuid.UUID(track_id) for track_id in resonance_prev - resonance_set]
        removed_uris = set(
            await db.scalars(
                select(SpotifyTrackMap.spotify_uri).where(
                    SpotifyTrackMap.track_id.in_(removed_ids),
                    SpotifyTrackMap.spotify_uri.in_(spotify_set & spotify_prev),
                )
            )
        )
        await write("DELETE", sorted(removed_uris))
        spotify_set.difference_update(removed_uris)

        removed_tracks = set(
            await db.scalars(
                select(SpotifyTrackMap.track_id).where(
                    SpotifyTrackMap.spotify_uri.in_(spotify_prev - spotify_before_removals),
                    SpotifyTrackMap.track_id.in_([uuid.UUID(track_id) for track_id in resonance_prev]),
                )
            )
        )
        await db.execute(
            delete(PlaylistEntry).where(
                PlaylistEntry.playlist_id == sync.playlist_id, PlaylistEntry.track_id.in_(removed_tracks)
            )
        )
        resonance_set.difference_update(str(track_id) for track_id in removed_tracks)

        last = await db.scalar(
            select(func.max(PlaylistEntry.position)).where(PlaylistEntry.playlist_id == sync.playlist_id)
        )
        position = last + 1 if last is not None else 0
        user = await db.get(User, sync.user_id)
        request_more = True
        for track in tracks:
            if track.uri not in spotify_set - spotify_prev:
                continue
            track_id = (await spotify.match(db, [track]))[0]
            if track_id is not None:
                if str(track_id) not in resonance_set:
                    db.add(PlaylistEntry(playlist_id=sync.playlist_id, track_id=track_id, position=position))
                    position += 1
                    resonance_set.add(str(track_id))
                continue
            if not request_more:
                continue
            duplicate = await db.scalar(
                select(SpotifyPending.id).where(
                    SpotifyPending.playlist_id == sync.playlist_id,
                    SpotifyPending.isrc == track.isrc
                    if track.isrc
                    else (SpotifyPending.title == track.title) & (SpotifyPending.artist == track.artist),
                )
            )
            if duplicate is not None:
                continue
            deezer_id = await spotify._deezer_id(track)
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
            else:
                db.add(
                    SpotifyPending(
                        user_id=user.id,
                        isrc=track.isrc,
                        deezer_id=deezer_id,
                        download_item_id=request.items[0].id if deezer_id is None else None,
                        title=track.title,
                        artist=track.artist,
                        duration=track.duration,
                        like=False,
                        playlist_id=sync.playlist_id,
                        position=position,
                    )
                )
                position += 1

    new_tracks = [track_id for track_id in resonance_now if str(track_id) not in resonance_prev]
    unmatched = []
    additions = []
    collected = set(spotify_set)
    for track_id in new_tracks:
        track = await db.get(Track, track_id)
        uri = await spotify_uri(db, account, client, track)
        if uri is None:
            if len(unmatched) < 500:
                unmatched.append({"title": track.title, "artist": track.artist_credit})
        elif uri not in collected:
            additions.append(uri)
            collected.add(uri)
    await write("POST", additions)
    spotify_set.update(additions)
    if not new_tracks:
        rows = await db.scalars(
            select(Track)
            .join(SpotifyTrackMap)
            .where(Track.id.in_(resonance_now), SpotifyTrackMap.spotify_uri.is_(None))
        )
        missing = {track.id: track for track in rows}
        unmatched = [
            {"title": missing[id].title, "artist": missing[id].artist_credit} for id in resonance_now if id in missing
        ][:500]
    sync.unmatched = unmatched
    sync.prev_spotify = sorted(spotify_set)
    sync.prev_tracks = sorted(resonance_set)
    sync.status = "idle"
    sync.error = None
    sync.last_synced_at = datetime.now(UTC)


async def run_sync(sync_id: uuid.UUID, *, pull: bool) -> None:
    if sync_id in _running:
        return
    _running.add(sync_id)
    try:
        async with SessionLocal() as db, spotify._client_factory() as client:
            sync = await db.get(SpotifySync, sync_id)
            if sync is None:
                return
            sync.status = "running"
            sync.error = None
            await db.commit()
            # Existing token/download helpers commit; savepoints keep all progress in this outer transaction.
            async with (
                db.begin(),
                AsyncSession(
                    bind=await db.connection(), join_transaction_mode="create_savepoint", expire_on_commit=False
                ) as progress,
            ):
                sync = await progress.get(SpotifySync, sync_id)
                if sync is not None:
                    await _sync(progress, client, sync, pull=pull)
                    await progress.commit()
    except (Exception, asyncio.CancelledError) as e:
        if not isinstance(e, (spotify.SpotifyError, asyncio.CancelledError)):
            log.exception("Spotify sync failed for %s", sync_id)
        async with SessionLocal() as db:
            sync = await db.get(SpotifySync, sync_id)
            if sync is not None:
                sync.status = "failed"
                sync.error = e.message if isinstance(e, spotify.SpotifyError) else "Abgleich fehlgeschlagen"
                await db.commit()
        if isinstance(e, asyncio.CancelledError):
            raise
    finally:
        _running.discard(sync_id)


def launch_sync(sync_id: uuid.UUID, *, pull: bool) -> None:
    task = asyncio.create_task(run_sync(sync_id, pull=pull))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)


async def _sync_loop() -> None:
    while True:
        await asyncio.sleep(600)
        try:
            async with SessionLocal() as db:
                ids = list(
                    await db.scalars(
                        select(SpotifySync.id).where(SpotifySync.two_way.is_(True), SpotifySync.status != "running")
                    )
                )
            for sync_id in ids:
                await run_sync(sync_id, pull=True)
        except Exception:
            log.exception("Spotify sync loop failed")


async def start() -> None:
    global _loop_task
    async with SessionLocal() as db:
        await db.execute(
            update(SpotifySync)
            .where(SpotifySync.status == "running")
            .values(status="failed", error="Durch Neustart abgebrochen")
        )
        await db.commit()
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_sync_loop())


async def stop() -> None:
    global _loop_task
    tasks = [*_tasks, *([_loop_task] if _loop_task is not None else [])]
    for task in tasks:
        task.cancel()
    await asyncio.gather(*tasks, return_exceptions=True)
    _tasks.clear()
    _loop_task = None
