from datetime import date

from fastapi import APIRouter, Request
from sqlalchemy import func, select

from app.deps import DB, CurrentUser
from app.i18n import language
from app.models import Playlist
from app.schemas import MixesOut
from app.services.mixes import CHARTS, discover_due, generate_discover, generate_mixes
from app.services.server_config import load_config
from app.services.views import playlists_out

router = APIRouter(prefix="/api/mixes", tags=["mixes"])


async def _out(db: DB, user: CurrentUser, lang: str) -> MixesOut:
    playlists = list(
        await db.scalars(
            select(Playlist).where(Playlist.owner_id == user.id, Playlist.kind == "mix").order_by(Playlist.mix_key)
        )
    )
    items = await playlists_out(db, playlists, user.id, lang)
    made_for_you = []
    genres = []
    decades = []
    charts = []
    discover = None
    for playlist, item in zip(playlists, items, strict=True):
        if playlist.mix_key == "discover-weekly":
            discover = item
        elif (playlist.mix_key or "").startswith("genre:"):
            genres.append(item)
        elif (playlist.mix_key or "").startswith(("decade:", "era:")):
            decades.append(item)
        elif (playlist.mix_key or "").startswith("chart:"):
            charts.append((playlist.mix_key, item))
        else:
            made_for_you.append(item)
    genres.sort(key=lambda item: -item.track_count)
    # Daily mixes first and artist mixes last, like Spotify's "Made for you".
    order = ["daily:", "discover", "on-repeat", "favourites", "new-music", "rewind", "artist:"]
    keys = {item.id: playlist.mix_key or "" for playlist, item in zip(playlists, items, strict=True)}
    made_for_you.sort(
        key=lambda item: (next((i for i, p in enumerate(order) if keys[item.id].startswith(p)), len(order)), keys[item.id])
    )
    chart_order = {key: index for index, key in enumerate(CHARTS)}
    charts.sort(key=lambda pair: chart_order.get(pair[0], len(CHARTS)))
    return MixesOut(
        made_for_you=made_for_you, genres=genres, discover=discover, decades=decades,
        charts=[item for _, item in charts],
    )


@router.get("", response_model=MixesOut)
async def get_mixes(user: CurrentUser, db: DB, request: Request) -> MixesOut:
    generated_at = await db.scalar(
        select(func.max(Playlist.generated_at)).where(
            Playlist.owner_id == user.id,
            Playlist.kind == "mix",
            Playlist.mix_key.is_distinct_from("discover-weekly"),
        )
    )
    if generated_at is None or generated_at.astimezone().date() != date.today():
        await generate_mixes(db, user, chart_downloads=False)
    cfg = await load_config(db)
    if cfg.mixes.discover_enabled:
        discover_at = await db.scalar(
            select(Playlist.generated_at).where(Playlist.owner_id == user.id, Playlist.mix_key == "discover-weekly")
        )
        if discover_due(discover_at):
            await generate_discover(db, user)
    return await _out(db, user, language(request))


@router.post("/refresh", response_model=MixesOut)
async def refresh_mixes(user: CurrentUser, db: DB, request: Request) -> MixesOut:
    await generate_mixes(db, user, chart_downloads=False)
    return await _out(db, user, language(request))
