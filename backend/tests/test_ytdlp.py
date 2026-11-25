import sys
from pathlib import Path

import pytest

from app.config import get_settings
from app.services import ytdlp
from app.services.sources import bandcamp, soundcloud, youtube


@pytest.fixture(autouse=True)
def data(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setattr(get_settings(), "data_dir", tmp_path)
    # The real yt-dlp modules go back in place afterwards, so other tests keep the classes they imported.
    saved = {name: module for name, module in sys.modules.items() if name.split(".")[0] in ("yt_dlp", "yt_dlp_ejs")}
    sources = [(source, source.yt_dlp) for source in (youtube, soundcloud, bandcamp)]
    path = list(sys.path)
    yield tmp_path
    for name in [name for name in sys.modules if name.split(".")[0] in ("yt_dlp", "yt_dlp_ejs")]:
        del sys.modules[name]
    sys.modules.update(saved)
    for source, module in sources:
        source.yt_dlp = module
    sys.path[:] = path
    ytdlp._active = None


def fake_package(packages: Path, version: str, broken: bool = False) -> None:
    package = packages / "yt_dlp"
    package.mkdir(parents=True, exist_ok=True)
    (package / "__init__.py").write_text("raise ImportError('broken')\n" if broken else "FAKE = True\n")
    (package / "version.py").write_text(f"__version__ = {version!r}\n")


def test_version_key_orders_dates_and_post_releases():
    assert ytdlp.version_key("2026.11.23") > ytdlp.version_key("2026.10.26")
    assert ytdlp.version_key("2026.1.5") < ytdlp.version_key("2026.10.1")
    assert ytdlp.version_key("2021.1.24.post1") > ytdlp.version_key("2021.1.24")


async def test_update_installs_the_newer_version_and_switches_the_sources(monkeypatch, data):
    bundled = ytdlp.current_version()
    commands: list[list[str]] = []

    async def latest():
        return "2999.1.1", ["yt-dlp-ejs==0.8.0"]

    async def run(*command):
        commands.append(list(map(str, command)))
        fake_package(Path(commands[-1][commands[-1].index("--target") + 1]), "2999.1.1")

    monkeypatch.setattr(ytdlp, "_latest", latest)
    monkeypatch.setattr(ytdlp, "_run", run)
    old = data / "yt-dlp" / "2026.1.1"
    fake_package(old / "packages", "2026.1.1")
    (old / "installed").touch()

    assert await ytdlp.update() is True
    assert "--no-deps" in commands[0]
    assert commands[0][-2:] == ["yt-dlp==2999.1.1", "yt-dlp-ejs==0.8.0"]
    assert ytdlp.current_version() == "2999.1.1"
    assert youtube.yt_dlp is soundcloud.yt_dlp is bandcamp.yt_dlp
    assert youtube.yt_dlp.FAKE
    assert (data / "yt-dlp" / "2999.1.1" / "installed").exists()
    assert not old.exists()
    assert bundled != "2999.1.1"

    # Nothing newer: nothing installed.
    commands.clear()
    assert await ytdlp.update() is False
    assert commands == []


async def test_update_skips_versions_not_newer_than_the_image(monkeypatch, data):
    async def latest():
        return "2020.1.1", []

    async def run(*command):
        raise AssertionError("no install expected")

    monkeypatch.setattr(ytdlp, "_latest", latest)
    monkeypatch.setattr(ytdlp, "_run", run)
    assert await ytdlp.update() is False
    assert not (data / "yt-dlp").exists()


async def test_a_version_that_fails_to_load_is_dropped(monkeypatch, data):
    bundled = ytdlp.current_version()

    async def latest():
        return "2999.1.1", []

    async def run(*command):
        command = list(map(str, command))
        fake_package(Path(command[command.index("--target") + 1]), "2999.1.1", broken=True)

    monkeypatch.setattr(ytdlp, "_latest", latest)
    monkeypatch.setattr(ytdlp, "_run", run)
    assert await ytdlp.update() is False
    assert ytdlp.current_version() == bundled
    assert not (data / "yt-dlp" / "2999.1.1").exists()


async def test_a_failed_install_leaves_nothing_behind(monkeypatch, data):
    async def latest():
        return "2999.1.1", []

    async def run(*command):
        raise RuntimeError("no network")

    monkeypatch.setattr(ytdlp, "_latest", latest)
    monkeypatch.setattr(ytdlp, "_run", run)
    with pytest.raises(RuntimeError):
        await ytdlp.update()
    assert not (data / "yt-dlp" / "2999.1.1").exists()


def test_startup_uses_the_newest_installed_version_if_newer_than_the_image(data):
    for version in ("2998.1.1", "2999.1.1"):
        fake_package(data / "yt-dlp" / version / "packages", version)
        (data / "yt-dlp" / version / "installed").touch()
    # Unfinished install: ignored.
    fake_package(data / "yt-dlp" / "3000.1.1" / "packages", "3000.1.1")
    ytdlp.use_newest_installed()
    assert ytdlp.current_version() == "2999.1.1"


def test_startup_keeps_the_image_version_when_it_is_newer(data):
    bundled = ytdlp.current_version()
    fake_package(data / "yt-dlp" / "2020.1.1" / "packages", "2020.1.1")
    (data / "yt-dlp" / "2020.1.1" / "installed").touch()
    ytdlp.use_newest_installed()
    assert ytdlp.current_version() == bundled
