"""Optional song analysis for AutoMix: where a song's voice starts and ends, from a stem separation (Demucs).

Off by default (Admin → Server → Bibliothek). When switched on, Demucs and PyTorch (CPU) are installed once into the
data folder (about 1 GB, so the image stays small), then the library is analyzed in the background, one song at a
time at low priority, most played songs first. The results replace the lyrics-based vocal bounds of `mixpoints`.
"""

import asyncio
import json
import logging
import os
import shutil
import sys
import time
import uuid
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import PlayEvent, Track, TrackVocals
from app.services.server_config import LibraryConfig, load_config
from app.services.transcode import resolve_path

log = logging.getLogger(__name__)

# Bump when the analysis changes so stored results get recomputed.
VERSION = 1
# Bump when the installed packages change so they get installed again.
_RUNTIME = 1
_PACKAGES = (
    ["--index-url", "https://download.pytorch.org/whl/cpu", "torch==2.8.0", "torchaudio==2.8.0"],
    ["demucs==4.0.1"],
)
_WORKER = Path(__file__).with_name("vocals_worker.py")
# Separating both windows of a song takes about a minute; give up on one after this long.
_SONG_TIMEOUT = 15 * 60
# The loaded model takes a lot of memory; it is released after this many seconds without work.
_WORKER_IDLE = 10 * 60

# A song that stops the worker this often in a row is stored as failed.
_MAX_CRASHES = 3

# The pause times are German time; the container itself runs in UTC.
_ZONE = ZoneInfo("Europe/Berlin")

_state: dict[str, str | None] = {"state": "off", "message": None}
_crashes: dict[uuid.UUID, int] = {}
_install_failed_at = 0.0
_loop_task: asyncio.Task | None = None


def _root() -> Path:
    return get_settings().data_dir / "vocals"


def _python() -> Path:
    return _root() / "venv" / "bin" / "python"


def _marker() -> Path:
    return _root() / f"installed-{_RUNTIME}"


def recommended_threads() -> int:
    """Half the machine's cores, so everything else on it keeps running."""
    return max(1, (os.cpu_count() or 2) // 2)


def threads(setting: int) -> int:
    """The threads the separation uses for the admin's setting (0 = recommended)."""
    return min(setting, os.cpu_count() or setting) if setting > 0 else recommended_threads()


def paused(library: LibraryConfig, now: datetime | None = None) -> bool:
    """Whether the background analysis pauses now; a window like 18:00–03:00 runs past midnight."""
    if not library.vocal_pause:
        return False
    local = (now or datetime.now(_ZONE)).astimezone(_ZONE)
    minute = local.hour * 60 + local.minute
    start, end = (int(t[:2]) * 60 + int(t[3:]) for t in (library.vocal_pause_from, library.vocal_pause_to))
    return start <= minute < end if start <= end else minute >= start or minute < end


async def _threads() -> int:
    async with SessionLocal() as db:
        return threads((await load_config(db)).library.vocal_threads)


def installed() -> bool:
    return _marker().exists() and _python().exists()


def state() -> dict[str, str | None]:
    return dict(_state)


async def _run(*command: str | Path) -> None:
    process = await asyncio.create_subprocess_exec(
        *map(str, command), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT,
    )
    output, _ = await process.communicate()
    if process.returncode != 0:
        tail = output.decode(errors="replace").strip().splitlines()[-3:]
        raise RuntimeError(" ".join(tail)[-300:] or f"exit {process.returncode}")


async def install() -> bool:
    """Installs Demucs into the data folder; False (with the reason in the state) when that fails."""
    global _install_failed_at
    _state.update(state="installing", message=None)
    root = _root()
    try:
        if root.exists():
            await asyncio.to_thread(shutil.rmtree, root)
        root.mkdir(parents=True)
        await _run(sys.executable, "-m", "venv", root / "venv")
        for packages in _PACKAGES:
            await _run(_python(), "-m", "pip", "install", "--no-cache-dir", "--disable-pip-version-check", *packages)
        _marker().touch()
    except (OSError, RuntimeError) as e:
        log.warning("Installing the song analysis failed: %s", e)
        _install_failed_at = time.monotonic()
        _state.update(state="failed", message=str(e))
        return False
    _state.update(state="ready", message=None)
    return True


class Worker:
    """The Demucs process; it keeps the model loaded between songs."""

    def __init__(self) -> None:
        self._process: asyncio.subprocess.Process | None = None
        # One request at a time: the background analysis and stems for playback share the worker.
        self._lock = asyncio.Lock()
        self._used_at = 0.0

    async def _start(self) -> asyncio.subprocess.Process:
        root = _root()
        process = await asyncio.create_subprocess_exec(
            # Lowest priority: the separation uses up to half the machine's cores and must not slow anything else down.
            "nice", "-n", "19", str(_python()), str(_WORKER),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            env={"TORCH_HOME": str(root / "torch"), "HOME": str(root), "PATH": "/usr/local/bin:/usr/bin:/bin"},
            limit=2**20,
        )
        try:
            # The first start downloads the model (80 MB).
            line = await asyncio.wait_for(_answer(process), timeout=_SONG_TIMEOUT)
            if not json.loads(line or b"{}").get("ready"):
                raise RuntimeError("Song analysis did not start")
        except BaseException:
            process.kill()
            await process.wait()
            raise
        return process

    async def analyze(self, path: Path, duration: float) -> tuple[float, float]:
        result = await self._request({"path": str(path), "duration": duration})
        return float(result["vocals_in"]), float(result["vocals_out"])

    async def instrumental(self, path: Path, length: float, out: Path) -> None:
        # A whole song for karaoke takes several times its length with one thread in the evening.
        timeout = max(_SONG_TIMEOUT, length * 8)
        await self._request({"path": str(path), "length": length, "stem": str(out)}, timeout)

    async def _request(self, request: dict, timeout: float = _SONG_TIMEOUT) -> dict:
        async with self._lock:
            try:
                return await self._send(request, timeout)
            finally:
                self._used_at = time.monotonic()

    async def _send(self, request: dict, timeout: float = _SONG_TIMEOUT) -> dict:
        if self._process is None or self._process.returncode is not None:
            self._process = await self._start()
        process = self._process
        # Asked per song, so a changed setting applies from the next song on without restarting the worker.
        request = {**request, "threads": await _threads()}
        process.stdin.write((json.dumps(request) + "\n").encode())
        try:
            await process.stdin.drain()
            line = await asyncio.wait_for(_answer(process), timeout=timeout)
        except (TimeoutError, OSError):
            await self.close()
            raise
        if not line:
            await self.close()
            raise RuntimeError("Song analysis stopped")
        result = json.loads(line)
        if "error" in result:
            raise ValueError(result["error"])
        return result

    async def close_idle(self) -> None:
        """Ends the process when it has had nothing to do for a while; the next request starts it again."""
        if not self._lock.locked() and time.monotonic() - self._used_at >= _WORKER_IDLE:
            await self.close()

    async def close(self) -> None:
        process, self._process = self._process, None
        if process is not None and process.returncode is None:
            process.kill()
            await process.wait()


async def _answer(process: asyncio.subprocess.Process) -> bytes:
    """The worker's next JSON line; anything else a library printed is skipped (empty at the end of the output)."""
    while True:
        line = await process.stdout.readline()
        if not line or line.lstrip().startswith(b"{"):
            return line
        log.debug("Song analysis printed: %s", line[:200])


_worker = Worker()


def _current():
    return select(TrackVocals.track_id).where(
        TrackVocals.track_id == Track.id, TrackVocals.version == VERSION, TrackVocals.mtime == Track.mtime
    ).exists()


async def _next_tracks(db: AsyncSession, limit: int) -> list[Track]:
    """Songs without a current analysis, the most played first."""
    plays = (
        select(PlayEvent.track_id, func.count().label("plays")).group_by(PlayEvent.track_id).subquery()
    )
    return list(await db.scalars(
        select(Track)
        .outerjoin(plays, plays.c.track_id == Track.id)
        .where(Track.is_temporary.is_(False), ~_current())
        .order_by(func.coalesce(plays.c.plays, 0).desc(), Track.created_at.desc(), Track.id)
        .limit(limit)
    ))


async def _store(
    track_id: uuid.UUID, mtime: float, bounds: tuple[float, float] | None, error: str | None = None
) -> None:
    values = {
        "version": VERSION, "mtime": mtime, "failed": bounds is None, "error": error[:500] if error else None,
        "vocals_in": bounds[0] if bounds else None, "vocals_out": bounds[1] if bounds else None,
        "analyzed_at": func.now(),
    }
    async with SessionLocal() as db:
        await db.execute(
            insert(TrackVocals).values(track_id=track_id, **values)
            .on_conflict_do_update(index_elements=[TrackVocals.track_id], set_=values)
        )
        await db.commit()


async def run_once(limit: int = 20) -> int:
    """Analyzes up to `limit` songs while the analysis is switched on; returns how many."""
    async with SessionLocal() as db:
        library = (await load_config(db)).library
        if not library.vocal_analysis and not library.karaoke:
            _state.update(state="off", message=None)
            await _worker.close()
            return 0
        tracks = await _next_tracks(db, limit) if library.vocal_analysis else []
    if not installed():
        # A failed install is retried after an hour (e.g. no internet at the moment).
        if _state["state"] == "failed" and time.monotonic() - _install_failed_at < 3600:
            return 0
        if not await install():
            return 0
    _state.update(state="ready", message=None)
    if not library.vocal_analysis or paused(library):
        # Installed for karaoke only, or paused at this time of day.
        return 0
    done = 0
    for track in tracks:
        error = None
        try:
            if not track.duration:
                raise ValueError("Unknown length")
            bounds = await _worker.analyze(resolve_path(track.path), track.duration)
        except ValueError as e:
            # The worker could not analyze this song (unreadable file, …).
            log.info("Song analysis failed for %s: %s", track.id, e)
            bounds, error = None, str(e)
        except (RuntimeError, OSError, TimeoutError) as e:
            # The worker itself stopped: not the song's fault, so it is not stored as failed (that once marked almost
            # the whole library) unless the same song keeps stopping it.
            crashes = _crashes[track.id] = _crashes.get(track.id, 0) + 1
            log.warning("Song analysis stopped at %s (%d. time): %s", track.id, crashes, e)
            if crashes < _MAX_CRASHES:
                break
            bounds, error = None, f"{type(e).__name__}: {e}"
        _crashes.pop(track.id, None)
        await _store(track.id, track.mtime, bounds, error)
        done += 1
        async with SessionLocal() as db:
            library = (await load_config(db)).library
        if not library.vocal_analysis or paused(library):
            break
    return done


# Seconds of a song's start separated for the desktop's vocal swap (its intro and the first bars after it).
STEM_SECONDS = 90.0
_STEM_DAYS = 30
_stems_pending: set[uuid.UUID] = set()
_stem_tasks: set[asyncio.Task] = set()
# Why separating a song failed, and when: it is not tried again for an hour.
_stem_errors: dict[uuid.UUID, tuple[float, str]] = {}


def stem_path(track: Track) -> Path:
    """The instrumental start of [track]'s current file."""
    return get_settings().data_dir / "stems" / f"{track.id}-{int(track.mtime or 0)}.opus"


def _clean_stems(directory: Path) -> None:
    cutoff = time.time() - _STEM_DAYS * 86400
    for path in directory.glob("*.opus"):
        if path.stat().st_mtime < cutoff:
            path.unlink(missing_ok=True)


def stem_error(track_id: uuid.UUID) -> str | None:
    failed = _stem_errors.get(track_id)
    return failed[1] if failed and time.monotonic() - failed[0] < 3600 else None


async def request_stem(db: AsyncSession, track: Track) -> str:
    """ready | pending | failed | unavailable: starts separating the song's start when the song analysis is on."""
    path = stem_path(track)
    if path.exists():
        return "ready"
    if track.id in _stems_pending:
        return "pending"
    if stem_error(track.id) is not None:
        return "failed"
    if not (await load_config(db)).library.vocal_analysis or not installed() or not track.duration:
        return "unavailable"
    path.parent.mkdir(parents=True, exist_ok=True)
    _clean_stems(path.parent)
    _separate(track.id, resolve_path(track.path), min(STEM_SECONDS, track.duration), path, _stems_pending, _stem_errors)
    return "pending"


def _separate(
    track_id: uuid.UUID,
    source: Path,
    length: float,
    path: Path,
    pending: set[uuid.UUID],
    errors: dict[uuid.UUID, tuple[float, str]],
    done: Callable[[], None] | None = None,
) -> None:
    """Writes the first `length` seconds of `source` without the voice to `path` in the background."""
    pending.add(track_id)

    async def run() -> None:
        partial = path.with_suffix(".part.opus")
        try:
            await _worker.instrumental(source, length, partial)
            partial.replace(path)
            if done is not None:
                done()
        except (ValueError, RuntimeError, OSError, TimeoutError) as e:
            log.warning("Instrumental failed for %s: %s", track_id, e)
            errors[track_id] = (time.monotonic(), str(e)[:500])
            partial.unlink(missing_ok=True)
        finally:
            pending.discard(track_id)

    task = asyncio.get_running_loop().create_task(run())
    _stem_tasks.add(task)
    task.add_done_callback(_stem_tasks.discard)


# Karaoke: whole songs without the voice, separated only when someone sings them, and only songs up to this long
# (a DJ set would take hours and gigabytes of memory).
KARAOKE_MAX_SECONDS = 15 * 60
KARAOKE_MAX_BYTES = 20 * 1024**3
# Songs separated at once; more requests wait (the client asks again) so a long queue cannot pile up work.
_KARAOKE_PARALLEL = 2
_karaoke_pending: set[uuid.UUID] = set()
_karaoke_errors: dict[uuid.UUID, tuple[float, str]] = {}


def karaoke_path(track: Track) -> Path:
    return get_settings().data_dir / "karaoke" / f"{track.id}-{int(track.mtime or 0)}.opus"


def karaoke_error(track_id: uuid.UUID) -> str | None:
    failed = _karaoke_errors.get(track_id)
    return failed[1] if failed and time.monotonic() - failed[0] < 3600 else None


def clean_karaoke(directory: Path, limit: int = KARAOKE_MAX_BYTES) -> None:
    """Deletes the songs sung longest ago (their files are touched when played) until the rest fits the limit."""
    files = []
    for path in directory.glob("*.opus"):
        if path.name.endswith(".part.opus"):
            continue
        try:
            stat = path.stat()
        except OSError:
            continue
        files.append((stat.st_mtime, stat.st_size, path))
    total = sum(size for _, size, _ in files)
    for _, size, path in sorted(files):
        if total <= limit:
            break
        path.unlink(missing_ok=True)
        total -= size


async def request_karaoke(db: AsyncSession, track: Track) -> str:
    """ready | pending | failed | unavailable: starts separating the whole song when karaoke is switched on."""
    path = karaoke_path(track)
    if path.exists():
        return "ready"
    if track.id in _karaoke_pending:
        return "pending"
    if karaoke_error(track.id) is not None:
        return "failed"
    if (
        not (await load_config(db)).library.karaoke
        or not track.duration
        or track.duration > KARAOKE_MAX_SECONDS
    ):
        return "unavailable"
    if not installed() or len(_karaoke_pending) >= _KARAOKE_PARALLEL:
        # Demucs is still being installed, or other songs are being separated: the client asks again.
        return "pending"
    path.parent.mkdir(parents=True, exist_ok=True)
    _separate(
        track.id, resolve_path(track.path), track.duration, path, _karaoke_pending, _karaoke_errors,
        done=lambda: clean_karaoke(path.parent),
    )
    return "pending"


async def bounds_for(db: AsyncSession, tracks: list[Track]) -> dict[uuid.UUID, tuple[float, float]]:
    """Stored voice bounds of tracks whose file has not changed since."""
    mtimes = {track.id: track.mtime for track in tracks}
    rows = await db.scalars(select(TrackVocals).where(
        TrackVocals.track_id.in_(mtimes), TrackVocals.version == VERSION, TrackVocals.failed.is_(False),
    ))
    return {
        row.track_id: (row.vocals_in, row.vocals_out)
        for row in rows
        if row.mtime == mtimes[row.track_id] and row.vocals_in is not None and row.vocals_out is not None
    }


async def status(db: AsyncSession) -> dict:
    library = (await load_config(db)).library
    enabled = library.vocal_analysis
    current = select(TrackVocals.failed).where(
        TrackVocals.track_id == Track.id, TrackVocals.version == VERSION, TrackVocals.mtime == Track.mtime
    ).scalar_subquery()
    total, analyzed, failed = (await db.execute(
        select(
            func.count(Track.id), func.count(Track.id).filter(current.is_(False)), func.count(Track.id).filter(current)
        ).where(Track.is_temporary.is_(False))
    )).one()
    shown = state() if enabled else {"state": "off", "message": None}
    if enabled and shown["state"] == "off":
        shown["state"] = "ready" if installed() else "installing"
    return {
        **shown, "enabled": enabled, "total": total, "analyzed": analyzed, "failed": failed,
        "karaoke": library.karaoke, "installed": installed(), "runtime": state()["state"],
        "runtime_message": state()["message"],
        "threads": threads(library.vocal_threads), "recommended_threads": recommended_threads(),
        "cpus": os.cpu_count() or 1, "paused": paused(library),
    }


async def _loop() -> None:
    while True:
        try:
            if not await run_once():
                await _worker.close_idle()
                await asyncio.sleep(60)
        except Exception:
            log.exception("Song analysis loop failed")
            await asyncio.sleep(60)


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
    await _worker.close()
