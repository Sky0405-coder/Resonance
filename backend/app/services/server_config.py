"""Runtime server configuration editable from the admin dashboard.

Stored as a single JSON document so that new options only need a field with a
default here — no migration required.
"""

from typing import Literal

from pydantic import BaseModel, Field, field_validator
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import ServerSetting

KEY = "server_config"


class RegistrationConfig(BaseModel):
    # "invite": only via one-time links created by admins; "public": anyone may sign up.
    mode: Literal["invite", "public"] = "invite"


class RadioConfig(BaseModel):
    # Fetch missing similar songs into the download queue when building a radio.
    auto_download_enabled: bool = True
    # Auto-downloaded radio songs are deleted after `temporary_retention_days`
    # unless someone likes them or adds them to a playlist.
    temporary_tracks_enabled: bool = True
    temporary_retention_days: int = Field(14, ge=1, le=365)


class DownloadConfig(BaseModel):
    # YouTube Music via yt-dlp as a download source.
    youtube_enabled: bool = True
    # Try public torrents (Prowlarr + qBittorrent) first for album requests.
    torrent_enabled: bool = False
    torrent_min_seeders: int = Field(1, ge=0, le=1000)
    # Give up (and fall back to YouTube) when a torrent makes no progress for this long.
    torrent_timeout_minutes: int = Field(60, ge=5, le=10080)
    prowlarr_api_key: str = ""
    qbittorrent_username: str = "admin"
    qbittorrent_password: str = ""
    # Replace low-quality (e.g. YouTube) files with better releases when found.
    quality_upgrade_enabled: bool = True
    daily_limit_enabled: bool = True
    daily_limit_per_user: int = Field(50, ge=1, le=10000)
    # Requests from non-admins need approval unless this is on.
    auto_approve_requests: bool = True


class LibraryConfig(BaseModel):
    # Free key from https://acoustid.org/new-application – enables audio fingerprint identification.
    acoustid_api_key: str = ""
    # "move": imported files leave the import folder; "copy": originals stay untouched.
    import_mode: Literal["move", "copy"] = "move"
    # Files that cannot be identified are imported with their existing tags instead of being left behind.
    import_unidentified: bool = True
    # Periodically import new files from the import folder (only in "move" mode).
    auto_import: bool = True


class AudiobookshelfConfig(BaseModel):
    # Show the "Hörbücher" tab and allow users to link their Audiobookshelf account.
    enabled: bool = False
    # Base URL of the Audiobookshelf server as reachable from the Resonance server, e.g. https://audio.k-node.de
    url: str = ""

    @field_validator("url")
    @classmethod
    def validate_url(cls, value: str) -> str:
        value = value.rstrip("/")
        if value and not value.startswith(("http://", "https://")):
            raise ValueError("Ungültige Adresse")
        return value


class ServerConfig(BaseModel):
    server_name: str = "Resonance"
    registration: RegistrationConfig = RegistrationConfig()
    radio: RadioConfig = RadioConfig()
    downloads: DownloadConfig = DownloadConfig()
    library: LibraryConfig = LibraryConfig()
    audiobookshelf: AudiobookshelfConfig = AudiobookshelfConfig()


def _deep_merge(base: dict, patch: dict) -> dict:
    out = dict(base)
    for k, v in patch.items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


async def load_config(db: AsyncSession) -> ServerConfig:
    row = await db.get(ServerSetting, KEY)
    return ServerConfig.model_validate(row.value) if row else ServerConfig()


async def update_config(db: AsyncSession, patch: dict) -> ServerConfig:
    current = await load_config(db)
    merged = ServerConfig.model_validate(_deep_merge(current.model_dump(), patch))
    row = await db.get(ServerSetting, KEY)
    if row:
        row.value = merged.model_dump()
    else:
        db.add(ServerSetting(key=KEY, value=merged.model_dump()))
    await db.commit()
    return merged
