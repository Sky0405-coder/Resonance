import asyncio
import os
import re
import shutil
import threading
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
        "rmx",
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


# yt-dlp writes the (rotated) cookies back when a download ends; parallel downloads must not read a half-written file.
_cookie_lock = threading.Lock()


def cookies_uploaded_stamp() -> Path:
    """Upload time of the cookies; the file's own mtime changes whenever yt-dlp saves rotated cookies."""
    return get_settings().data_dir / "youtube-cookies.uploaded"


def _private_cookies(dest_dir: Path) -> tuple[Path, Path] | None:
    """A copy of the cookies for one download: (shared file, private copy)."""
    if not (shared := cookies_file()):
        return None
    private = dest_dir / "cookies.txt"
    with _cookie_lock:
        shutil.copyfile(shared, private)
    return shared, private


def _save_cookies(shared: Path, private: Path) -> None:
    """Keeps the rotated cookies yt-dlp got from YouTube, replacing the shared file in one step."""
    try:
        text = private.read_text(encoding="utf-8")
        if "youtube.com" not in text:
            return
        with _cookie_lock:
            temp = shared.with_name(shared.name + ".part")
            temp.write_text(text, encoding="utf-8")
            temp.chmod(0o600)
            os.replace(temp, shared)
    except OSError:
        pass  # e.g. a read-only RESONANCE_YTDLP_COOKIES_FILE: the next download simply uses the old cookies


def cookies_expired_marker() -> Path:
    """Exists while yt-dlp reports the cookies as rotated/invalid (shown in the admin settings)."""
    return get_settings().data_dir / "youtube-cookies.expired"


class _CookieWatch:
    """yt-dlp logger: stays quiet like before, but notices when YouTube no longer accepts the cookies."""

    def __init__(self) -> None:
        self.expired = False

    def debug(self, message: str) -> None:
        pass

    def info(self, message: str) -> None:
        pass

    def warning(self, message: str) -> None:
        if "cookies are no longer valid" in message:
            self.expired = True

    def error(self, message: str) -> None:
        pass


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
                    variants = [(title, artists)]
                    # Label and fan channels upload videos as "Artist - Title": the channel is not the artist.
                    parts = re.split(r"\s+[-–—]\s+", title, maxsplit=1)
                    if filter == "videos" and len(parts) == 2:
                        variants.append((parts[1], [parts[0]]))
                    scored = [
                        (score, title, artists)
                        for title, artists in variants
                        if (score := score_candidate(meta, title, artists, duration, filter == "videos")) is not None
                    ]
                    if not scored:
                        continue
                    score, title, artists = max(scored, key=lambda v: v[0])
                    # YouTube Music lists censored album versions under the same title; prefer the explicit one.
                    if result.get("isExplicit"):
                        score += EXPLICIT_BONUS
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
            watch = None
            if cookies := _private_cookies(dest_dir):
                watch = _CookieWatch()
                options |= {"cookiefile": str(cookies[1]), "logger": watch, "no_warnings": False}
            try:
                with yt_dlp.YoutubeDL(options) as ydl:
                    info = ydl.extract_info(f"https://music.youtube.com/watch?v={candidate.ref}", download=True)
                    src = Path(ydl.prepare_filename(info))
            finally:
                if cookies is not None and watch is not None:
                    marker = cookies_expired_marker()
                    if watch.expired:
                        marker.parent.mkdir(parents=True, exist_ok=True)
                        marker.touch()
                    else:
                        marker.unlink(missing_ok=True)
                        _save_cookies(*cookies)
                    cookies[1].unlink(missing_ok=True)
            if cancelled():
                raise Cancelled()
            codec = info.get("acodec", "")
            extension = ".opus" if codec.startswith("opus") else ".m4a" if codec.startswith("mp4a") else None
            return finish_download(src, dest_dir, extension)

        return await asyncio.to_thread(run)
