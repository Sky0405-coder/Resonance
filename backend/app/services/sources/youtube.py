import asyncio
import re
import subprocess
from collections.abc import Callable
from pathlib import Path

import yt_dlp
from rapidfuzz import fuzz
from ytmusicapi import YTMusic

from app.config import get_settings
from app.services.musicbrainz import TrackMeta
from app.services.sources.base import Cancelled, Candidate


def norm(s: str) -> str:
    s = s.casefold()
    s = re.sub(r"\([^)]*\)|\[[^]]*\]", lambda m: "" if any(
        word in m.group()
        for word in ("remaster", "remastered", "version", "edit", "explicit", "clean", "mono", "stereo")
    ) else m.group(), s)
    s = re.sub(r"\b(?:feat\.|ft\.|featuring)\s+[^()[\]]*", "", s)
    return " ".join(s.split()).strip()


def score_candidate(meta: TrackMeta, title: str, artists: list[str],
                    duration: float | None, is_video: bool) -> float | None:
    title_ratio = fuzz.token_set_ratio(norm(meta.title), norm(title))
    artist_ratio = max((fuzz.token_set_ratio(norm(meta.artist), norm(a)) for a in artists), default=0)
    d = abs(meta.duration - duration) if meta.duration is not None and duration is not None else None
    if title_ratio < 70 or artist_ratio < 60 or (d is not None and d > 15):
        return None
    for word in ("live", "cover", "karaoke", "instrumental", "remix", "sped up", "slowed", "nightcore", "8d", "reverb"):
        pattern = rf"\b{re.escape(word)}\b"
        if re.search(pattern, title.casefold()) and not re.search(pattern, meta.title.casefold()):
            return None
    duration_score = 50 if d is None else 100 if d <= 2 else 0 if d >= 15 else 100 * (15 - d) / 13
    score = 0.5 * title_ratio + 0.3 * artist_ratio + 0.2 * duration_score
    if is_video:
        if d is not None and d > 5:
            return None
        score -= 10
    return score


class YouTubeMusicSource:
    name = "youtube"

    def __init__(self) -> None:
        self._music = YTMusic()

    async def find(self, meta: TrackMeta) -> Candidate | None:
        def search() -> Candidate | None:
            for filter in ("songs", "videos"):
                candidates = []
                for result in self._music.search(f"{meta.artist} {meta.title}", filter=filter, limit=10):
                    ref = result.get("videoId")
                    if not ref:
                        continue
                    title = result.get("title", "")
                    artists = [a["name"] for a in result.get("artists", []) if a.get("name")]
                    duration = result.get("duration_seconds")
                    if duration is None and result.get("duration"):
                        try:
                            duration = sum(float(v) * 60 ** i for i, v in enumerate(
                                reversed(result["duration"].split(":"))))
                        except ValueError:
                            pass
                    score = score_candidate(meta, title, artists, duration, filter == "videos")
                    if score is not None:
                        candidates.append(Candidate(self.name, ref, title, " / ".join(artists), duration, score))
                if candidates:
                    return max(candidates, key=lambda c: c.score)
            return None

        return await asyncio.to_thread(search)

    async def download(self, candidate: Candidate, dest_dir: Path,
                       progress: Callable[[float], None], cancelled: Callable[[], bool]) -> Path:
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
            settings = get_settings()
            options = {
                "format": "bestaudio[acodec=opus]/bestaudio[ext=m4a]/bestaudio",
                "outtmpl": str(dest_dir / "source.%(ext)s"), "noplaylist": True, "quiet": True,
                "no_warnings": True, "progress_hooks": [hook],
            }
            if settings.ytdlp_cookies_file:
                options["cookiefile"] = str(settings.ytdlp_cookies_file)
            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(f"https://music.youtube.com/watch?v={candidate.ref}", download=True)
                src = Path(ydl.prepare_filename(info))
            if cancelled():
                raise Cancelled()
            codec = info.get("acodec", "")
            if codec.startswith("opus"):
                dest, args = dest_dir / "audio.opus", ["-c:a", "copy"]
            elif codec.startswith("mp4a"):
                dest, args = dest_dir / "audio.m4a", ["-c:a", "copy"]
            else:
                dest, args = dest_dir / "audio.opus", ["-c:a", "libopus", "-b:a", "192k"]
            subprocess.run([settings.ffmpeg_path, "-nostdin", "-loglevel", "error", "-i", str(src),
                            "-map", "0:a:0", "-vn", *args, str(dest)], check=True)
            src.unlink()
            return dest

        return await asyncio.to_thread(run)
