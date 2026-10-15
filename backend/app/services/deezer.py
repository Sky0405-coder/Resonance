import asyncio
import time
from collections import deque
from typing import Any

import httpx


class DeezerError(Exception):
    pass


class NotFound(DeezerError):
    pass


def artist_string(track: dict) -> str:
    if "contributors" in track:
        names = [c["name"] for c in track["contributors"] if c.get("role") == "Main"]
        if not names:
            return ""
        remaining = names[1:]
        features = ", ".join(remaining[:-1]) + " & " + remaining[-1] if len(remaining) > 1 else "".join(remaining)
        return names[0] + (" feat. " + features if features else "")
    return track.get("artist", {}).get("name", "")


class DeezerClient:
    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None
        self._lock = asyncio.Lock()
        # Start times of the most recent requests (rate limit window).
        self._starts: deque[float] = deque(maxlen=45)
        self._cache: dict[tuple, tuple[float, dict]] = {}

    async def _get(self, path: str, **params: Any) -> dict:
        key = (path, tuple(sorted(params.items())))
        cached = self._cache.get(key)
        if cached and time.monotonic() - cached[0] < 3600:
            return cached[1]
        if self._client is None:
            self._client = httpx.AsyncClient(base_url="https://api.deezer.com/", timeout=15)
        try:
            for attempt in range(4):
                # Deezer allows 50 requests per 5 s: start at most 45 in any 5 s window; requests may overlap.
                async with self._lock:
                    while len(self._starts) >= 45 and time.monotonic() - self._starts[0] < 5:
                        await asyncio.sleep(5 - (time.monotonic() - self._starts[0]))
                    self._starts.append(time.monotonic())
                response = await self._client.get(path, params=params)
                response.raise_for_status()
                data = response.json()
                if "error" in data:
                    error = data["error"]
                    if error.get("code") == 800:
                        raise NotFound(str(error))
                    if error.get("code") == 4 and attempt < 3:
                        await asyncio.sleep(1)
                        continue
                    raise DeezerError(str(error))
                break
        except (httpx.HTTPError, ValueError) as e:
            raise DeezerError(str(e)) from e
        self._cache.pop(key, None)
        self._cache[key] = (time.monotonic(), data)
        if len(self._cache) > 2000:
            del self._cache[next(iter(self._cache))]
        return data

    async def search_tracks(self, q: str, limit: int) -> list[dict]:
        return (await self._get("search/track", q=q, limit=limit)).get("data", [])

    async def search_albums(self, q: str, limit: int) -> list[dict]:
        return (await self._get("search/album", q=q, limit=limit)).get("data", [])

    async def search_artists(self, q: str, limit: int) -> list[dict]:
        return (await self._get("search/artist", q=q, limit=limit)).get("data", [])

    async def track(self, id: str) -> dict:
        return await self._get(f"track/{id}")

    async def track_by_isrc(self, isrc: str) -> dict | None:
        try:
            return await self._get(f"track/isrc:{isrc}")
        except NotFound:
            return None

    async def album(self, id: str) -> dict:
        return await self._get(f"album/{id}")

    async def album_tracks(self, id: str) -> list[dict]:
        return (await self._get(f"album/{id}/tracks", limit=500)).get("data", [])

    async def artist(self, id: str) -> dict:
        return await self._get(f"artist/{id}")

    async def artist_top(self, id: str, limit: int = 10) -> list[dict]:
        return (await self._get(f"artist/{id}/top", limit=limit)).get("data", [])

    async def artist_radio(self, id: str) -> list[dict]:
        return (await self._get(f"artist/{id}/radio", limit=50)).get("data", [])

    async def artist_related(self, id: str, limit: int = 10) -> list[dict]:
        return (await self._get(f"artist/{id}/related", limit=limit)).get("data", [])

    async def artist_albums(self, id: str) -> list[dict]:
        return (await self._get(f"artist/{id}/albums", limit=100)).get("data", [])


deezer = DeezerClient()
