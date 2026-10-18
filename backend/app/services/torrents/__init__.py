from urllib.parse import urljoin

import httpx


class TorrentError(Exception):
    pass


async def obtain_source(chosen: dict) -> str | bytes:
    source = chosen.get("magnetUrl") or ""
    if not source.startswith("magnet:"):
        url = chosen.get("downloadUrl")
        if not url:
            raise TorrentError("Torrent-Downloadadresse fehlt")
        try:
            async with httpx.AsyncClient(timeout=60, follow_redirects=False) as client:
                for _ in range(20):
                    response = await client.get(url)
                    location = response.headers.get("Location", "")
                    if location.startswith("magnet:"):
                        source = location
                        break
                    if response.is_redirect and location:
                        url = urljoin(str(response.url), location)
                        continue
                    response.raise_for_status()
                    if response.status_code != 200:
                        raise TorrentError("Torrent-Download fehlgeschlagen")
                    source = response.content
                    break
                else:
                    raise TorrentError("Zu viele Torrent-Weiterleitungen")
        except httpx.HTTPError as e:
            raise TorrentError("Torrent-Download fehlgeschlagen") from e
    return source
