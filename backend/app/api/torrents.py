import httpx
from fastapi import APIRouter, Request

from app.config import get_settings
from app.deps import DB, AdminUser
from app.i18n import language, translate
from app.services.server_config import load_config
from app.services.torrents import TorrentError
from app.services.torrents.qbittorrent import QBittorrent

router = APIRouter(prefix="/api/admin/torrents", tags=["admin"])


@router.get("/status")
async def status(admin: AdminUser, db: DB, request: Request) -> dict[str, dict[str, bool | str]]:
    cfg = await load_config(db)
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.get(
                f"{get_settings().prowlarr_url.rstrip('/')}/api/v1/system/status",
                headers={"X-Api-Key": cfg.downloads.prowlarr_api_key},
            )
            response.raise_for_status()
            version = response.json()["version"]
        prowlarr = {"ok": True, "message": f"Version {version}"}
    except httpx.HTTPStatusError as e:
        prowlarr = {"ok": False, "message": f"Prowlarr-Anfrage fehlgeschlagen (HTTP {e.response.status_code})"}
    except (httpx.HTTPError, ValueError, KeyError, TypeError):
        prowlarr = {"ok": False, "message": "Prowlarr nicht erreichbar oder ungültige Antwort"}
    try:
        async with QBittorrent(cfg) as qb:
            version = await qb.version()
        qbittorrent = {"ok": True, "message": f"Version {version}"}
    except TorrentError as e:
        qbittorrent = {"ok": False, "message": str(e)}
    for result in (prowlarr, qbittorrent):
        result["message"] = translate(result["message"], language(request))
    return {"prowlarr": prowlarr, "qbittorrent": qbittorrent}
