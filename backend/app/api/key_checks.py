"""Checks the API keys entered in Admin → Server against their services, with the saved values."""

import uuid
from typing import Literal

import httpx
from fastapi import APIRouter, Request

from app.deps import DB, AdminUser
from app.i18n import language, translate
from app.services.server_config import ServerConfig, load_config

router = APIRouter(prefix="/api/admin/keys", tags=["admin"])

Service = Literal["acoustid", "discogs", "lastfm", "fanarttv", "spotify", "discord"]

# Radiohead: a well-known artist every service has.
_ARTIST = "Radiohead"
_ARTIST_MBID = "a74b1b7f-71a5-4011-9441-d0b5e4122711"


def _client_factory() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=20, headers={"User-Agent": "Resonance/1.0"})


def _key(cfg: ServerConfig, service: Service) -> str:
    return {
        "acoustid": cfg.library.acoustid_api_key,
        "discogs": cfg.library.discogs_token,
        "lastfm": cfg.library.lastfm_api_key,
        "fanarttv": cfg.library.fanarttv_api_key,
        "spotify": cfg.spotify.client_id and cfg.spotify.client_secret,
        "discord": cfg.integrations.discord_client_id,
    }[service]


async def _valid(client: httpx.AsyncClient, cfg: ServerConfig, service: Service) -> bool:
    """True for a working key, False for one the service rejects; raises when the service cannot be asked."""
    match service:
        case "acoustid":
            # Any track id: a valid key answers "ok" (with no results), an invalid one error code 4.
            response = await client.get("https://api.acoustid.org/v2/lookup", params={
                "client": cfg.library.acoustid_api_key, "trackid": str(uuid.UUID(int=0)),
            })
            data = response.json()
            if data.get("status") == "ok":
                return True
            if (data.get("error") or {}).get("code") in (4, 5):
                return False
            raise ValueError(data)
        case "discogs":
            response = await client.get(
                "https://api.discogs.com/oauth/identity",
                headers={"Authorization": f"Discogs token={cfg.library.discogs_token}"},
            )
        case "lastfm":
            response = await client.get("https://ws.audioscrobbler.com/2.0/", params={
                "method": "artist.getInfo", "artist": _ARTIST, "api_key": cfg.library.lastfm_api_key, "format": "json",
            })
            if response.status_code < 500 and response.json().get("error") in (10, 26):
                return False
        case "fanarttv":
            response = await client.get(
                f"https://webservice.fanart.tv/v3/music/{_ARTIST_MBID}", params={"api_key": cfg.library.fanarttv_api_key},
            )
        case "spotify":
            response = await client.post(
                "https://accounts.spotify.com/api/token", data={"grant_type": "client_credentials"},
                auth=(cfg.spotify.client_id, cfg.spotify.client_secret),
            )
        case "discord":
            response = await client.get(
                f"https://discord.com/api/v10/applications/{cfg.integrations.discord_client_id}/rpc"
            )
    if response.status_code in (400, 401, 403, 404):
        return False
    response.raise_for_status()
    return True


@router.get("/{service}/check")
async def check(service: Service, admin: AdminUser, db: DB, request: Request) -> dict[str, bool | str]:
    cfg = await load_config(db)
    if not _key(cfg, service):
        result = {"ok": False, "message": "Kein Schlüssel eingetragen"}
    else:
        try:
            async with _client_factory() as client:
                ok = await _valid(client, cfg, service)
            result = {"ok": ok, "message": "Schlüssel gültig" if ok else "Schlüssel ungültig"}
        except (httpx.HTTPError, ValueError, TypeError, AttributeError):
            result = {"ok": False, "message": "Dienst nicht erreichbar"}
    result["message"] = translate(str(result["message"]), language(request))
    return result
