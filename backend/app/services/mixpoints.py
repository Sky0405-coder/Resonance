"""Tempo, beat grid and mix points of a song for AutoMix (beat-matched transitions in the app)."""

import asyncio
import logging
import subprocess
import uuid
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from sqlalchemy import select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Track, TrackMixPoints
from app.services.transcode import resolve_path

log = logging.getLogger(__name__)

# Bump when the analysis changes so stored results get recomputed.
VERSION = 1
_RATE = 11025
_HOP = 256  # ~23 ms per frame
_FRAME = 1024
_MIN_BPM, _MAX_BPM = 70.0, 180.0


@dataclass
class MixPoints:
    bpm: float | None
    # Where the next song starts playing: the first beat after leading silence.
    mix_in: float
    # Where this song starts fading out (a beat, so the next one can start on the beat), and its audible end.
    mix_out: float
    end: float


def _decode(path: Path) -> np.ndarray:
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-ac", "1", "-ar", str(_RATE), "-f", "f32le", "-"],
        capture_output=True,
        check=True,
        timeout=120,
    )
    return np.frombuffer(result.stdout, dtype=np.float32)


def _frames(samples: np.ndarray) -> np.ndarray:
    count = 1 + (len(samples) - _FRAME) // _HOP
    index = np.arange(_FRAME)[None, :] + _HOP * np.arange(count)[:, None]
    return samples[index] * np.hanning(_FRAME).astype(np.float32)


def _smooth(values: np.ndarray, seconds: float) -> np.ndarray:
    width = max(1, int(seconds * _RATE / _HOP))
    return np.convolve(values, np.ones(width) / width, mode="same")


def _tempo(onset: np.ndarray) -> float | None:
    """Autocorrelation of the onset strength with a preference around 120 BPM (as most beat trackers do)."""
    fps = _RATE / _HOP
    min_lag, max_lag = int(np.ceil(fps * 60 / _MAX_BPM)), int(fps * 60 / _MIN_BPM)
    if len(onset) < max_lag * 8:
        return None
    centered = onset - onset.mean()
    spectrum = np.fft.rfft(centered, n=2 * len(centered))
    corr = np.fft.irfft(spectrum * np.conj(spectrum))[: max_lag + 2]
    if corr[0] <= 0:
        return None
    corr /= corr[0]
    lags = np.arange(min_lag, max_lag + 1)
    bpms = 60 * fps / lags
    prior = np.exp(-0.5 * (np.log2(bpms / 120) / 0.9) ** 2)
    # A beat period also correlates at twice its length; reward lags whose double agrees.
    double = np.array([corr[min(2 * lag, len(corr) - 1)] if 2 * lag < len(corr) else 0 for lag in lags])
    score = (corr[lags] + 0.5 * np.clip(double, 0, None)) * prior
    best = int(np.argmax(score))
    if corr[lags[best]] < 0.05:
        return None
    # Parabolic interpolation for a sub-frame period.
    lag = float(lags[best])
    if 0 < best < len(lags) - 1:
        a, b, c = score[best - 1], score[best], score[best + 1]
        denominator = a - 2 * b + c
        if denominator != 0:
            lag += 0.5 * (a - c) / denominator
    return 60 * fps / _refine(onset, lag)


def _refine(onset: np.ndarray, lag: float) -> float:
    """Fine-tune the beat period so one grid fits the whole song (autocorrelation alone is off by up to ~1 %)."""
    frames = np.arange(len(onset))
    best_lag, best_score = lag, -1.0
    for candidate in lag * (1 + np.linspace(-0.015, 0.015, 61)):
        for phase in np.arange(0, candidate, 1.0):
            score = float(np.interp(np.arange(phase, len(onset) - 1, candidate), frames, onset).sum())
            if score > best_score:
                best_lag, best_score = candidate, score
    return best_lag


def _beat_near(onset: np.ndarray, period: float, center: int, span: int) -> float:
    """The beat phase (in frames) that best fits the onsets around `center`, as an absolute frame position."""
    start, stop = max(0, center - span), min(len(onset), center + span)
    window = onset[start:stop]
    if len(window) < period * 2:
        return float(center)
    best_phase, best_score = 0.0, -1.0
    for phase in np.arange(0, period, 0.5):
        positions = np.arange(phase, len(window) - 1, period)
        score = float(np.interp(positions, np.arange(len(window)), window).sum())
        if score > best_score:
            best_phase, best_score = phase, score
    beat = start + best_phase
    # Nearest grid point to the center.
    return beat + round((center - beat) / period) * period


def analyze(path: Path) -> MixPoints:
    samples = _decode(path)
    duration = len(samples) / _RATE
    if len(samples) < _FRAME * 4:
        return MixPoints(None, 0.0, max(0.0, duration - 1), duration)
    frames = _frames(samples)
    rms = np.sqrt(np.mean(frames**2, axis=1) + 1e-12)
    level = 20 * np.log10(rms)
    loud = float(np.percentile(level, 80))
    # Frame times at the window centers, where onsets and levels show up.
    offset = _FRAME / 2 / _RATE
    seconds = np.arange(len(level)) * _HOP / _RATE + offset

    smooth = _smooth(level, 1.0)
    audible = np.nonzero(level > loud - 35)[0]
    start = float(seconds[audible[0]]) if len(audible) else 0.0
    end = float(seconds[audible[-1]] + offset) if len(audible) else duration
    strong = np.nonzero(smooth > loud - 9)[0]
    last_strong = float(seconds[strong[-1]]) if len(strong) else end

    magnitude = np.abs(np.fft.rfft(frames, axis=1)).astype(np.float32)
    flux = np.diff(np.log1p(100 * magnitude), axis=0)
    onset = np.concatenate([[0.0], np.clip(flux, 0, None).sum(axis=1)])
    onset = np.clip(onset - _smooth(onset, 0.5), 0, None)

    bpm = _tempo(onset)
    # Fade over about 16 beats, ending a few seconds after the last loud part (or at the end of the audio).
    fade = min(14.0, max(6.0, 16 * 60 / bpm)) if bpm else 8.0
    out = max(start, min(end, last_strong + 4) - fade)
    mix_in = start
    if bpm:
        period = _RATE / _HOP * 60 / bpm
        span = int(8 * period)

        def to_frame(t: float) -> int:
            return int((t - offset) * _RATE / _HOP)

        mix_in = _beat_near(onset, period, to_frame(start), span) * _HOP / _RATE + offset
        if mix_in < start - 0.05:
            mix_in += period * _HOP / _RATE
        beat_out = _beat_near(onset, period, to_frame(out), span) * _HOP / _RATE + offset
        out = beat_out if beat_out <= end - 4 else out
    return MixPoints(
        bpm=round(float(bpm), 2) if bpm else None,
        mix_in=round(max(0.0, float(mix_in)), 3),
        mix_out=round(max(0.0, float(out)), 3),
        end=round(float(end), 3),
    )


_limit = asyncio.Semaphore(2)


async def analyze_async(path: Path) -> MixPoints | None:
    async with _limit:
        try:
            return await asyncio.to_thread(analyze, path)
        except (OSError, subprocess.SubprocessError, ValueError) as e:
            log.info("Mix point analysis failed for %s: %s", path, e)
            return None


async def for_tracks(db: AsyncSession, ids: list[uuid.UUID]) -> dict[uuid.UUID, MixPoints | None]:
    """Stored results, analyzing tracks that are new or whose file changed (about half a second each)."""
    tracks = {track.id: track for track in await db.scalars(select(Track).where(Track.id.in_(ids)))}
    stored = {row.track_id: row for row in await db.scalars(select(TrackMixPoints).where(TrackMixPoints.track_id.in_(ids)))}
    result: dict[uuid.UUID, MixPoints | None] = {}
    for id in ids:
        track = tracks.get(id)
        if track is None:
            result[id] = None
            continue
        row = stored.get(id)
        if row is not None and row.version == VERSION and row.mtime == track.mtime:
            result[id] = MixPoints(row.bpm, row.mix_in, row.mix_out, row.end)
            continue
        points = await analyze_async(resolve_path(track.path))
        result[id] = points
        if points is not None:
            values = {
                "version": VERSION,
                "mtime": track.mtime,
                "bpm": points.bpm,
                "mix_in": points.mix_in,
                "mix_out": points.mix_out,
                "end": points.end,
            }
            await db.execute(
                insert(TrackMixPoints)
                .values(track_id=id, **values)
                .on_conflict_do_update(index_elements=[TrackMixPoints.track_id], set_=values)
            )
            await db.commit()
    return result
