from fastapi import APIRouter
from sqlalchemy import select

from app.deps import DB, CurrentUser
from app.models import User
from app.schemas import ArtistRef

router = APIRouter(prefix="/api/users", tags=["users"])


@router.get("", response_model=list[ArtistRef])
async def list_users(user: CurrentUser, db: DB) -> list[ArtistRef]:
    users = await db.scalars(select(User).where(User.id != user.id, ~User.is_disabled))
    return sorted(
        [ArtistRef(id=other.id, name=other.display_name) for other in users],
        key=lambda other: other.name.casefold(),
    )
