import asyncio
import mimetypes
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
