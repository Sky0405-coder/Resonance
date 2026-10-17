import uuid
from datetime import datetime

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, ConfigDict
from sqlalchemy import select

from app.deps import DB, CurrentUser
from app.i18n import language, translate
from app.models import Playlist, SpotifyAccount, SpotifySync
from app.services import spotify, spotify_sync

router = APIRouter(prefix="/api/playlists", tags=["spotify"])


class SpotifySyncIn(BaseModel):
    spotify_playlist_id: str | None
    two_way: bool


class SpotifySyncPatch(BaseModel):
    two_way: bool


class UnmatchedTrack(BaseModel):
    title: str
    artist: str


class SpotifySyncOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    spotify_playlist_id: str
    spotify_url: str | None
    two_way: bool
    status: str
    error: str | None
    last_synced_at: datetime | None
    unmatched: list[UnmatchedTrack]


def _out(sync: SpotifySync, lang: str) -> SpotifySyncOut:
    return SpotifySyncOut.model_validate(sync).model_copy(
        update={"error": translate(sync.error, lang) if sync.error is not None else None}
    )


async def _playlist(db: DB, user: CurrentUser, id: uuid.UUID) -> Playlist:
    playlist = await db.get(Playlist, id)
    if playlist is None or playlist.owner_id != user.id:
        raise HTTPException(404, "Playlist nicht gefunden")
    if playlist.kind != "user":
        raise HTTPException(409, "Diese Playlist kann nicht mit Spotify verknüpft werden")
    return playlist


async def _linked(db: DB, id: uuid.UUID) -> SpotifySync:
    sync = await db.scalar(select(SpotifySync).where(SpotifySync.playlist_id == id))
    if sync is None:
        raise HTTPException(404, "Nicht mit Spotify verknüpft")
    return sync


@router.get("/{id}/spotify", response_model=SpotifySyncOut | None)
async def get_sync(id: uuid.UUID, user: CurrentUser, db: DB, request: Request) -> SpotifySyncOut | None:
    await _playlist(db, user, id)
    sync = await db.scalar(select(SpotifySync).where(SpotifySync.playlist_id == id))
    return _out(sync, language(request)) if sync is not None else None


@router.post("/{id}/spotify", response_model=SpotifySyncOut, status_code=201)
async def create_sync(
    id: uuid.UUID, body: SpotifySyncIn, user: CurrentUser, db: DB, request: Request
) -> SpotifySyncOut:
    playlist = await _playlist(db, user, id)
    await db.refresh(playlist, with_for_update=True)
    account = await db.get(SpotifyAccount, user.id)
    if account is None:
        raise HTTPException(409, "Kein Spotify-Konto verbunden")
    if not {"playlist-modify-private", "playlist-modify-public"}.issubset((account.scope or "").split()):
        raise HTTPException(409, "Spotify-Schreibrechte fehlen – bitte Spotify in den Einstellungen neu verbinden")
    if await db.scalar(select(SpotifySync.id).where(SpotifySync.playlist_id == id)) is not None:
        raise HTTPException(409, "Playlist ist bereits mit Spotify verknüpft")
    try:
        async with spotify._client_factory() as client:
            spotify_id = body.spotify_playlist_id
            if spotify_id is None:
                created = await spotify._send(
                    db,
                    account,
                    client,
                    "POST",
                    "me/playlists",
                    {"name": playlist.name, "public": False, "description": "Aus Resonance exportiert"},
                )
                spotify_id = created["id"]
                url = (created.get("external_urls") or {}).get("spotify")
            else:
                available = await spotify._fetch_playlists(db, account, client)
                if spotify_id not in {item["id"] for item in available}:
                    raise HTTPException(422, "Spotify-Playlist nicht verfügbar")
                url = f"https://open.spotify.com/playlist/{spotify_id}"
    except spotify.SpotifyError as e:
        raise HTTPException(e.status, e.message) from e
    sync = SpotifySync(
        user_id=user.id,
        playlist_id=id,
        spotify_playlist_id=spotify_id,
        spotify_url=url,
        two_way=body.two_way,
        status="running",
    )
    db.add(sync)
    await db.commit()
    result = _out(sync, language(request))
    spotify_sync.launch_sync(sync.id, pull=sync.two_way)
    return result


@router.post("/{id}/spotify/sync", response_model=SpotifySyncOut, status_code=202)
async def sync_now(id: uuid.UUID, user: CurrentUser, db: DB, request: Request) -> SpotifySyncOut:
    await _playlist(db, user, id)
    sync = await _linked(db, id)
    if sync.status == "running":
        return _out(sync, language(request))
    sync.status = "running"
    await db.commit()
    result = _out(sync, language(request))
    spotify_sync.launch_sync(sync.id, pull=sync.two_way)
    return result


@router.patch("/{id}/spotify", response_model=SpotifySyncOut)
async def update_sync(
    id: uuid.UUID, body: SpotifySyncPatch, user: CurrentUser, db: DB, request: Request
) -> SpotifySyncOut:
    await _playlist(db, user, id)
    sync = await _linked(db, id)
    sync.two_way = body.two_way
    await db.commit()
    return _out(sync, language(request))


@router.delete("/{id}/spotify", status_code=204)
async def delete_sync(id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    await _playlist(db, user, id)
    await db.delete(await _linked(db, id))
    await db.commit()
