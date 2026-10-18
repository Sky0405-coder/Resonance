from urllib.parse import quote, urljoin

import httpx


class TorrentError(Exception):
    pass


def _magnet_from_hash(chosen: dict) -> str | None:
    info_hash = chosen.get("infoHash")
    if not info_hash:
        return None
    return f"magnet:?xt=urn:btih:{info_hash}&dn={quote(chosen.get('title') or '')}"


async def obtain_source(chosen: dict) -> str | bytes:
    """Magnet link or .torrent bytes of a Prowlarr result.

    Prowlarr puts its own proxy link (http) into magnetUrl or downloadUrl depending on the indexer; the proxy
    answers with the .torrent file or a redirect to the magnet link.
    """
    for field in ("magnetUrl", "guid"):
        value = chosen.get(field) or ""
        if value.startswith("magnet:"):
            return value
    urls = [u for u in (chosen.get("downloadUrl"), chosen.get("magnetUrl")) if u and u.startswith("http")]
    error: TorrentError | None = None
    for url in dict.fromkeys(urls):
        try:
            return await _fetch(url)
        except TorrentError as e:
            error = e
    if magnet := _magnet_from_hash(chosen):
        return magnet
    raise error or TorrentError("Torrent-Downloadadresse fehlt")


async def _fetch(url: str) -> str | bytes:
    try:
        async with httpx.AsyncClient(timeout=60, follow_redirects=False) as client:
            for _ in range(20):
                response = await client.get(url)
                location = response.headers.get("Location", "")
                if location.startswith("magnet:"):
                    return location
                if response.is_redirect and location:
                    url = urljoin(str(response.url), location)
                    continue
                response.raise_for_status()
                if response.status_code != 200:
                    raise TorrentError("Torrent-Download fehlgeschlagen")
                return response.content
            raise TorrentError("Zu viele Torrent-Weiterleitungen")
    except httpx.HTTPError as e:
        raise TorrentError("Torrent-Download fehlgeschlagen") from e
