from app.services.server_config import ServerConfig
from app.services.sources.base import Source
from app.services.sources.soundcloud import SoundCloudSource
from app.services.sources.youtube import YouTubeMusicSource

_youtube: YouTubeMusicSource | None = None
_soundcloud: SoundCloudSource | None = None


def enabled_sources(cfg: ServerConfig) -> list[Source]:
    global _youtube, _soundcloud
    sources: list[Source] = []
    if cfg.downloads.youtube_enabled:
        if _youtube is None:
            _youtube = YouTubeMusicSource()
        sources.append(_youtube)
    if cfg.downloads.soundcloud_enabled:
        if _soundcloud is None:
            _soundcloud = SoundCloudSource()
        sources.append(_soundcloud)
    return sources
