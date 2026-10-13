import asyncio
import time
from typing import Any

import httpx
from pydantic import BaseModel

from app.config import get_settings
from app.services.matching import name_key

VERSION = "0.1.0"


# MusicBrainz special-purpose artist for compilations.
VARIOUS_ARTISTS_ID = "89ad4ac3-39f7-470e-963a-56509c546377"


class TrackMeta(BaseModel):
    title: str
    artist: str
    artist_mbid: str | None
    album: str
    album_artist: str
    album_artist_mbid: str | None
    track_no: int | None
    track_total: int | None
    disc_no: int | None
    disc_total: int | None
    year: int | None
    date: str | None
    duration: float | None
    isrc: str | None
    genre: str | None
    label: str | None
    mb_recording_id: str | None
    mb_release_id: str | None
    mb_release_group_id: str | None
    cover_url: str | None = None
    deezer_track_id: str | None = None
    deezer_album_id: str | None = None


class MusicBrainzError(Exception):
    pass


class NotFound(MusicBrainzError):
    pass


def _credit(data: dict) -> tuple[str, str | None]:
    credits = data.get("artist-credit", [])
    name = "".join(
        c if isinstance(c, str) else c.get("name", c.get("artist", {}).get("name", "")) + c.get("joinphrase", "")
        for c in credits
    )
    first = next((c.get("artist", {}).get("id") for c in credits if isinstance(c, dict)), None)
    return name, first


def _year(date: str | None) -> int | None:
    return int(date[:4]) if date and date[:4].isdigit() else None


def _choose(releases: list[dict], recording: bool = False, prefer_album: str | None = None) -> dict:
    if not releases:
        raise NotFound("Keine Veröffentlichung gefunden")

    def key(r: dict) -> tuple:
        rg = r.get("release-group", {})
        media = r.get("media", [])
        format_rank = {"Digital Media": 0, "CD": 1}.get(media[0].get("format") if media else None, 2)
        ranks = (int(r["status"] != "Official") if "status" in r else 1,)
        if recording:
            ranks += (
                int(bool(rg.get("secondary-types"))),
                {"Album": 0, "EP": 1, "Single": 2}.get(rg.get("primary-type"), 3),
            )
        if prefer_album is not None:
            ranks = (int(name_key(r.get("title", "")) != name_key(prefer_album)), *ranks)
        return (*ranks, format_rank, r.get("date") or "9999", r["id"])

    return min(releases, key=key)


class MusicBrainzClient:
    def __init__(self) -> None:
        self._client: httpx.AsyncClient | None = None
        self._lock = asyncio.Lock()
        self._last_started = 0.0
        self._cache: dict[tuple, tuple[float, dict]] = {}

    async def _get(self, path: str, **params: Any) -> dict:
        params["fmt"] = "json"
        key = (path, tuple(sorted(params.items())))
        cached = self._cache.get(key)
        if cached and time.monotonic() - cached[0] < 3600:
            return cached[1]
        async with self._lock:
            cached = self._cache.get(key)
            if cached and time.monotonic() - cached[0] < 3600:
                return cached[1]
            if self._client is None:
                contact = get_settings().musicbrainz_contact
                ua = f"Resonance/{VERSION} ( {contact} )" if contact else f"Resonance/{VERSION}"
                self._client = httpx.AsyncClient(
                    base_url="https://musicbrainz.org/ws/2/", timeout=20, headers={"User-Agent": ua}
                )
            try:
                for attempt in range(2):
                    await asyncio.sleep(max(0, 1.1 - (time.monotonic() - self._last_started)))
                    self._last_started = time.monotonic()
                    response = await self._client.get(path, params=params)
                    if response.status_code == 503 and attempt == 0:
                        await asyncio.sleep(2)
                        continue
                    if response.status_code == 404:
                        raise NotFound("Nicht bei MusicBrainz gefunden")
                    response.raise_for_status()
                    data = response.json()
                    break
            except (httpx.HTTPError, ValueError) as e:
                raise MusicBrainzError(str(e)) from e
            self._cache.pop(key, None)
            self._cache[key] = (time.monotonic(), data)
            if len(self._cache) > 2000:
                del self._cache[next(iter(self._cache))]
            return data

    async def release_full(self, release_id: str) -> dict:
        return await self._get(
            f"release/{release_id}", inc="recordings+artist-credits+isrcs+release-groups+labels+genres+media"
        )

    async def track_meta_list(self, release_json: dict) -> list[TrackMeta]:
        release = release_json
        rg = release["release-group"]
        album_artist, album_artist_mbid = _credit(release)
        if album_artist_mbid == VARIOUS_ARTISTS_ID:
            album_artist = "Various Artists"  # credited as "Verschiedene Interpreten", "Multi-interprètes", …
        genres = rg.get("genres", [])
        genre = max(genres, key=lambda g: g.get("count", 0))["name"].title() if genres else None
        label = next((l["label"]["name"] for l in release.get("label-info", []) if l.get("label")), None)
        date = release.get("date")
        media = release.get("media", [])
        out = []
        for medium in media:
            tracks = medium.get("tracks", [])
            for track in tracks:
                recording = track.get("recording", {})
                if recording.get("video"):
                    continue
                # Releases often credit only the main artist on the track; the recording keeps the features.
                credited = max((track, recording), key=lambda d: len(d.get("artist-credit") or []))
                artist, artist_mbid = _credit(credited)
                length = track.get("length", recording.get("length"))
                out.append(
                    TrackMeta(
                        title=track.get("title", recording.get("title", "")),
                        artist=artist or album_artist,
                        artist_mbid=artist_mbid or album_artist_mbid,
                        album=release["title"],
                        album_artist=album_artist,
                        album_artist_mbid=album_artist_mbid,
                        track_no=track.get("position"),
                        track_total=len(tracks),
                        disc_no=medium.get("position"),
                        disc_total=len(media),
                        year=_year(date),
                        date=date,
                        duration=length / 1000 if length is not None else None,
                        isrc=next(iter(recording.get("isrcs", [])), None),
                        genre=genre,
                        label=label,
                        mb_recording_id=recording["id"],
                        mb_release_id=release["id"],
                        mb_release_group_id=rg["id"],
                    )
                )
        return out

    async def recording_basic(self, mbid: str) -> dict:
        recording = await self._get(f"recording/{mbid}", inc="artist-credits+isrcs+genres")
        artist, artist_mbid = _credit(recording)
        genres = recording.get("genres", [])
        length = recording.get("length")
        return {
            "title": recording.get("title", ""),
            "artist": artist,
            "artist_mbid": artist_mbid,
            "isrc": next(iter(recording.get("isrcs", [])), None),
            "genre": max(genres, key=lambda g: g.get("count", 0))["name"].title() if genres else None,
            "length": length / 1000 if length is not None else None,
        }

    async def recording_meta(self, recording_mbid: str, prefer_album: str | None = None) -> TrackMeta:
        recording = await self._get(f"recording/{recording_mbid}", inc="releases+release-groups")
        release = await self.release_full(
            _choose(recording.get("releases", []), recording=True, prefer_album=prefer_album)["id"]
        )
        for meta in await self.track_meta_list(release):
            if meta.mb_recording_id == recording_mbid:
                return meta
        raise NotFound("Keine Aufnahme auf der Veröffentlichung gefunden")

    async def isrc_recordings(self, isrc: str) -> list[dict]:
        try:
            return (await self._get(f"isrc/{isrc}")).get("recordings", [])
        except NotFound:
            return []

    async def release_by_barcode(self, barcode: str, track_count: int) -> str | None:
        data = await self._get("release", query=f"barcode:{barcode}", limit=5)
        for release in data.get("releases", []):
            media = release.get("media", [])
            count = sum(m.get("track-count", 0) for m in media) if media else release.get("track-count")
            if count == track_count:
                return release["id"]
        return None


mb = MusicBrainzClient()
