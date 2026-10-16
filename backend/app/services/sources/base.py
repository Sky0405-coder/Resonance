import subprocess
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

from app.config import get_settings
from app.services.musicbrainz import TrackMeta


@dataclass
class Candidate:
    source: str
    ref: str
    title: str
    artist: str
    duration: float | None
    score: float


class Cancelled(Exception):
    pass


def finish_download(src: Path, dest_dir: Path, copy_extension: str | None) -> Path:
    dest = dest_dir / f"audio{copy_extension or '.opus'}"
    args = ["-c:a", "copy"] if copy_extension else ["-c:a", "libopus", "-b:a", "192k"]
    subprocess.run(
        [
            get_settings().ffmpeg_path,
            "-nostdin",
            "-loglevel",
            "error",
            "-i",
            str(src),
            "-map",
            "0:a:0",
            "-vn",
            *args,
            str(dest),
        ],
        check=True,
    )
    src.unlink()
    return dest


class Source(Protocol):
    name: str

    def candidate(self, ref: str) -> Candidate: ...

    async def find(self, meta: TrackMeta, exclude: frozenset[str] = frozenset()) -> Candidate | None: ...

    async def download(
        self, candidate: Candidate, dest_dir: Path, progress: Callable[[float], None], cancelled: Callable[[], bool]
    ) -> Path: ...
