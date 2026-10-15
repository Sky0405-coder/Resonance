from datetime import date

from fastapi import APIRouter
from sqlalchemy import func, select

from app.deps import DB, CurrentUser
from app.models import Playlist
from app.schemas import MixesOut
from app.services.mixes import generate_mixes
from app.services.views import playlists_out

router = APIRouter(prefix="/api/mixes", tags=["mixes"])


async def _out(db: DB, user: CurrentUser) -> MixesOut:
    playlists = list(
        await db.scalars(
            select(Playlist).where(Playlist.owner_id == user.id, Playlist.kind == "mix").order_by(Playlist.mix_key)
        )
    )
    items = await playlists_out(db, playlists, user.id)
    made_for_you = []
    genres = []
    for playlist, item in zip(playlists, items, strict=True):
        if (playlist.mix_key or "").startswith("genre:"):
            genres.append(item)
        else:
            made_for_you.append(item)
    genres.sort(key=lambda item: -item.track_count)
    return MixesOut(made_for_you=made_for_you, genres=genres)


@router.get("", response_model=MixesOut)
async def get_mixes(user: CurrentUser, db: DB) -> MixesOut:
    generated_at = await db.scalar(
        select(func.max(Playlist.generated_at)).where(Playlist.owner_id == user.id, Playlist.kind == "mix")
    )
    if generated_at is None or generated_at.astimezone().date() != date.today():
        await generate_mixes(db, user)
    return await _out(db, user)


@router.post("/refresh", response_model=MixesOut)
async def refresh_mixes(user: CurrentUser, db: DB) -> MixesOut:
    await generate_mixes(db, user)
    return await _out(db, user)
