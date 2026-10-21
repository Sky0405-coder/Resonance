import asyncio
import logging
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import mutagen
from mutagen.id3 import ID3
from sqlalchemy import and_, func, or_, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import Album, PlayEvent, Track, TrackLyrics
from app.schemas import LyricLine, LyricsOut
from app.services.musicbrainz import VERSION
from app.services.server_config import load_config
from app.services.tags import primary_artist

log = logging.getLogger(__name__)


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
    try:
        row = await fetch_online_lyrics(db, track)
    except LyricsError:
        row = None
    return _result(row.synced, row.plain, row.instrumental, "lrclib") if row else _result(None, None, False, None)


async def fetch_online_lyrics(db: AsyncSession, track: Track) -> TrackLyrics | None:
    """Shared LRCLIB cache for on-demand and background callers; errors remain uncached."""
    cached = await db.get(TrackLyrics, track.id)
    if cached is not None and (cached.source != "none" or cached.fetched_at > datetime.now(UTC) - timedelta(days=30)):
        return cached
    cfg = await load_config(db)
    if not cfg.library.lyrics_online:
        return None
    album = await db.get(Album, track.album_id)
    data = await lrclib_lookup(primary_artist(track.artist_credit), track.title, album.title, track.duration) or {}
    values = {
        "synced": data.get("syncedLyrics"),
        "plain": data.get("plainLyrics"),
        "instrumental": bool(data.get("instrumental", False)),
        "source": (
            "lrclib" if data.get("syncedLyrics") or data.get("plainLyrics") or data.get("instrumental") else "none"
        ),
        "fetched_at": datetime.now(UTC),
    }
    # A lyrics view can request the same song while the background lookup is in flight.
    row = await db.scalar(
        insert(TrackLyrics)
        .values(track_id=track.id, **values)
        .on_conflict_do_update(index_elements=[TrackLyrics.track_id], set_=values)
        .returning(TrackLyrics)
        .execution_options(populate_existing=True)
    )
    await db.commit()
    return row


_loop_task: asyncio.Task | None = None


async def run_once() -> None:
    async with SessionLocal() as db:
        cfg = await load_config(db)
        if not cfg.lyrics.background_fetch or not cfg.library.lyrics_online:
            return
        played = select(PlayEvent.track_id, func.max(PlayEvent.played_at).label("last_played")).group_by(
            PlayEvent.track_id
        ).subquery()
        missing = TrackLyrics.track_id.is_(None)
        ids = list(await db.scalars(
            select(Track.id)
            .outerjoin(TrackLyrics, TrackLyrics.track_id == Track.id)
            .outerjoin(played, played.c.track_id == Track.id)
            .where(
                Track.is_temporary.is_(False),
                or_(missing, and_(
                    TrackLyrics.source == "none", TrackLyrics.fetched_at < datetime.now(UTC) - timedelta(days=30)
                )),
            )
            .order_by(missing.desc(), played.c.last_played.desc().nulls_last(), Track.created_at.desc(), Track.id)
            .limit(100)
        ))
    for id in ids:
        # At most 1200 lookups per hour, including across batch boundaries.
        await asyncio.sleep(3)
        async with SessionLocal() as db:
            cfg = await load_config(db)
            if not cfg.lyrics.background_fetch or not cfg.library.lyrics_online:
                return
            track = await db.get(Track, id)
            if track is not None and not track.is_temporary:
                await fetch_online_lyrics(db, track)


async def _loop() -> None:
    delay = 60
    while True:
        await asyncio.sleep(delay)
        delay = 60
        try:
            await run_once()
        except LyricsError as exc:
            log.info("Background lyrics lookup failed; retrying in 10 minutes: %s", exc)
            delay = 600
        except Exception:
            log.exception("Background lyrics loop failed")


async def start() -> None:
    global _loop_task
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_loop())


async def stop() -> None:
    global _loop_task
    if _loop_task is not None:
        _loop_task.cancel()
        await asyncio.gather(_loop_task, return_exceptions=True)
        _loop_task = None
