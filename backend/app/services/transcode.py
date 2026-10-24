import asyncio
import hashlib
import mimetypes
import os
from collections.abc import AsyncIterator
from pathlib import Path

from app.config import get_settings

FORMAT_MEDIA_TYPES = {"opus": "audio/ogg", "mp3": "audio/mpeg"}
_CODEC_ARGS = {
    "opus": ["-c:a", "libopus", "-f", "ogg"],
    "mp3": ["-c:a", "libmp3lame", "-f", "mp3"],
}
_EXTRA_TYPES = {".flac": "audio/flac", ".opus": "audio/ogg", ".ogg": "audio/ogg", ".m4a": "audio/mp4", ".wav": "audio/wav"}


# Codecs every client (browser, Android, libmpv) can decode natively; everything else is transcoded in "auto" mode.
NATIVE_CODECS = {"mp3", "flac", "aac", "vorbis", "opus", "wave"}


def resolve_path(stored: str) -> Path:
    """Track paths are stored relative to the music dir so the library survives being moved."""
    p = Path(stored)
    return p if p.is_absolute() else get_settings().music_dir / p


def media_type(path: Path) -> str:
    return _EXTRA_TYPES.get(path.suffix.lower()) or mimetypes.guess_type(path.name)[0] or "application/octet-stream"


async def stream(path: Path, fmt: str, bitrate: int) -> AsyncIterator[bytes]:
    proc = await asyncio.create_subprocess_exec(
        get_settings().ffmpeg_path,
        "-nostdin", "-loglevel", "error",
        "-i", str(path),
        "-map", "0:a:0", "-vn",
        *_CODEC_ARGS[fmt],
        "-b:a", f"{bitrate}k",
        "pipe:1",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )  # fmt: skip
    assert proc.stdout is not None
    try:
        while chunk := await proc.stdout.read(64 * 1024):
            yield chunk
    finally:
        # Client disconnected or finished: make sure ffmpeg does not linger.
        if proc.returncode is None:
            proc.kill()
        await proc.wait()


# --- Cached transcodes ---------------------------------------------------------
# A live ffmpeg pipe has no length and cannot answer byte ranges. Browsers and TVs (Samsung) buffer a part of the
# song and then ask for the rest by byte range: without it playback stops after ~1:20 and "play" starts over. So each
# transcode is also written to a cache file; the first request streams while it grows, later range requests (resume,
# seek) are served from the finished file.

CACHE_MAX_BYTES = 3 * 1024**3
_jobs: dict[Path, asyncio.Task[None]] = {}


def cache_dir() -> Path:
    return get_settings().data_dir / "transcodes"


def cache_path(path: Path, fmt: str, bitrate: int) -> Path:
    stat = path.stat()
    name = hashlib.sha1(f"{path}|{stat.st_mtime_ns}|{stat.st_size}|{fmt}|{bitrate}".encode()).hexdigest()
    return cache_dir() / f"{name}.{'ogg' if fmt == 'opus' else fmt}"


def _part(target: Path) -> Path:
    return target.with_name(target.name + ".part")


async def _transcode(path: Path, fmt: str, bitrate: int, target: Path) -> None:
    part = _part(target)
    try:
        with part.open("wb") as out:
            async for chunk in stream(path, fmt, bitrate):
                out.write(chunk)
                out.flush()
        os.replace(part, target)
    except BaseException:
        part.unlink(missing_ok=True)
        raise
    finally:
        _jobs.pop(target, None)


def _prune(keep: Path) -> None:
    files = sorted((f for f in cache_dir().glob("*") if f.is_file() and f != keep), key=lambda f: f.stat().st_mtime)
    total = sum(f.stat().st_size for f in files)
    for f in files:
        if total <= CACHE_MAX_BYTES:
            break
        if f.suffix == ".part" or _part(f) in _jobs:
            continue
        total -= f.stat().st_size
        f.unlink(missing_ok=True)


def start(path: Path, fmt: str, bitrate: int) -> tuple[Path, asyncio.Task[None] | None]:
    """The cache file for this transcode and the job still writing it (None once it is complete)."""
    target = cache_path(path, fmt, bitrate)
    if target.is_file():
        target.touch()  # recently played files are pruned last
        return target, None
    job = _jobs.get(target)
    if job is None:
        target.parent.mkdir(parents=True, exist_ok=True)
        _prune(target)
        # Not tied to the request: the file is finished even when the player drops this connection early.
        job = _jobs[target] = asyncio.create_task(_transcode(path, fmt, bitrate, target))
    return target, job


async def follow(target: Path, job: asyncio.Task[None]) -> AsyncIterator[bytes]:
    """Streams a cache file while the job is still writing it."""
    part = _part(target)
    while not part.exists() and not job.done():
        await asyncio.sleep(0.02)
    if not part.exists():
        await job  # failed (raises) or already renamed
        with target.open("rb") as f:
            while chunk := f.read(64 * 1024):
                yield chunk
        return
    with part.open("rb") as f:  # stays readable after the rename
        while True:
            chunk = f.read(64 * 1024)
            if chunk:
                yield chunk
            elif job.done():
                await job
                while chunk := f.read(64 * 1024):
                    yield chunk
                return
            else:
                await asyncio.sleep(0.05)
