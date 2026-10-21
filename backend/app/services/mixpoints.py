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

from app.db import SessionLocal
from app.models import Track, TrackMixPoints
from app.services.transcode import resolve_path

log = logging.getLogger(__name__)

# Bump when the analysis changes so stored results get recomputed.
VERSION = 3
_RATE = 11025
_HOP = 256  # ~23 ms per frame
_FRAME = 1024
_MIN_BPM, _MAX_BPM = 70.0, 180.0
_MAJOR = np.array([6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88])
_MINOR = np.array([6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17])
_CAMELOT_MAJOR = ("8B", "3B", "10B", "5B", "12B", "7B", "2B", "9B", "4B", "11B", "6B", "1B")
_CAMELOT_MINOR = ("5A", "12A", "7A", "2A", "9A", "4A", "11A", "6A", "1A", "8A", "3A", "10A")


@dataclass
class MixPoints:
    bpm: float | None
    # Where the next song starts playing: the first beat after leading silence.
    mix_in: float
    # Where this song starts fading out (a beat, so the next one can start on the beat), and its audible end.
    mix_out: float
    end: float
    key: str | None = None
    key_confidence: float | None = None


def _decode(path: Path) -> np.ndarray:
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-ac", "1", "-ar", str(_RATE), "-f", "f32le", "-"],
        capture_output=True,
        check=True,
        timeout=120,
    )
    return np.frombuffer(result.stdout, dtype=np.float32)


def _frames(samples: np.ndarray, frame: int = _FRAME, hop: int = _HOP) -> np.ndarray:
    count = 1 + (len(samples) - frame) // hop
    index = np.arange(frame)[None, :] + hop * np.arange(count)[:, None]
    return samples[index] * np.hanning(frame).astype(np.float32)


def _key(samples: np.ndarray) -> tuple[str | None, float | None]:
    if len(samples) < 4096 * 4:
        return None, None
    frames = _frames(samples, 4096, 2048)
    rms = np.sqrt(np.mean(frames**2, axis=1))
    if float(rms.max()) < 1e-5:
        return None, None
    magnitude = np.abs(np.fft.rfft(frames[rms > np.percentile(rms, 30)], axis=1))
    frequencies = np.fft.rfftfreq(4096, 1 / _RATE)
    bins = (frequencies >= 55) & (frequencies <= 4000)
    # Semitones relative to A4, shifted so C is pitch class zero.
    classes = (np.rint(12 * np.log2(frequencies[bins] / 440)).astype(int) + 9) % 12
    chroma = np.bincount(classes, weights=np.log1p(magnitude[:, bins]).sum(axis=0), minlength=12)
    if float(np.std(chroma)) < 1e-12:
        return None, None
    scores = [
        (float(np.corrcoef(chroma, np.roll(profile, root))[0, 1]), code)
        for profile, codes in ((_MAJOR, _CAMELOT_MAJOR), (_MINOR, _CAMELOT_MINOR))
        for root, code in enumerate(codes)
    ]
    scores.sort(reverse=True)
    best, code = scores[0]
    if best < 0.3:
        return None, None
    return code, round(float(np.clip(best - scores[1][0], 0, 1)), 3)


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
        # Prefer the start of a 16-beat phrase (counted from the first beat) up to 8 beats away: songs change
        # sections there, so the transition lands where a DJ would start it.
        beat = 60 / bpm
        phrase = 16 * beat
        boundary = mix_in + round((out - mix_in) / phrase) * phrase
        if boundary > mix_in and abs(boundary - out) <= 8 * beat and boundary <= end - 4:
            out = boundary
    key, confidence = _key(samples)
    return MixPoints(
        bpm=round(float(bpm), 2) if bpm else None,
        mix_in=round(max(0.0, float(mix_in)), 3),
        mix_out=round(max(0.0, float(out)), 3),
        end=round(float(end), 3),
        key=key,
        key_confidence=confidence,
    )


_limit = asyncio.Semaphore(2)
_background_limit = asyncio.Semaphore(1)
# Include waiting callers so background work yields before both slots fill up.
_analysis_requests = 0


async def analyze_async(path: Path) -> MixPoints | None:
    global _analysis_requests
    _analysis_requests += 1
    try:
        async with _limit:
            try:
                return await asyncio.to_thread(analyze, path)
            except (OSError, subprocess.SubprocessError, ValueError) as e:
                log.info("Mix point analysis failed for %s: %s", path, e)
                return None
    finally:
        _analysis_requests -= 1


async def for_tracks(db: AsyncSession, ids: list[uuid.UUID]) -> dict[uuid.UUID, MixPoints | None]:
    """Stored results, analyzing tracks that are new or whose file changed (about half a second each)."""
    tracks = {track.id: track for track in await db.scalars(select(Track).where(Track.id.in_(ids)))}
    stored = {row.track_id: row for row in await db.scalars(
        select(TrackMixPoints).where(TrackMixPoints.track_id.in_(ids))
    )}
    result: dict[uuid.UUID, MixPoints | None] = {}
    for id in ids:
        track = tracks.get(id)
        if track is None:
            result[id] = None
            continue
        row = stored.get(id)
        if row is not None and row.version == VERSION and row.mtime == track.mtime:
            result[id] = None if row.failed else MixPoints(
                row.bpm, row.mix_in, row.mix_out, row.end, row.key, row.key_confidence
            )
            continue
        points = await analyze_async(resolve_path(track.path))
        result[id] = points
        values = {
            "version": VERSION,
            "mtime": track.mtime,
            "failed": points is None,
            "bpm": points.bpm if points else None,
            "mix_in": points.mix_in if points else None,
            "mix_out": points.mix_out if points else None,
            "end": points.end if points else None,
            "key": points.key if points else None,
            "key_confidence": points.key_confidence if points else None,
        }
        await db.execute(
            insert(TrackMixPoints)
            .values(track_id=id, **values)
            .on_conflict_do_update(index_elements=[TrackMixPoints.track_id], set_=values)
        )
        await db.commit()
    return result


_loop_task: asyncio.Task | None = None


async def run_once() -> None:
    async with SessionLocal() as db:
        current = select(TrackMixPoints.track_id).where(TrackMixPoints.version == VERSION)
        ids = list(await db.scalars(
            select(Track.id)
            .where(Track.is_temporary.is_(False), ~Track.id.in_(current))
            .order_by(Track.created_at, Track.id)
            .limit(120)
        ))
    for id in ids:
        # At most 720 per hour; leave both analysis slots available to on-demand requests between ticks.
        while True:
            await asyncio.sleep(5)
            if not _analysis_requests and not _limit.locked() and not _background_limit.locked():
                break
        try:
            async with _background_limit, SessionLocal() as db:
                await for_tracks(db, [id])
        except Exception:
            log.exception("Background mix point analysis failed for %s", id)


async def _loop() -> None:
    while True:
        await asyncio.sleep(60)
        try:
            await run_once()
        except Exception:
            log.exception("Mix point analysis loop failed")


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
