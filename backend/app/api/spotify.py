import html
import secrets
import time
import uuid
from datetime import UTC, datetime, timedelta
from urllib.parse import urlencode

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import HTMLResponse
from pydantic import BaseModel, ConfigDict, Field
from sqlalchemy import select

from app.deps import DB, CurrentUser
from app.models import SpotifyAccount, SpotifyImport, SpotifyPlaylistLink, User
from app.services import spotify
from app.services.server_config import load_config

router = APIRouter(prefix="/api/spotify", tags=["spotify"])


class SpotifyImportIn(BaseModel):
    liked: bool = False
    playlist_ids: list[str] = Field(default=[], max_length=200)
    links: list[str] = Field(default=[], max_length=50)
    download_missing: bool = False


class SpotifyImportOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    user_id: uuid.UUID
    status: str
    liked: bool
    playlist_ids: list[str]
    links: list[str]
    download_missing: bool
    total: int
    matched: int
    missing: int
    requested: int
    message: str | None
    missing_tracks: list[dict]
    created_at: datetime
    finished_at: datetime | None


async def _account(db: DB, user_id: uuid.UUID) -> SpotifyAccount:
    account = await db.get(SpotifyAccount, user_id)
    if account is None:
        raise HTTPException(409, "Kein Spotify-Konto verbunden")
    return account


@router.get("/status")
async def status(user: CurrentUser, db: DB) -> dict:
    cfg = (await load_config(db)).spotify
    account = await db.get(SpotifyAccount, user.id)
    return {
        "configured": bool(cfg.client_id and cfg.client_secret),
        "connected": account is not None,
        "display_name": account.display_name if account else None,
    }


@router.get("/login")
async def login(request: Request, user: CurrentUser, db: DB) -> dict:
    cfg = (await load_config(db)).spotify
    if not cfg.client_id or not cfg.client_secret:
        raise HTTPException(409, "Spotify ist auf diesem Server nicht eingerichtet")
    now = time.monotonic()
    for state, (_, created) in list(spotify._states.items()):
        if now - created >= 600:
            del spotify._states[state]
    state = secrets.token_urlsafe(24)
    spotify._states[state] = (user.id, now)
    return {
        "url": "https://accounts.spotify.com/authorize?"
        + urlencode(
            {
                "response_type": "code",
                "client_id": cfg.client_id,
                "scope": "playlist-read-private playlist-read-collaborative user-library-read",
                "redirect_uri": spotify.redirect_uri(request),
                "state": state,
            }
        )
    }


@router.get("/callback", name="spotify_callback", response_class=HTMLResponse)
async def callback(db: DB, request: Request, code: str = "", state: str = "", error: str = "") -> HTMLResponse:
    try:
        stored = spotify._states.pop(state, None)
        if stored is None or time.monotonic() - stored[1] >= 600:
            raise spotify.SpotifyError(400, "Ungültiger oder abgelaufener Status")
        if error:
            raise spotify.SpotifyError(400, error)
        if not code:
            raise spotify.SpotifyError(400, "Autorisierungscode fehlt")
        cfg = (await load_config(db)).spotify
        tokens = await spotify.exchange_code(cfg, code, spotify.redirect_uri(request))
        async with spotify._client_factory() as client:
            account = SpotifyAccount(
                user_id=stored[0],
                spotify_user_id="",
                access_token=tokens["access_token"],
                refresh_token=tokens["refresh_token"],
                expires_at=datetime.now(UTC) + timedelta(seconds=tokens["expires_in"] - 60),
            )
            profile = await spotify._get(db, account, client, "me")
            account.spotify_user_id = profile["id"]
            account.display_name = profile.get("display_name")
            await db.merge(account)
            await db.commit()
        message = "Spotify ist verbunden. Du kannst dieses Fenster schließen und zu Resonance zurückkehren."
        status_code = 200
    except spotify.SpotifyError as e:
        message = f"Verbindung fehlgeschlagen: {e.message}"
        status_code = e.status
    except (KeyError, ValueError, TypeError):
        message = "Verbindung fehlgeschlagen: Spotify nicht erreichbar"
        status_code = 502
    return HTMLResponse(
        '<!doctype html><html lang="de"><meta charset="utf-8"><title>Spotify</title>'
        '<body style="background:#121212;color:#fff;font-family:sans-serif;padding:2rem">'
        f"<p>{html.escape(message)}</p></body></html>",
        status_code=status_code,
    )


@router.delete("/login", status_code=204)
async def logout(user: CurrentUser, db: DB) -> None:
    account = await db.get(SpotifyAccount, user.id)
    if account is not None:
        await db.delete(account)
        await db.commit()


@router.get("/playlists")
async def playlists(user: CurrentUser, db: DB) -> dict:
    account = await _account(db, user.id)
    try:
        async with spotify._client_factory() as client:
            items = await spotify._fetch_playlists(db, account, client)
            liked = await spotify._get(db, account, client, "me/tracks", limit=1)
    except spotify.SpotifyError as e:
        raise HTTPException(e.status, e.message) from e
    imported = set(
        await db.scalars(select(SpotifyPlaylistLink.spotify_playlist_id).where(SpotifyPlaylistLink.user_id == user.id))
    )
    return {
        "liked_count": liked["total"],
        "playlists": [{**item, "imported": item["id"] in imported} for item in items],
    }


@router.post("/imports", response_model=SpotifyImportOut, status_code=202)
async def create_import(body: SpotifyImportIn, user: CurrentUser, db: DB) -> SpotifyImportOut:
    if not body.liked and not body.playlist_ids and not body.links:
        raise HTTPException(422, "Nichts ausgewählt")
    links: list[str] = []
    for link in body.links:
        id = spotify.playlist_id_from_link(link)
        if id is None:
            raise HTTPException(422, f"Ungültiger Spotify-Link: {link}")
        if id not in links:
            links.append(id)
    if body.liked or body.playlist_ids:
        await _account(db, user.id)
    await db.scalar(select(User).where(User.id == user.id).with_for_update())
    active = await db.scalar(
        select(SpotifyImport.id).where(
            SpotifyImport.user_id == user.id, SpotifyImport.status.in_(["queued", "running"])
        )
    )
    if active is not None:
        raise HTTPException(409, "Es läuft bereits ein Import")
    batch = SpotifyImport(user_id=user.id, status="queued", links=links, **body.model_dump(exclude={"links"}))
    db.add(batch)
    await db.commit()
    result = SpotifyImportOut.model_validate(batch)
    spotify.launch_import(batch.id)
    return result


@router.get("/imports")
async def imports(user: CurrentUser, db: DB) -> list[dict]:
    batches = await db.scalars(
        select(SpotifyImport)
        .where(SpotifyImport.user_id == user.id)
        .order_by(SpotifyImport.created_at.desc())
        .limit(20)
    )
    return [SpotifyImportOut.model_validate(batch).model_dump(exclude={"missing_tracks"}) for batch in batches]


@router.get("/imports/{id}", response_model=SpotifyImportOut)
async def import_detail(id: uuid.UUID, user: CurrentUser, db: DB) -> SpotifyImportOut:
    batch = await db.get(SpotifyImport, id)
    if batch is None or batch.user_id != user.id:
        raise HTTPException(404, "Import nicht gefunden")
    return SpotifyImportOut.model_validate(batch)
