import html
import re

from rapidfuzz import fuzz

from app.services.sources.youtube import norm


_EDITION = re.compile(r"\s*(\([^)]*\)|\[[^\]]*\])")
_SUFFIX = re.compile(r"\s+-\s+[^-]*\b(remaster(ed)?|edition|version|deluxe|anniversary|mono|stereo)\b.*$", re.I)


def clean_album(album: str) -> str:
    """Drop edition details that torrent names rarely contain: "Radio-Aktivität (2009 Remaster, German Version)"."""
    cleaned = _SUFFIX.sub("", _EDITION.sub("", album)).strip()
    return cleaned or album


def search_query(artist: str, album: str) -> str:
    album = clean_album(album)
    return album if artist.casefold() == "various artists" else f"{artist} {album}"


def choose(results: list[dict], artist: str, album: str, total_duration: float, min_seeders: int) -> dict | None:
    candidates = []
    album = clean_album(album)
    for result in results:
        # Some indexers (e.g. The Pirate Bay) return HTML entities: "Radio-Aktivit&auml;t".
        title = html.unescape(result.get("title", ""))
        seeders = result.get("seeders") or 0
        size = result.get("size") or 0
        if result.get("protocol") != "torrent" or seeders < min_seeders:
            continue
        wanted = album if artist.casefold() == "various artists" else f"{artist} {album}"
        if fuzz.token_set_ratio(norm(wanted), norm(title)) < 80:
            continue
        if any(
            re.search(rf"\b{re.escape(word)}\b", title.casefold())
            and not re.search(rf"\b{re.escape(word)}\b", album.casefold())
            for word in ("discography", "collection", "anthology", "box set", "boxset", "complete works")
        ):
            continue
        if size < total_duration * 16_000 or size > 3 * 1024**3:
            continue
        lower = title.casefold()
        rank = 3 if "flac" in lower else 2 if "320" in lower else 1 if "v0" in lower or "mp3" in lower else 0
        candidates.append(
            ((rank, min(seeders, 50), -size), result if title == result.get("title") else {**result, "title": title})
        )
    return max(candidates, key=lambda c: c[0])[1] if candidates else None
