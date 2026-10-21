import asyncio
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import httpx
import pytest
from app.db import Base, SessionLocal, engine
from app.models import (
    EpisodeProgress,
    Podcast,
    PodcastEpisode,
    PodcastSubscription,
    User,
)
from app.services import podcasts
from sqlalchemy import delete, select

from tests.conftest import auth, register

FEED = Path(__file__).with_name("fixtures").joinpath("podcast.xml").read_bytes()


@pytest.fixture
async def feeds(monkeypatch, client):
    requests = []
    responses = []
    original = httpx.AsyncClient

    def handle(request):
        requests.append(request)
        if responses:
            return responses.pop(0)
        if request.url.host == "itunes.apple.com":
            return httpx.Response(200, json={"results": [{
                "collectionId": 123, "collectionName": "Discovery", "artistName": "Author",
                "artworkUrl600": "https://pod.example/cover.jpg", "feedUrl": "https://pod.example/feed.xml",
            }, {"collectionId": 456}]})
        return httpx.Response(200, content=FEED, headers={"etag": '"v1"', "last-modified": "Wed, 21 Oct 2026"})

    monkeypatch.setattr(podcasts, "_client", lambda: original(transport=httpx.MockTransport(handle)))
    podcasts._cache.clear()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    admin = await register(client, "podcast_admin")
    await client.patch("/api/admin/config", headers=auth(admin["token"]), json={"registration": {"mode": "public"}})
    yield requests, responses
    podcasts._cache.clear()


def test_parse_feed():
    metadata, episodes = podcasts.parse_feed(FEED)
    assert metadata["title"] == "Resonance Podcast" and metadata["author"] == "Radio Author"
    assert metadata["description"] == "Feed description & more."
    assert metadata["image_url"] == "https://pod.example/cover.jpg"
    assert len(episodes) == 4
    assert [e["duration_seconds"] for e in episodes] == [123.5, 754, 3723, None]
    assert episodes[1]["guid"] == "https://pod.example/2.mp3"
    assert episodes[0]["description"] == "Hello world & friends.\nNext."
    assert episodes[0]["published_at"] == datetime(2026, 10, 21, 10, tzinfo=UTC)
    assert episodes[3]["published_at"] is None
    assert podcasts.plain_text("<p>" + "a" * 25000 + "</p>") == "a" * 20000
    for duration in ["bad", "NaN", "inf", "-2", "1:2:3:4"]:
        assert podcasts.duration_seconds(duration) is None


@pytest.mark.parametrize("data", [
    b"<rss>", b"<feed/>", b'<!DOCTYPE rss [<!ENTITY x SYSTEM "file:///etc/passwd">]><rss><channel/></rss>',
])
def test_unsafe_or_invalid_feed(data):
    with pytest.raises(podcasts.PodcastError):
        podcasts.parse_feed(data)


async def test_subscribe_progress_continue_counts_and_stream(client, feeds):
    user = await register(client, "podcast_listener")
    other = await register(client, "podcast_other")
    headers = auth(user["token"])
    preview = await client.get("/api/podcasts/preview", headers=headers,
                               params={"feed_url": "https://pod.example/feed.xml"})
    assert preview.status_code == 200
    assert (await client.get("/api/podcasts/subscriptions", headers=headers)).json() == []
    r = await client.post("/api/podcasts/subscriptions", headers=headers,
                          json={"feed_url": "https://pod.example/feed.xml"})
    assert r.status_code == 201, r.text
    podcast = r.json()
    id = podcast["id"]
    repeat = await client.post("/api/podcasts/subscriptions", headers=headers,
                               json={"feed_url": "https://pod.example/feed.xml"})
    assert repeat.json()["id"] == id and len(feeds[0]) == 1
    detail = (await client.get(f"/api/podcasts/{id}", headers=headers)).json()
    assert detail["subscribed"] and len(detail["episodes"]) == 4
    episodes = detail["episodes"]
    # Keep the 30-day count independent of the date the suite runs.
    async with SessionLocal() as db:
        for index, episode in enumerate(episodes):
            row = await db.get(PodcastEpisode, uuid.UUID(episode["id"]))
            row.published_at = datetime.now(UTC) - timedelta(days=index if index < 2 else 40)
        await db.commit()
    subscribed = (await client.get("/api/podcasts/subscriptions", headers=headers)).json()
    assert subscribed[0]["unplayed_count"] == 2
    assert subscribed[0]["latest_episode_at"]
    assert (await client.get("/api/podcasts/continue", headers=headers)).json() == []
    first, second = [e["id"] for e in episodes[:2]]
    for episode, position in [(first, 40), (second, 20)]:
        r = await client.put(f"/api/podcasts/episodes/{episode}/progress", headers=headers,
                             json={"position_seconds": position, "completed": False})
        assert r.status_code == 204
    continued = (await client.get("/api/podcasts/continue", headers=headers)).json()
    assert [e["id"] for e in continued] == [second, first]
    assert continued[0]["podcast_title"] == podcast["title"]
    assert (await client.get("/api/podcasts/continue", headers=auth(other["token"]))).json() == []
    r = await client.put(f"/api/podcasts/episodes/{first}/progress", headers=headers,
                         json={"position_seconds": 120, "completed": True})
    assert r.status_code == 204
    assert (await client.get("/api/podcasts/subscriptions", headers=headers)).json()[0]["unplayed_count"] == 1
    assert len((await client.get("/api/podcasts/continue", headers=headers)).json()) == 1
    single = (await client.get(f"/api/podcasts/episodes/{first}", headers=headers)).json()
    assert single["position_seconds"] == 120 and single["completed"]
    page = (await client.get(f"/api/podcasts/{id}?offset=1&limit=1", headers=headers)).json()
    assert len(page["episodes"]) == 1 and page["episodes"][0]["position_seconds"] == 20
    response = await client.get(f"/api/podcasts/episodes/{first}/stream?token={user['token']}")
    assert response.status_code == 302 and response.headers["location"] == single["audio_url"]
    assert (await client.get(f"/api/podcasts/episodes/{first}/stream")).status_code == 401
    assert (await client.delete(f"/api/podcasts/subscriptions/{id}", headers=headers)).status_code == 204
    assert (await client.get("/api/podcasts/subscriptions", headers=headers)).json() == []
    assert not (await client.get(f"/api/podcasts/{id}", headers=headers)).json()["subscribed"]
    async with SessionLocal() as db:
        await db.execute(delete(Podcast).where(Podcast.id == uuid.UUID(id)))
        await db.commit()
        assert await db.scalar(select(EpisodeProgress).where(EpisodeProgress.episode_id == uuid.UUID(first))) is None
        subscription = await db.scalar(
            select(PodcastSubscription).where(PodcastSubscription.podcast_id == uuid.UUID(id))
        )
        assert subscription is None


async def test_refresh_conditional_and_upsert(feeds):
    async with SessionLocal() as db:
        podcast = await podcasts.get_or_fetch(db, "https://pod.example/feed.xml")
        await db.commit()
        episode = await db.scalar(select(PodcastEpisode).where(PodcastEpisode.podcast_id == podcast.id))
        original_id = episode.id
        feeds[1].append(httpx.Response(304))
        await podcasts.refresh(db, podcast)
        assert feeds[0][-1].headers["if-none-match"] == '"v1"'
        assert feeds[0][-1].headers["if-modified-since"] == "Wed, 21 Oct 2026"
        feeds[1].append(httpx.Response(200, content=FEED.replace(b"Seconds", b"Updated"), headers={"etag": '"v2"'}))
        await podcasts.refresh(db, podcast)
        await db.refresh(episode)
        assert episode.id == original_id and podcast.etag == '"v2"'
        assert len(list(await db.scalars(select(PodcastEpisode).where(PodcastEpisode.podcast_id == podcast.id)))) == 4


async def test_search_cache_and_errors(client, feeds, monkeypatch):
    user = await register(client, "podcast_searcher")
    headers = auth(user["token"])
    for query in ["hello world", "HELLO WORLD"]:
        response = await client.get("/api/podcasts/search", params={"q": query}, headers=headers)
        assert response.status_code == 200
        assert response.json() == [{
            "itunes_id": 123, "title": "Discovery", "author": "Author",
            "image_url": "https://pod.example/cover.jpg", "feed_url": "https://pod.example/feed.xml",
        }]
    assert len(feeds[0]) == 1
    assert dict(feeds[0][0].url.params) == {"media": "podcast", "limit": "25", "term": "hello world"}
    key = "hello world"
    podcasts._cache[key] = (podcasts._cache[key][0] - 601, [])
    await podcasts.search(key)
    assert len(feeds[0]) == 2
    feeds[1].append(httpx.Response(503))
    assert (await client.get("/api/podcasts/search?q=unavailable", headers=headers)).status_code == 502
    for data in [b"not xml", b"x" * (podcasts.MAX_FEED_BYTES + 1)]:
        feeds[1].append(httpx.Response(200, content=data))
        with pytest.raises(podcasts.PodcastError):
            await podcasts.fetch_feed("https://pod.example/invalid.xml")
    response = await client.put(f"/api/podcasts/episodes/{uuid.uuid4()}/progress", headers=headers,
                                json={"position_seconds": -1, "completed": False})
    assert response.status_code == 422
    assert (await client.get(f"/api/podcasts/episodes/{uuid.uuid4()}", headers=headers)).status_code == 404
    assert (await client.get(f"/api/podcasts/{uuid.uuid4()}", headers=headers)).status_code == 404


async def test_continue_limit_order_and_subscription_sorting(client, feeds):
    user = await register(client, "podcast_many")
    headers = auth(user["token"])
    async with SessionLocal() as db:
        listener = await db.scalar(select(User).where(User.username == "podcast_many"))
        first = await podcasts.get_or_fetch(db, "https://first.example/feed")
        second = await podcasts.get_or_fetch(db, "https://second.example/feed")
        db.add_all([PodcastSubscription(user_id=listener.id, podcast_id=p.id) for p in [first, second]])
        for index in range(13):
            episode = PodcastEpisode(
                podcast_id=second.id, guid=f"extra-{index}", title=f"Extra {index}",
                audio_url=f"https://pod.example/{index}.mp3", published_at=datetime.now(UTC),
            )
            db.add(episode)
            await db.flush()
            db.add(EpisodeProgress(
                user_id=listener.id, episode_id=episode.id, position_seconds=10, completed=index == 12,
                updated_at=datetime.now(UTC) + timedelta(seconds=index),
            ))
        await db.commit()
    rows = (await client.get("/api/podcasts/continue", headers=headers)).json()
    assert len(rows) == 10
    assert [row["title"] for row in rows] == [f"Extra {index}" for index in range(11, 1, -1)]
    rows = (await client.get("/api/podcasts/subscriptions", headers=headers)).json()
    assert [row["id"] for row in rows] == [str(second.id), str(first.id)]


async def test_background_refresh_skips_unsubscribed_and_continues_after_errors(feeds, monkeypatch, caplog):
    async with SessionLocal() as db:
        user = await db.scalar(select(User))
        subscribed = [await podcasts.get_or_fetch(db, f"https://{name}.example/feed") for name in ["one", "two"]]
        await podcasts.get_or_fetch(db, "https://unsubscribed.example/feed")
        db.add_all([PodcastSubscription(user_id=user.id, podcast_id=p.id) for p in subscribed])
        await db.commit()
    visited = []
    delays = []

    async def refresh(db, podcast):
        visited.append(podcast.id)
        if len(visited) == 1:
            raise podcasts.PodcastError("Broken feed")

    async def sleep(seconds):
        delays.append(seconds)
        if seconds == 7200:
            raise asyncio.CancelledError

    monkeypatch.setattr(podcasts, "refresh", refresh)
    monkeypatch.setattr(podcasts.asyncio, "sleep", sleep)
    with pytest.raises(asyncio.CancelledError):
        await podcasts._refresh_loop()
    assert set(visited) == {p.id for p in subscribed}
    assert delays == [5, 7200]
    assert "Podcast refresh failed" in caplog.text
