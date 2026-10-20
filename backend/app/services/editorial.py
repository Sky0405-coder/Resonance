"""Apple Music's editorial playlists, shared across users."""

import logging
from dataclasses import dataclass, field
from datetime import date, timedelta
from typing import NamedTuple

import httpx

from app.services import apple_music, covers
from app.services.deezer import DeezerError, deezer
from app.services.spotify import SpotifyError, SpotifyTrack


class Editorial(NamedTuple):
    key: str
    name: str
    apple_name: str
    group: str


EDITORIAL: list[Editorial] = [
    Editorial(f"editorial:{decade}s-hits", f"{decade}er Hits", f"{decade}er Hits Essentials", "decades")
    for decade in ("60", "70", "80", "90", "00", "10")
] + [
    Editorial("editorial:80s-hiphop", "80er Hip-Hop Hits", "80er Hip-Hop Essentials", "eras"),
    Editorial("editorial:90s-hiphop", "90er Hip-Hop Hits", "90er Hip-Hop Essentials", "eras"),
    Editorial("editorial:00s-hiphop", "00er Hip-Hop Hits", "00er Hip-Hop Essentials", "eras"),
    Editorial("editorial:90s-deutschrap", "90er Deutschrap", "90er Deutscher Hip-Hop Essentials", "eras"),
    Editorial("editorial:00s-deutschrap", "00er Deutschrap", "00er Deutschrap Essentials", "eras"),
    Editorial("editorial:10s-deutschrap", "10er Deutschrap", "10er Deutschrap Essentials", "eras"),
    Editorial("editorial:80s-rock", "80er Rock Hits", "80er Rock Essentials", "eras"),
    Editorial("editorial:90s-rock", "90er Rock Hits", "90er Rock Essentials", "eras"),
    Editorial("editorial:00s-rock", "00er Rock Hits", "00er Rock Essentials", "eras"),
    Editorial("editorial:80s-club", "80er Club Hits", "80er Club Essentials", "eras"),
    Editorial("editorial:00s-dance", "00er Dance Hits", "00er Dance Party Essentials", "eras"),
    Editorial("editorial:00s-deutschpop", "00er Deutschpop", "'00s Deutschpop Essentials", "eras"),
    Editorial("editorial:10s-deutschpop", "10er Deutschpop", "10er Deutschpop Essentials", "eras"),
] + [
    Editorial(f"editorial:year-{year}", f"Hits {year}", f"Pop-Hits: {year}", "years")
    for year in (1969, 1977, 1985, 1989, 1991, 1994, 1999, 2000, 2004, 2007, 2010, 2014, 2016, 2020)
] + [
    Editorial(f"editorial:year-{year}-hiphop", f"Hip-Hop Hits {year}", f"Hip-Hop/R&B-Hits: {year}", "years")
    for year in (1988, 1994, 1999, 2004)
] + [Editorial("editorial:deutschrap-100", "Deutschrap 100", "Deutschrap 100", "charts")]
BY_KEY = {entry.key: entry for entry in EDITORIAL}
_refs: dict[str, tuple[date, str | None]] = {}
log = logging.getLogger(__name__)


@dataclass
class EditorialPlaylist:
    tracks: list[SpotifyTrack]
    image_url: str | None
    cover_file: str | None = None
    deezer_ids: dict[str, str | None] = field(default_factory=dict)


_cache: dict[str, tuple[date, EditorialPlaylist]] = {}


def refresh_days(entry: Editorial) -> int:
    return 1 if entry.group == "charts" else 7


async def resolve(entry: Editorial) -> str | None:
    today = date.today()
    cached = _refs.get(entry.key)
    if cached is not None and today < cached[0] + timedelta(days=7):
        return cached[1]
    async with apple_music._client_factory() as client:
        response = await apple_music._get(
            client, "/catalog/de/search", term=entry.apple_name, types="playlists", limit=10
        )
    name = entry.apple_name.replace("’", "'").casefold()
    ref = None
    for item in (response.get("results", {}).get("playlists", {}).get("data") or []):
        attributes = item.get("attributes") or {}
        if (
            (attributes.get("name") or "").replace("’", "'").casefold() == name
            and (attributes.get("curatorName") or "").startswith("Apple Music")
        ):
            ref = f"apple:de:{item['id']}"
            break
    if ref is None:
        log.info("Apple Music editorial playlist not found: %s", entry.apple_name)
    _refs[entry.key] = (today, ref)
    return ref


async def playlist_tracks(entry: Editorial) -> EditorialPlaylist | None:
    today = date.today()
    cached = _cache.get(entry.key)
    if cached is not None and today < cached[0] + timedelta(days=refresh_days(entry)):
        return cached[1]
    try:
        ref = await resolve(entry)
        if ref is None:
            return cached[1] if cached is not None else None
        metadata, tracks = await apple_music.fetch_playlist(ref)
    except SpotifyError:
        log.debug("Editorial playlist lookup failed: %s", entry.key, exc_info=True)
        return cached[1] if cached is not None else None
    result = EditorialPlaylist(tracks, metadata.get("image_url"), cached[1].cover_file if cached else None)
    if cached is not None:
        isrcs = {track.isrc for track in tracks if track.isrc}
        result.deezer_ids = {isrc: id for isrc, id in cached[1].deezer_ids.items() if id and isrc in isrcs}
    if result.image_url:
        try:
            async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
                response = await client.get(result.image_url)
                response.raise_for_status()
            result.cover_file = covers.store(response.content) or result.cover_file
        except httpx.HTTPError:
            log.debug("Editorial artwork lookup failed: %s", entry.key, exc_info=True)
    _cache[entry.key] = (today, result)
    return result


async def deezer_id(key: str, isrc: str | None) -> str | None:
    if not isrc:
        return None
    playlist = _cache[key][1]
    if isrc not in playlist.deezer_ids:
        try:
            track = await deezer.track_by_isrc(isrc)
        except DeezerError:
            log.debug("Editorial ISRC lookup failed: %s", isrc, exc_info=True)
            return None
        playlist.deezer_ids[isrc] = str(track["id"]) if track else None
    return playlist.deezer_ids[isrc]
