import asyncio
import re
import unicodedata
from collections.abc import Callable
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import yt_dlp
from rapidfuzz import fuzz
from ytmusicapi import YTMusic

from app.config import get_settings
from app.services.musicbrainz import TrackMeta
from app.services.sources.base import Cancelled, Candidate, finish_download


def video_id(url: str) -> str | None:
    try:
        parsed = urlsplit(url)
        if parsed.scheme != "https":
            return None
        if parsed.netloc == "youtu.be":
            ref = parsed.path.removeprefix("/")
        elif parsed.netloc in {"music.youtube.com", "www.youtube.com", "youtube.com", "m.youtube.com"}:
            if parsed.path != "/watch":
                return None
            ref = parse_qs(parsed.query).get("v", [""])[0]
        else:
            return None
        return ref if re.fullmatch(r"[A-Za-z0-9_-]{11}", ref) else None
    except ValueError:
        return None


def norm(s: str) -> str:
    s = s.casefold()
    s = re.sub(
        r"\([^)]*\)|\[[^]]*\]",
        lambda m: (
            ""
            if any(
                word in m.group()
                for word in ("remaster", "remastered", "version", "edit", "explicit", "clean", "mono", "stereo")
            )
            else m.group()
        ),
        s,
    )
    s = re.sub(r"\b(?:feat\.|ft\.|featuring)\s+[^()[\]]*", "", s)
    return " ".join(s.split()).strip()


# Explicit versions win over otherwise equal clean ones.
EXPLICIT_BONUS = 15


def _fold(s: str) -> str:
    """Accents and typographic apostrophes do not matter for matching (Ćelo = Celo, ’69 = '69)."""
    s = "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))
    return s.replace("’", "'").replace("‘", "'")


_ARTIST_SEPARATORS = r"\s*(?:,|&|/|\+|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\bx\b|\bund\b|\band\b)\s*"


def _artist_names(artist: str) -> set[str]:
    """The full credit plus each credited artist: "Sido feat. Fler" matches a result credited to Fler."""
    folded = _fold(artist.casefold())
    names = {_fold(norm(artist))} | {" ".join(n.split()) for n in re.split(_ARTIST_SEPARATORS, folded)}
    return {n for n in names if n}


def score_candidate(
    meta: TrackMeta, title: str, artists: list[str], duration: float | None, is_video: bool
) -> float | None:
    title_ratio = fuzz.token_set_ratio(_fold(norm(meta.title)), _fold(norm(title)))
    wanted = _artist_names(meta.artist)
    found = set().union(*(_artist_names(a) for a in artists)) | {_fold(norm(" ".join(artists)))} if artists else set()
    artist_ratio = max((fuzz.token_set_ratio(w, f) for w in wanted for f in found if f), default=0)
    d = abs(meta.duration - duration) if meta.duration is not None and duration is not None else None
    if title_ratio < 70 or artist_ratio < 60 or (d is not None and d > 15):
        return None
    for word in (
        "live",
        "cover",
        "karaoke",
        "instrumental",
        "remix",
        "sped up",
        "slowed",
        "nightcore",
        "8d",
        "reverb",
        "clean",
        "radio edit",
        "censored",
        "originally performed",
        "tribute",
        "a cappella",
        "acapella",
    ):
        pattern = rf"\b{re.escape(word)}\b"
        if re.search(pattern, title.casefold()) and not re.search(pattern, meta.title.casefold()):
            return None
    duration_score = 50 if d is None else 100 if d <= 2 else 0 if d >= 15 else 100 * (15 - d) / 13
    score = 0.5 * title_ratio + 0.3 * artist_ratio + 0.2 * duration_score
    if is_video:
        # Music videos often add a short intro or outro.
        if d is not None and d > 10:
            return None
        score -= 10
    return score


def uploaded_path() -> Path:
    """cookies.txt of a YouTube account an admin uploaded (age-restricted videos need a signed-in account)."""
    return get_settings().data_dir / "youtube-cookies.txt"


def cookies_file() -> Path | None:
    """The cookies file yt-dlp should use: RESONANCE_YTDLP_COOKIES_FILE wins over the upload."""
    if configured := get_settings().ytdlp_cookies_file:
        return configured
    path = uploaded_path()
    return path if path.is_file() else None


class YouTubeMusicSource:
    name = "youtube"

    def __init__(self) -> None:
        self._music = YTMusic()

    def candidate(self, ref: str) -> Candidate:
        return Candidate(self.name, ref, "", "", None, 100.0)

    async def find(self, meta: TrackMeta, exclude: frozenset[str] = frozenset()) -> Candidate | None:
        def search() -> Candidate | None:
            for filter in ("songs", "videos"):
                candidates = []
                for result in self._music.search(f"{meta.artist} {meta.title}", filter=filter, limit=10):
                    ref = result.get("videoId")
                    if not ref or ref in exclude:
                        continue
                    title = result.get("title", "")
                    artists = [a["name"] for a in result.get("artists", []) if a.get("name")]
                    duration = result.get("duration_seconds")
                    if duration is None and result.get("duration"):
                        try:
                            duration = sum(
                                float(v) * 60**i for i, v in enumerate(reversed(result["duration"].split(":")))
                            )
                        except ValueError:
                            pass
                    score = score_candidate(meta, title, artists, duration, filter == "videos")
                    # YouTube Music lists censored album versions under the same title; prefer the explicit one.
                    if score is not None and result.get("isExplicit"):
                        score += EXPLICIT_BONUS
                    if score is not None:
                        candidates.append(Candidate(self.name, ref, title, " / ".join(artists), duration, score))
                if candidates:
                    return max(candidates, key=lambda c: c.score)
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
                "format": "bestaudio[acodec=opus]/bestaudio[ext=m4a]/bestaudio",
                "outtmpl": str(dest_dir / "source.%(ext)s"),
                "noplaylist": True,
                "quiet": True,
                "no_warnings": True,
                "progress_hooks": [hook],
            }
            if cookies := cookies_file():
                options["cookiefile"] = str(cookies)
            with yt_dlp.YoutubeDL(options) as ydl:
                info = ydl.extract_info(f"https://music.youtube.com/watch?v={candidate.ref}", download=True)
                src = Path(ydl.prepare_filename(info))
            if cancelled():
                raise Cancelled()
            codec = info.get("acodec", "")
            extension = ".opus" if codec.startswith("opus") else ".m4a" if codec.startswith("mp4a") else None
            return finish_download(src, dest_dir, extension)

        return await asyncio.to_thread(run)
