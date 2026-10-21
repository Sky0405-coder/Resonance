import uuid
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import RedirectResponse, Response
from pydantic import BaseModel, Field, HttpUrl
from sqlalchemy import and_, delete, func, select
from sqlalchemy.dialects.postgresql import insert

from app.deps import DB, CurrentUser
from app.models import EpisodeProgress, Podcast, PodcastEpisode, PodcastSubscription
from app.services import podcasts

router = APIRouter(prefix="/api/podcasts", tags=["podcasts"])


class SubscribeIn(BaseModel):
    feed_url: HttpUrl


class ProgressIn(BaseModel):
    position_seconds: float = Field(ge=0, allow_inf_nan=False)
    completed: bool


def _podcast(podcast: Podcast) -> dict:
    return {key: getattr(podcast, key) for key in (
        "id", "feed_url", "title", "author", "description", "image_url", "website", "last_fetched_at", "created_at"
    )}


def _episode(episode: PodcastEpisode, podcast: Podcast, progress: EpisodeProgress | None) -> dict:
    return {
        **{key: getattr(episode, key) for key in (
            "id", "podcast_id", "guid", "title", "description", "published_at", "duration_seconds",
            "audio_url", "audio_type", "image_url", "created_at",
        )},
        "podcast_title": podcast.title,
        "podcast_image_url": podcast.image_url,
        "position_seconds": progress.position_seconds if progress else 0,
        "completed": progress.completed if progress else False,
    }


async def _get_podcast(db: DB, id: uuid.UUID) -> Podcast:
    podcast = await db.get(Podcast, id)
    if podcast is None:
        raise HTTPException(404, "Podcast nicht gefunden")
    return podcast


async def _get_episode(db: DB, id: uuid.UUID) -> PodcastEpisode:
    episode = await db.get(PodcastEpisode, id)
    if episode is None:
        raise HTTPException(404, "Episode nicht gefunden")
    return episode


@router.get("/search")
async def search(user: CurrentUser, q: str = Query("", max_length=500)) -> list[dict]:
    try:
        return await podcasts.search(q)
    except podcasts.PodcastError as exc:
        raise HTTPException(502, "Podcast-Suche nicht erreichbar") from exc


@router.get("/preview")
async def preview(feed_url: HttpUrl, user: CurrentUser, db: DB) -> dict:
    # Cache a discovered feed so search can open its detail page without subscribing.
    try:
        podcast = await podcasts.get_or_fetch(db, str(feed_url))
    except podcasts.PodcastError as exc:
        raise HTTPException(502, "Podcast-Feed nicht erreichbar oder ungültig") from exc
    await db.commit()
    return _podcast(podcast)


@router.post("/subscriptions", status_code=201)
async def subscribe(body: SubscribeIn, user: CurrentUser, db: DB) -> dict:
    try:
        podcast = await podcasts.get_or_fetch(db, str(body.feed_url))
    except podcasts.PodcastError as exc:
        raise HTTPException(502, "Podcast-Feed nicht erreichbar oder ungültig") from exc
    await db.execute(
        insert(PodcastSubscription).values(user_id=user.id, podcast_id=podcast.id).on_conflict_do_nothing()
    )
    await db.commit()
    return {**_podcast(podcast), "subscribed": True}


@router.delete("/subscriptions/{id}", status_code=204)
async def unsubscribe(id: uuid.UUID, user: CurrentUser, db: DB) -> Response:
    await db.execute(delete(PodcastSubscription).where(
        PodcastSubscription.user_id == user.id, PodcastSubscription.podcast_id == id
    ))
    await db.commit()
    return Response(status_code=204)


@router.get("/subscriptions")
async def subscriptions(user: CurrentUser, db: DB) -> list[dict]:
    latest = select(func.max(PodcastEpisode.published_at)).where(
        PodcastEpisode.podcast_id == Podcast.id
    ).correlate(Podcast).scalar_subquery()
    completed = select(EpisodeProgress.episode_id).where(
        EpisodeProgress.user_id == user.id,
        EpisodeProgress.episode_id == PodcastEpisode.id,
        EpisodeProgress.completed.is_(True),
    ).exists()
    unplayed = select(func.count(PodcastEpisode.id)).where(
        PodcastEpisode.podcast_id == Podcast.id,
        PodcastEpisode.published_at >= datetime.now(UTC) - timedelta(days=30),
        ~completed,
    ).correlate(Podcast).scalar_subquery()
    rows = await db.execute(select(Podcast, latest, unplayed).join(PodcastSubscription).where(
        PodcastSubscription.user_id == user.id
    ).order_by(latest.desc().nullslast(), Podcast.title))
    return [
        {**_podcast(podcast), "latest_episode_at": date, "unplayed_count": count, "subscribed": True}
        for podcast, date, count in rows
    ]


@router.get("/continue")
async def continue_listening(user: CurrentUser, db: DB) -> list[dict]:
    rows = await db.execute(select(PodcastEpisode, Podcast, EpisodeProgress)
        .join(Podcast, Podcast.id == PodcastEpisode.podcast_id)
        .join(EpisodeProgress, EpisodeProgress.episode_id == PodcastEpisode.id)
        .where(EpisodeProgress.user_id == user.id, EpisodeProgress.completed.is_(False))
        .order_by(EpisodeProgress.updated_at.desc(), PodcastEpisode.id).limit(10))
    return [_episode(episode, podcast, progress) for episode, podcast, progress in rows]


@router.get("/episodes/{id}")
async def episode(id: uuid.UUID, user: CurrentUser, db: DB) -> dict:
    episode = await _get_episode(db, id)
    podcast = await _get_podcast(db, episode.podcast_id)
    progress = await db.get(EpisodeProgress, (user.id, id))
    return _episode(episode, podcast, progress)


@router.put("/episodes/{id}/progress", status_code=204)
async def progress(id: uuid.UUID, body: ProgressIn, user: CurrentUser, db: DB) -> Response:
    await _get_episode(db, id)
    await db.execute(insert(EpisodeProgress).values(user_id=user.id, episode_id=id, **body.model_dump())
        .on_conflict_do_update(index_elements=["user_id", "episode_id"], set_={
            **body.model_dump(), "updated_at": datetime.now(UTC),
        }))
    await db.commit()
    return Response(status_code=204)


@router.get("/episodes/{id}/stream")
async def stream(id: uuid.UUID, user: CurrentUser, db: DB) -> RedirectResponse:
    episode = await _get_episode(db, id)
    return RedirectResponse(episode.audio_url, status_code=302)


@router.get("/{id}")
async def detail(
    id: uuid.UUID, user: CurrentUser, db: DB,
    offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200),
) -> dict:
    podcast = await _get_podcast(db, id)
    rows = await db.execute(select(PodcastEpisode, EpisodeProgress).outerjoin(EpisodeProgress, and_(
        EpisodeProgress.episode_id == PodcastEpisode.id, EpisodeProgress.user_id == user.id,
    )).where(PodcastEpisode.podcast_id == id)
        .order_by(PodcastEpisode.published_at.desc().nullslast(), PodcastEpisode.created_at.desc(), PodcastEpisode.id)
        .offset(offset).limit(limit))
    subscribed = await db.get(PodcastSubscription, (user.id, id)) is not None
    return {
        **_podcast(podcast), "subscribed": subscribed,
        "episodes": [_episode(episode, podcast, progress) for episode, progress in rows],
    }
