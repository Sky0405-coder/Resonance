import re
from pathlib import Path

from app.config import get_settings
from app.services.musicbrainz import TrackMeta


def _component(value: str) -> str:
    value = re.sub(r'[/\\:*?"<>|\x00-\x1f\x7f-\x9f]', "_", value)
    return " ".join(value.split()).strip().rstrip(".")[:120].rstrip(" .") or "_"


def target_relpath(meta: TrackMeta, ext: str) -> str:
    artist = _component(meta.album_artist)
    album = _component(f"{meta.album}{f' ({meta.year})' if meta.year else ''}")
    disc = f"{meta.disc_no}-" if (meta.disc_total or 1) > 1 else ""
    number = f"{meta.track_no:02d} - " if meta.track_no is not None else ""
    extension = _component(ext)
    stem = _component(f"{disc}{number}{meta.title}")[:120 - len(extension)].rstrip(" .") or "_"
    filename = f"{stem}{extension}"
    rel = Path(artist) / album / filename
    index = 2
    while (get_settings().music_dir / rel).exists():
        suffix = f" ({index})"
        base = stem[:120 - len(extension) - len(suffix)].rstrip(" .") or "_"
        rel = Path(artist) / album / f"{base}{suffix}{extension}"
        index += 1
    return str(rel)
