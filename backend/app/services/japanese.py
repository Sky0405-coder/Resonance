"""Optional Japanese dictionary for lyrics: MeCab with UniDic (fugashi) and cutlet's romaji, which read words in
context (君 as きみ, は as "wa"). Off by default (Admin → Server → Bibliothek); when switched on it is installed once
into the data folder (about 250 MB, so the image stays small). Without it lyrics are read with pykakasi, which reads
kanji one by one and often picks the wrong reading.
"""

import asyncio
import logging
import shutil
import sys
import threading
import time
from pathlib import Path

from app.config import get_settings
from app.db import SessionLocal
from app.services.server_config import load_config

log = logging.getLogger(__name__)

# Bump when the installed packages change so they get installed again.
_RUNTIME = 1
# cutlet without its dependency mojimoji, which has no wheel for arm64 (the image has no compiler); a module with the
# two functions cutlet uses stands in for it, on top of jaconv.
_PACKAGES = (["--no-deps", "cutlet==0.5.0"], ["fugashi>=1.3", "unidic-lite>=1.0.8", "jaconv>=0.3"])
_MOJIMOJI = '''"""Stand-in for mojimoji (no arm64 wheel) with the two functions cutlet uses."""
import jaconv


def zen_to_han(text, kana=True, digit=True, ascii=True):
    return jaconv.z2h(text, kana=kana, digit=digit, ascii=ascii)


def han_to_zen(text, kana=True, digit=True, ascii=True):
    return jaconv.h2z(text, kana=kana, digit=digit, ascii=ascii)
'''

_state: dict[str, str | None] = {"state": "off", "message": None}
_failed_at = 0.0
_lock = threading.Lock()
_tools = None


def _root() -> Path:
    return get_settings().data_dir / "japanese"


def _marker() -> Path:
    return _root() / f"installed-{_RUNTIME}"


def installed() -> bool:
    return _marker().exists()


def tools():
    """(tagger, cutlet) when the dictionary is installed and switched on, else None; callers hold `lock`."""
    global _tools
    if _state["state"] != "ready":
        return None
    if _tools is None:
        packages = str(_root() / "packages")
        if packages not in sys.path:
            sys.path.append(packages)
        try:
            import cutlet
            import fugashi

            _tools = (fugashi.Tagger(), cutlet.Cutlet())
        except Exception as e:  # noqa: BLE001 - a broken install falls back to pykakasi
            log.warning("Japanese dictionary failed to load: %s", e)
            _state.update(state="failed", message=str(e)[:300])
            return None
    return _tools


lock = _lock


def state() -> dict[str, str | None]:
    return dict(_state)


async def _run(*command: str | Path) -> None:
    process = await asyncio.create_subprocess_exec(
        *map(str, command), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT
    )
    output, _ = await process.communicate()
    if process.returncode != 0:
        tail = output.decode(errors="replace").strip().splitlines()[-3:]
        raise RuntimeError(" ".join(tail)[-300:] or f"exit {process.returncode}")


async def install() -> bool:
    global _failed_at
    _state.update(state="installing", message=None)
    root = _root()
    try:
        if root.exists():
            await asyncio.to_thread(shutil.rmtree, root)
        packages = root / "packages"
        packages.mkdir(parents=True)
        for spec in _PACKAGES:
            await _run(
                sys.executable, "-m", "pip", "install", "--no-cache-dir", "--disable-pip-version-check",
                "--target", packages, *spec,
            )
        (packages / "mojimoji.py").write_text(_MOJIMOJI)
        _marker().touch()
    except (OSError, RuntimeError) as e:
        log.warning("Installing the Japanese dictionary failed: %s", e)
        _failed_at = time.monotonic()
        _state.update(state="failed", message=str(e))
        return False
    _state.update(state="ready", message=None)
    return True


async def ensure() -> None:
    """Follows the admin switch: installs the dictionary when switched on, stops using it when switched off."""
    global _tools
    async with SessionLocal() as db:
        enabled = (await load_config(db)).lyrics.japanese_dictionary
    if not enabled:
        with _lock:
            _state.update(state="off", message=None)
            _tools = None
        return
    if _state["state"] in ("ready", "installing"):
        return
    if installed():
        _state.update(state="ready", message=None)
        return
    # A failed install is retried after an hour (e.g. no internet at the moment).
    if _state["state"] == "failed" and time.monotonic() - _failed_at < 3600:
        return
    await install()


async def status() -> dict:
    async with SessionLocal() as db:
        enabled = (await load_config(db)).lyrics.japanese_dictionary
    return {"enabled": enabled, **state()}


_loop_task: asyncio.Task | None = None


async def _loop() -> None:
    while True:
        try:
            await ensure()
        except Exception:
            log.exception("Japanese dictionary check failed")
        await asyncio.sleep(30)


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
