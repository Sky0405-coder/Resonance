import asyncio
import logging
import random
import re
import uuid
from collections import Counter, defaultdict
from datetime import UTC, date, datetime, timedelta

from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.db import SessionLocal
from app.models import PlayEvent, Playlist, PlaylistEntry, Track, TrackLike, User
from app.services.deezer import DeezerError, deezer
from app.services.matching import name_key

GENRE_NAMES = {"hip hop": "Hip-Hop", "r&b": "R&B", "edm": "EDM"}
log = logging.getLogger(__name__)
_loop_task: asyncio.Task | None = None


def genre_keys(raw: str | None) -> list[str]:
    if not raw:
        return []
    aliases = {
        "hip hop": "hip hop",
        "hiphop": "hip hop",
        "rap": "hip hop",
        "hip hop rap": "hip hop",
        "r&b": "r&b",
        "rnb": "r&b",
        "r and b": "r&b",
        "electronica": "electronic",
        "electro": "electronic",
        "rock & roll": "rock",
        "rock n roll": "rock",
    }
    # Preserve the alias containing the same separator used by multi-genre tags.
    raw = re.sub(r"\brock\s+&\s+roll\b", "rock n roll", raw, flags=re.IGNORECASE)
    keys: list[str] = []
    for part in re.split(r"[;,/|]| & ", raw):
        key = " ".join(part.strip().casefold().replace("-", " ").replace("_", " ").split())
        if key and key not in {"unknown", "other", "misc"}:
            key = aliases.get(key, key)
            if key not in keys:
                keys.append(key)
    return keys


async def generate_mixes(db: AsyncSession, user: User) -> None:
    now = datetime.now(UTC)
    tracks = list(
        await db.scalars(
            select(Track)
            .options(joinedload(Track.album), joinedload(Track.artist))
            .where(~Track.is_temporary)
            .order_by(Track.id)
        )
    )
    by_artist: dict[uuid.UUID, list[Track]] = defaultdict(list)
    by_genre: dict[str, list[Track]] = defaultdict(list)
    for track in tracks:
        by_artist[track.artist_id].append(track)
        for key in genre_keys(track.genre) or genre_keys(track.album.genre):
            by_genre[key].append(track)
    artists = {artist_id: artist_tracks[0].artist for artist_id, artist_tracks in by_artist.items()}
    artist_ids_by_key = {artist.name_key: artist.id for artist in artists.values()}
    dominant: dict[uuid.UUID, str] = {}
    for artist_id, artist_tracks in by_artist.items():
        counts = Counter(
            key for track in artist_tracks for key in (genre_keys(track.genre) or genre_keys(track.album.genre))
        )
        dominant[artist_id] = min(counts, key=lambda key: (-counts[key], key)) if counts else "other"

    history = {
        row.track_id: row
        for row in await db.execute(
            select(
                PlayEvent.track_id,
                func.count().label("total"),
                func.count()
                .filter(PlayEvent.played_at >= now - timedelta(days=90), PlayEvent.seconds_played >= 30)
                .label("recent"),
                func.min(PlayEvent.played_at).label("first"),
                func.max(PlayEvent.played_at).label("last"),
            )
            .where(PlayEvent.user_id == user.id)
            .group_by(PlayEvent.track_id)
        )
    }
    likes = dict(
        (await db.execute(select(TrackLike.track_id, TrackLike.created_at).where(TrackLike.user_id == user.id))).all()
    )
    scores = {
        track.id: (history[track.id].recent if track.id in history else 0) + 3 * (track.id in likes) for track in tracks
    }
    artist_scores = {
        artist_id: sum(scores[track.id] for track in artist_tracks) for artist_id, artist_tracks in by_artist.items()
    }
    favourites = sorted(
        (artist_id for artist_id in artists if artist_scores[artist_id] > 0),
        key=lambda artist_id: (-artist_scores[artist_id], artists[artist_id].name_key),
    )[:30]
    related_cache: dict[uuid.UUID, list[uuid.UUID]] = {}

    async def related_artists(seeds: list[uuid.UUID]) -> list[uuid.UUID]:
        related: dict[uuid.UUID, None] = {}
        for artist_id in seeds:
            if artist_id not in related_cache:
                related_cache[artist_id] = []
                try:
                    matches = await deezer.search_artists(artists[artist_id].name, 5)
                    match = next(
                        (item for item in matches if name_key(item["name"]) == artists[artist_id].name_key), None
                    )
                    if match is not None:
                        results = await deezer.artist_related(str(match["id"]), 10)
                        related_cache[artist_id] = list(
                            dict.fromkeys(
                                artist_ids_by_key[name_key(item["name"])]
                                for item in results
                                if name_key(item["name"]) in artist_ids_by_key
                            )
                        )
                except DeezerError:
                    log.debug("Mix related artist lookup failed", exc_info=True)
            related.update(dict.fromkeys(related_cache[artist_id]))
        return list(related)

    produced: set[str] = set()

    async def write(key: str, name: str, description: str, chosen: list[Track]) -> None:
        track_ids = list(dict.fromkeys(track.id for track in chosen))[:50]
        if len(track_ids) < 5:
            return
        playlist = await db.scalar(
            insert(Playlist)
            .values(
                owner_id=user.id,
                mix_key=key,
                kind="mix",
                is_public=False,
                name=name,
                description=description,
                generated_at=now,
            )
            .on_conflict_do_update(
                index_elements=[Playlist.owner_id, Playlist.mix_key],
                index_where=Playlist.mix_key.is_not(None),
                set_={
                    "kind": "mix",
                    "is_public": False,
                    "name": name,
                    "description": description,
                    "generated_at": now,
                    "updated_at": now,
                },
            )
            .returning(Playlist)
            .execution_options(populate_existing=True)
        )
        await db.execute(delete(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist.id))
        db.add_all(
            [
                PlaylistEntry(playlist_id=playlist.id, track_id=track_id, position=i)
                for i, track_id in enumerate(track_ids, 1)
            ]
        )
        produced.add(key)

    groups: dict[str, list[uuid.UUID]] = defaultdict(list)
    for artist_id in favourites:
        groups[dominant[artist_id]].append(artist_id)
    eligible = sorted(
        (key for key, group in groups.items() if len(group) >= 2),
        key=lambda key: (-sum(artist_scores[artist_id] for artist_id in groups[key]), key),
    )[:3]
    daily_groups = [groups[key] for key in eligible] if len(eligible) >= 2 else ([favourites] if favourites else [])
    for index, group in enumerate(daily_groups, 1):
        key = f"daily:{index}"
        rng = random.Random(f"{user.id}:{date.today()}:{key}")
        chosen: list[Track] = []
        for artist_id in group:
            candidates = list(by_artist[artist_id])
            rng.shuffle(candidates)
            candidates.sort(
                key=lambda track: (track.id not in likes, -(history[track.id].recent if track.id in history else 0))
            )
            chosen.extend(candidates[:6])
        related = [artist_id for artist_id in await related_artists(group[:5]) if artist_id not in group][:8]
        for artist_id in related:
            candidates = list(by_artist[artist_id])
            rng.shuffle(candidates)
            chosen.extend(candidates[:3])
        rng.shuffle(chosen)
        await write(
            key,
            f"Daily Mix {index}",
            ", ".join(artists[artist_id].name for artist_id in group[:3]) + " und mehr",
            chosen,
        )

    if favourites:
        rng = random.Random(f"{user.id}:{date.today()}:discover")
        related = await related_artists(favourites[:10])
        favourite_genres = {dominant[artist_id] for artist_id in favourites}
        fill = [
            artist_id
            for artist_id in artists
            if artist_id not in favourites and dominant[artist_id] in favourite_genres and artist_id not in related
        ]
        rng.shuffle(fill)
        discovered: list[Track] = []
        for artist_id in [*related, *fill]:
            candidates = [track for track in by_artist[artist_id] if track.id not in history and track.id not in likes]
            rng.shuffle(candidates)
            discovered.extend(candidates[:2])
            if len(discovered) >= 30:
                break
        discovered = discovered[:30]
        rng.shuffle(discovered)
        await write(
            "discover", "Neu für dich", "Songs aus deiner Bibliothek, die du noch nicht gehört hast", discovered
        )

    cutoff = now - timedelta(days=60)
    rewound: list[Track] = []
    for track in tracks:
        plays = history.get(track.id)
        if track.id not in likes and (plays is None or plays.total < 3):
            continue
        if plays is not None and plays.last >= cutoff:
            continue
        since = [likes[track.id]] if track.id in likes else []
        if plays is not None:
            since.append(plays.first)
        if min(since) < cutoff:
            rewound.append(track)
    random.Random(f"{user.id}:{date.today()}:rewind").shuffle(rewound)
    await write("rewind", "Lange nicht gehört", "Songs, die du lange nicht gehört hast", rewound)

    genres = sorted(
        (key for key, genre_tracks in by_genre.items() if len(genre_tracks) >= 15),
        key=lambda key: (-len(by_genre[key]), key),
    )[:12]
    for genre in genres:
        key = f"genre:{genre}"
        rng = random.Random(f"{user.id}:{date.today()}:{key}")
        candidates = list(by_genre[genre])
        rng.shuffle(candidates)
        preferred = sorted(
            (track for track in candidates if scores[track.id] > 0), key=lambda track: -scores[track.id]
        )[:15]
        preferred_ids = {track.id for track in preferred}
        chosen = [*preferred, *(track for track in candidates if track.id not in preferred_ids)][:50]
        display = GENRE_NAMES.get(genre, genre.title())
        await write(key, f"{display} Mix", f"Das Beste aus {display} in deiner Bibliothek", chosen)

    await db.execute(
        delete(Playlist).where(
            Playlist.owner_id == user.id,
            Playlist.kind == "mix",
            Playlist.mix_key.is_(None) | Playlist.mix_key.not_in(produced),
        )
    )
    await db.commit()


async def _generate_due() -> None:
    now = datetime.now(UTC)
    async with SessionLocal() as db:
        newest = (
            select(
                Playlist.owner_id, func.max(Playlist.generated_at).label("generated_at"), func.count().label("count")
            )
            .where(Playlist.kind == "mix")
            .group_by(Playlist.owner_id)
            .subquery()
        )
        rows = (
            await db.execute(
                select(User.id, newest.c.generated_at)
                .outerjoin(newest, newest.c.owner_id == User.id)
                .where(~User.is_disabled, (User.last_seen_at >= now - timedelta(days=14)) | newest.c.count.is_(None))
            )
        ).all()
    for user_id, generated_at in rows:
        if generated_at is not None and generated_at.astimezone().date() == date.today():
            continue
        try:
            async with SessionLocal() as db:
                user = await db.get(User, user_id)
                if user is not None and not user.is_disabled:
                    await generate_mixes(db, user)
        except Exception:
            log.exception("Mix generation failed for user %s", user_id)


async def _generate_loop() -> None:
    while True:
        await asyncio.sleep(600)
        try:
            await _generate_due()
        except Exception:
            log.exception("Mix generation loop failed")


async def start() -> None:
    global _loop_task
    if _loop_task is None or _loop_task.done():
        _loop_task = asyncio.create_task(_generate_loop())


async def stop() -> None:
    global _loop_task
    if _loop_task is not None:
        _loop_task.cancel()
        await asyncio.gather(_loop_task, return_exceptions=True)
        _loop_task = None
