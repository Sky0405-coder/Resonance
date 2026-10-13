import asyncio
import os
from pathlib import Path

from app.config import get_settings

_semaphore = asyncio.Semaphore(max(1, (os.cpu_count() or 2) // 2))


async def fingerprint(path: Path) -> str | None:
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
            "base64",
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
        return stdout.decode().strip() or None if process.returncode == 0 else None
