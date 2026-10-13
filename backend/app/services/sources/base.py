from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Protocol

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


class Source(Protocol):
    name: str

    async def find(self, meta: TrackMeta) -> Candidate | None: ...

    async def download(self, candidate: Candidate, dest_dir: Path,
                       progress: Callable[[float], None], cancelled: Callable[[], bool]) -> Path: ...
