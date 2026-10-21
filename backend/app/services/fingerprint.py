import asyncio
import os
from pathlib import Path

from app.config import get_settings

_semaphore = asyncio.Semaphore(max(1, (os.cpu_count() or 2) // 2))


async def fingerprint(path: Path) -> str | None:
    raw = await _fingerprint(path, "base64")
    return raw.decode().strip() or None if raw is not None else None


async def fingerprint_raw(path: Path) -> bytes | None:
    """The first 120 seconds as Chromaprint's little-endian uint32 array."""
    raw = await _fingerprint(path, "raw")
    return raw if raw and len(raw) % 4 == 0 else None


async def _fingerprint(path: Path, fmt: str) -> bytes | None:
    async with _semaphore:
        process = await asyncio.create_subprocess_exec(
            get_settings().ffmpeg_path,
            "-nostdin",
            "-v",
            "error",
            "-i",
            str(path),
            "-t",
            "120",
            "-ac",
            "2",
            "-f",
            "chromaprint",
            "-fp_format",
            fmt,
            "-",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        try:
            stdout, _ = await process.communicate()
        except asyncio.CancelledError:
            if process.returncode is None:
                process.kill()
            await process.wait()
            raise
        return stdout or None if process.returncode == 0 else None
