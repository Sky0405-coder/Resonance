"""Bandcamp's free streams (128 kbit/s MP3) for songs that are on neither YouTube nor SoundCloud, often from small
labels that sell on Bandcamp only."""

import asyncio
import logging
import re
from urllib.parse import urlsplit

import httpx
import yt_dlp

from app.services.musicbrainz import TrackMeta
from app.services.sources.base import Candidate
from app.services.sources.soundcloud import SoundCloudSource
from app.services.sources.youtube import score_candidate

log = logging.getLogger(__name__)

SEARCH_URL = "https://bandcamp.com/api/bcsearch_public_api/1/autocomplete_elastic"


class _Silent:
    """yt-dlp prints errors even when quiet; a track without a free stream is no error here."""

    def debug(self, message: str) -> None:
        pass

    info = warning = error = debug


def track_url(url: str) -> str | None:
    try:
        parsed = urlsplit(url)
        if (
            parsed.scheme == "https"
            and (parsed.hostname or "").endswith(".bandcamp.com")
            and re.fullmatch(r"/track/[^/]+/?", parsed.path)
        ):
            return url
    except ValueError:
        pass
    return None


def search_texts(meta: TrackMeta) -> list[str]:
    """Bandcamp's search wants the words as they are listed: "(feat. …)" finds nothing, and neither does "The
    Bahama Soul Club" for a band listed as "Bahama Soul Club". Tried in order until one finds the song."""
    title = " ".join(re.sub(r"\([^)]*\)|\[[^]]*\]|\b(?:feat\.|ft\.|featuring)\s.*", "", meta.title).split())
    artist = " ".join(meta.artist.split())
    texts = [f"{artist} {title}", f"{re.sub(r'(?i)^the ', '', artist)} {title}", title]
    return list(dict.fromkeys(texts))


class BandcampSource(SoundCloudSource):
    name = "bandcamp"

    async def _search(self, text: str) -> list[dict]:
        async with httpx.AsyncClient(timeout=15, headers={"User-Agent": "Mozilla/5.0"}) as client:
            response = await client.post(SEARCH_URL, json={
                "search_text": text, "search_filter": "t", "full_page": False, "fan_id": None,
            })
            response.raise_for_status()
            return response.json().get("auto", {}).get("results", [])

    async def find(self, meta: TrackMeta, exclude: frozenset[str] = frozenset()) -> Candidate | None:
        for text in search_texts(meta):
            try:
                results = await self._search(text)
            except Exception:
                log.debug("Bandcamp search failed", exc_info=True)
                return None
            if (candidate := await self._best(meta, results, exclude)) is not None:
                return candidate
        return None

    async def _best(self, meta: TrackMeta, results: list[dict], exclude: frozenset[str]) -> Candidate | None:
        # The search knows no lengths: rank by name first, then look up the length of the best few.
        ranked = sorted(
            (
                (score, url, result["name"], result["band_name"])
                for result in results
                if result.get("type") == "t" and (url := result.get("item_url_path")) and url not in exclude
                and result.get("name") and result.get("band_name")
                and (score := score_candidate(meta, result["name"], [result["band_name"]], None, False)) is not None
            ),
            reverse=True,
        )

        def details(url: str) -> dict | None:
            try:
                with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "logger": _Silent()}) as ydl:
                    return ydl.extract_info(url, download=False)
            except Exception:
                # Tracks without a free stream have no formats.
                log.debug("Bandcamp track unavailable: %s", url, exc_info=True)
                return None

        for _, url, title, artist in ranked[:3]:
            info = await asyncio.to_thread(details, url)
            if info is None:
                continue
            duration = info.get("duration")
            score = score_candidate(meta, title, [artist], duration, False)
            if score is not None:
                return Candidate(self.name, url, title, artist, duration, score)
        return None
