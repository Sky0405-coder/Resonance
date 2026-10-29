"""Public playlists of Deezer, Apple Music and Spotify: search, preview and Deezer playlists for the import."""

import asyncio
import logging
import re

import httpx

from app.services import apple_music, spotify
from app.services.deezer import DeezerError, NotFound, artist_string, deezer
from app.services.server_config import SpotifyConfig
from app.services.spotify import SpotifyError, SpotifyTrack

log = logging.getLogger(__name__)


def deezer_ref_from_link(link: str) -> str | None:
    """`https://www.deezer.com/de/playlist/123` → `deezer:123` (stored like a Spotify playlist id)."""
    url = re.fullmatch(
        r"(?:https://)?(?:www\.)?deezer\.com/(?:[a-z]{2}/)?playlist/([0-9]{1,20})(?:\?[^\s#]*)?", link
    )
    return f"deezer:{url[1]}" if url else None


def ref_from_link(link: str) -> str | None:
    """The import id of a Spotify, Apple Music or Deezer playlist link."""
    return (
        spotify.playlist_id_from_link(link)
        or apple_music.playlist_ref_from_link(link)
        or deezer_ref_from_link(link)
    )


async def fetch_deezer(ref: str) -> tuple[dict, list[SpotifyTrack]]:
    id = ref.removeprefix("deezer:")
    try:
        data = await deezer._get(f"playlist/{id}")
        tracks: list[SpotifyTrack] = []
        while len(tracks) < 10000:
            page = await deezer._get(f"playlist/{id}/tracks", index=len(tracks), limit=100)
            items = page.get("data") or []
            for item in items:
                album = item.get("album") or {}
                tracks.append(
                    SpotifyTrack(
                        title=item["title"],
                        artist=artist_string(item),
                        album=album.get("title"),
                        isrc=item.get("isrc"),
                        duration=float(item["duration"]) if item.get("duration") else None,
                        added_at=None,
                        position=len(tracks),
                        deezer_id=str(item["id"]),
                    )
                )
            if not items or not page.get("next"):
                break
    except NotFound as e:
        raise SpotifyError(404, "Playlist nicht gefunden oder privat") from e
    except (DeezerError, KeyError, TypeError, ValueError) as e:
        raise SpotifyError(502, "Deezer nicht erreichbar") from e
    metadata = {
        "id": ref,
        "name": data.get("title") or id,
        "owner": (data.get("creator") or {}).get("name"),
        "image_url": data.get("picture_xl") or data.get("picture_big"),
    }
    return metadata, tracks


async def fetch(link: str) -> tuple[str, dict, list[SpotifyTrack]]:
    """Name, owner, cover and songs of a playlist link. Foreign Spotify playlists only show their first 100 songs."""
    ref = ref_from_link(link)
    if ref is None:
        raise SpotifyError(422, f"Ungültiger Spotify-Link: {link}")
    if ref.startswith("deezer:"):
        return ref, *await fetch_deezer(ref)
    if ref.startswith("apple:"):
        return ref, *await apple_music.fetch_playlist(ref)
    return ref, *await spotify.fetch_embed_playlist(ref)


async def _search_deezer(q: str, limit: int) -> list[dict]:
    items = (await deezer._get("search/playlist", q=q, limit=limit)).get("data") or []
    return [
        {
            "source": "deezer",
            "link": item["link"],
            "name": item["title"],
            "owner": (item.get("user") or {}).get("name"),
            "image_url": item.get("picture_big") or item.get("picture_medium"),
            "track_count": item.get("nb_tracks"),
        }
        for item in items
        if item.get("public", True) and item.get("link")
    ]


async def _search_apple(q: str, limit: int) -> list[dict]:
    async with apple_music._client_factory() as client:
        data = await apple_music._get(client, "/catalog/de/search", term=q, types="playlists", limit=limit)
    items = data.get("results", {}).get("playlists", {}).get("data", [])
    results = []
    for item in items:
        attributes = item.get("attributes") or {}
        artwork = (attributes.get("artwork") or {}).get("url")
        if not attributes.get("url") or not attributes.get("name"):
            continue
        results.append({
            "source": "apple",
            "link": attributes["url"],
            "name": attributes["name"],
            "owner": attributes.get("curatorName"),
            "image_url": artwork.replace("{w}", "500").replace("{h}", "500") if artwork else None,
            "track_count": None,
        })
    return results


async def _search_spotify(q: str, limit: int, cfg: SpotifyConfig) -> list[dict]:
    if not cfg.client_id or not cfg.client_secret:
        return []
    async with spotify._client_factory() as client:
        token = (await spotify._token(client, cfg, {"grant_type": "client_credentials"}))["access_token"]
        response = await client.get(
            "https://api.spotify.com/v1/search",
            params={"q": q, "type": "playlist", "limit": limit, "market": "DE"},
            headers={"Authorization": f"Bearer {token}"},
        )
        response.raise_for_status()
    results = []
    # Spotify returns null for playlists it does not hand out.
    for item in (response.json().get("playlists") or {}).get("items") or []:
        if not item or not (item.get("external_urls") or {}).get("spotify"):
            continue
        images = item.get("images") or []
        results.append({
            "source": "spotify",
            "link": item["external_urls"]["spotify"],
            "name": item.get("name") or "",
            "owner": (item.get("owner") or {}).get("display_name"),
            "image_url": images[0]["url"] if images else None,
            "track_count": (item.get("tracks") or item.get("items") or {}).get("total"),
        })
    return results


async def search(q: str, cfg: SpotifyConfig, limit: int = 8) -> list[dict]:
    """Playlists of all three services, interleaved (Deezer, Apple Music, Spotify, Deezer, …). A service that fails
    is left out."""
    lists = await asyncio.gather(
        _search_deezer(q, limit), _search_apple(q, limit), _search_spotify(q, limit, cfg), return_exceptions=True
    )
    found: list[list[dict]] = []
    for result in lists:
        if isinstance(result, BaseException):
            if not isinstance(result, (DeezerError, SpotifyError, httpx.HTTPError, KeyError, TypeError, ValueError)):
                raise result
            log.info("Playlist search failed: %s", result)
            continue
        found.append(result)
    merged = []
    for i in range(max((len(items) for items in found), default=0)):
        merged.extend(items[i] for items in found if i < len(items))
    return merged
