import uuid
from datetime import UTC, datetime, timedelta
from typing import Literal

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import FileResponse, RedirectResponse, Response
from pydantic import BaseModel, Field, HttpUrl
from sqlalchemy import and_, delete, func, literal, select, true
from sqlalchemy.dialects.postgresql import insert

from app import i18n
from app.deps import DB, CurrentUser
from app.models import EpisodeProgress, Podcast, PodcastEpisode, PodcastSubscription
from app.services import podcast_ads, podcasts

router = APIRouter(prefix="/api/podcasts", tags=["podcasts"])


class SubscribeIn(BaseModel):
    feed_url: HttpUrl


class ProgressIn(BaseModel):
    position_seconds: float = Field(ge=0, allow_inf_nan=False)
    completed: bool


class PlayedIn(BaseModel):
    completed: bool


class RemoveAdsIn(BaseModel):
    enabled: bool


class PodcastSearchResult(BaseModel):
    itunes_id: int | None
    title: str
    author: str | None
    image_url: str | None
    feed_url: str
    source: Literal["apple", "fyyd"]


PODCAST_GENRES = (
    (1303, "Comedy", "Comedy"),
    (1489, "Nachrichten", "News"),
    (1488, "True Crime", "True Crime"),
    (1324, "Gesellschaft & Kultur", "Society & Culture"),
    (1545, "Sport", "Sports"),
    (1533, "Wissenschaft", "Science"),
    (1487, "Geschichte", "History"),
    (1321, "Wirtschaft", "Business"),
    (1512, "Gesundheit & Fitness", "Health & Fitness"),
    (1305, "Kinder & Familie", "Kids & Family"),
    (1310, "Musik", "Music"),
    (1318, "Technologie", "Technology"),
    (1304, "Bildung", "Education"),
    (1502, "Freizeit", "Leisure"),
    (1483, "Fiktion", "Fiction"),
)


def store_country(request: Request) -> str:
    return "DE" if i18n.language(request) == "de" else "US"


def _podcast(podcast: Podcast) -> dict:
    return {key: getattr(podcast, key) for key in (
        "id", "feed_url", "title", "author", "description", "image_url", "website", "last_fetched_at", "created_at"
    )}


def _episode(
    episode: PodcastEpisode, podcast: Podcast, progress: EpisodeProgress | None, ad_free: set[uuid.UUID],
) -> dict:
    """`ad_free` holds the podcasts the user listens to without inserted ads; their cleaned episodes report the
    cleaned length and how much was cut, the others whether removal is still to come."""
    removing = podcast.id in ad_free
    cleaned = removing and episode.ad_status == "done"
    return {
        **{key: getattr(episode, key) for key in (
            "id", "podcast_id", "guid", "title", "description", "published_at",
            "audio_url", "audio_type", "image_url", "created_at",
        )},
        "duration_seconds": episode.ad_duration if cleaned else episode.duration_seconds,
        "ads_removed_seconds": episode.ad_seconds if cleaned else None,
        "ad_status": (episode.ad_status or "pending") if removing else None,
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


async def _ad_free(db: DB, user_id: uuid.UUID) -> set[uuid.UUID]:
    return set(await db.scalars(select(PodcastSubscription.podcast_id).where(
        PodcastSubscription.user_id == user_id, PodcastSubscription.remove_ads,
    )))


async def _get_episode(db: DB, id: uuid.UUID) -> PodcastEpisode:
    episode = await db.get(PodcastEpisode, id)
    if episode is None:
        raise HTTPException(404, "Episode nicht gefunden")
    return episode


@router.get("/search", response_model=list[PodcastSearchResult])
async def search(request: Request, user: CurrentUser, q: str = Query("", max_length=500)) -> list[dict]:
    try:
        return await podcasts.search(q, store_country(request))
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
    ad_free = await _ad_free(db, user.id)
    return [_episode(episode, podcast, progress, ad_free) for episode, podcast, progress in rows]


@router.get("/discover")
async def discover(request: Request, user: CurrentUser, db: DB) -> dict:
    country = store_country(request)
    lang = i18n.language(request)
    genres = [
        {"id": genre_id, "name": german if lang == "de" else english}
        for genre_id, german, english in PODCAST_GENRES
    ]
    subscriptions = list(await db.scalars(
        select(Podcast).join(PodcastSubscription).where(PodcastSubscription.user_id == user.id)
        .order_by(PodcastSubscription.created_at.desc(), Podcast.title)
    ))
    subscribed_feeds = {podcasts.normalize_feed_url(podcast.feed_url) for podcast in subscriptions}
    sections = []
    resolved = []
    for podcast in subscriptions:
        genre_id = await podcasts.podcast_genre(podcast, country)
        if genre_id is None:
            continue
        resolved.append((podcast, genre_id))
        if len(resolved) == 2:
            break
    seen_genres = set()
    for podcast, genre_id in resolved:
        if genre_id in seen_genres:
            continue
        seen_genres.add(genre_id)
        try:
            items = await podcasts.top_podcasts(country, genre_id, limit=50)
        except podcasts.PodcastError:
            continue
        items = [item for item in items if podcasts.normalize_feed_url(item["feed_url"]) not in subscribed_feeds][:20]
        if items:
            title = f"Weil du {podcast.title} hörst" if lang == "de" else f"Because you listen to {podcast.title}"
            sections.append({"id": f"because:{podcast.id}", "title": title, "items": items})
    try:
        items = await podcasts.top_podcasts(country, None, limit=50)
        sections.append({
            "id": "top",
            "title": "Top-Podcasts" if lang == "de" else "Top podcasts",
            "items": items[:30],
        })
    except podcasts.PodcastError:
        pass
    return {"genres": genres, "sections": sections}


@router.get("/genres/{genre_id}", response_model=list[PodcastSearchResult])
async def genre_podcasts(genre_id: int, request: Request, user: CurrentUser) -> list[dict]:
    if genre_id not in {genre[0] for genre in PODCAST_GENRES}:
        raise HTTPException(404, "Podcast-Kategorie nicht gefunden")
    try:
        return await podcasts.top_podcasts(store_country(request), genre_id)
    except podcasts.PodcastError as exc:
        raise HTTPException(502, "Podcast-Charts nicht erreichbar") from exc


@router.get("/latest")
async def latest(
    user: CurrentUser, db: DB, limit: int = Query(20, ge=1, le=50),
) -> list[dict]:
    rows = await db.execute(
        select(PodcastEpisode, Podcast, EpisodeProgress)
        .join(Podcast, Podcast.id == PodcastEpisode.podcast_id)
        .join(PodcastSubscription, PodcastSubscription.podcast_id == Podcast.id)
        .outerjoin(EpisodeProgress, and_(
            EpisodeProgress.episode_id == PodcastEpisode.id,
            EpisodeProgress.user_id == user.id,
        ))
        .where(
            PodcastSubscription.user_id == user.id,
            (EpisodeProgress.episode_id.is_(None) | EpisodeProgress.completed.is_(False)),
        )
        .order_by(PodcastEpisode.published_at.desc().nullslast(), PodcastEpisode.id)
        .limit(limit)
    )
    ad_free = await _ad_free(db, user.id)
    return [_episode(episode, podcast, progress, ad_free) for episode, podcast, progress in rows]


@router.get("/episodes/{id}")
async def episode(id: uuid.UUID, user: CurrentUser, db: DB) -> dict:
    episode = await _get_episode(db, id)
    podcast = await _get_podcast(db, episode.podcast_id)
    progress = await db.get(EpisodeProgress, (user.id, id))
    return _episode(episode, podcast, progress, await _ad_free(db, user.id))


@router.put("/episodes/{id}/progress", status_code=204)
async def progress(id: uuid.UUID, body: ProgressIn, user: CurrentUser, db: DB) -> Response:
    await _get_episode(db, id)
    await db.execute(insert(EpisodeProgress).values(user_id=user.id, episode_id=id, **body.model_dump())
        .on_conflict_do_update(index_elements=["user_id", "episode_id"], set_={
            **body.model_dump(), "updated_at": datetime.now(UTC),
        }))
    await db.commit()
    return Response(status_code=204)


@router.get("/episodes/{id}/stream", response_model=None)
async def stream(id: uuid.UUID, user: CurrentUser, db: DB) -> RedirectResponse | FileResponse:
    """The ad-free file when the user wants one and it is ready, otherwise the host's file (and the episode is
    queued, so it is ad-free next time)."""
    episode = await _get_episode(db, id)
    subscription = await db.get(PodcastSubscription, (user.id, episode.podcast_id))
    if subscription is not None and subscription.remove_ads:
        path = podcast_ads.episode_path(episode.id)
        if episode.ad_status == "done" and path.exists():
            return FileResponse(path, media_type="audio/mpeg")
        if episode.ad_status in (None, "failed", "done"):
            podcast_ads.request(episode.id)
    return RedirectResponse(episode.audio_url, status_code=302)


@router.get("/{id}")
async def detail(
    id: uuid.UUID, user: CurrentUser, db: DB,
    offset: int = Query(0, ge=0), limit: int = Query(50, ge=1, le=200),
    order: Literal["newest", "oldest"] = "newest",
) -> dict:
    """The podcast with a page of its episodes, newest first or (to listen through from the start) oldest first."""
    podcast = await _get_podcast(db, id)
    if order == "oldest":
        sort = (PodcastEpisode.published_at.asc().nullsfirst(), PodcastEpisode.created_at, PodcastEpisode.id)
    else:
        sort = (PodcastEpisode.published_at.desc().nullslast(), PodcastEpisode.created_at.desc(), PodcastEpisode.id)
    rows = await db.execute(select(PodcastEpisode, EpisodeProgress).outerjoin(EpisodeProgress, and_(
        EpisodeProgress.episode_id == PodcastEpisode.id, EpisodeProgress.user_id == user.id,
    )).where(PodcastEpisode.podcast_id == id).order_by(*sort).offset(offset).limit(limit))
    subscription = await db.get(PodcastSubscription, (user.id, id))
    ad_free = {id} if subscription is not None and subscription.remove_ads else set()
    count = await db.scalar(select(func.count()).select_from(PodcastEpisode).where(PodcastEpisode.podcast_id == id))
    completed = await db.scalar(select(func.count()).select_from(EpisodeProgress).join(PodcastEpisode).where(
        PodcastEpisode.podcast_id == id, EpisodeProgress.user_id == user.id, EpisodeProgress.completed,
    ))
    return {
        **_podcast(podcast), "subscribed": subscription is not None, "remove_ads": bool(ad_free),
        "episode_count": count, "completed_count": completed,
        "episodes": [_episode(episode, podcast, progress, ad_free) for episode, progress in rows],
    }


@router.put("/{id}/remove-ads", status_code=204)
async def remove_ads(id: uuid.UUID, body: RemoveAdsIn, user: CurrentUser, db: DB) -> Response:
    """Listen to a subscribed podcast without inserted ads; its newest episodes are cleaned in the background."""
    subscription = await db.get(PodcastSubscription, (user.id, id))
    if subscription is None:
        raise HTTPException(409, "Nur für abonnierte Podcasts")
    subscription.remove_ads = body.enabled
    await db.commit()
    if body.enabled:
        podcast_ads.wake()
    return Response(status_code=204)


@router.put("/{id}/played", status_code=204)
async def mark_all_played(id: uuid.UUID, body: PlayedIn, user: CurrentUser, db: DB) -> Response:
    """Marks every episode of the podcast as heard (or, with `completed: false`, all of them as new again)."""
    await _get_podcast(db, id)
    if body.completed:
        statement = insert(EpisodeProgress).from_select(
            ["user_id", "episode_id", "position_seconds", "completed"],
            select(literal(user.id), PodcastEpisode.id, literal(0.0), true()).where(PodcastEpisode.podcast_id == id),
        )
        await db.execute(statement.on_conflict_do_update(
            index_elements=["user_id", "episode_id"], set_={"completed": True, "updated_at": datetime.now(UTC)},
        ))
    else:
        await db.execute(delete(EpisodeProgress).where(
            EpisodeProgress.user_id == user.id,
            EpisodeProgress.episode_id.in_(select(PodcastEpisode.id).where(PodcastEpisode.podcast_id == id)),
        ))
    await db.commit()
    return Response(status_code=204)
