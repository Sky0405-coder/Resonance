from fastapi import APIRouter

from app.deps import DB, CurrentUser
from app.schemas import RadioIn, RadioOut
from app.services.radio import build_radio
from app.services.views import playlists_out

router = APIRouter(prefix="/api/radio", tags=["radio"])


@router.post("", response_model=RadioOut)
async def create_radio(body: RadioIn, user: CurrentUser, db: DB) -> RadioOut:
    playlist, requested = await build_radio(db, user, body.seed_type, body.id)
    return RadioOut(playlist=(await playlists_out(db, [playlist], user.id))[0], requested=requested)
