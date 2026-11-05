"""Blend: two users' shared mix, made from both tastes every day (each gets the same songs as their own mix)."""

import logging
import math
import random
import uuid
from collections import Counter
from datetime import UTC, date, datetime

from sqlalchemy import delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Blend, Playlist, PlaylistEntry, Track, User
from app.services.matching import name_key
from app.services.mixes import _Taste, _taste, _write
from app.services.tags import primary_artist

SIZE = 50
# Songs both love lead the blend, then the two take turns.
SHARED = 15
PER_ARTIST = 3
log = logging.getLogger(__name__)


def mix_key(partner_id: uuid.UUID) -> str:
    return f"blend:{partner_id}"


def taste_match(a: _Taste, b: _Taste) -> float:
    """How alike two tastes are (0..1): the cosine of their artist scores, damped so a few artists played a lot do
    not decide it alone."""
    keys_a = {name_key(a.artists[artist_id].name): math.sqrt(score) for artist_id, score in a.artist_scores.items()}
    keys_b = {name_key(b.artists[artist_id].name): math.sqrt(score) for artist_id, score in b.artist_scores.items()}
    dot = sum(value * keys_b.get(key, 0) for key, value in keys_a.items())
    norm = math.sqrt(sum(v * v for v in keys_a.values())) * math.sqrt(sum(v * v for v in keys_b.values()))
    return round(dot / norm, 3) if norm else 0.0


def choose(a: _Taste, b: _Taste, a_id: uuid.UUID, b_id: uuid.UUID, seed: str) -> list[tuple[Track, uuid.UUID | None]]:
    """The blend's songs with whose taste each came from (None: both)."""
    rng = random.Random(seed)

    def ranked(taste: _Taste, ids: list[uuid.UUID]) -> list[uuid.UUID]:
        # Higher scores make larger random priorities more likely: the favourites lead, with some variety daily.
        return sorted(ids, key=lambda track_id: rng.random() ** (1 / taste.scores[track_id]), reverse=True)

    tracks = {track.id: track for track in a.tracks}
    liked_a = [track_id for track_id, score in a.scores.items() if score > 0]
    liked_b = [track_id for track_id, score in b.scores.items() if score > 0]
    both = set(liked_a) & set(liked_b)
    shared = sorted(both, key=lambda track_id: rng.random() ** (1 / (a.scores[track_id] + b.scores[track_id])))
    shared.reverse()
    turns = [ranked(a, [i for i in liked_a if i not in both]), ranked(b, [i for i in liked_b if i not in both])]
    chosen: list[tuple[Track, uuid.UUID | None]] = []
    seen: set[uuid.UUID] = set()
    artists: Counter[str] = Counter()

    def add(track_id: uuid.UUID, by: uuid.UUID | None) -> bool:
        track = tracks.get(track_id)
        if track is None or track_id in seen:
            return False
        artist = name_key(primary_artist(track.artist_credit))
        if artists[artist] >= PER_ARTIST:
            return False
        chosen.append((track, by))
        seen.add(track_id)
        artists[artist] += 1
        return True

    for track_id in shared:
        if len(chosen) >= SHARED:
            break
        add(track_id, None)
    owners = [a_id, b_id]
    turn = rng.randrange(2)
    while len(chosen) < SIZE and any(turns):
        if not turns[turn]:
            turn = 1 - turn
        track_id = turns[turn].pop(0)
        if add(track_id, owners[turn]):
            turn = 1 - turn
    for track_id in shared:
        if len(chosen) >= SIZE:
            break
        add(track_id, None)
    # Mixed through, with the shared songs spread instead of all at the start.
    rng.shuffle(chosen)
    return chosen


def _name(a: User, b: User) -> str:
    return f"{a.display_name} + {b.display_name}"


async def generate(db: AsyncSession, blend: Blend) -> float:
    """Makes both users' playlists of the blend again; returns how alike both tastes are."""
    a = await db.get(User, blend.user_a_id)
    b = await db.get(User, blend.user_b_id)
    if a is None or b is None:
        return 0.0
    now = datetime.now(UTC)
    taste_a = await _taste(db, a, now)
    taste_b = await _taste(db, b, now)
    match = taste_match(taste_a, taste_b)
    chosen = choose(taste_a, taste_b, a.id, b.id, f"{blend.id}:{date.today()}")
    name = _name(a, b)
    description = f"Eure gemeinsame Playlist – täglich neu · {round(match * 100)} % Übereinstimmung"
    track_ids = [track.id for track, _ in chosen]
    for user, partner in ((a, b), (b, a)):
        playlist = await _write(db, user, mix_key(partner.id), name, description, track_ids, now)
        if playlist is None:
            # Nothing to blend yet; an older playlist stays until there is.
            continue
        by = {track.id: owner for track, owner in chosen}
        for entry in await db.scalars(select(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist.id)):
            entry.added_by_id = by.get(entry.track_id)
    await db.commit()
    return match


async def blends_of(db: AsyncSession, user: User) -> list[Blend]:
    return list(
        await db.scalars(
            select(Blend).where(or_(Blend.user_a_id == user.id, Blend.user_b_id == user.id)).order_by(Blend.created_at)
        )
    )


def partner_id(blend: Blend, user: User) -> uuid.UUID:
    return blend.user_b_id if blend.user_a_id == user.id else blend.user_a_id


async def create(db: AsyncSession, user: User, partner: User) -> Blend:
    existing = await db.scalar(
        select(Blend).where(
            or_(
                (Blend.user_a_id == user.id) & (Blend.user_b_id == partner.id),
                (Blend.user_a_id == partner.id) & (Blend.user_b_id == user.id),
            )
        )
    )
    if existing is not None:
        return existing
    blend = Blend(user_a_id=user.id, user_b_id=partner.id)
    db.add(blend)
    await db.commit()
    await generate(db, blend)
    return blend


async def leave(db: AsyncSession, blend: Blend) -> None:
    """Ends the blend for both: it is one shared playlist, which needs both."""
    await db.execute(
        delete(Playlist).where(
            or_(
                (Playlist.owner_id == blend.user_a_id) & (Playlist.mix_key == mix_key(blend.user_b_id)),
                (Playlist.owner_id == blend.user_b_id) & (Playlist.mix_key == mix_key(blend.user_a_id)),
            )
        )
    )
    await db.delete(blend)
    await db.commit()


async def generate_due(db: AsyncSession, user: User) -> None:
    """The user's blends not yet made today."""
    for blend in await blends_of(db, user):
        generated_at = await db.scalar(
            select(Playlist.generated_at).where(
                Playlist.owner_id == user.id, Playlist.mix_key == mix_key(partner_id(blend, user))
            )
        )
        if generated_at is None or generated_at.astimezone().date() != date.today():
            try:
                await generate(db, blend)
            except Exception:
                log.exception("Blend %s failed", blend.id)
                await db.rollback()
