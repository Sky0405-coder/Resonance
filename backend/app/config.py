from functools import lru_cache
from pathlib import Path

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Static process configuration (env vars). Runtime-changeable settings live in the DB, see services/server_settings.py."""

    model_config = SettingsConfigDict(env_prefix="RESONANCE_", env_file=".env", extra="ignore")

    database_url: str = "postgresql+asyncpg://app:app@localhost:55432/app"
    # Root of the sorted music library (read by the scanner, written by the importer later on).
    music_dir: Path = Path("/data/music")
    # Writable directory for caches (covers, transcodes) and other app state.
    data_dir: Path = Path("/data/app")
    # Built Flutter web app; served at / when present.
    web_dir: Path | None = None

    # Working directory for in-progress downloads (same disk as music_dir so moves are cheap).
    downloads_dir: Path = Path("/data/downloads")
    # Contact for the MusicBrainz User-Agent (their API policy asks for one), e.g. an e-mail or URL.
    musicbrainz_contact: str = ""
    # Number of parallel download workers; 0 disables the background worker (tests).
    download_workers: int = 2
    # Optional Netscape cookies file for yt-dlp (age-restricted videos).
    ytdlp_cookies_file: Path | None = None

    session_ttl_days: int = 90
    invite_default_ttl_hours: int = 72
    ffmpeg_path: str = "ffmpeg"
    cors_origins: list[str] = ["*"]

    @property
    def cover_cache_dir(self) -> Path:
        return self.data_dir / "covers"


@lru_cache
def get_settings() -> Settings:
    return Settings()
