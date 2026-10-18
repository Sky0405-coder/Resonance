from typing import Any, Self

import httpx

from app.config import get_settings
from app.services.server_config import ServerConfig
from app.services.torrents import TorrentError


class QBittorrent:
    def __init__(self, cfg: ServerConfig) -> None:
        self._cfg = cfg
        self._client = httpx.AsyncClient(base_url=get_settings().qbittorrent_url.rstrip("/"), timeout=60)
        self._logged_in = False

    async def __aenter__(self) -> Self:
        return self

    async def __aexit__(self, *args: object) -> None:
        await self._client.aclose()

    async def _login(self) -> None:
        response = await self._client.post(
            "/api/v2/auth/login",
            data={
                "username": self._cfg.downloads.qbittorrent_username,
                "password": self._cfg.downloads.qbittorrent_password,
            },
        )
        # qBittorrent < 5.1 answers 200 "Ok.", newer versions 204 without body; failures are 200 "Fails." or 401.
        if not (response.status_code == 204 or (response.status_code == 200 and response.text == "Ok.")):
            raise TorrentError("qBittorrent-Anmeldung fehlgeschlagen")
        response.raise_for_status()
        self._logged_in = True

    async def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        try:
            if not self._logged_in:
                await self._login()
            response = await self._client.request(method, path, **kwargs)
            if response.status_code == 403:
                await self._login()
                response = await self._client.request(method, path, **kwargs)
            response.raise_for_status()
            return response
        except httpx.HTTPStatusError as e:
            raise TorrentError(f"qBittorrent-Anfrage fehlgeschlagen (HTTP {e.response.status_code})") from e
        except httpx.HTTPError as e:
            raise TorrentError("qBittorrent nicht erreichbar") from e

    async def add(
        self, source: str | bytes, tag: str, category: str = "resonance", savepath: str = "/data/downloads/torrents"
    ) -> None:
        fields = {
            "savepath": (None, savepath),
            "category": (None, category),
            "tags": (None, tag),
        }
        if isinstance(source, str):
            fields["urls"] = (None, source)
        else:
            fields["torrents"] = ("file.torrent", source)
        await self._request("POST", "/api/v2/torrents/add", files=fields)

    async def info(self, tag: str, category: str = "resonance") -> dict | None:
        response = await self._request("GET", "/api/v2/torrents/info", params={"category": category, "tag": tag})
        try:
            rows = response.json()
            if not isinstance(rows, list):
                raise TypeError()
            return rows[0] if rows else None
        except (ValueError, KeyError, TypeError) as e:
            raise TorrentError("Ungültige qBittorrent-Antwort") from e

    async def all(self, category: str = "resonance") -> list[dict]:
        response = await self._request("GET", "/api/v2/torrents/info", params={"category": category})
        try:
            rows = response.json()
            if not isinstance(rows, list):
                raise TypeError()
            return rows
        except (ValueError, TypeError) as e:
            raise TorrentError("Ungültige qBittorrent-Antwort") from e

    async def create_category(self, name: str, save_path: str) -> None:
        try:
            await self._request(
                "POST", "/api/v2/torrents/createCategory", data={"category": name, "savePath": save_path}
            )
        except TorrentError as e:
            if not isinstance(e.__cause__, httpx.HTTPStatusError) or e.__cause__.response.status_code != 409:
                raise

    async def files(self, hash: str) -> list[dict]:
        response = await self._request("GET", "/api/v2/torrents/files", params={"hash": hash})
        try:
            rows = response.json()
            if not isinstance(rows, list):
                raise TypeError()
            return rows
        except (ValueError, TypeError) as e:
            raise TorrentError("Ungültige qBittorrent-Antwort") from e

    async def delete(self, hash: str, delete_files: bool) -> None:
        await self._request(
            "POST", "/api/v2/torrents/delete", data={"hashes": hash, "deleteFiles": str(delete_files).lower()}
        )

    async def version(self) -> str:
        return (await self._request("GET", "/api/v2/app/version")).text
