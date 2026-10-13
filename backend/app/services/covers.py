"""Album cover cache.

Originals are normalised to JPEG and stored under `<data>/covers/<hash>.jpg`;
resized variants are created lazily next to them.
"""

import hashlib
import io
from pathlib import Path

from PIL import Image

from app.config import get_settings

MAX_ORIGINAL = 1200
# Snap requested sizes to a few buckets so the cache stays small.
SIZE_BUCKETS = (64, 128, 300, 600)


def _dir() -> Path:
    d = get_settings().cover_cache_dir
    d.mkdir(parents=True, exist_ok=True)
    return d


def store(data: bytes) -> str | None:
    """Normalise and cache image bytes; returns the cache file name or None if unreadable."""
    try:
        img = Image.open(io.BytesIO(data))
        img = img.convert("RGB")
    except Exception:
        return None
    img.thumbnail((MAX_ORIGINAL, MAX_ORIGINAL))
    buf = io.BytesIO()
    img.save(buf, "JPEG", quality=90)
    out = buf.getvalue()
    name = hashlib.sha1(out).hexdigest()[:20] + ".jpg"
    path = _dir() / name
    if not path.exists():
        path.write_bytes(out)
    return name


def resized(name: str, size: int | None) -> Path | None:
    original = _dir() / name
    if not original.exists():
        return None
    if size is None:
        return original
    bucket = next((b for b in SIZE_BUCKETS if b >= size), None)
    if bucket is None:
        return original
    target = original.with_name(f"{original.stem}_{bucket}.jpg")
    if not target.exists():
        with Image.open(original) as img:
            img.thumbnail((bucket, bucket))
            img.save(target, "JPEG", quality=85)
    return target
