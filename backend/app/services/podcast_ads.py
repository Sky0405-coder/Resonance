"""Removes dynamically inserted ads from podcast episodes.

Hosts like Megaphone, Acast or Podigee splice ads into the MP3 per download, so two downloads of the same episode
carry the same show but different ads. The show's MP3 frames stay byte-identical, so comparing the frame hashes of
three downloads finds the spliced spots: whatever the first download has where another one differs is an ad. Cut
ads are remembered as frame hashes, which also catches a spot that happened to be the same in every download.
Ads read by the hosts themselves are part of the show and stay in.
"""

import asyncio
import hashlib
import logging
import uuid
from contextlib import suppress
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from difflib import SequenceMatcher
from pathlib import Path

import httpx
from sqlalchemy import delete, func, select, update

from app.config import get_settings
from app.db import SessionLocal
from app.models.podcasts import (
    EpisodeProgress,
    PodcastAd,
    PodcastEpisode,
    PodcastSubscription,
)

log = logging.getLogger(__name__)

HASH = 8
MAX_BYTES = 1024 * 1024 * 1024
# A spliced spot is at least a few seconds long; shorter differences are re-encoded frames around a splice.
MIN_AD = 3.0
MAX_AD = 300.0
LEARN = (5.0, 180.0)
MAX_SHARE = 0.4
RECENT_DAYS = 30
PER_PODCAST = 3
KEEP_DAYS = 45
AGENTS = (
    "AppleCoreMedia/1.0.0.21A329 (iPhone; U; CPU OS 17_0 like Mac OS X; de_de)",
    "Spotify/8.9.10 Android/34 (Pixel 8)",
    "Resonance/1.6 (Podcast; +https://github.com/Sky0405-coder/Resonance)",
)

_BITRATES = {
    1: (0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320),
    2: (0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160),
}
_RATES = {3: (44100, 48000, 32000), 2: (22050, 24000, 16000), 0: (11025, 12000, 8000)}

_pending: dict[uuid.UUID, None] = {}
_wake = asyncio.Event()
_task: asyncio.Task | None = None


class AdError(Exception):
    pass


@dataclass(frozen=True)
class Frame:
    start: int
    end: int
    seconds: float
    hash: bytes


def _header(data: bytes | memoryview, i: int) -> tuple[int, float] | None:
    """Length and duration of the MPEG layer III frame starting at `i`, or None if there is none."""
    if i + 4 > len(data) or data[i] != 0xFF or data[i + 1] & 0xE0 != 0xE0:
        return None
    version = (data[i + 1] >> 3) & 3
    layer = (data[i + 1] >> 1) & 3
    bitrate = data[i + 2] >> 4
    rate = (data[i + 2] >> 2) & 3
    if version == 1 or layer != 1 or bitrate in (0, 15) or rate == 3:
        return None
    padding = (data[i + 2] >> 1) & 1
    sample_rate = _RATES[version][rate]
    kbps = _BITRATES[1 if version == 3 else 2][bitrate]
    samples = 1152 if version == 3 else 576
    return samples * kbps * 125 // sample_rate + padding, samples / sample_rate


def frames(data: bytes) -> list[Frame]:
    """The audio frames of an MP3 (ID3 tags and Xing/Info/VBRI headers skipped), each with a hash of its content."""
    view = memoryview(data)
    result: list[Frame] = []
    i = 0
    while i + 4 <= len(data):
        if data[i:i + 3] == b"ID3" and i + 10 <= len(data):
            size = (data[i + 6] << 21) | (data[i + 7] << 14) | (data[i + 8] << 7) | data[i + 9]
            i += 10 + size + (10 if data[i + 5] & 0x10 else 0)
            continue
        header = _header(data, i)
        if header is None or header[0] < 24:
            i += 1
            continue
        length, seconds = header
        end = i + length
        # A real frame is followed by the next one (or the end); random 0xFFE bytes mostly are not.
        if end < len(data) - 4 and _header(data, end) is None and data[end:end + 3] not in (b"ID3", b"TAG"):
            i += 1
            continue
        payload = view[i + 4:min(end, len(data))]
        head = bytes(payload[:40])
        if not result and (b"Xing" in head or b"Info" in head or head[32:36] == b"VBRI"):
            i = end
            continue
        result.append(Frame(i, min(end, len(data)), seconds, hashlib.blake2b(payload, digest_size=HASH).digest()))
        i = end
    return result


def _times(items: list[Frame]) -> list[float]:
    times = [0.0]
    for frame in items:
        times.append(times[-1] + frame.seconds)
    return times


def compare(main: list[Frame], other: list[Frame]) -> list[tuple[int, int]] | None:
    """Frame ranges of `main` that `other` has something else in place of, or None if the two are not comparable."""
    a = [f.hash for f in main]
    matcher = SequenceMatcher(None, a, [f.hash for f in other], autojunk=False)
    blocks = [m for m in matcher.get_matching_blocks() if m.size >= 40]
    if sum(m.size for m in blocks) < 0.6 * len(a):
        return None
    times = _times(main)
    gaps = []
    previous = 0
    for block in [*blocks, None]:
        start = block.a if block is not None else len(a)
        if start > previous:
            gaps.append((previous, start))
        if block is not None:
            previous = block.a + block.size
    ranges = []
    for start, end in gaps:
        seconds = times[end] - times[start]
        if seconds > MAX_AD:
            return None
        if seconds >= MIN_AD:
            ranges.append((start, end))
    return ranges


def known(main: list[Frame], ads: set[bytes]) -> list[tuple[int, int]]:
    """Runs of at least five seconds of frames that were cut from earlier episodes as ads."""
    counts: dict[bytes, int] = {}
    for frame in main:
        counts[frame.hash] = counts.get(frame.hash, 0) + 1
    # Frames repeated all over the episode (digital silence) say nothing about ads.
    hits = [i for i, frame in enumerate(main) if frame.hash in ads and counts[frame.hash] <= 3]
    times = _times(main)
    runs: list[list[int]] = []
    for index in hits:
        if runs and index - runs[-1][1] <= 6:
            runs[-1][1] = index
        else:
            runs.append([index, index])
    return [(start, last + 1) for start, last in runs if times[last + 1] - times[start] >= LEARN[0]]


def merge(ranges: list[tuple[int, int]]) -> list[tuple[int, int]]:
    result: list[tuple[int, int]] = []
    for start, end in sorted(ranges):
        if result and start <= result[-1][1]:
            result[-1] = (result[-1][0], max(result[-1][1], end))
        else:
            result.append((start, end))
    return result


@dataclass
class Analysis:
    cut: list[tuple[int, int]]
    learned: list[tuple[bytes, float]]
    removed: float
    duration: float


def analyze(main: list[Frame], others: list[list[Frame]], ads: set[bytes]) -> Analysis:
    found = [ranges for other in others if (ranges := compare(main, other)) is not None]
    if not found:
        raise AdError("Downloads differ too much to compare (re-encoded per request?)")
    spliced = merge([r for ranges in found for r in ranges])
    cut = merge(spliced + known(main, ads))
    times = _times(main)
    removed = sum(times[end] - times[start] for start, end in cut)
    if removed > MAX_SHARE * times[-1]:
        raise AdError(f"Would remove {removed:.0f} of {times[-1]:.0f} s")
    dropped = {i for start, end in cut for i in range(start, end)}
    show = {frame.hash for i, frame in enumerate(main) if i not in dropped}
    learned = []
    for start, end in spliced:
        seconds = times[end] - times[start]
        if LEARN[0] <= seconds <= LEARN[1]:
            hashes = [f.hash for f in main[start:end] if f.hash not in show]
            if len([h for h in hashes if h not in ads]) > 0.2 * len(hashes):
                learned.append((b"".join(dict.fromkeys(hashes)), seconds))
    return Analysis(cut, learned, removed, times[-1] - removed)


def episode_path(episode_id: uuid.UUID) -> Path:
    return get_settings().data_dir / "podcasts" / f"{episode_id}.mp3"


async def _download(client: httpx.AsyncClient, url: str, agent: str, target: Path) -> None:
    size = 0
    async with client.stream("GET", url, headers={"User-Agent": agent}) as response:
        response.raise_for_status()
        with target.open("wb") as file:
            async for chunk in response.aiter_bytes(1 << 16):
                size += len(chunk)
                if size > MAX_BYTES:
                    raise AdError("Episode larger than 1 GB")
                file.write(chunk)


def known_hashes(packed: bytes) -> list[bytes]:
    return [packed[i:i + HASH] for i in range(0, len(packed), HASH)]


async def _known_ads() -> set[bytes]:
    async with SessionLocal() as db:
        rows = await db.scalars(select(PodcastAd.hashes).order_by(PodcastAd.created_at.desc()).limit(1000))
        return {h for row in rows for h in known_hashes(row)}


async def _write(source: Path, main: list[Frame], cut: list[tuple[int, int]], target: Path) -> None:
    dropped = {i for start, end in cut for i in range(start, end)}
    raw = target.with_suffix(".raw.mp3")
    with source.open("rb") as file, raw.open("wb") as out:
        for i, frame in enumerate(main):
            if i not in dropped:
                file.seek(frame.start)
                out.write(file.read(frame.end - frame.start))
    # Remux for a fresh Xing header, so players see the new length.
    process = await asyncio.create_subprocess_exec(
        get_settings().ffmpeg_path, "-v", "error", "-y", "-i", str(raw), "-map", "0:a", "-c", "copy",
        "-map_metadata", "-1", "-write_xing", "1", str(target),
        stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE,
    )
    _, error = await process.communicate()
    raw.unlink(missing_ok=True)
    if process.returncode != 0:
        target.unlink(missing_ok=True)
        raise AdError(f"ffmpeg failed: {error.decode(errors='replace')[-300:]}")


async def process(episode_id: uuid.UUID) -> None:
    async with SessionLocal() as db:
        episode = await db.get(PodcastEpisode, episode_id)
        if episode is None:
            return
        status = episode.ad_status
        # Already done (and the file still there), or known to have no inserted ads / not to work: nothing to do.
        if status not in (None, "failed") and (status != "done" or episode_path(episode_id).exists()):
            return
        url, podcast_id = episode.audio_url, episode.podcast_id
    folder = get_settings().data_dir / "podcasts"
    work = folder / "tmp" / str(episode_id)
    work.mkdir(parents=True, exist_ok=True)
    status, removed, duration = "failed", None, None
    try:
        paths = [work / f"{n}.mp3" for n in range(len(AGENTS))]
        async with httpx.AsyncClient(timeout=httpx.Timeout(60, read=120), follow_redirects=True) as client:
            for agent, path in zip(AGENTS, paths, strict=True):
                await _download(client, url, agent, path)
        parsed = await asyncio.to_thread(lambda: [frames(path.read_bytes()) for path in paths])
        if len(parsed[0]) < 100:
            raise AdError("Not an MP3 episode")
        result = await asyncio.to_thread(analyze, parsed[0], parsed[1:], await _known_ads())
        if result.cut:
            await _write(paths[0], parsed[0], result.cut, episode_path(episode_id))
            status, removed, duration = "done", result.removed, result.duration
        else:
            status, removed = "none", 0.0
        if result.learned:
            async with SessionLocal() as db:
                db.add_all(PodcastAd(podcast_id=podcast_id, hashes=h, seconds=s) for h, s in result.learned)
                await db.commit()
        log.info("Ads in episode %s: %s, %.0f s removed", episode_id, status, removed or 0)
    except AdError as exc:
        status = "unsupported"
        log.info("Ads in episode %s not removed: %s", episode_id, exc)
    except Exception:
        log.exception("Removing ads failed: %s", episode_id)
    finally:
        for path in work.glob("*"):
            path.unlink(missing_ok=True)
        with suppress(OSError):
            work.rmdir()
    async with SessionLocal() as db:
        await db.execute(update(PodcastEpisode).where(PodcastEpisode.id == episode_id).values(
            ad_status=status, ad_seconds=removed, ad_duration=duration, ad_processed_at=datetime.now(UTC),
        ))
        await db.commit()


def request(episode_id: uuid.UUID) -> None:
    """Queues an episode (e.g. one that is being played) ahead of the periodic scan."""
    _pending[episode_id] = None
    _wake.set()


def wake() -> None:
    _wake.set()


async def _candidates() -> list[uuid.UUID]:
    """Episodes someone is in the middle of, then the newest few of every podcast someone listens to without ads."""
    now = datetime.now(UTC)
    open_status = PodcastEpisode.ad_status.is_(None) | (
        (PodcastEpisode.ad_status == "failed") & (PodcastEpisode.ad_processed_at < now - timedelta(days=1))
    )
    async with SessionLocal() as db:
        result = list(await db.scalars(
            select(PodcastEpisode.id).join(EpisodeProgress, EpisodeProgress.episode_id == PodcastEpisode.id)
            .join(PodcastSubscription, (PodcastSubscription.podcast_id == PodcastEpisode.podcast_id)
                  & (PodcastSubscription.user_id == EpisodeProgress.user_id))
            .where(PodcastSubscription.remove_ads, EpisodeProgress.completed.is_(False),
                   EpisodeProgress.position_seconds > 0, open_status)
            .group_by(PodcastEpisode.id).order_by(func.max(EpisodeProgress.updated_at).desc())
        ))
        podcast_ids = list(await db.scalars(
            select(PodcastSubscription.podcast_id).where(PodcastSubscription.remove_ads).distinct()
        ))
        for podcast_id in podcast_ids:
            result += await db.scalars(select(PodcastEpisode.id).where(
                PodcastEpisode.podcast_id == podcast_id,
                PodcastEpisode.published_at >= now - timedelta(days=RECENT_DAYS),
                open_status,
            ).order_by(PodcastEpisode.published_at.desc()).limit(PER_PODCAST))
        return list(dict.fromkeys(result))


async def cleanup() -> None:
    """Drops cleaned files after a while unless someone is still in the middle of the episode."""
    cutoff = datetime.now(UTC) - timedelta(days=KEEP_DAYS)
    listening = select(EpisodeProgress.episode_id).where(
        EpisodeProgress.episode_id == PodcastEpisode.id, EpisodeProgress.completed.is_(False),
        EpisodeProgress.position_seconds > 0,
    ).exists()
    async with SessionLocal() as db:
        ids = list(await db.scalars(select(PodcastEpisode.id).where(
            PodcastEpisode.ad_status == "done", PodcastEpisode.ad_processed_at < cutoff, ~listening,
        )))
        for episode_id in ids:
            episode_path(episode_id).unlink(missing_ok=True)
        if ids:
            await db.execute(update(PodcastEpisode).where(PodcastEpisode.id.in_(ids)).values(
                ad_status=None, ad_seconds=None, ad_duration=None, ad_processed_at=None,
            ))
        await db.execute(delete(PodcastAd).where(PodcastAd.created_at < func.now() - timedelta(days=180)))
        await db.commit()


async def _loop() -> None:
    while True:
        _wake.clear()
        try:
            await cleanup()
            queue = await _candidates()
            while _pending or queue:
                # Episodes asked for while playing go first.
                episode_id = next(iter(_pending)) if _pending else queue.pop(0)
                await process(episode_id)
                _pending.pop(episode_id, None)
        except Exception:
            log.exception("Podcast ad removal cycle failed")
        with suppress(TimeoutError):
            await asyncio.wait_for(_wake.wait(), 30 * 60)


async def start() -> None:
    global _task
    if _task is None:
        _task = asyncio.create_task(_loop())


async def stop() -> None:
    global _task
    if _task is not None:
        _task.cancel()
        with suppress(asyncio.CancelledError):
            await _task
        _task = None
