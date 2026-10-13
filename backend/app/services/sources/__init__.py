from app.services.server_config import ServerConfig
from app.services.sources.base import Source
from app.services.sources.youtube import YouTubeMusicSource

_youtube: YouTubeMusicSource | None = None


def enabled_sources(cfg: ServerConfig) -> list[Source]:
    global _youtube
    if not cfg.downloads.youtube_enabled:
        return []
    if _youtube is None:
        _youtube = YouTubeMusicSource()
    return [_youtube]
