import random
import time
import uuid
from collections import Counter, defaultdict
from datetime import date

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Track, TrackLike, User
from app.services.deezer import DeezerError, deezer
from app.services.matching import name_key
from app.services.mixes import genre_keys
from app.services.tags import primary_artist
from app.services.views import track_options

_related_cache: dict[str, tuple[float, set[str]]] = {}


async def _related(artist_key: str, seeds: list[Track]) -> set[str]:
    cached = _related_cache.get(artist_key)
    if cached is not None and time.monotonic() - cached[0] < 24 * 3600:
        return cached[1]
    related: set[str] = set()
    try:
        artist_id = None
        seed = next((track for track in seeds if track.isrc), seeds[0])
        if seed.isrc:
            track = await deezer.track_by_isrc(seed.isrc)
            if track is not None:
                artist_id = str(track["artist"]["id"])
        if artist_id is None:
            artists = await deezer.search_artists(primary_artist(seed.artist_credit), 5)
            artist_id = next((str(a["id"]) for a in artists if name_key(a["name"]) == artist_key), None)
        if artist_id is not None:
            related = {name_key(a["name"]) for a in await deezer.artist_related(artist_id, 10)}
    except DeezerError:
        pass
    _related_cache[artist_key] = (time.monotonic(), related)
    return related


async def recommend(
    db: AsyncSession, user: User, track_ids: list[uuid.UUID], limit: int, exclude_ids: list[uuid.UUID]
) -> list[Track]:
    library = list(await db.scalars(select(Track).options(*track_options()).order_by(Track.id)))
    seed_ids = set(track_ids)
    seeds: dict[str, list[Track]] = defaultdict(list)
    genres: Counter[str] = Counter()
    for track in library:
        if track.id in seed_ids:
            seeds[name_key(primary_artist(track.artist_credit))].append(track)
            genres.update(genre_keys(track.genre) or genre_keys(track.album.genre))
    seed_artists = sorted(seeds, key=lambda key: (-len(seeds[key]), key))[:5]
    related: set[str] = set()
    for key in seed_artists:
        related.update(await _related(key, seeds[key]))
    shared_genres = {key for key, count in genres.items() if count >= 2}
    excluded = seed_ids | set(exclude_ids)
    available = [track for track in library if track.id not in excluded]
    rng = random.Random(f"{user.id}:{','.join(sorted(map(str, seed_ids)))}:{date.today()}")
    weighted = []
    for track in available:
        artist = name_key(primary_artist(track.artist_credit))
        weight = 3 if artist in related else 1 if artist in seed_artists else 0
        if shared_genres.intersection(genre_keys(track.genre) or genre_keys(track.album.genre)):
            weight = max(weight, 1)
        if weight:
            # Higher weights make larger random priorities more likely.
            weighted.append((rng.random() ** (1 / weight), track))
    weighted.sort(key=lambda item: item[0], reverse=True)
    chosen: list[Track] = []
    included: set[uuid.UUID] = set()
    counts: Counter[str] = Counter()

    def add(tracks: list[Track]) -> None:
        for track in tracks:
            artist = name_key(primary_artist(track.artist_credit))
            if len(chosen) == limit:
                return
            if track.id not in included and counts[artist] < 2:
                chosen.append(track)
                included.add(track.id)
                counts[artist] += 1

    add([track for _, track in weighted])
    if len(chosen) < limit:
        liked = set(await db.scalars(select(TrackLike.track_id).where(TrackLike.user_id == user.id)))
        favourites = [track for track in available if track.id in liked]
        rng.shuffle(favourites)
        add(favourites)
    if len(chosen) < limit:
        rng.shuffle(available)
        add(available)
    return chosen
