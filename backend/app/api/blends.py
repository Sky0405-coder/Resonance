import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, HTTPException, status
from sqlalchemy import select

from app.deps import DB, CurrentUser
from app.models import Blend, Playlist, User
from app.schemas import ArtistRef, BlendIn, BlendOut
from app.services import blends
from app.services.mixes import _taste

router = APIRouter(prefix="/api/blends", tags=["blends"])


async def _out(db: DB, user: User, blend: Blend, match: float | None = None) -> BlendOut:
    partner = await db.get(User, blends.partner_id(blend, user))
    playlist_id = await db.scalar(
        select(Playlist.id).where(Playlist.owner_id == user.id, Playlist.mix_key == blends.mix_key(partner.id))
    )
    if match is None:
        now = datetime.now(UTC)
        match = blends.taste_match(await _taste(db, user, now), await _taste(db, partner, now))
    return BlendOut(
        id=blend.id, partner=ArtistRef(id=partner.id, name=partner.display_name), playlist_id=playlist_id, match=match
    )


@router.get("", response_model=list[BlendOut])
async def list_blends(user: CurrentUser, db: DB) -> list[BlendOut]:
    return [await _out(db, user, blend) for blend in await blends.blends_of(db, user)]


@router.post("", response_model=BlendOut, status_code=status.HTTP_201_CREATED)
async def create_blend(body: BlendIn, user: CurrentUser, db: DB) -> BlendOut:
    if body.user_id == user.id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Mit dir selbst geht kein Blend")
    partner = await db.get(User, body.user_id)
    if partner is None or partner.is_disabled:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Unbekannter Nutzer")
    blend = await blends.create(db, user, partner)
    return await _out(db, user, blend)


@router.delete("/{blend_id}", status_code=status.HTTP_204_NO_CONTENT)
async def leave_blend(blend_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    blend = await db.get(Blend, blend_id)
    if blend is None or user.id not in (blend.user_a_id, blend.user_b_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Blend nicht gefunden")
    await blends.leave(db, blend)
