"""Ringtones: a short cut of a song with fades, starting where the song is fullest (usually the chorus)."""

import asyncio
import subprocess
from pathlib import Path

import numpy as np

from app.config import get_settings

_RATE = 8000
FADE_IN = 0.5
FADE_OUT = 2.0


def _energy(path: Path) -> np.ndarray:
    """Loudness per second (RMS of a mono 8 kHz decode)."""
    result = subprocess.run(
        [get_settings().ffmpeg_path, "-v", "error", "-nostdin", "-i", str(path), "-ac", "1", "-ar", str(_RATE),
         "-f", "f32le", "-"],
        capture_output=True,
        check=True,
        timeout=120,
    )  # fmt: skip
    samples = np.frombuffer(result.stdout, dtype=np.float32)
    seconds = len(samples) // _RATE
    if seconds == 0:
        return np.zeros(0, dtype=np.float32)
    frames = samples[: seconds * _RATE].reshape(seconds, _RATE)
    return np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))


def highlight(energy: np.ndarray, length: float) -> float:
    """Start of the loudest `length` seconds, leaving out the last fifth (outros and fade-outs repeat the chorus
    but end abruptly). Shorter songs than the cut start at 0."""
    window = round(length)
    usable = max(window, int(len(energy) * 0.8))
    if len(energy) <= window or window <= 0:
        return 0.0
    sums = np.convolve(energy[:usable], np.ones(window), mode="valid")
    if not len(sums) or not np.any(sums > 0):
        return 0.0
    # The first loud window wins over equally loud later ones (the first chorus).
    best = float(sums.max())
    return float(np.flatnonzero(sums >= best * 0.97)[0])


def levels(energy: np.ndarray) -> list[float]:
    """Loudness per second scaled to 0..1, for drawing the song's shape under the cut picker."""
    peak = float(energy.max()) if len(energy) else 0.0
    if peak <= 0:
        return [0.0] * len(energy)
    return [round(float(v), 2) for v in energy / peak]


async def suggest(path: Path, length: float) -> tuple[float, list[float]]:
    """Where the cut should start and the song's loudness per second (empty if it cannot be decoded)."""
    try:
        energy = await asyncio.to_thread(_energy, path)
    except (subprocess.SubprocessError, OSError):
        return 0.0, []
    return highlight(energy, length), levels(energy)


async def cut(path: Path, start: float, length: float) -> bytes:
    """MP3 (plays as a ringtone on every Android) of `length` seconds from `start`, faded in and out."""
    fade_out = max(0.0, length - FADE_OUT)
    process = await asyncio.create_subprocess_exec(
        get_settings().ffmpeg_path, "-v", "error", "-nostdin", "-ss", f"{start:.2f}", "-t", f"{length:.2f}",
        "-i", str(path), "-vn", "-map_metadata", "-1",
        "-af", f"afade=t=in:d={FADE_IN},afade=t=out:st={fade_out:.2f}:d={FADE_OUT}",
        "-c:a", "libmp3lame", "-b:a", "192k", "-f", "mp3", "-",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )  # fmt: skip
    try:
        data, error = await asyncio.wait_for(process.communicate(), timeout=60)
    except TimeoutError:
        process.kill()
        await process.wait()
        raise RuntimeError("ffmpeg timed out") from None
    if process.returncode != 0 or not data:
        raise RuntimeError(error.decode(errors="replace")[-300:] or "ffmpeg failed")
    return data
