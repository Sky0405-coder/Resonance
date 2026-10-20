"""Precomputed frequency spectrum of a song for the app's visualizer (works on every platform, no audio tap needed)."""

import asyncio
import logging
import struct
import subprocess
import uuid
from pathlib import Path

import numpy as np
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Track
from app.services.transcode import resolve_path

log = logging.getLogger(__name__)

# Bump when the analysis or the format changes so cached files get recomputed.
VERSION = 1
FPS = 20
BANDS = 24
_RATE = 22050
_HOP = _RATE / FPS
_FRAME = 2048
_LOW, _HIGH = 40.0, 10000.0
# File layout: magic, band count, frames per second, frame count, then one byte (0–255) per band and frame.
MAGIC = b"RSP1"
_HEADER = struct.Struct("<4sBfI")


def _decode(path: Path) -> np.ndarray:
    result = subprocess.run(
        [
            get_settings().ffmpeg_path, "-v", "error", "-nostdin", "-i", str(path),
            "-ac", "1", "-ar", str(_RATE), "-f", "f32le", "-",
        ],
        capture_output=True,
        check=True,
        timeout=180,
    )
    return np.frombuffer(result.stdout, dtype=np.float32)


def _band_edges() -> np.ndarray:
    """FFT bin index ranges of logarithmically spaced bands (each at least one bin wide)."""
    freqs = np.geomspace(_LOW, _HIGH, BANDS + 1)
    bins = np.round(freqs * _FRAME / _RATE).astype(int)
    for i in range(1, len(bins)):
        bins[i] = max(bins[i], bins[i - 1] + 1)
    return bins


def analyze(path: Path) -> bytes:
    samples = _decode(path)
    count = max(0, int((len(samples) - _FRAME) // _HOP) + 1)
    if count == 0:
        return _HEADER.pack(MAGIC, BANDS, float(FPS), 0)
    edges = _band_edges()
    window = np.hanning(_FRAME).astype(np.float32)
    starts = (np.arange(count) * _HOP).astype(np.int64)
    levels = np.empty((count, BANDS), dtype=np.float32)
    # In chunks so a long file never needs one huge FFT matrix.
    for chunk in range(0, count, 1000):
        index = starts[chunk : chunk + 1000, None] + np.arange(_FRAME)[None, :]
        power = np.abs(np.fft.rfft(samples[index] * window, axis=1)) ** 2
        cumulative = np.concatenate([np.zeros((len(power), 1)), np.cumsum(power, axis=1)], axis=1)
        band_power = (cumulative[:, edges[1:]] - cumulative[:, edges[:-1]]) / np.diff(edges)
        levels[chunk : chunk + 1000] = 10 * np.log10(band_power + 1e-12)
    # Music has far more energy in the bass; tilt by +3 dB per octave so the highs stay visible.
    centers = np.sqrt(np.geomspace(_LOW, _HIGH, BANDS + 1)[:-1] * np.geomspace(_LOW, _HIGH, BANDS + 1)[1:])
    levels += 3 * np.log2(centers / _LOW)
    peak = float(np.percentile(levels, 99.5))
    scaled = np.clip((levels - (peak - 48)) / 48, 0, 1)
    body = np.round(scaled * 255).astype(np.uint8)
    return _HEADER.pack(MAGIC, BANDS, float(FPS), count) + body.tobytes()


def _cache_dir() -> Path:
    directory = get_settings().data_dir / "spectrum"
    directory.mkdir(parents=True, exist_ok=True)
    return directory


_limit = asyncio.Semaphore(2)


async def for_track(db: AsyncSession, id: uuid.UUID) -> bytes | None:
    """The cached spectrum, computed on first request (one to two seconds per song); None if not analyzable."""
    track = await db.get(Track, id)
    if track is None:
        return None
    mtime = int(track.mtime or 0)
    cached = _cache_dir() / f"{id}-{mtime}-v{VERSION}.bin"
    if cached.exists():
        return cached.read_bytes()
    async with _limit:
        if cached.exists():
            return cached.read_bytes()
        try:
            data = await asyncio.to_thread(analyze, resolve_path(track.path))
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            log.info("Spectrum analysis failed for %s: %s", track.path, e)
            return None
        for old in _cache_dir().glob(f"{id}-*.bin"):
            old.unlink(missing_ok=True)
        cached.write_bytes(data)
        return data
