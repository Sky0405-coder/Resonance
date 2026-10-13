"""Runtime server configuration editable from the admin dashboard.

Stored as a single JSON document so that new options only need a field with a
default here — no migration required.
"""

from typing import Literal

from pydantic import BaseModel, Field
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
    # Replace low-quality (e.g. YouTube) files with better releases when found.
    quality_upgrade_enabled: bool = True
    daily_limit_enabled: bool = True
    daily_limit_per_user: int = Field(50, ge=1, le=10000)
    # Requests from non-admins need approval unless this is on.
    auto_approve_requests: bool = True


class ServerConfig(BaseModel):
    server_name: str = "Resonance"
    registration: RegistrationConfig = RegistrationConfig()
    radio: RadioConfig = RadioConfig()
    downloads: DownloadConfig = DownloadConfig()


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
