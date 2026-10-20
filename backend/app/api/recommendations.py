from fastapi import APIRouter

from app.deps import DB, CurrentUser
from app.schemas import RecommendationsIn, TrackOut
from app.services.recommendations import recommend
from app.services.views import tracks_out

router = APIRouter(prefix="/api/recommendations", tags=["recommendations"])


@router.post("", response_model=list[TrackOut])
async def recommendations(body: RecommendationsIn, user: CurrentUser, db: DB) -> list[TrackOut]:
    tracks = await recommend(db, user, body.track_ids, body.limit, body.exclude_ids)
    return await tracks_out(db, user, tracks)
