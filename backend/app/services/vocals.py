"""Optional song analysis for AutoMix: where a song's voice starts and ends, from a stem separation (Demucs).

Off by default (Admin → Server → Bibliothek). When switched on, Demucs and PyTorch (CPU) are installed once into the
data folder (about 1 GB, so the image stays small), then the library is analyzed in the background, one song at a
time at low priority, most played songs first. The results replace the lyrics-based vocal bounds of `mixpoints`.
"""

import asyncio
import json
import logging
import shutil
import sys
import time
import uuid
from pathlib import Path

from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import SessionLocal
from app.models import PlayEvent, Track, TrackVocals
from app.services.server_config import load_config
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

_state: dict[str, str | None] = {"state": "off", "message": None}
_install_failed_at = 0.0
_loop_task: asyncio.Task | None = None


def _root() -> Path:
    return get_settings().data_dir / "vocals"


def _python() -> Path:
    return _root() / "venv" / "bin" / "python"


def _marker() -> Path:
    return _root() / f"installed-{_RUNTIME}"


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

    async def _start(self) -> asyncio.subprocess.Process:
        root = _root()
        process = await asyncio.create_subprocess_exec(
            str(_python()), str(_WORKER),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
            env={"TORCH_HOME": str(root / "torch"), "HOME": str(root), "PATH": "/usr/local/bin:/usr/bin:/bin"},
            limit=2**20,
        )
        try:
            # The first start downloads the model (80 MB).
            line = await asyncio.wait_for(process.stdout.readline(), timeout=_SONG_TIMEOUT)
            if not json.loads(line or b"{}").get("ready"):
                raise RuntimeError("Song analysis did not start")
        except BaseException:
            process.kill()
            await process.wait()
            raise
        return process

    async def analyze(self, path: Path, duration: float) -> tuple[float, float]:
        if self._process is None or self._process.returncode is not None:
            self._process = await self._start()
        process = self._process
        process.stdin.write((json.dumps({"path": str(path), "duration": duration}) + "\n").encode())
        try:
            await process.stdin.drain()
            line = await asyncio.wait_for(process.stdout.readline(), timeout=_SONG_TIMEOUT)
        except (TimeoutError, OSError):
            await self.close()
            raise
        if not line:
            await self.close()
            raise RuntimeError("Song analysis stopped")
        result = json.loads(line)
        if "error" in result:
            raise ValueError(result["error"])
        return float(result["vocals_in"]), float(result["vocals_out"])

    async def close(self) -> None:
        process, self._process = self._process, None
        if process is not None and process.returncode is None:
            process.kill()
            await process.wait()


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


async def _store(track_id: uuid.UUID, mtime: float, bounds: tuple[float, float] | None) -> None:
    values = {
        "version": VERSION, "mtime": mtime, "failed": bounds is None,
        "vocals_in": bounds[0] if bounds else None, "vocals_out": bounds[1] if bounds else None,
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
        if not (await load_config(db)).library.vocal_analysis:
            _state.update(state="off", message=None)
            await _worker.close()
            return 0
        tracks = await _next_tracks(db, limit)
    if not installed():
        # A failed install is retried after an hour (e.g. no internet at the moment).
        if _state["state"] == "failed" and time.monotonic() - _install_failed_at < 3600:
            return 0
        if not await install():
            return 0
    _state.update(state="ready", message=None)
    done = 0
    for track in tracks:
        try:
            if not track.duration:
                raise ValueError("Unknown length")
            bounds = await _worker.analyze(resolve_path(track.path), track.duration)
        except (ValueError, RuntimeError, OSError, TimeoutError) as e:
            log.info("Song analysis failed for %s: %s", track.id, e)
            bounds = None
        await _store(track.id, track.mtime, bounds)
        done += 1
        async with SessionLocal() as db:
            if not (await load_config(db)).library.vocal_analysis:
                break
    return done


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
    enabled = (await load_config(db)).library.vocal_analysis
    total, analyzed = (await db.execute(
        select(func.count(Track.id), func.count(Track.id).filter(_current())).where(Track.is_temporary.is_(False))
    )).one()
    current = state() if enabled else {"state": "off", "message": None}
    if enabled and current["state"] == "off":
        current["state"] = "ready" if installed() else "installing"
    return {**current, "enabled": enabled, "total": total, "analyzed": analyzed}


async def _loop() -> None:
    while True:
        try:
            if not await run_once():
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
