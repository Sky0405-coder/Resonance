import asyncio
import logging
import random
import re
import uuid
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import UTC, date, datetime, time, timedelta
from itertools import zip_longest

from fastapi import HTTPException
from sqlalchemy import delete, func, select
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.engine import Row
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.api.catalog import _track
from app.db import SessionLocal
from app.models import (
    Artist,
    PlayEvent,
    Playlist,
    PlaylistEntry,
    RadioPending,
    Track,
    TrackLike,
    User,
)
from app.services.deezer import DeezerError, artist_string, deezer
from app.services.downloads import create_request
from app.services.matching import match_tracks, name_key
from app.services.server_config import load_config
from app.services.tags import primary_artist

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


def decade_label(decade: int) -> str:
    """1980 → "80er", 2010 → "2010er" (as the decades are usually called)."""
    return f"{decade % 100:02d}er" if decade < 2000 else f"{decade}er"


def mix_search_terms(mix_key: str | None) -> list[str]:
    """Extra words a mix is found by in the search, e.g. "80s" or "achtziger" for the 80er Mix."""
    if not mix_key or not mix_key.startswith("decade:"):
        return []
    decade = int(mix_key.split(":", 1)[1])
    short = f"{decade % 100:02d}"
    words = {
        1950: ["fünfziger", "fifties"],
        1960: ["sechziger", "sixties"],
        1970: ["siebziger", "seventies"],
        1980: ["achtziger", "eighties"],
        1990: ["neunziger", "nineties"],
        2000: ["nullerjahre", "noughties"],
        2010: ["zehnerjahre"],
        2020: ["zwanziger"],
    }.get(decade, [])
    return [str(decade), f"{decade}s", f"{short}s", f"{short}er", *words]


@dataclass
class _Taste:
    tracks: list[Track]
    by_artist: dict[uuid.UUID, list[Track]]
    artists: dict[uuid.UUID, Artist]
    history: dict[uuid.UUID, Row]
    likes: dict[uuid.UUID, datetime]
    scores: dict[uuid.UUID, int]
    artist_scores: dict[uuid.UUID, int]
    favourites: list[uuid.UUID]


async def _taste(db: AsyncSession, user: User, now: datetime) -> _Taste:
    tracks = list(
        await db.scalars(
            select(Track)
            .options(joinedload(Track.album), joinedload(Track.artist))
            .where(~Track.is_temporary)
            .order_by(Track.id)
        )
    )
    by_artist: dict[uuid.UUID, list[Track]] = defaultdict(list)
    for track in tracks:
        by_artist[track.artist_id].append(track)
    artists = {artist_id: artist_tracks[0].artist for artist_id, artist_tracks in by_artist.items()}
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
    return _Taste(tracks, by_artist, artists, history, likes, scores, artist_scores, favourites)


async def _deezer_artist_id(artist: Artist) -> str | None:
    try:
        matches = await deezer.search_artists(artist.name, 5)
        return next((str(item["id"]) for item in matches if name_key(item["name"]) == artist.name_key), None)
    except DeezerError:
        log.debug("Mix artist lookup failed", exc_info=True)
        return None


async def _related_artists(artist_id: str | None) -> list[dict]:
    if artist_id is None:
        return []
    try:
        return await deezer.artist_related(artist_id, 10)
    except DeezerError:
        log.debug("Mix related artist lookup failed", exc_info=True)
        return []


async def _write(
    db: AsyncSession,
    user: User,
    key: str,
    name: str,
    description: str,
    track_ids: list[uuid.UUID],
    now: datetime,
    pending: list[str] | None = None,
) -> Playlist | None:
    if not track_ids and not pending:
        return None
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
    await db.execute(delete(RadioPending).where(RadioPending.playlist_id == playlist.id))
    await db.execute(delete(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist.id))
    db.add_all(
        [
            PlaylistEntry(playlist_id=playlist.id, track_id=track_id, position=i)
            for i, track_id in enumerate(track_ids, 1)
        ]
    )
    db.add_all([RadioPending(playlist_id=playlist.id, deezer_id=deezer_id) for deezer_id in pending or []])
    return playlist


def discover_due(generated_at: datetime | None) -> bool:
    local = datetime.now(UTC).astimezone()
    monday = datetime.combine(local.date() - timedelta(days=local.weekday()), time.min).astimezone()
    return generated_at is None or generated_at < monday


async def generate_discover(db: AsyncSession, user: User) -> Playlist | None:
    cfg = await load_config(db)
    if not cfg.mixes.discover_enabled:
        return None
    now = datetime.now(UTC)
    taste = await _taste(db, user, now)
    seeds = [taste.artists[artist_id] for artist_id in taste.favourites[:10]]
    if not seeds:
        return None
    seed_ids = [await _deezer_artist_id(artist) for artist in seeds]
    seed_keys = {artist.name_key for artist in seeds}
    seed_tracks: list[list[dict]] = []
    for seed_id in seed_ids:
        tracks: list[dict] = []
        for artist in await _related_artists(seed_id):
            if str(artist["id"]) in seed_ids or name_key(artist["name"]) in seed_keys:
                continue
            try:
                tracks.extend(await deezer.artist_top(str(artist["id"]), 5))
            except DeezerError:
                log.debug("Discover top tracks lookup failed", exc_info=True)
        seed_tracks.append(tracks)
    candidates: list[dict] = []
    ids: set[str] = set()
    names: set[tuple[str, str]] = set()
    artist_counts: Counter[str] = Counter()
    for group in zip_longest(*seed_tracks):
        for track in group:
            if track is None:
                continue
            deezer_id = str(track["id"])
            artist_key = name_key(primary_artist(artist_string(track)))
            key = (artist_key, name_key(track["title"]))
            if deezer_id in ids or key in names or artist_counts[artist_key] >= 2:
                continue
            candidates.append(track)
            ids.add(deezer_id)
            names.add(key)
            artist_counts[artist_key] += 1
    catalog = [_track(track) for track in candidates]
    await match_tracks(db, catalog)
    eligible = [
        track for track in catalog if track.library_id not in taste.history and track.library_id not in taste.likes
    ]
    chosen: list[uuid.UUID] = []
    pending: list[str] = []
    download_limit = cfg.mixes.discover_downloads
    for track in eligible[:30]:
        if track.library_id is not None:
            if track.library_id not in chosen:
                chosen.append(track.library_id)
        elif len(pending) < download_limit:
            try:
                await create_request(
                    db, user, "track", track.id, temporary=cfg.radio.temporary_tracks_enabled, radio=True
                )
            except HTTPException as exc:
                if exc.status_code == 429:
                    download_limit = 0
                continue
            pending.append(track.id)
    playlist = await _write(
        db, user, "discover-weekly", "Mix der Woche", "Neue Songs für dich – jeden Montag neu", chosen, now, pending
    )
    await db.commit()
    return playlist


async def generate_mixes(db: AsyncSession, user: User) -> None:
    now = datetime.now(UTC)
    taste = await _taste(db, user, now)
    tracks, by_artist, artists = taste.tracks, taste.by_artist, taste.artists
    history, likes, scores = taste.history, taste.likes, taste.scores
    artist_scores, favourites = taste.artist_scores, taste.favourites
    artist_ids_by_key = {artist.name_key: artist.id for artist in artists.values()}
    by_genre: dict[str, list[Track]] = defaultdict(list)
    for track in tracks:
        for key in genre_keys(track.genre) or genre_keys(track.album.genre):
            by_genre[key].append(track)
    dominant: dict[uuid.UUID, str] = {}
    for artist_id, artist_tracks in by_artist.items():
        counts = Counter(
            key for track in artist_tracks for key in (genre_keys(track.genre) or genre_keys(track.album.genre))
        )
        dominant[artist_id] = min(counts, key=lambda key: (-counts[key], key)) if counts else "other"
    related_cache: dict[uuid.UUID, list[uuid.UUID]] = {}

    async def related_artists(seeds: list[uuid.UUID]) -> list[uuid.UUID]:
        related: dict[uuid.UUID, None] = {}
        for artist_id in seeds:
            if artist_id not in related_cache:
                related_cache[artist_id] = []
                results = await _related_artists(await _deezer_artist_id(artists[artist_id]))
                related_cache[artist_id] = list(
                    dict.fromkeys(
                        artist_ids_by_key[name_key(item["name"])]
                        for item in results
                        if name_key(item["name"]) in artist_ids_by_key
                    )
                )
            related.update(dict.fromkeys(related_cache[artist_id]))
        return list(related)

    produced: set[str] = set()

    async def write(key: str, name: str, description: str, chosen: list[Track]) -> None:
        track_ids = list(dict.fromkeys(track.id for track in chosen))[:50]
        if len(track_ids) < 5:
            return
        await _write(db, user, key, name, description, track_ids, now)
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

    favourite_tracks = sorted((track for track in tracks if scores[track.id] > 0), key=lambda track: -scores[track.id])
    rng = random.Random(f"{user.id}:{date.today()}:favourites")
    favourite_tracks = favourite_tracks[:50]
    rng.shuffle(favourite_tracks)
    await write("favourites", "Deine Favoriten", "Deine meistgehörten und gelikten Songs", favourite_tracks)

    # New releases (this or last year) and recent library additions by favourite artists, like a "New Music Mix".
    favourite_set = set(favourites)
    recent = now - timedelta(days=30)
    fresh = [
        track
        for track in tracks
        if track.artist_id in favourite_set
        and ((track.year or track.album.year or 0) >= now.year - 1 or (track.created_at and track.created_at >= recent))
        and (history[track.id].total if track.id in history else 0) < 3
    ]
    random.Random(f"{user.id}:{date.today()}:new-music").shuffle(fresh)
    await write(
        "new-music", "Neuheiten-Mix", "Neue Songs deiner Lieblingskünstler und frisch in der Bibliothek", fresh
    )

    by_decade: dict[int, list[Track]] = defaultdict(list)
    for track in tracks:
        year = track.year or track.album.year
        if year and 1950 <= year <= now.year:
            by_decade[year // 10 * 10].append(track)
    for decade in sorted(decade for decade, decade_tracks in by_decade.items() if len(decade_tracks) >= 15):
        key = f"decade:{decade}"
        rng = random.Random(f"{user.id}:{date.today()}:{key}")
        candidates = list(by_decade[decade])
        rng.shuffle(candidates)
        preferred = sorted(
            (track for track in candidates if scores[track.id] > 0), key=lambda track: -scores[track.id]
        )[:15]
        preferred_ids = {track.id for track in preferred}
        chosen = [*preferred, *(track for track in candidates if track.id not in preferred_ids)][:50]
        rng.shuffle(chosen)
        label = decade_label(decade)
        await write(key, f"{label} Mix", f"Das Beste aus den {label}n in deiner Bibliothek", chosen)

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
            Playlist.mix_key.is_distinct_from("discover-weekly"),
            Playlist.mix_key.is_(None) | Playlist.mix_key.not_in(produced),
        )
    )
    await db.commit()


async def _generate_due() -> None:
    now = datetime.now(UTC)
    async with SessionLocal() as db:
        newest = (
            select(
                Playlist.owner_id,
                func.max(Playlist.generated_at)
                .filter(Playlist.mix_key.is_distinct_from("discover-weekly"))
                .label("generated_at"),
                func.count().label("count"),
            )
            .where(Playlist.kind == "mix")
            .group_by(Playlist.owner_id)
            .subquery()
        )
        cfg = await load_config(db)
        discover = (
            select(Playlist.owner_id, Playlist.generated_at).where(Playlist.mix_key == "discover-weekly").subquery()
        )
        rows = (
            await db.execute(
                select(User.id, newest.c.generated_at, discover.c.generated_at)
                .outerjoin(newest, newest.c.owner_id == User.id)
                .outerjoin(discover, discover.c.owner_id == User.id)
                .where(~User.is_disabled, (User.last_seen_at >= now - timedelta(days=14)) | newest.c.count.is_(None))
            )
        ).all()
    for user_id, generated_at, discover_at in rows:
        daily_due = generated_at is None or generated_at.astimezone().date() != date.today()
        weekly_due = cfg.mixes.discover_enabled and discover_due(discover_at)
        if not daily_due and not weekly_due:
            continue
        try:
            async with SessionLocal() as db:
                user = await db.get(User, user_id)
                if user is not None and not user.is_disabled:
                    if daily_due:
                        await generate_mixes(db, user)
                    if weekly_due:
                        await generate_discover(db, user)
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
