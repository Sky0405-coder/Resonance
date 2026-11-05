"""A playlist rendered as one MP3 mix with AutoMix's transitions (beat-matched, on phrases, with a bass swap), with
a chapter per song. Rendered once per order and set of transitions, in the background, one at a time."""

import asyncio
import hashlib
import json
import logging
import math
import subprocess
import tempfile
import time
import uuid
from dataclasses import dataclass, field
from itertools import pairwise
from pathlib import Path

import numpy as np
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import Playlist, PlaylistEntry, PlaylistTransition, Track
from app.services import mixpoints
from app.services.mixpoints import MixPoints
from app.services.transcode import resolve_path

log = logging.getLogger(__name__)

RATE = 44100
# Bump when the sound of a render changes, so cached files are made again.
VERSION = 1
MAX_SONGS = 150
KEEP_DAYS = 7
_MAX_TEMPO_CHANGE = 0.16
_BASS_CUTOFF = 150.0


@dataclass
class Plan:
    """One transition in song times (seconds): the outgoing song blends from `start` for `duration` seconds of
    output; the incoming one starts at `incoming_start`, plays at `speed` during the blend and returns to its own
    tempo over `ramp` seconds after it; the bass swaps `swap` seconds into the blend."""

    start: float
    incoming_start: float
    duration: float
    swap: float
    speed: float = 1.0
    ramp: float = 0.0


@dataclass
class Status:
    state: str = "idle"  # idle | running | done | failed
    progress: float = 0.0
    key: str | None = None
    error: str | None = None
    task: asyncio.Task | None = field(default=None, repr=False)


_status: dict[uuid.UUID, Status] = {}
_limit = asyncio.Semaphore(1)


def _speed(outgoing_bpm: float | None, incoming_bpm: float | None) -> float | None:
    """The incoming song's speed that matches the outgoing tempo (double/half time count), None when too far."""
    if not outgoing_bpm or not incoming_bpm or outgoing_bpm <= 0 or incoming_bpm <= 0:
        return None
    ratio = outgoing_bpm / incoming_bpm
    while ratio > 1.5:
        ratio /= 2
    while ratio < 0.75:
        ratio *= 2
    return ratio if abs(ratio - 1) <= _MAX_TEMPO_CHANGE else None


def plan(outgoing: MixPoints | None, incoming: MixPoints | None, custom: PlaylistTransition | None = None) -> Plan:
    """Like the app's AutoMix plan: the next song's intro (or 8 beats) runs under the current one, the bass swaps on
    a phrase after the analyzed mix-out point (a full phrase with section starts), the current song fades after it."""
    if outgoing is None or incoming is None:
        end = outgoing.end if outgoing else None
        start = max(0.0, (end or 0) - 8) if end else 0.0
        return Plan(start, incoming.mix_in if incoming else 0.0, 6.0, 3.0)
    speed = _speed(outgoing.bpm, incoming.bpm)
    beat = 60 / outgoing.bpm if outgoing.bpm else None
    if custom is not None:
        length = custom.bars * 4 * beat if beat else custom.bars * 2.0
        length = max(2.0, min(length, outgoing.end - custom.start))
        return Plan(custom.start, custom.incoming_start, length, length / 2, speed or 1.0, 8 * beat if beat and speed else 0)
    if speed is None or beat is None:
        # Different tempos: a short crossfade at the end, the next song from its first beat.
        start = max(outgoing.mix_out, outgoing.end - 8)
        duration = max(2.0, min(6.0, outgoing.end - start))
        return Plan(start, incoming.mix_in, duration, duration / 2)

    def beats(count: int) -> float:
        return count * beat

    intro = None if incoming.intro_end is None else incoming.intro_end - incoming.mix_in
    from_intro = intro is not None and intro / speed >= beats(4) - 0.05
    lead = min(intro / speed, beats(16)) if from_intro else beats(8)
    lead = max(1, round(lead / beat)) * beat
    tail = min(max(lead, beats(4)), beats(8))
    duration = lead + tail
    swap_after = beats(16) if outgoing.phrases is not None else beats(8)
    start = outgoing.mix_out + swap_after - lead
    if start + duration > outgoing.end:
        bar = beats(4)
        start -= math.ceil((start + duration - outgoing.end) / bar - 1e-4) * bar
    if start < outgoing.end / 2:
        start = min(outgoing.mix_out, outgoing.end / 2)
        duration = min(duration, outgoing.end - start)
        lead = min(lead, duration / 2)
    incoming_start = incoming.intro_end - lead * speed if from_intro else incoming.mix_in
    return Plan(start, max(0.0, incoming_start), duration, lead, speed, beats(16))


def decode(path: Path) -> np.ndarray:
    """Stereo float samples at 44.1 kHz."""
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-nostdin", "-i", str(path), "-ac", "2", "-ar", str(RATE), "-f", "f32le", "-"],
        capture_output=True,
        check=True,
        timeout=300,
    )
    return np.frombuffer(result.stdout, dtype=np.float32).reshape(-1, 2)


def split_bass(audio: np.ndarray, cutoff: float = _BASS_CUTOFF) -> tuple[np.ndarray, np.ndarray]:
    """(low, high) parts of a stretch of audio, crossing over smoothly within an octave around `cutoff`."""
    if len(audio) == 0:
        return audio, audio
    spectrum = np.fft.rfft(audio, axis=0)
    freqs = np.fft.rfftfreq(len(audio), 1 / RATE)
    octave = np.clip(np.log2(np.maximum(freqs, 1e-3) / cutoff) + 0.5, 0, 1)
    low_gain = np.cos(octave * np.pi / 2) ** 2
    low = np.fft.irfft(spectrum * low_gain[:, None], n=len(audio), axis=0).astype(np.float32)
    return low, audio - low


def stretch(audio: np.ndarray, start: float, speeds: np.ndarray) -> tuple[np.ndarray, float]:
    """Plays `audio` from `start` (samples) with a speed per output sample (pitch follows, like a turntable);
    returns the output and where in `audio` it ended."""
    positions = start + np.concatenate([[0.0], np.cumsum(speeds[:-1])])
    positions = positions[positions < len(audio) - 1]
    index = np.arange(len(audio))
    out = np.stack([np.interp(positions, index, audio[:, c]) for c in range(2)], axis=1).astype(np.float32)
    end = float(positions[-1] + speeds[len(positions) - 1]) if len(positions) else start
    return out, end


def blend(outgoing: np.ndarray, incoming: np.ndarray, swap: int) -> np.ndarray:
    """The current song fades out after the swap, the next one fades in before it; the bass belongs to one song at a
    time and changes hands at the swap (over a quarter second)."""
    length = min(len(outgoing), len(incoming))
    outgoing, incoming = outgoing[:length], incoming[:length]
    t = np.arange(length, dtype=np.float32)
    swap = int(np.clip(swap, 1, max(1, length - 1)))
    fade_in = np.where(t < swap, np.sin(np.pi / 2 * t / swap), 1.0)
    fade_out = np.where(t < swap, 1.0, np.cos(np.pi / 2 * np.clip((t - swap) / max(1, length - swap), 0, 1)))
    w = np.clip((t - swap) / (0.25 * RATE) + 0.5, 0, 1)
    out_low, out_high = split_bass(outgoing)
    in_low, in_high = split_bass(incoming)
    mixed = (fade_out * (1 - w))[:, None] * out_low + fade_out[:, None] * out_high
    mixed += (fade_in * w)[:, None] * in_low + fade_in[:, None] * in_high
    return mixed.astype(np.float32)


def _gain(track: Track) -> float:
    """ReplayGain toward a common loudness (the app normalizes the same way), never louder than +6 dB."""
    gain = track.replaygain_track_gain if track.replaygain_track_gain is not None else track.replaygain_album_gain
    return 10 ** (min(6.0, gain) / 20) if gain is not None else 1.0


def render_songs(
    songs: list[tuple[Track, MixPoints | None]],
    plans: list[Plan],
    write,
    progress=lambda value: None,
) -> tuple[list[float], float]:
    """Writes the mix as float stereo blocks through `write`; returns where each song starts and the length (s)."""
    starts: list[float] = []
    written = 0
    current: np.ndarray | None = None
    position = 0.0  # where the current song continues (samples of its own audio)
    head: np.ndarray | None = None  # the current song's already rendered start (the blend and the ramp back)
    for index, (track, _) in enumerate(songs):
        audio = decode(resolve_path(track.path)) * _gain(track)
        if current is None:
            current, position = audio, 0.0
            starts.append(0.0)
            progress(index / len(songs))
            continue
        p = plans[index - 1]
        # The current song up to the transition (after the part already rendered with the previous blend).
        start = max(int(p.start * RATE), int(position))
        if head is not None:
            write(head)
            written += len(head)
            head = None
        write(np.clip(current[int(position) : start], -1, 1))
        written += max(0, start - int(position))
        length = int(p.duration * RATE)
        outgoing = current[start : start + length]
        ramp = int(p.ramp * RATE)
        speeds = np.concatenate([
            np.full(len(outgoing), p.speed, dtype=np.float64),
            np.linspace(p.speed, 1.0, ramp, dtype=np.float64) if ramp else np.zeros(0),
        ])
        rendered, position = stretch(audio, p.incoming_start * RATE, speeds)
        mixed = blend(outgoing, rendered[: len(outgoing)], int(p.swap * RATE))
        starts.append((written + int(p.swap * RATE)) / RATE)
        head = np.clip(np.concatenate([mixed, rendered[len(mixed) :]]), -1, 1)
        current = audio
        progress(index / len(songs))
    if current is not None:
        if head is not None:
            write(head)
            written += len(head)
        rest = current[int(position) :]
        write(np.clip(rest, -1, 1))
        written += len(rest)
    progress(1.0)
    return starts, written / RATE


def _dir() -> Path:
    path = get_settings().data_dir / "mix_renders"
    path.mkdir(parents=True, exist_ok=True)
    return path


def file_for(playlist_id: uuid.UUID) -> Path:
    return _dir() / f"{playlist_id}.mp3"


def _cleanup() -> None:
    cutoff = time.time() - KEEP_DAYS * 86400
    for path in _dir().iterdir():
        if path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)


async def _load(db: AsyncSession, playlist_id: uuid.UUID):
    entries = list(await db.scalars(
        select(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist_id).order_by(PlaylistEntry.position)
    ))[:MAX_SONGS]
    tracks = {t.id: t for t in await db.scalars(select(Track).where(Track.id.in_({e.track_id for e in entries})))}
    transitions = {
        (t.from_track_id, t.to_track_id): t
        for t in await db.scalars(select(PlaylistTransition).where(PlaylistTransition.playlist_id == playlist_id))
    }
    ordered = [tracks[e.track_id] for e in entries if e.track_id in tracks]
    return ordered, transitions


def cache_key(tracks: list[Track], transitions: dict) -> str:
    parts = [f"v{VERSION}:{mixpoints.VERSION}"]
    parts += [f"{t.id}:{t.mtime}" for t in tracks]
    parts += sorted(f"{a}>{b}:{t.start}:{t.incoming_start}:{t.bars}" for (a, b), t in transitions.items())
    return hashlib.sha1("|".join(parts).encode()).hexdigest()[:16]


def status(playlist_id: uuid.UUID) -> Status:
    return _status.get(playlist_id) or Status()


async def current_key(db: AsyncSession, playlist_id: uuid.UUID) -> str:
    tracks, transitions = await _load(db, playlist_id)
    return cache_key(tracks, transitions)


def ready(playlist_id: uuid.UUID, key: str) -> bool:
    path = file_for(playlist_id)
    meta = path.with_suffix(".json")
    if not path.exists() or not meta.exists():
        return False
    try:
        return json.loads(meta.read_text()).get("key") == key
    except (OSError, ValueError):
        return False


async def _render(playlist_id: uuid.UUID, state: Status) -> None:
    async with _limit:
        state.state = "running"
        async with SessionLocal() as db:
            playlist = await db.get(Playlist, playlist_id)
            tracks, transitions = await _load(db, playlist_id)
            points = await mixpoints.for_tracks(db, [t.id for t in tracks])
        songs = [(t, points.get(t.id)) for t in tracks]
        plans = [
            plan(a[1], b[1], transitions.get((a[0].id, b[0].id))) for a, b in pairwise(songs)
        ]
        path = file_for(playlist_id)
        name = playlist.name if playlist else "Mix"
        loop = asyncio.get_running_loop()

        def progress(value: float) -> None:
            loop.call_soon_threadsafe(setattr, state, "progress", round(value * 0.98, 3))

        await asyncio.to_thread(_encode, songs, plans, path, name, progress)
        path.with_suffix(".json").write_text(json.dumps({"key": state.key, "name": name}))
        state.progress = 1.0
        state.state = "done"


def _encode(songs, plans, path: Path, name: str, progress) -> None:
    """Pipes the mix into LAME, then adds the title and chapters (song starts) in a second, copying pass."""
    with tempfile.TemporaryDirectory(dir=path.parent) as scratch:
        raw = Path(scratch) / "mix.mp3"
        encoder = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-nostdin", "-y", "-f", "f32le", "-ar", str(RATE), "-ac", "2", "-i", "-",
             "-c:a", "libmp3lame", "-b:a", "256k", str(raw)],
            stdin=subprocess.PIPE,
        )
        try:
            starts, total = render_songs(
                songs, plans, lambda block: encoder.stdin.write(block.astype(np.float32).tobytes()), progress
            )
        finally:
            encoder.stdin.close()
            encoder.wait(timeout=600)
        if encoder.returncode != 0:
            raise RuntimeError("Encoding failed")
        metadata = Path(scratch) / "chapters.txt"
        metadata.write_text(chapters(name, [track for track, _ in songs], starts, total))
        subprocess.run(
            ["ffmpeg", "-v", "error", "-nostdin", "-y", "-i", str(raw), "-i", str(metadata), "-map_metadata", "1",
             "-map_chapters", "1", "-c", "copy", "-id3v2_version", "3", str(path)],
            check=True,
            timeout=600,
        )


def chapters(name: str, tracks: list[Track], starts: list[float], total: float) -> str:
    """FFmpeg metadata with the mix's title and a chapter per song (players show and skip by them)."""
    lines = [";FFMETADATA1", f"title={_escape(name)}", "artist=Resonance"]
    for track, begin, end in zip(tracks, starts, [*starts[1:], total], strict=True):
        lines += [
            "[CHAPTER]",
            "TIMEBASE=1/1000",
            f"START={int(begin * 1000)}",
            f"END={int(end * 1000)}",
            f"title={_escape(f'{track.artist_credit} - {track.title}')}",
        ]
    return "\n".join(lines) + "\n"


def _escape(value: str) -> str:
    for char in ("\\", "=", ";", "#", "\n"):
        value = value.replace(char, "\\" + char)
    return value


async def start(db: AsyncSession, playlist_id: uuid.UUID) -> Status:
    """Starts rendering unless the current version is rendering or ready."""
    key = await current_key(db, playlist_id)
    state = _status.get(playlist_id)
    if state is not None and state.key == key and state.state == "running":
        return state
    if ready(playlist_id, key):
        _status[playlist_id] = Status("done", 1.0, key)
        return _status[playlist_id]
    _cleanup()
    state = Status("running", 0.0, key)
    _status[playlist_id] = state

    async def run() -> None:
        try:
            await _render(playlist_id, state)
        except Exception as e:
            log.exception("Rendering the mix of %s failed", playlist_id)
            state.state, state.error = "failed", str(e)

    state.task = asyncio.create_task(run())
    return state
