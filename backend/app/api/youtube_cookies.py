"""YouTube sign-in for downloads: admins upload a cookies.txt of a YouTube account so yt-dlp can fetch
age-restricted (explicit) videos."""

import os
from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, UploadFile
from pydantic import BaseModel

from app.config import get_settings
from app.deps import AdminUser
from app.services.sources.youtube import uploaded_path

router = APIRouter(tags=["admin"])

MAX_COOKIE_BYTES = 1024 * 1024


class YouTubeCookies(BaseModel):
    configured: bool
    # Set from the environment (RESONANCE_YTDLP_COOKIES_FILE): the upload is not used then.
    from_env: bool
    uploaded_at: datetime | None


def _status() -> YouTubeCookies:
    path = uploaded_path()
    uploaded = datetime.fromtimestamp(path.stat().st_mtime, UTC) if path.is_file() else None
    from_env = bool(get_settings().ytdlp_cookies_file)
    return YouTubeCookies(configured=from_env or uploaded is not None, from_env=from_env, uploaded_at=uploaded)


def _valid(text: str) -> bool:
    """A Netscape cookies.txt with YouTube cookies (7 tab-separated fields per cookie line)."""
    for line in text.splitlines():
        if line.startswith("#HttpOnly_"):
            line = line.removeprefix("#HttpOnly_")
        elif not line.strip() or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) == 7 and fields[0].lstrip(".").endswith("youtube.com"):
            return True
    return False


@router.get("/api/admin/youtube-cookies", response_model=YouTubeCookies)
async def youtube_cookies(admin: AdminUser) -> YouTubeCookies:
    return _status()


@router.put("/api/admin/youtube-cookies", response_model=YouTubeCookies)
async def upload_youtube_cookies(admin: AdminUser, file: UploadFile) -> YouTubeCookies:
    data = await file.read(MAX_COOKIE_BYTES + 1)
    if len(data) > MAX_COOKIE_BYTES:
        raise HTTPException(413, "Datei zu groß")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise HTTPException(422, "Keine gültige cookies.txt-Datei") from None
    if not _valid(text):
        raise HTTPException(422, "Keine YouTube-Cookies im Netscape-Format (cookies.txt) gefunden")
    path = uploaded_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".part")
    temp.write_text(text, encoding="utf-8")
    temp.chmod(0o600)
    os.replace(temp, path)
    return _status()


@router.delete("/api/admin/youtube-cookies", response_model=YouTubeCookies)
async def delete_youtube_cookies(admin: AdminUser) -> YouTubeCookies:
    uploaded_path().unlink(missing_ok=True)
    return _status()
