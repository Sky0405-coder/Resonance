import asyncio
import hashlib
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
    Album,
    Artist,
    DownloadItem,
    PlayEvent,
    Playlist,
    PlaylistEntry,
    RadioPending,
    Role,
    Track,
    TrackLike,
    User,
)
from app.schemas import CatalogTrack
from app.services import covers, editorial, mix_covers
from app.services.deezer import DeezerError, artist_string, deezer
from app.services.downloads import create_request
from app.services.matching import match_tracks, name_key
from app.services.server_config import ServerConfig, load_config
from app.services.spotify import catalog_tracks
from app.services.tags import primary_artist

GENRE_NAMES = {"hip hop": "Hip-Hop", "r&b": "R&B", "edm": "EDM"}
CHARTS = {"chart:de": ("Top 100 Deutschland", "1111143121"), "chart:global": ("Top 100 Global", "3155776842")}
_chart_cache: dict[str, tuple[date, list[dict]]] = {}
_chart_requested: dict[str, date] = {}
_chart_request_lock = asyncio.Lock()
log = logging.getLogger(__name__)
_loop_task: asyncio.Task | None = None


async def chart_tracks(key: str) -> list[dict] | None:
    today = date.today()
    cached = _chart_cache.get(key)
    if cached is not None and cached[0] == today:
        return cached[1]
    try:
        tracks = await deezer.playlist_tracks(CHARTS[key][1], 100)
    except DeezerError:
        log.debug("Chart playlist lookup failed", exc_info=True)
        return cached[1] if cached is not None else None
    _chart_cache[key] = (today, tracks)
    return tracks


async def _chart_downloads(db: AsyncSession, ids: list[str], now: datetime) -> set[str]:
    return set(
        await db.scalars(
            select(DownloadItem.meta["deezer_track_id"].astext).where(
                DownloadItem.meta["deezer_track_id"].astext.in_(ids),
                DownloadItem.created_at >= now - timedelta(days=7),
                DownloadItem.status != "failed",
            )
        )
    )


def _sources(cfg: ServerConfig) -> list[tuple[str, str, str]]:
    sources = []
    if cfg.mixes.charts_enabled:
        sources.extend((key, name, "Die aktuellen Charts – täglich aktualisiert") for key, (name, _) in CHARTS.items())
    if cfg.mixes.editorial_enabled:
        sources.extend(
            (
                entry.key, entry.name,
                "Kuratiert von Apple Music – " + (
                    "täglich aktualisiert" if entry.group == "charts" else "wöchentlich aktualisiert"
                ),
            )
            for entry in editorial.EDITORIAL
            if entry.group != "years" or cfg.mixes.editorial_years
        )
    return sources


def _request_due(key: str) -> bool:
    requested = _chart_requested.get(key)
    days = editorial.refresh_days(editorial.BY_KEY[key]) if key in editorial.BY_KEY else 1
    return requested is None or date.today() >= requested + timedelta(days=days)


async def _source_catalog(db: AsyncSession, key: str) -> list[CatalogTrack] | None:
    if key in CHARTS:
        source = await chart_tracks(key)
        catalog = [_track(track) for track in source] if source is not None else None
    else:
        source = await editorial.playlist_tracks(editorial.BY_KEY[key])
        catalog = catalog_tracks(source.tracks) if source is not None else None
        for track in catalog or []:
            track.id = source.deezer_ids.get(track.isrc) or ""
    if catalog is not None:
        for start in range(0, len(catalog), 500):
            await match_tracks(db, catalog[start : start + 500])
    return catalog


def _source_positions(catalog: list[CatalogTrack]) -> tuple[dict[uuid.UUID, float], dict[str, float]]:
    positions: dict[uuid.UUID, float] = {}
    unmatched: dict[str, float] = {}
    for rank, track in enumerate(catalog, 1):
        if track.library_id is not None:
            positions.setdefault(track.library_id, rank)
        elif track.id:
            unmatched.setdefault(track.id, rank)
    return positions, unmatched


async def _request_chart_songs(
    db: AsyncSession, user: User, key: str, unmatched: dict[str, float], now: datetime,
    catalog: list[CatalogTrack] | None = None,
) -> None:
    """Request missing source songs, shared by all users, once per source refresh period."""
    cfg = await load_config(db)
    is_editorial = key in editorial.BY_KEY
    limit = cfg.mixes.editorial_downloads if is_editorial else cfg.mixes.charts_downloads
    if limit <= 0:
        return
    async with _chart_request_lock:
        if not _request_due(key):
            return
        if is_editorial:
            unmatched.clear()
            for rank, track in enumerate(catalog or [], 1):
                if track.library_id is not None:
                    continue
                deezer_id = track.id or await editorial.deezer_id(key, track.isrc)
                if deezer_id:
                    unmatched.setdefault(deezer_id, rank)
        known = await _chart_downloads(db, list(unmatched), now)
        requested = 0
        for deezer_id in unmatched:
            if deezer_id in known:
                continue
            if requested >= limit:
                break
            requested += 1
            try:
                await create_request(
                    db, user, "track", deezer_id, temporary=cfg.radio.temporary_tracks_enabled, radio=True
                )
            except HTTPException as exc:
                if exc.status_code == 429:
                    break
            else:
                known.add(deezer_id)
        _chart_requested[key] = date.today()


async def refresh_chart_downloads() -> None:
    """Request missing source songs and queue them at their source positions for every user's playlist."""
    async with SessionLocal() as db:
        cfg = await load_config(db)
        sources = [
            key for key, _, _ in _sources(cfg)
            if _request_due(key) and (
                cfg.mixes.charts_downloads > 0 if key in CHARTS else cfg.mixes.editorial_downloads > 0
            )
        ]
        if not sources:
            return
        requester = await db.scalar(
            select(User).where(User.role == Role.admin, ~User.is_disabled).order_by(User.created_at).limit(1)
        )
        if requester is None:
            return
        now = datetime.now(UTC)
        editorial_count = 0
        for key in sources:
            if key in editorial.BY_KEY and editorial_count >= 4:
                continue
            catalog = await _source_catalog(db, key)
            if catalog is None:
                continue
            if key in editorial.BY_KEY:
                editorial_count += 1
            _, unmatched = _source_positions(catalog)
            await _request_chart_songs(db, requester, key, unmatched, now, catalog)
            known = await _chart_downloads(db, list(unmatched), now)
            for playlist in await db.scalars(select(Playlist).where(Playlist.mix_key == key)):
                playlist_id = playlist.id
                if key in editorial.BY_KEY:
                    await _cover(db, playlist, [])
                queued = set(
                    await db.scalars(select(RadioPending.deezer_id).where(RadioPending.playlist_id == playlist_id))
                )
                db.add_all(
                    RadioPending(playlist_id=playlist_id, deezer_id=deezer_id, position=unmatched[deezer_id])
                    for deezer_id in unmatched
                    if deezer_id in known and deezer_id not in queued
                )
            await db.commit()
        # Songs that finished downloading before they were queued here.
        from app.services.radio import resolve_radio_pending

        await resolve_radio_pending(db)


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
    if mix_key in editorial.BY_KEY:
        entry = editorial.BY_KEY[mix_key]
        terms = [entry.name, entry.apple_name]
        decade = re.match(r"editorial:(\d{2})s-", mix_key)
        genres = []
        for genre, words in {
            "hiphop": ["hip-hop", "hip hop", "hiphop", "rap"],
            "deutschrap": ["deutschrap", "german rap", "hip-hop", "hip hop", "hiphop", "rap"],
            "deutschpop": ["deutschpop", "german pop", "pop"],
            "rock": ["rock"], "dance": ["dance"], "club": ["club", "dance"],
        }.items():
            if genre in mix_key:
                genres.extend(words)
        terms.extend(genres)
        if decade:
            short = int(decade[1])
            decade_terms = mix_search_terms(f"decade:{1900 + short if short >= 50 else 2000 + short}")
            terms.extend(decade_terms)
            terms.extend(f"{term} {genre}" for term in decade_terms for genre in genres)
        if entry.group == "years":
            year = mix_key.split("-")[1]
            terms.extend([year, f"hits {year}", f"charts {year}"])
        elif entry.group == "charts":
            terms.append("charts")
        return terms
    if mix_key == "chart:de":
        return ["charts", "top 100", "top 100 germany", "deutschland charts"]
    if mix_key == "chart:global":
        return ["charts", "top 100", "top 100 global", "world", "weltweit"]
    if mix_key and mix_key.startswith("era:"):
        _, decade, genre = mix_key.split(":", 2)
        names = {genre, GENRE_NAMES.get(genre, genre.title()), genre.replace(" ", "-")}
        return [f"{term} {name}" for term in mix_search_terms(f"decade:{decade}") for name in names]
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


async def _cover(db: AsyncSession, playlist: Playlist, track_ids: list[uuid.UUID]) -> None:
    key = playlist.mix_key or ""
    if key.startswith("editorial:"):
        cached = editorial._cache.get(key)
        if cached is not None and cached[1].cover_file:
            playlist.cover_file = cached[1].cover_file
        return
    images: list[bytes] = []
    files: list[str] = []
    if not key.startswith("chart:"):
        rows = {
            track_id: (album_id, file)
            for track_id, album_id, file in await db.execute(
                select(Track.id, Album.id, Album.cover_file)
                .join(Album, Album.id == Track.album_id)
                .where(Track.id.in_(track_ids), Album.cover_file.is_not(None))
            )
        }
        albums: set[uuid.UUID] = set()
        for track_id in track_ids:
            if track_id not in rows:
                continue
            album_id, name = rows[track_id]
            if album_id in albums:
                continue
            path = covers.resized(name, None)
            if path is None:
                continue
            albums.add(album_id)
            files.append(name)
            images.append(path.read_bytes())
            if len(files) == 4:
                break
    cover_key = hashlib.sha256("\0".join([playlist.name, key, *sorted(set(files))]).encode()).hexdigest()[:32]
    if playlist.cover_key == cover_key and playlist.cover_file:
        return
    data = await asyncio.to_thread(mix_covers.render, playlist.name, "Resonance", images, key)
    cover_file = covers.store(data)
    if cover_file:
        playlist.cover_file = cover_file
        playlist.cover_key = cover_key


async def _write(
    db: AsyncSession,
    user: User,
    key: str,
    name: str,
    description: str,
    track_ids: list[uuid.UUID],
    now: datetime,
    pending: list[str] | None = None,
    pending_positions: dict[str, float] | None = None,
    track_positions: dict[uuid.UUID, float] | None = None,
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
            PlaylistEntry(playlist_id=playlist.id, track_id=track_id, position=(track_positions or {}).get(track_id, i))
            for i, track_id in enumerate(track_ids, 1)
        ]
    )
    db.add_all(
        [
            RadioPending(
                playlist_id=playlist.id, deezer_id=deezer_id, position=(pending_positions or {}).get(deezer_id)
            )
            for deezer_id in pending or []
        ]
    )
    await _cover(db, playlist, track_ids)
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
    for track in eligible:
        # Fill up to the configured size; songs beyond the download limit are skipped, not counted.
        if len(chosen) + len(pending) >= cfg.mixes.discover_size:
            break
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


async def generate_mixes(db: AsyncSession, user: User, *, chart_downloads: bool = True) -> None:
    """`chart_downloads=False` (requests from the app) leaves requesting missing chart songs to the scheduler,
    which takes a minute and would block the response."""
    now = datetime.now(UTC)
    cfg = await load_config(db)
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

    editorial_count = 0
    requester = None
    for key, name, description in _sources(cfg):
        catalog = await _source_catalog(db, key)
        if catalog is None:
            if await db.scalar(select(Playlist.id).where(Playlist.owner_id == user.id, Playlist.mix_key == key)):
                produced.add(key)
            continue
        positions, unmatched = _source_positions(catalog)
        if chart_downloads and _request_due(key):
            if key in CHARTS:
                await _request_chart_songs(db, user, key, unmatched, now)
            elif cfg.mixes.editorial_downloads > 0 and editorial_count < 4:
                if requester is None:
                    requester = await db.scalar(
                        select(User).where(User.role == Role.admin, ~User.is_disabled)
                        .order_by(User.created_at).limit(1)
                    )
                if requester is not None:
                    editorial_count += 1
                    await _request_chart_songs(db, requester, key, unmatched, now, catalog)
        known = await _chart_downloads(db, list(unmatched), now)
        pending = [deezer_id for deezer_id in unmatched if deezer_id in known]
        playlist = await _write(
            db, user, key, name, description, list(positions), now,
            pending, pending_positions=unmatched, track_positions=positions,
        )
        if playlist is not None:
            produced.add(key)

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

    def pick(key: str, pool: list[Track], *, shuffle: bool = True) -> list[Track]:
        """Up to 15 of the user's favourites from the pool first, then random others; 50 at most."""
        rng = random.Random(f"{user.id}:{date.today()}:{key}")
        candidates = list(pool)
        rng.shuffle(candidates)
        preferred = sorted(
            (track for track in candidates if scores[track.id] > 0), key=lambda track: -scores[track.id]
        )[:15]
        preferred_ids = {track.id for track in preferred}
        chosen = [*preferred, *(track for track in candidates if track.id not in preferred_ids)][:50]
        if shuffle:
            rng.shuffle(chosen)
        return chosen

    # Spotify's "On Repeat": what the user played most in the last 30 days.
    repeat_counts = dict(
        (
            await db.execute(
                select(PlayEvent.track_id, func.count())
                .where(
                    PlayEvent.user_id == user.id,
                    PlayEvent.played_at >= now - timedelta(days=30),
                    PlayEvent.seconds_played >= 30,
                )
                .group_by(PlayEvent.track_id)
                .having(func.count() >= 2)
            )
        ).all()
    )
    on_repeat = sorted(
        (track for track in tracks if track.id in repeat_counts), key=lambda t: (-repeat_counts[t.id], t.id)
    )[:30]
    await write("on-repeat", "Auf Repeat", "Deine meistgehörten Songs der letzten 30 Tage", on_repeat)

    # Artist mixes: a favourite artist plus similar artists from the library.
    for artist_id in favourites[:6]:
        rng = random.Random(f"{user.id}:{date.today()}:artist:{artist_id}")
        own = list(by_artist[artist_id])
        rng.shuffle(own)
        chosen = own[:20]
        for related_id in [other for other in await related_artists([artist_id]) if other != artist_id][:10]:
            others = list(by_artist[related_id])
            rng.shuffle(others)
            chosen.extend(others[:3])
        if len(chosen) < 12:
            continue
        rng.shuffle(chosen)
        name = artists[artist_id].name
        await write(f"artist:{artist_id}", f"{name} Mix", f"{name} und ähnliche Künstler", chosen)

    by_decade: dict[int, list[Track]] = defaultdict(list)
    decade_of: dict[uuid.UUID, int] = {}
    for track in tracks:
        year = track.year or track.album.year
        if year and 1950 <= year <= now.year:
            by_decade[year // 10 * 10].append(track)
            decade_of[track.id] = year // 10 * 10
    for decade in sorted(decade for decade, decade_tracks in by_decade.items() if len(decade_tracks) >= 15):
        label = decade_label(decade)
        key = f"decade:{decade}"
        chosen = pick(key, by_decade[decade])
        await write(key, f"{label} Mix", f"Das Beste aus den {label}n in deiner Bibliothek", chosen)

    genres = sorted(
        (key for key, genre_tracks in by_genre.items() if len(genre_tracks) >= 15),
        key=lambda key: (-len(by_genre[key]), key),
    )[:12]
    for genre in genres:
        key = f"genre:{genre}"
        display = GENRE_NAMES.get(genre, genre.title())
        chosen = pick(key, by_genre[genre], shuffle=False)
        await write(key, f"{display} Mix", f"Das Beste aus {display} in deiner Bibliothek", chosen)

    # Genre by decade ("90er Hip-Hop", like Spotify's and Apple Music's era playlists), for every genre with enough
    # songs. Skipped where it would be practically the genre's own mix.
    eras: list[tuple[int, str, list[Track]]] = []
    for genre in (key for key, genre_tracks in by_genre.items() if len(genre_tracks) >= 10):
        per_decade: dict[int, list[Track]] = defaultdict(list)
        for track in by_genre[genre]:
            if track.id in decade_of:
                per_decade[decade_of[track.id]].append(track)
        for decade, era_tracks in per_decade.items():
            if len(era_tracks) < 10 or len(era_tracks) >= 0.95 * len(by_genre[genre]):
                continue
            eras.append((decade, genre, era_tracks))
    eras.sort(key=lambda era: (-len(era[2]), era[0], era[1]))
    for decade, genre, era_tracks in eras[:40]:
        label = decade_label(decade)
        display = GENRE_NAMES.get(genre, genre.title())
        key = f"era:{decade}:{genre}"
        chosen = pick(key, era_tracks)
        await write(key, f"{label} {display}", f"{display} aus den {label}n in deiner Bibliothek", chosen)

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
                        await generate_mixes(db, user, chart_downloads=False)
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
        try:
            await refresh_chart_downloads()
        except Exception:
            log.exception("Chart downloads failed")


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
