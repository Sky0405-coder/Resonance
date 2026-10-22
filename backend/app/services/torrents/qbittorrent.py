import base64
import hashlib
import re
from typing import Any, Self
from urllib.parse import parse_qs, urlsplit

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
        try:
            await self._request("POST", "/api/v2/torrents/add", files=fields)
        except TorrentError as e:
            # 409: the torrent is already in qBittorrent (an earlier attempt or another request); adopt it.
            if not isinstance(e.__cause__, httpx.HTTPStatusError) or e.__cause__.response.status_code != 409:
                raise
            hash = info_hash(source)
            if hash is None:
                raise
            response = await self._request("GET", "/api/v2/torrents/info", params={"hashes": hash})
            if not response.json():
                raise
            await self._request("POST", "/api/v2/torrents/setCategory", data={"hashes": hash, "category": category})
            await self._request("POST", "/api/v2/torrents/addTags", data={"hashes": hash, "tags": tag})

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


def info_hash(source: str | bytes) -> str | None:
    """BitTorrent v1 info hash (lowercase hex) of a magnet link or .torrent file, None if unknown."""
    if isinstance(source, str):
        if not source.startswith("magnet:"):
            return None
        for value in parse_qs(urlsplit(source).query).get("xt", []):
            match = re.fullmatch(r"urn:btih:([0-9a-fA-F]{40}|[A-Za-z2-7]{32})", value)
            if match:
                digest = match.group(1)
                return digest.lower() if len(digest) == 40 else base64.b32decode(digest.upper()).hex()
        return None
    try:
        if not source.startswith(b"d"):
            return None
        position = 1
        while source[position : position + 1] != b"e":
            key, position = _bdecode_string(source, position)
            start = position
            position = _bskip(source, position)
            if key == b"info":
                return hashlib.sha1(source[start:position]).hexdigest()
    except (IndexError, ValueError):
        return None
    return None


def _bdecode_string(data: bytes, position: int) -> tuple[bytes, int]:
    colon = data.index(b":", position)
    end = colon + 1 + int(data[position:colon])
    if end > len(data):
        raise ValueError("truncated")
    return data[colon + 1 : end], end


def _bskip(data: bytes, position: int) -> int:
    """Position after the bencoded value starting at position."""
    kind = data[position : position + 1]
    if kind == b"i":
        return data.index(b"e", position) + 1
    if kind in {b"l", b"d"}:
        position += 1
        while data[position : position + 1] != b"e":
            position = _bskip(data, position)
        return position + 1
    if kind.isdigit():
        return _bdecode_string(data, position)[1]
    raise ValueError("invalid bencode")
