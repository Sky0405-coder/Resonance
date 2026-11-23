import os
import sys
from datetime import UTC, datetime
from pathlib import Path

import pytest
from sqlalchemy import select

from app.config import get_settings
from app.db import SessionLocal
from app.models import PlayEvent, Track, TrackLyrics, TrackVocals, User
from app.services import mixpoints, vocals
from app.services.server_config import LibraryConfig, update_config
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
    assert rows[missing_id].error == "CalledProcessError" and rows[track_id].error is None
    assert (rows[track_id].vocals_in, rows[track_id].vocals_out) == (4.5, 34)
    # Done: no second install, nothing left to analyze.
    commands.clear()
    assert await vocals.run_once() == 0 and commands == []

    status = (await client.get("/api/mixpoints/status", headers=headers)).json()["vocals"]
    assert status.pop("threads") == status.pop("recommended_threads") >= 1
    assert status.pop("cpus") >= 1 and status.pop("paused") is False
    assert status == {
        "state": "ready", "message": None, "enabled": True, "total": 2, "analyzed": 1, "failed": 1,
        "karaoke": False, "installed": True, "runtime": "ready", "runtime_message": None,
    }

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


async def test_a_stopped_worker_does_not_fail_the_song(env, monkeypatch, runtime):  # noqa: F811
    _, _, track_id, missing_id = env
    (runtime / "venv" / "bin").mkdir(parents=True)
    (runtime / "venv" / "bin" / "python").touch()
    (runtime / f"installed-{vocals._RUNTIME}").touch()
    monkeypatch.setattr(vocals, "_crashes", {})
    calls: list[str] = []

    class StoppingWorker(FakeWorker):
        async def analyze(self, path: Path, duration: float) -> tuple[float, float]:
            calls.append(path.name)
            raise RuntimeError("Song analysis stopped")

    monkeypatch.setattr(vocals, "_worker", StoppingWorker())
    async with SessionLocal() as db:
        (await db.get(Track, missing_id)).duration = 30
        await db.commit()
    await enable()
    # Each run stops at the first song and stores nothing, until the same song stopped the worker three times.
    assert [await vocals.run_once() for _ in range(3)] == [0, 0, 1]
    assert len(set(calls[:3])) == 1
    async with SessionLocal() as db:
        rows = list(await db.scalars(select(TrackVocals)))
    assert len(rows) == 1 and rows[0].failed and rows[0].error == "RuntimeError: Song analysis stopped"
    assert rows[0].track_id in (track_id, missing_id)


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
        "        print(json.dumps({'vocals_in': 1.5, 'vocals_out': r['duration'] - 2, 'nice': os.nice(0), 'threads': r['threads']}), flush=True)\n"
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
        async def one_thread() -> int:
            return 1

        monkeypatch.setattr(vocals, "_threads", one_thread)
        answer = await worker._request({"path": "/music/d", "duration": 5})
        assert answer["nice"] == 19 and answer["threads"] == 1
    finally:
        await worker.close()


async def test_idle_worker_releases_the_model_until_the_next_song(tmp_path, monkeypatch, runtime):
    script = tmp_path / "worker.py"
    script.write_text(
        "import json, sys\n"
        "print(json.dumps({'ready': True}), flush=True)\n"
        "for line in sys.stdin:\n"
        "    print(json.dumps({'vocals_in': 1.0, 'vocals_out': 2.0}), flush=True)\n"
    )
    monkeypatch.setattr(vocals, "_python", lambda: Path(sys.executable))
    monkeypatch.setattr(vocals, "_WORKER", script)
    worker = vocals.Worker()
    try:
        await worker.analyze(Path("/music/a"), 10)
        first = worker._process
        await worker.close_idle()
        assert worker._process is first
        worker._used_at -= vocals._WORKER_IDLE
        await worker.close_idle()
        assert worker._process is None and first.returncode is not None
        await worker.analyze(Path("/music/b"), 10)
        assert worker._process is not None
    finally:
        await worker.close()


async def test_stem_endpoint_separates_the_start_once_and_serves_it(env, monkeypatch, runtime):  # noqa: F811
    client, headers, track_id, missing_id = env
    calls: list[float] = []

    class StemWorker(FakeWorker):
        async def instrumental(self, path: Path, length: float, out: Path) -> None:
            calls.append(length)
            out.write_bytes(b"OggS-stem")

    monkeypatch.setattr(vocals, "_worker", StemWorker())
    url = f"/api/tracks/{track_id}/stems"
    # Song analysis off: nothing to separate.
    assert (await client.post(url, headers=headers)).json()["state"] == "unavailable"
    await enable()
    monkeypatch.setattr(vocals, "installed", lambda: True)
    response = await client.post(url, headers=headers)
    assert response.json() == {"state": "pending", "seconds": 40.0}
    assert (await client.post(url, headers=headers)).json()["state"] in ("pending", "ready")
    for task in list(vocals._stem_tasks):
        await task
    assert (await client.post(url, headers=headers)).json()["state"] == "ready"
    assert calls == [40.0], "separated once, the song is 40 s long"
    response = await client.get(f"{url}/intro", headers=headers)
    assert response.status_code == 200 and response.content == b"OggS-stem"
    assert response.headers["content-type"] == "audio/ogg"
    assert (await client.get(f"/api/tracks/{missing_id}/stems/intro", headers=headers)).status_code == 404
    assert (await client.post("/api/tracks/00000000-0000-0000-0000-000000000000/stems", headers=headers)).status_code == 404


async def test_failed_stem_is_reported_and_not_retried_at_once(env, monkeypatch, runtime):  # noqa: F811
    client, headers, track_id, missing_id = env
    calls = []

    class BrokenWorker(FakeWorker):
        async def instrumental(self, path: Path, length: float, out: Path) -> None:
            calls.append(path)
            raise ValueError("CalledProcessError: ffmpeg")

    monkeypatch.setattr(vocals, "_worker", BrokenWorker())
    monkeypatch.setattr(vocals, "_stem_errors", {})
    monkeypatch.setattr(vocals, "installed", lambda: True)
    await enable()
    url = f"/api/tracks/{track_id}/stems"
    assert (await client.post(url, headers=headers)).json()["state"] == "pending"
    for task in list(vocals._stem_tasks):
        await task
    result = (await client.post(url, headers=headers)).json()
    assert result["state"] == "failed" and "ffmpeg" in result["error"]
    assert len(calls) == 1


async def enable_karaoke(on: bool = True) -> None:
    async with SessionLocal() as db:
        await update_config(db, {"library": {"karaoke": on}})


async def test_karaoke_alone_installs_demucs_but_analyzes_nothing(env, monkeypatch, runtime):  # noqa: F811
    installs = []

    async def install():
        installs.append(1)
        return True

    monkeypatch.setattr(vocals, "install", install)
    worker = FakeWorker()
    monkeypatch.setattr(vocals, "_worker", worker)
    await enable_karaoke()
    assert await vocals.run_once() == 0
    assert installs == [1] and worker.paths == [] and vocals.state()["state"] == "ready"


async def test_karaoke_separates_the_whole_song_only_when_asked(env, monkeypatch, runtime):  # noqa: F811
    client, headers, track_id, missing_id = env
    calls: list[float] = []

    class StemWorker(FakeWorker):
        async def instrumental(self, path: Path, length: float, out: Path) -> None:
            calls.append(length)
            out.write_bytes(b"OggS-karaoke")

    monkeypatch.setattr(vocals, "_worker", StemWorker())
    monkeypatch.setattr(vocals, "_karaoke_errors", {})
    url = f"/api/tracks/{track_id}/karaoke"
    # Karaoke off on the server: the app shows the lyrics with the original song.
    assert (await client.post(url, headers=headers)).json() == {"state": "unavailable"}
    await enable_karaoke()
    # Demucs not installed yet: the app asks again.
    assert (await client.post(url, headers=headers)).json() == {"state": "pending"}
    assert calls == []
    monkeypatch.setattr(vocals, "installed", lambda: True)
    assert (await client.post(url, headers=headers)).json() == {"state": "pending"}
    for task in list(vocals._stem_tasks):
        await task
    assert (await client.post(url, headers=headers)).json() == {"state": "ready"}
    assert calls == [40.0], "the whole song, once"
    response = await client.get(url, headers=headers)
    assert response.status_code == 200 and response.content == b"OggS-karaoke"
    assert response.headers["content-type"] == "audio/ogg"
    assert (await client.get(f"/api/tracks/{missing_id}/karaoke", headers=headers)).status_code == 404
    async with SessionLocal() as db:
        (await db.get(Track, missing_id)).duration = vocals.KARAOKE_MAX_SECONDS + 1
        await db.commit()
    missing = f"/api/tracks/{missing_id}/karaoke"
    assert (await client.post(missing, headers=headers)).json() == {"state": "unavailable"}, "too long"


async def test_karaoke_waits_while_two_songs_are_separated(env, monkeypatch, runtime):  # noqa: F811
    client, headers, track_id, _missing = env
    monkeypatch.setattr(vocals, "installed", lambda: True)
    monkeypatch.setattr(vocals, "_karaoke_pending", {"a", "b"})
    started = []
    monkeypatch.setattr(vocals, "_separate", lambda *args, **kwargs: started.append(args))
    await enable_karaoke()
    assert (await client.post(f"/api/tracks/{track_id}/karaoke", headers=headers)).json() == {"state": "pending"}
    assert started == []


def test_karaoke_keeps_the_songs_sung_last_within_the_limit(tmp_path):
    for age, name in enumerate(["new", "middle", "old"]):
        path = tmp_path / f"{name}.opus"
        path.write_bytes(b"x" * 100)
        os.utime(path, (1000 - age, 1000 - age))
    (tmp_path / "busy.part.opus").write_bytes(b"x" * 500)
    vocals.clean_karaoke(tmp_path, limit=250)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["busy.part.opus", "middle.opus", "new.opus"]


@pytest.mark.parametrize(
    ("window", "utc", "paused"),
    [
        # 18:00–03:00 German time runs past midnight. Winter: Germany is UTC+1.
        (("18:00", "03:00"), "2026-11-18T16:59:00", False),
        (("18:00", "03:00"), "2026-11-18T17:00:00", True),
        (("18:00", "03:00"), "2026-11-18T23:30:00", True),
        (("18:00", "03:00"), "2026-11-19T01:59:00", True),
        (("18:00", "03:00"), "2026-11-19T02:00:00", False),
        # Summer: UTC+2.
        (("18:00", "03:00"), "2026-07-01T16:00:00", True),
        (("18:00", "03:00"), "2026-07-01T01:00:00", False),
        # Within one day.
        (("09:30", "17:00"), "2026-11-18T08:29:00", False),
        (("09:30", "17:00"), "2026-11-18T08:30:00", True),
        (("09:30", "17:00"), "2026-11-18T16:00:00", False),
    ],
)
def test_pause_window_in_german_time(window, utc, paused):
    library = LibraryConfig(vocal_pause=True, vocal_pause_from=window[0], vocal_pause_to=window[1])
    now = datetime.fromisoformat(utc).replace(tzinfo=UTC)
    assert vocals.paused(library, now) is paused
    assert vocals.paused(LibraryConfig(vocal_pause_from=window[0], vocal_pause_to=window[1]), now) is False


def test_threads_follow_the_setting_and_default_to_half_the_cores(monkeypatch):
    monkeypatch.setattr(vocals.os, "cpu_count", lambda: 8)
    assert vocals.threads(0) == vocals.recommended_threads() == 4
    assert vocals.threads(1) == 1
    assert vocals.threads(6) == 6
    assert vocals.threads(64) == 8, "never more than the machine has"


async def test_paused_analysis_waits_but_karaoke_still_runs(env, monkeypatch, runtime):  # noqa: F811
    client, headers, track_id, _missing = env
    worker = FakeWorker()
    monkeypatch.setattr(vocals, "_worker", worker)
    monkeypatch.setattr(vocals, "installed", lambda: True)
    async with SessionLocal() as db:
        await update_config(db, {"library": {
            "vocal_analysis": True, "karaoke": True, "vocal_pause": True,
            "vocal_pause_from": "00:00", "vocal_pause_to": "23:59",
        }})
    monkeypatch.setattr(vocals, "paused", lambda library, now=None: library.vocal_pause)
    assert await vocals.run_once() == 0 and worker.paths == []
    started = []
    monkeypatch.setattr(vocals, "_separate", lambda *args, **kwargs: started.append(args[0]))
    monkeypatch.setattr(vocals, "_karaoke_errors", {})
    assert (await client.post(f"/api/tracks/{track_id}/karaoke", headers=headers)).json() == {"state": "pending"}
    assert started == [track_id]
    status = (await client.get("/api/mixpoints/status", headers=headers)).json()["vocals"]
    assert status["paused"] is True
    async with SessionLocal() as db:
        await update_config(db, {"library": {"vocal_pause": False}})
    assert await vocals.run_once() == 2


async def test_bad_pause_time_is_rejected(env):  # noqa: F811
    client, headers, *_ = env
    response = await client.patch(
        "/api/admin/config", json={"library": {"vocal_pause_from": "25:00"}}, headers=headers
    )
    assert response.status_code == 422
