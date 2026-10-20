"""Public Apple Music playlists by link, read through the catalog API the Apple Music web player uses."""

import base64
import json
import re
import time

import httpx

from app.services.musicbrainz import TrackMeta, _year
from app.services.spotify import SpotifyError, SpotifyTrack

_WEB = "https://music.apple.com"
_API = "https://amp-api.music.apple.com/v1"
_HEADERS = {
    "User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36",
    "Origin": _WEB,
}
# The web player's developer token (a JWT valid for months) and when to fetch a new one.
_token: tuple[str, float] | None = None


def _client_factory() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=30, headers=_HEADERS, follow_redirects=True)


def playlist_ref_from_link(link: str) -> str | None:
    """`https://music.apple.com/de/playlist/name/pl.…` → `apple:de:pl.…` (stored like a Spotify playlist id)."""
    url = re.fullmatch(
        r"(?:https://)?(?:embed\.)?music\.apple\.com/([a-z]{2})/playlist/(?:[^/?#\s]+/)?(pl\.[A-Za-z0-9-]{4,48})"
        r"(?:\?[^\s#]*)?",
        link,
    )
    return f"apple:{url[1]}:{url[2]}" if url else None


def _expiry(token: str) -> float:
    try:
        payload = token.split(".")[1]
        return float(json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))["exp"])
    except (IndexError, ValueError, KeyError, TypeError):
        return time.time() + 86400


async def _developer_token(client: httpx.AsyncClient, *, fresh: bool = False) -> str:
    global _token
    if _token is not None and not fresh and _token[1] > time.time():
        return _token[0]
    try:
        page = await client.get(f"{_WEB}/us/browse")
        script = re.search(r'src="(/assets/index[^"]*\.js)"', page.text)
        if script is None:
            raise SpotifyError(502, "Apple Music nicht erreichbar")
        bundle = (await client.get(_WEB + script[1])).text
        candidates = re.findall(r'"(eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+)"', bundle)
        for token in candidates:
            probe = await client.get(
                f"{_API}/catalog/us/search", params={"term": "a", "types": "songs", "limit": 1},
                headers={"Authorization": f"Bearer {token}"},
            )
            if probe.is_success:
                # Renew a day early.
                _token = (token, _expiry(token) - 86400)
                return token
    except httpx.HTTPError as e:
        raise SpotifyError(502, "Apple Music nicht erreichbar") from e
    raise SpotifyError(502, "Apple Music nicht erreichbar")


async def _get(client: httpx.AsyncClient, path: str, **params) -> dict:
    for attempt in range(2):
        token = await _developer_token(client, fresh=attempt > 0)
        try:
            response = await client.get(
                _API + path, params=params or None, headers={"Authorization": f"Bearer {token}"}
            )
        except httpx.HTTPError as e:
            raise SpotifyError(502, "Apple Music nicht erreichbar") from e
        if response.status_code == 401 and attempt == 0:
            continue
        if response.status_code == 404:
            raise SpotifyError(404, "Playlist nicht gefunden oder privat")
        if not response.is_success:
            raise SpotifyError(502, "Apple Music nicht erreichbar")
        return response.json()
    raise SpotifyError(502, "Apple Music nicht erreichbar")


async def fetch_playlist(ref: str) -> tuple[dict, list[SpotifyTrack]]:
    _, storefront, id = ref.split(":", 2)
    async with _client_factory() as client:
        data = (await _get(client, f"/catalog/{storefront}/playlists/{id}"))["data"]
        if not data:
            raise SpotifyError(404, "Playlist nicht gefunden oder privat")
        attributes = data[0].get("attributes") or {}
        artwork = (attributes.get("artwork") or {}).get("url")
        metadata = {
            "id": ref,
            "name": attributes.get("name") or id,
            "owner": attributes.get("curatorName"),
            "image_url": artwork.replace("{w}", "640").replace("{h}", "640") if artwork else None,
        }
        tracks: list[SpotifyTrack] = []
        path: str | None = f"/catalog/{storefront}/playlists/{id}/tracks"
        params: dict = {"limit": 100}
        while path is not None:
            page = await _get(client, path, **params)
            for item in page.get("data") or []:
                song = item.get("attributes") or {}
                if item.get("type") != "songs" or not song.get("name"):
                    continue
                duration = song.get("durationInMillis")
                tracks.append(
                    SpotifyTrack(
                        title=song["name"],
                        artist=song.get("artistName") or "",
                        album=song.get("albumName"),
                        isrc=song.get("isrc"),
                        duration=duration / 1000 if duration is not None else None,
                        added_at=None,
                        position=len(tracks),
                    )
                )
            # "next" is a path below /v1 that already carries the offset.
            next_page = page.get("next")
            path, params = (next_page.removeprefix("/v1"), {}) if next_page else (None, {})
            if len(tracks) >= 10000:
                break
    return metadata, tracks


def artwork_url(attributes: dict) -> str | None:
    url = (attributes.get("artwork") or {}).get("url")
    return url.replace("{w}", "1400").replace("{h}", "1400") if url else None


async def search_songs(term: str, limit: int = 15) -> list[dict]:
    async with _client_factory() as client:
        data = await _get(client, "/catalog/de/search", term=term, types="songs", limit=limit)
    return data.get("results", {}).get("songs", {}).get("data", [])


async def search_albums(term: str, limit: int = 10) -> list[dict]:
    async with _client_factory() as client:
        data = await _get(client, "/catalog/de/search", term=term, types="albums", limit=limit)
    return data.get("results", {}).get("albums", {}).get("data", [])


def _song_meta(song: dict, album: dict | None = None) -> TrackMeta:
    attrs = song.get("attributes") or {}
    release = (album or {}).get("attributes") or {}
    date = release.get("releaseDate") or attrs.get("releaseDate")
    genres = attrs.get("genreNames") or release.get("genreNames") or []
    duration = attrs.get("durationInMillis")
    return TrackMeta(
        title=attrs["name"],
        artist=attrs.get("artistName") or "",
        artist_mbid=None,
        album=release.get("name") or attrs.get("albumName") or "",
        album_artist=release.get("artistName") or attrs.get("artistName") or "",
        album_artist_mbid=None,
        year=_year(date),
        date=date,
        track_no=attrs.get("trackNumber"),
        track_total=release.get("trackCount"),
        disc_no=attrs.get("discNumber"),
        disc_total=None,
        genre=next((g for g in genres if g.casefold() not in {"musik", "music"}), None),
        isrc=attrs.get("isrc"),
        duration=duration / 1000 if duration is not None else None,
        label=release.get("recordLabel"),
        mb_recording_id=None,
        mb_release_id=None,
        mb_release_group_id=None,
        cover_url=artwork_url(release) or artwork_url(attrs),
    )


async def song_meta(id: str) -> TrackMeta:
    async with _client_factory() as client:
        songs = (await _get(client, f"/catalog/de/songs/{id}", include="albums")).get("data") or []
        if not songs:
            raise SpotifyError(404, "Song nicht gefunden")
        song = songs[0]
        albums = song.get("relationships", {}).get("albums", {}).get("data") or []
        album = albums[0] if albums else None
        if album and not album.get("attributes"):
            albums = (await _get(client, f"/catalog/de/albums/{album['id']}")).get("data") or []
            album = albums[0] if albums else None
    return _song_meta(song, album)


async def album_metas(id: str) -> list[TrackMeta]:
    async with _client_factory() as client:
        albums = (await _get(client, f"/catalog/de/albums/{id}", include="tracks")).get("data") or []
        if not albums:
            raise SpotifyError(404, "Album nicht gefunden")
        album = albums[0]
        page = album.get("relationships", {}).get("tracks") or {}
        songs = list(page.get("data") or [])
        path = page.get("next")
        if not page:
            path = f"/catalog/de/albums/{id}/tracks"
        seen = set()
        while path and path not in seen:
            seen.add(path)
            page = await _get(client, path.removeprefix("/v1"))
            songs.extend(page.get("data") or [])
            path = page.get("next")
    metas = [_song_meta(s, album) for s in songs if s.get("type") == "songs"]
    for meta in metas:
        meta.disc_total = max((m.disc_no or 1 for m in metas), default=1)
        meta.track_total = sum((m.disc_no or 1) == (meta.disc_no or 1) for m in metas)
    return metas
