import asyncio
import logging
import re
from collections.abc import Callable
from pathlib import Path
from urllib.parse import urlsplit

import yt_dlp

from app.services.musicbrainz import TrackMeta
from app.services.sources.base import Cancelled, Candidate, finish_download
from app.services.sources.youtube import score_candidate

log = logging.getLogger(__name__)


def track_url(url: str) -> str | None:
    try:
        parsed = urlsplit(url)
        if (
            parsed.scheme == "https"
            and parsed.netloc in {"soundcloud.com", "m.soundcloud.com"}
            and re.fullmatch(r"/[^/]+/[^/]+/?", parsed.path)
        ):
            return url
    except ValueError:
        pass
    return None


class SoundCloudSource:
    name = "soundcloud"

    def candidate(self, ref: str) -> Candidate:
        return Candidate(self.name, ref, "", "", None, 100.0)

    async def find(self, meta: TrackMeta, exclude: frozenset[str] = frozenset()) -> Candidate | None:
        def search() -> Candidate | None:
            try:
                with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "extract_flat": True}) as ydl:
                    info = ydl.extract_info(f"scsearch10:{meta.artist} {meta.title}", download=False)
                candidates = []
                for entry in (info or {}).get("entries", []) or []:
                    if not entry or not (ref := entry.get("url")) or ref in exclude:
                        continue
                    title = entry.get("title") or ""
                    artists = [entry.get("uploader") or ""]
                    variants = [(title, artists)]
                    if " - " in title:
                        left, right = title.split(" - ", 1)
                        variants.append((right, [left]))
                    duration = entry.get("duration")
                    for title, artists in variants:
                        score = score_candidate(meta, title, artists, duration, is_video=False)
                        if score is not None:
                            candidates.append(Candidate(self.name, ref, title, " / ".join(artists), duration, score))
                return max(candidates, key=lambda c: c.score) if candidates else None
            except Exception:
                log.debug("SoundCloud search failed", exc_info=True)
                return None

        return await asyncio.to_thread(search)

    async def download(
        self, candidate: Candidate, dest_dir: Path, progress: Callable[[float], None], cancelled: Callable[[], bool]
    ) -> Path:
        loop = asyncio.get_running_loop()

        def hook(data: dict) -> None:
            if cancelled():
                raise Cancelled()
            total = data.get("total_bytes") or data.get("total_bytes_estimate")
            if total:
                loop.call_soon_threadsafe(progress, min(1.0, data.get("downloaded_bytes", 0) / total))

        def run() -> Path:
            if cancelled():
                raise Cancelled()
            options = {
                "format": "bestaudio[ext=opus]/bestaudio[ext=mp3]/bestaudio",
                "outtmpl": str(dest_dir / "source.%(ext)s"),
                "noplaylist": True,
                "quiet": True,
                "no_warnings": True,
                "progress_hooks": [hook],
            }
            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(candidate.ref, download=True)
                src = Path(ydl.prepare_filename(info))
            if cancelled():
                raise Cancelled()
            codec = info.get("acodec") or info.get("ext", "")
            if codec.startswith("opus"):
                extension = ".opus"
            elif codec.startswith("mp3"):
                extension = ".mp3"
            elif codec.startswith(("aac", "mp4a", "m4a")):
                extension = ".m4a"
            else:
                extension = None
            return finish_download(src, dest_dir, extension)

        return await asyncio.to_thread(run)
