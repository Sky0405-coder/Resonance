from app.services.server_config import ServerConfig
from app.services.sources.bandcamp import BandcampSource
from app.services.sources.base import Source
from app.services.sources.soundcloud import SoundCloudSource
from app.services.sources.youtube import YouTubeMusicSource

_youtube: YouTubeMusicSource | None = None
_soundcloud: SoundCloudSource | None = None
_bandcamp: BandcampSource | None = None


def enabled_sources(cfg: ServerConfig) -> list[Source]:
    global _youtube, _soundcloud, _bandcamp
    sources: list[Source] = []
    if cfg.downloads.youtube_enabled:
        if _youtube is None:
            _youtube = YouTubeMusicSource()
        sources.append(_youtube)
    if cfg.downloads.soundcloud_enabled:
        if _soundcloud is None:
            _soundcloud = SoundCloudSource()
        sources.append(_soundcloud)
    if cfg.downloads.bandcamp_enabled:
        if _bandcamp is None:
            _bandcamp = BandcampSource()
        sources.append(_bandcamp)
    return sources
