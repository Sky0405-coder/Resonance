from pathlib import Path

import pytest

from app.config import get_settings
from app.db import SessionLocal
from app.services import japanese
from app.services.server_config import update_config
from tests.test_mixpoints import env  # noqa: F401


@pytest.fixture(autouse=True)
def runtime(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Path:
    monkeypatch.setattr(get_settings(), "data_dir", tmp_path)
    monkeypatch.setattr(japanese, "_state", {"state": "off", "message": None})
    monkeypatch.setattr(japanese, "_tools", None)
    monkeypatch.setattr(japanese, "_failed_at", 0.0)
    return tmp_path / "japanese"


async def switch(on: bool) -> None:
    async with SessionLocal() as db:
        await update_config(db, {"lyrics": {"japanese_dictionary": on}})


async def test_dictionary_installs_only_when_switched_on(env, monkeypatch, runtime):  # noqa: F811
    commands: list[tuple[str, ...]] = []

    async def run(*command):
        commands.append(tuple(map(str, command)))

    monkeypatch.setattr(japanese, "_run", run)
    await switch(False)
    await japanese.ensure()
    assert commands == [] and not runtime.exists() and japanese.state()["state"] == "off"

    await switch(True)
    await japanese.ensure()
    assert japanese.state()["state"] == "ready" and japanese.installed()
    assert all("--target" in command for command in commands)
    assert any("cutlet==0.5.0" in command and "--no-deps" in command for command in commands)
    assert any("fugashi>=1.3" in command for command in commands)
    assert "def zen_to_han" in (runtime / "packages" / "mojimoji.py").read_text()
    commands.clear()
    await japanese.ensure()
    assert commands == [], "installed once"

    client, headers, *_ = env
    status = (await client.get("/api/admin/lyrics/japanese", headers=headers)).json()
    assert status == {"enabled": True, "state": "ready", "message": None}

    await switch(False)
    await japanese.ensure()
    assert japanese.state()["state"] == "off" and japanese.tools() is None


async def test_failed_install_is_reported_and_retried_later(env, monkeypatch, runtime):  # noqa: F811
    calls = []

    async def run(*command):
        calls.append(command)
        raise RuntimeError("No matching distribution found for fugashi")

    monkeypatch.setattr(japanese, "_run", run)
    monkeypatch.setattr(japanese.time, "monotonic", lambda: 100.0)
    await switch(True)
    await japanese.ensure()
    assert japanese.state() == {"state": "failed", "message": "No matching distribution found for fugashi"}
    await japanese.ensure()
    assert len(calls) == 1, "not again within the hour"
    monkeypatch.setattr(japanese.time, "monotonic", lambda: 100.0 + 3601)
    await japanese.ensure()
    assert len(calls) == 2
