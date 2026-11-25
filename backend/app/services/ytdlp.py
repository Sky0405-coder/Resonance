"""Keeps yt-dlp current without a new release: YouTube changes its player every few weeks and an older yt-dlp then
finds only thumbnails ("Requested format is not available"). Once a day the newest version from PyPI is installed into
the data folder and the download sources switch to it; after a restart the newest installed one is used again. If a
version fails to load, the one before it stays in use.
"""

import asyncio
import importlib
import logging
import re
import shutil
import sys
from pathlib import Path

import httpx

from app.config import get_settings

log = logging.getLogger(__name__)

_CHECK_EVERY = 24 * 3600
_FIRST_CHECK = 60
_PYPI = "https://pypi.org/pypi/yt-dlp/json"

_loop_task: asyncio.Task | None = None
_active: Path | None = None


def _root() -> Path:
    return get_settings().data_dir / "yt-dlp"


def version_key(version: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", version))


def current_version() -> str:
    from app.services.sources import youtube

    return youtube.yt_dlp.version.__version__


def _installed() -> list[tuple[str, Path]]:
    """Complete installs in the data folder, newest first."""
    root = _root()
    if not root.is_dir():
        return []
    found = [(path.name, path) for path in root.iterdir() if (path / "installed").exists()]
    return sorted(found, key=lambda item: version_key(item[0]), reverse=True)


def _modules() -> list:
    from app.services.sources import bandcamp, soundcloud, youtube

    return [youtube, soundcloud, bandcamp]


def _load(packages: Path | None):
    """Imports yt-dlp afresh, from `packages` or else from the image, and hands it to the download sources."""
    global _active
    # yt-dlp wraps a regex of urllib3 when it is imported; a second import would wrap the wrapper.
    url = sys.modules.get("urllib3.util.url")
    pattern = getattr(url, "_PERCENT_RE", None)
    while type(pattern).__name__ == "Urllib3PercentREOverride":
        pattern = pattern.re
        url._PERCENT_RE = pattern
    for name in list(sys.modules):
        if name.split(".")[0] in ("yt_dlp", "yt_dlp_ejs"):
            del sys.modules[name]
    if _active is not None and str(_active) in sys.path:
        sys.path.remove(str(_active))
    if packages is not None:
        sys.path.insert(0, str(packages))
    _active = packages
    importlib.invalidate_caches()
    module = importlib.import_module("yt_dlp")
    importlib.import_module("yt_dlp.version")
    for source in _modules():
        source.yt_dlp = module
    return module


def activate(packages: Path | None) -> bool:
    """Switches to the yt-dlp in `packages`; on failure the one in use before stays."""
    previous = _active
    try:
        _load(packages)
        return True
    except Exception as e:  # noqa: BLE001 - a broken download must not break downloads
        log.warning("yt-dlp in %s failed to load: %s", packages, e)
        _load(previous)
        return False


def use_newest_installed() -> None:
    bundled = version_key(current_version())
    for version, path in _installed():
        if version_key(version) <= bundled:
            return
        if activate(path / "packages"):
            log.info("Using yt-dlp %s from the data folder", version)
            return


async def _run(*command: str | Path) -> None:
    process = await asyncio.create_subprocess_exec(
        *map(str, command), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
    )
    output, _ = await process.communicate()
    if process.returncode != 0:
        tail = output.decode(errors="replace").strip().splitlines()[-3:]
        raise RuntimeError(" ".join(tail)[-300:] or f"exit {process.returncode}")


async def _latest() -> tuple[str, list[str]]:
    """The newest version on PyPI and the extra packages its "default" install pins (the challenge solver)."""
    async with httpx.AsyncClient(timeout=30, headers={"User-Agent": "Resonance/1.0"}) as client:
        response = await client.get(_PYPI)
        response.raise_for_status()
        info = response.json()["info"]
    extras = []
    for requirement in info.get("requires_dist") or []:
        spec, _, marker = requirement.partition(";")
        if 'extra == "default"' in marker and spec.strip().startswith("yt-dlp-ejs"):
            extras.append(spec.strip())
    return info["version"], extras


async def update() -> bool:
    """Installs and switches to a newer yt-dlp when PyPI has one; True when it did."""
    version, extras = await _latest()
    if version_key(version) <= version_key(current_version()):
        return False
    target = _root() / version
    if target.exists():
        await asyncio.to_thread(shutil.rmtree, target)
    packages = target / "packages"
    packages.mkdir(parents=True)
    try:
        # Without dependencies: those of the image (requests, websockets, ...) stay in use.
        await _run(
            sys.executable, "-m", "pip", "install", "--no-cache-dir", "--disable-pip-version-check", "--no-deps",
            "--target", packages, f"yt-dlp=={version}", *extras,
        )
    except (OSError, RuntimeError):
        await asyncio.to_thread(shutil.rmtree, target, True)
        raise
    if not activate(packages):
        await asyncio.to_thread(shutil.rmtree, target, True)
        return False
    (target / "installed").touch()
    log.info("Updated yt-dlp to %s", version)
    for _, path in _installed():
        if path != target:
            await asyncio.to_thread(shutil.rmtree, path, True)
    return True


async def _loop() -> None:
    await asyncio.sleep(_FIRST_CHECK)
    while True:
        try:
            await update()
        except Exception as e:  # noqa: BLE001 - offline or PyPI down: try again tomorrow
            log.warning("yt-dlp update check failed: %s", e)
        await asyncio.sleep(_CHECK_EVERY)


async def start() -> None:
    global _loop_task
    try:
        use_newest_installed()
    except Exception:
        log.exception("Loading the updated yt-dlp failed")
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_loop())


async def stop() -> None:
    global _loop_task
    if _loop_task is not None:
        _loop_task.cancel()
        await asyncio.gather(_loop_task, return_exceptions=True)
        _loop_task = None
