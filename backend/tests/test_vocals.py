import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.db import SessionLocal
from app.models import PlayEvent, Track, TrackLyrics, TrackVocals, User
from app.services import mixpoints, vocals
from app.services.server_config import update_config
from tests.test_mixpoints import env  # noqa: F401


@pytest.fixture(autouse=True)
def runtime(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(get_settings(), "data_dir", tmp_path)
    monkeypatch.setattr(vocals, "_state", {"state": "off", "message": None})
    monkeypatch.setattr(vocals, "_install_failed_at", 0.0)
    return tmp_path / "vocals"


class FakeWorker:
    def __init__(self) -> None:
        self.paths: list[str] = []
        self.closed = 0

    async def analyze(self, path: Path, duration: float) -> tuple[float, float]:
        self.paths.append(path.name)
        if path.name == "missing.wav":
            raise ValueError("CalledProcessError")
        return 4.5, duration - 6

    async def close(self) -> None:
        self.closed += 1


async def enable(on: bool = True) -> None:
    async with SessionLocal() as db:
        await update_config(db, {"library": {"vocal_analysis": on}})


async def test_off_by_default_and_nothing_is_installed(env, monkeypatch, runtime):  # noqa: F811
    worker = FakeWorker()
    monkeypatch.setattr(vocals, "_worker", worker)
    assert await vocals.run_once() == 0
    assert worker.paths == [] and worker.closed == 1 and not runtime.exists()
    assert vocals.state()["state"] == "off"


async def test_installs_once_then_analyzes_the_most_played_first(env, monkeypatch, runtime):  # noqa: F811
    client, headers, track_id, missing_id = env
    commands: list[tuple[str, ...]] = []

    async def run(*command):
        commands.append(tuple(map(str, command)))
        if command[1:3] == ("-m", "venv"):
            python = Path(command[3]) / "bin" / "python"
            python.parent.mkdir(parents=True)
            python.touch()

    monkeypatch.setattr(vocals, "_run", run)
    worker = FakeWorker()
    monkeypatch.setattr(vocals, "_worker", worker)
    async with SessionLocal() as db:
        user = await db.scalar(select(User))
        db.add(PlayEvent(user_id=user.id, track_id=missing_id, played_at=datetime.now(UTC)))
        (await db.get(Track, missing_id)).duration = 30
        await db.commit()
    await enable()
    assert await vocals.run_once() == 2
    assert commands[0][1:3] == ("-m", "venv")
    assert any("torch==2.8.0" in command for command in commands)
    assert any("demucs==4.0.1" in command for command in commands)
    assert vocals.installed()
    # The played (here: broken) song first.
    assert worker.paths == ["missing.wav", "beat.wav"]
    async with SessionLocal() as db:
        rows = {row.track_id: row for row in await db.scalars(select(TrackVocals))}
    assert rows[missing_id].failed and rows[missing_id].vocals_in is None
    assert (rows[track_id].vocals_in, rows[track_id].vocals_out) == (4.5, 34)
    # Done: no second install, nothing left to analyze.
    commands.clear()
    assert await vocals.run_once() == 0 and commands == []

    status = (await client.get("/api/mixpoints/status", headers=headers)).json()["vocals"]
    assert status == {"state": "ready", "message": None, "enabled": True, "total": 2, "analyzed": 2}

    # The heard voice replaces the lyrics; a changed file falls back to them until it is analyzed again.
    async def analyze(path):
        return mixpoints.MixPoints(120, 0, 30, 39)

    monkeypatch.setattr(mixpoints, "analyze_async", analyze)
    async with SessionLocal() as db:
        db.add(TrackLyrics(track_id=track_id, synced="[00:10]A\n[00:18]B\n[00:30]C", source="lrclib"))
        await db.commit()
    points = (await client.get("/api/mixpoints", params={"ids": str(track_id)}, headers=headers)).json()
    assert (points[str(track_id)]["vocals_in"], points[str(track_id)]["vocals_out"]) == (4.5, 34)
    async with SessionLocal() as db:
        (await db.get(Track, track_id)).mtime += 1
        await db.commit()
    points = (await client.get("/api/mixpoints", params={"ids": str(track_id)}, headers=headers)).json()
    assert (points[str(track_id)]["vocals_in"], points[str(track_id)]["vocals_out"]) == (10, 36)
    assert await vocals.run_once() == 1 and worker.paths[-1] == "beat.wav"


async def test_a_failed_install_waits_an_hour(env, monkeypatch, runtime):  # noqa: F811
    calls = []

    async def run(*command):
        calls.append(command)
        raise RuntimeError("No matching distribution found for torch==2.8.0")

    monkeypatch.setattr(vocals, "_run", run)
    monkeypatch.setattr(vocals, "_worker", FakeWorker())
    await enable()
    assert await vocals.run_once() == 0
    assert vocals.state() == {"state": "failed", "message": "No matching distribution found for torch==2.8.0"}
    assert await vocals.run_once() == 0 and len(calls) == 1
    monkeypatch.setattr(vocals, "_install_failed_at", -3601.0)
    monkeypatch.setattr(vocals.time, "monotonic", lambda: 0.0)
    assert await vocals.run_once() == 0 and len(calls) == 2


async def test_worker_protocol_keeps_one_process(tmp_path, monkeypatch, runtime):
    script = tmp_path / "worker.py"
    script.write_text(
        "import json, sys, os\n"
        "print(json.dumps({'ready': True}), flush=True)\n"
        "for line in sys.stdin:\n"
        "    r = json.loads(line)\n"
        "    if r['path'].endswith('bad'):\n"
        "        print(json.dumps({'error': 'broken'}), flush=True)\n"
        "    elif r['path'].endswith('crash'):\n"
        "        sys.exit(1)\n"
        "    else:\n"
        "        print(json.dumps({'vocals_in': 1.5, 'vocals_out': r['duration'] - 2, 'pid': os.getpid()}), flush=True)\n"
    )
    monkeypatch.setattr(vocals, "_python", lambda: Path(sys.executable))
    monkeypatch.setattr(vocals, "_WORKER", script)
    worker = vocals.Worker()
    try:
        assert await worker.analyze(Path("/music/a"), 100) == (1.5, 98)
        first = worker._process
        with pytest.raises(ValueError, match="broken"):
            await worker.analyze(Path("/music/bad"), 100)
        assert await worker.analyze(Path("/music/b"), 50) == (1.5, 48)
        assert worker._process is first
        with pytest.raises(RuntimeError):
            await worker.analyze(Path("/music/crash"), 50)
        assert worker._process is None
        assert await worker.analyze(Path("/music/c"), 10) == (1.5, 8)
    finally:
        await worker.close()
