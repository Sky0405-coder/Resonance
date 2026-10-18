import httpx

from app.config import get_settings
from app.services.server_config import ServerConfig
from app.services.torrents import TorrentError


async def search(cfg: ServerConfig, query: str, categories: list[int] = [3000]) -> list[dict]:
    try:
        async with httpx.AsyncClient(timeout=60) as client:
            response = await client.get(
                f"{get_settings().prowlarr_url.rstrip('/')}/api/v1/search",
                params=[("query", query), *(("categories", category) for category in categories), ("type", "search")],
                headers={"X-Api-Key": cfg.downloads.prowlarr_api_key},
            )
            response.raise_for_status()
            results = response.json()
            if not isinstance(results, list):
                raise TypeError()
            return results
    except httpx.HTTPStatusError as e:
        raise TorrentError(f"Prowlarr-Anfrage fehlgeschlagen (HTTP {e.response.status_code})") from e
    except (httpx.HTTPError, ValueError, TypeError) as e:
        raise TorrentError("Prowlarr nicht erreichbar oder ungültige Antwort") from e
