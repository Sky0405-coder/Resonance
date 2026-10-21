import asyncio
from pathlib import Path

import numpy as np

from app.services.fingerprint import fingerprint_raw


async def test_raw_chromaprint_from_ffmpeg(tmp_path: Path) -> None:
    path = tmp_path / "audio.wav"
    process = await asyncio.create_subprocess_exec(
        "ffmpeg", "-nostdin", "-v", "error", "-f", "lavfi", "-i",
        "anoisesrc=duration=15:sample_rate=44100:seed=1", str(path),
    )
    assert await process.wait() == 0
    raw = await fingerprint_raw(path)
    assert isinstance(raw, bytes)
    assert len(raw) % 4 == 0
    assert len(np.frombuffer(raw, dtype="<u4")) >= 50
    assert await fingerprint_raw(tmp_path / "missing.wav") is None
