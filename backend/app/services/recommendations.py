"""Songs to add to a playlist: ones that sound and feel like it.

Each library song gets a style score from what ties it to the playlist's songs (Deezer's radio of their artists,
related artists, the artists' Last.fm tags, shared genres, songs the user keeps in playlists or plays together with
them) and a sound match (energy and tempo from the song analysis, near the playlist's own). The best ones win, with
a little daily randomness so the list changes from day to day; at most two per artist."""

import asyncio
import math
import random
import time
import uuid
from collections import Counter, defaultdict
from datetime import UTC, date, datetime, timedelta
from statistics import median, pstdev

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import (
    PlayEvent,
    Playlist,
    PlaylistEntry,
    Track,
    TrackLike,
    TrackMixPoints,
    User,
)
from app.services.deezer import DeezerError, deezer
from app.services.matching import name_key
from app.services.mixes import genre_keys
from app.services.tags import primary_artist
from app.services.views import track_options

# artist key -> (fetched at, related artist keys, (artist key, title key) of the songs on the artist's Deezer radio)
_related_cache: dict[str, tuple[float, set[str], set[tuple[str, str]]]] = {}
SEED_ARTISTS = 8
# Plays further apart than this belong to different listening sessions.
_SESSION_GAP = timedelta(minutes=30)


async def _related(artist_key: str, seeds: list[Track]) -> tuple[set[str], set[tuple[str, str]]]:
    cached = _related_cache.get(artist_key)
    if cached is not None and time.monotonic() - cached[0] < 24 * 3600:
        return cached[1], cached[2]
    related: set[str] = set()
    radio: set[tuple[str, str]] = set()
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
            try:
                radio = {
                    (name_key(item["artist"]["name"]), name_key(item["title"]))
                    for item in await deezer.artist_radio(artist_id)
                    if item.get("artist") and item.get("title")
                }
            except DeezerError:
                pass
    except DeezerError:
        pass
    _related_cache[artist_key] = (time.monotonic(), related, radio)
    return related, radio


def _tag_weights(library: list[Track]) -> dict[str, float]:
    """Inverse document frequency of each Last.fm tag over the library's artists: "pop" says little, "dark pop" more."""
    artists = {
        track.artist.id: track.artist.lastfm_tags for track in library if track.artist and track.artist.lastfm_tags
    }
    counts: Counter[str] = Counter(tag for tags in artists.values() for tag in tags)
    total = len(artists) + 1
    return {tag: math.log(total / count) for tag, count in counts.items()}


def _tag_vector(tags: dict | None, weights: dict[str, float]) -> dict[str, float]:
    return {tag: count / 100 * weights.get(tag, 0) for tag, count in (tags or {}).items() if count >= 10}


def _cosine(a: dict[str, float], b: dict[str, float]) -> float:
    if not a or not b:
        return 0.0
    dot = sum(value * b.get(tag, 0) for tag, value in a.items())
    norm = math.sqrt(sum(v * v for v in a.values())) * math.sqrt(sum(v * v for v in b.values()))
    return dot / norm if norm else 0.0


def _tempo_distance(bpm: float, center: float) -> float:
    """How far apart two tempos are in octaves, counting double and half time as the same."""
    d = math.log2(bpm / center)
    return min(abs(d), abs(d - 1), abs(d + 1))


class _Sound:
    """The playlist's energy and tempo (median and spread); a song's match with it from 0 to 1."""

    def __init__(self, points: list[tuple[float | None, float | None]]):
        energies = [e for e, _ in points if e is not None]
        tempos = [b for _, b in points if b]
        self.energy = median(energies) if energies else None
        self.energy_spread = max(0.08, pstdev(energies)) if len(energies) >= 2 else 0.12
        self.tempo = median(tempos) if tempos else None
        spread = pstdev([_tempo_distance(b, self.tempo) for b in tempos]) if len(tempos) >= 2 else 0.0
        self.tempo_spread = max(0.1, spread)

    def match(self, energy: float | None, bpm: float | None) -> float:
        """1 for a song right in the middle; unanalyzed songs count as so-so."""
        if self.energy is None and self.tempo is None:
            return 1.0
        score = 0.6
        if energy is not None and self.energy is not None:
            z = (energy - self.energy) / self.energy_spread
            score = math.exp(-z * z / 2)
        if bpm and self.tempo:
            z = _tempo_distance(bpm, self.tempo) / self.tempo_spread
            score *= 0.6 + 0.4 * math.exp(-z * z / 2)
        return score


async def _sessions_with(db: AsyncSession, user: User, seed_ids: set[uuid.UUID]) -> Counter[uuid.UUID]:
    """How many of the user's listening sessions of the last year had each song together with a playlist song."""
    rows = (
        await db.execute(
            select(PlayEvent.track_id, PlayEvent.played_at)
            .where(PlayEvent.user_id == user.id, PlayEvent.played_at > datetime.now(UTC) - timedelta(days=365))
            .order_by(PlayEvent.played_at.desc())
            .limit(20000)
        )
    ).all()
    together: Counter[uuid.UUID] = Counter()
    session: set[uuid.UUID] = set()
    last: datetime | None = None

    def close() -> None:
        if session & seed_ids:
            together.update(session - seed_ids)

    for track_id, played_at in rows:
        if last is not None and last - played_at > _SESSION_GAP:
            close()
            session = set()
        session.add(track_id)
        last = played_at
    close()
    return together


async def _playlists_with(db: AsyncSession, user: User, seed_ids: set[uuid.UUID]) -> Counter[uuid.UUID]:
    """Songs in the user's own playlists (not generated mixes) next to playlist songs, weighted by how many of the
    playlist's songs each of those playlists holds."""
    rows = (
        await db.execute(
            select(PlaylistEntry.playlist_id, PlaylistEntry.track_id)
            .join(Playlist, Playlist.id == PlaylistEntry.playlist_id)
            .where(Playlist.owner_id == user.id, Playlist.mix_key.is_(None), Playlist.radio_seed.is_(None))
        )
    ).all()
    members: dict[uuid.UUID, set[uuid.UUID]] = defaultdict(set)
    for playlist_id, track_id in rows:
        members[playlist_id].add(track_id)
    together: Counter[uuid.UUID] = Counter()
    for tracks in members.values():
        shared = len(tracks & seed_ids)
        # The playlist being filled itself (nearly all its songs are seeds) adds nothing new.
        if shared and shared < len(seed_ids) * 0.9:
            for track_id in tracks - seed_ids:
                together[track_id] += min(1.0, shared / 3)
    return together


async def recommend(
    db: AsyncSession, user: User, track_ids: list[uuid.UUID], limit: int, exclude_ids: list[uuid.UUID]
) -> list[Track]:
    library = list(await db.scalars(select(Track).options(*track_options()).order_by(Track.id)))
    # Without seeds (a new, empty playlist), the user's latest likes stand in; those may be suggested too.
    from_likes = not track_ids
    if from_likes:
        track_ids = list(
            await db.scalars(
                select(TrackLike.track_id)
                .where(TrackLike.user_id == user.id)
                .order_by(TrackLike.created_at.desc(), TrackLike.id)
                .limit(25)
            )
        )
    seed_ids = set(track_ids)
    seeds: dict[str, list[Track]] = defaultdict(list)
    genres: Counter[str] = Counter()
    seed_tracks = [track for track in library if track.id in seed_ids]
    for track in seed_tracks:
        seeds[name_key(primary_artist(track.artist_credit))].append(track)
        genres.update(genre_keys(track.genre) or genre_keys(track.album.genre))
    seed_artists = sorted(seeds, key=lambda key: (-len(seeds[key]), key))[:SEED_ARTISTS]
    related: set[str] = set()
    radio: set[tuple[str, str]] = set()
    for artist_related, artist_radio in await asyncio.gather(*(_related(key, seeds[key]) for key in seed_artists)):
        related |= artist_related
        radio |= artist_radio
    shared_genres = {key for key, count in genres.items() if count >= 2}

    weights = _tag_weights(library)
    profile: Counter[str] = Counter()
    for track in seed_tracks:
        if track.artist is not None:
            profile.update(_tag_vector(track.artist.lastfm_tags, weights))
    profile_vector = dict(profile)
    artist_similarity: dict[uuid.UUID, float] = {}

    analysis = {
        track_id: (energy, bpm)
        for track_id, energy, bpm in (
            await db.execute(
                select(TrackMixPoints.track_id, TrackMixPoints.energy, TrackMixPoints.bpm).where(
                    TrackMixPoints.failed.is_(False)
                )
            )
        ).all()
    }
    sound = _Sound([analysis[track.id] for track in seed_tracks if track.id in analysis])
    sessions = await _sessions_with(db, user, seed_ids) if seed_ids else Counter()
    playlists = await _playlists_with(db, user, seed_ids) if seed_ids else Counter()

    excluded = set(exclude_ids) if from_likes else seed_ids | set(exclude_ids)
    available = [track for track in library if track.id not in excluded]
    rng = random.Random(f"{user.id}:{','.join(sorted(map(str, seed_ids)))}:{date.today()}")

    def sound_of(track: Track) -> float:
        energy, bpm = analysis.get(track.id, (None, None))
        return sound.match(energy, bpm)

    scored = []
    for track in available:
        artist = name_key(primary_artist(track.artist_credit))
        style = 0.0
        if (artist, name_key(track.title)) in radio:
            style += 4
        if artist in related:
            style += 3
        elif artist in seed_artists:
            style += 1.5
        if track.artist is not None and track.artist.lastfm_tags and profile_vector:
            if track.artist.id not in artist_similarity:
                artist_similarity[track.artist.id] = _cosine(
                    _tag_vector(track.artist.lastfm_tags, weights), profile_vector
                )
            style += 3 * artist_similarity[track.artist.id]
        if shared_genres.intersection(genre_keys(track.genre) or genre_keys(track.album.genre)):
            style += 1
        style += 2 * min(1.0, sessions[track.id] / 3) + 2 * min(1.0, playlists[track.id])
        # Weak ties alone (a broad shared tag) are not enough to count as fitting.
        if style >= 1:
            score = style * (0.35 + 0.65 * sound_of(track))
            scored.append((score * (0.75 + 0.5 * rng.random()), track))
    scored.sort(key=lambda item: item[0], reverse=True)
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

    add([track for _, track in scored])
    if len(chosen) < limit:
        # Then the user's favourites, and then anything, those that sound most like the playlist first.
        liked = set(await db.scalars(select(TrackLike.track_id).where(TrackLike.user_id == user.id)))
        favourites = [track for track in available if track.id in liked]
        rng.shuffle(favourites)
        favourites.sort(key=sound_of, reverse=True)
        add(favourites)
    if len(chosen) < limit:
        rng.shuffle(available)
        available.sort(key=sound_of, reverse=True)
        add(available)
    return chosen
