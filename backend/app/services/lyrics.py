import asyncio
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import mutagen
from mutagen.id3 import ID3
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Album, Track, TrackLyrics
from app.schemas import LyricLine, LyricsOut
from app.services.musicbrainz import VERSION
from app.services.server_config import load_config
from app.services.tags import primary_artist


class LyricsError(Exception):
    pass


_client: httpx.AsyncClient | None = None
_semaphore = asyncio.Semaphore(4)


# LRC ID tags; other bracketed text such as "[Chorus: Drake]" is part of the lyrics.
_META = r"\[(?:ar|ti|al|au|by|re|ve|la|id|length|offset|tool|#):[^\]]*\]"


def parse_lrc(text: str) -> list[tuple[int | None, str]]:
    stamp = re.compile(r"\[(\d+):(\d{2})(?:\.(\d{1,3}))?\]")
    offsets = re.findall(r"\[offset:([+-]?\d+)\]", text, flags=re.IGNORECASE)
    offset = int(offsets[-1]) if offsets else 0
    timed: list[tuple[int | None, str]] = []
    plain: list[tuple[int | None, str]] = []
    for line in text.lstrip("\ufeff").splitlines():
        if line.strip() and re.fullmatch(rf"(?:\s*{_META}\s*)+", line, flags=re.IGNORECASE):
            continue
        line = re.sub(_META, "", line, flags=re.IGNORECASE)
        stamps = []
        remaining = line
        while match := stamp.match(remaining):
            minutes, seconds, fraction = match.groups()
            ms = (int(minutes) * 60 + int(seconds)) * 1000 + int((fraction or "0").ljust(3, "0"))
            stamps.append(max(0, ms - offset))
            remaining = remaining[match.end() :]
        value = re.sub(r"<\d+:\d{2}(?:\.\d{1,3})?>", "", remaining).strip()
        if stamps:
            timed.extend((ms, value) for ms in stamps)
        else:
            plain.append((None, value))
    if timed:
        return sorted(timed, key=lambda item: item[0] or 0)
    while plain and not plain[0][1]:
        plain.pop(0)
    while plain and not plain[-1][1]:
        plain.pop()
    return plain


def sidecar_path(path: Path) -> Path | None:
    sidecar = path.with_suffix(".lrc")
    if sidecar.is_file():
        return sidecar
    return (
        next(
            (p for p in path.parent.iterdir() if p.stem == path.stem and p.suffix.lower() == ".lrc" and p.is_file()),
            None,
        )
        if path.parent.is_dir()
        else None
    )


def local_lyrics(path: Path) -> str | None:
    try:
        sidecar = sidecar_path(path)
        if sidecar is not None:
            return sidecar.read_text(encoding="utf-8", errors="replace").lstrip("\ufeff")
        audio = mutagen.File(path)
        if audio is None or audio.tags is None:
            return None
        if isinstance(audio.tags, ID3):
            return next((frame.text for frame in audio.tags.getall("USLT") if frame.text.strip()), None)
        for key in ("lyrics", "unsyncedlyrics", "syncedlyrics", "©lyr"):
            for name, values in audio.tags.items():
                if name.casefold() == key:
                    for value in values if isinstance(values, list) else [values]:
                        if isinstance(value, str) and value.strip():
                            return value
    except Exception:  # noqa: BLE001 - damaged files simply have no lyrics
        return None
    return None


async def lrclib_lookup(artist: str, title: str, album: str, duration: float) -> dict | None:
    global _client
    if _client is None:
        _client = httpx.AsyncClient(
            base_url="https://lrclib.net/api/",
            headers={"User-Agent": f"Resonance/{VERSION} (https://github.com/Sky0405-coder/Resonance)"},
            timeout=10,
        )
    try:
        async with _semaphore:
            response = await _client.get(
                "get",
                params={"artist_name": artist, "track_name": title, "album_name": album, "duration": round(duration)},
            )
            if response.status_code == 200:
                return response.json()
            if response.status_code != 404:
                raise LyricsError(f"LRCLIB: HTTP {response.status_code}")
            response = await _client.get("search", params={"artist_name": artist, "track_name": title})
            if response.status_code != 200:
                raise LyricsError(f"LRCLIB: HTTP {response.status_code}")
            return next((item for item in response.json() if abs(float(item["duration"]) - duration) <= 3), None)
    except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
        raise LyricsError(str(exc)) from exc


def _result(synced: str | None, plain: str | None, instrumental: bool, source: str | None) -> LyricsOut:
    lines = [LyricLine(time_ms=ms if synced else None, text=text) for ms, text in parse_lrc(synced or plain or "")]
    return LyricsOut(
        synced=bool(lines) and all(line.time_ms is not None for line in lines),
        instrumental=instrumental,
        source=source if lines or instrumental else None,
        lines=lines,
    )


async def get_lyrics(db: AsyncSession, track: Track) -> LyricsOut:
    path = get_settings().music_dir / track.path
    local = await asyncio.to_thread(local_lyrics, path)
    if local is not None:
        source = "file" if await asyncio.to_thread(sidecar_path, path) else "embedded"
        return _result(local, None, False, source)
    cached = await db.get(TrackLyrics, track.id)
    if cached is not None and (cached.source != "none" or cached.fetched_at > datetime.now(UTC) - timedelta(days=30)):
        return _result(cached.synced, cached.plain, cached.instrumental, "lrclib")
    cfg = await load_config(db)
    if cfg.library.lyrics_online:
        album = await db.get(Album, track.album_id)
        try:
            data = await lrclib_lookup(primary_artist(track.artist_credit), track.title, album.title, track.duration)
        except LyricsError:
            return _result(None, None, False, None)
        data = data or {}
        row = cached or TrackLyrics(track_id=track.id)
        row.synced = data.get("syncedLyrics")
        row.plain = data.get("plainLyrics")
        row.instrumental = bool(data.get("instrumental", False))
        row.source = "lrclib" if row.synced or row.plain or row.instrumental else "none"
        row.fetched_at = datetime.now(UTC)
        db.add(row)
        await db.commit()
        return _result(row.synced, row.plain, row.instrumental, "lrclib")
    return _result(None, None, False, None)
