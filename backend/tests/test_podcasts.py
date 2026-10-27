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
        if request.url.host == "itunes.apple.com":
            if request.url.path.endswith("/search"):
                return httpx.Response(200, json={"results": [{
                    "collectionId": 123, "collectionName": "Discovery", "artistName": "Author",
                    "artworkUrl600": "https://pod.example/cover.jpg", "feedUrl": "https://pod.example/feed.xml",
                }, {"collectionId": 456}]})
            return httpx.Response(200, json={"results": []})
        if request.url.host == "api.fyyd.de":
            return httpx.Response(200, json={"data": []})
        if responses:
            return responses.pop(0)
        return httpx.Response(200, content=FEED, headers={"etag": '"v1"', "last-modified": "Wed, 21 Oct 2026"})

    monkeypatch.setattr(podcasts, "_client", lambda: original(transport=httpx.MockTransport(handle)))
    podcasts._cache.clear()
    podcasts._chart_cache.clear()
    podcasts._genre_cache.clear()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    admin = await register(client, "podcast_admin")
    await client.patch("/api/admin/config", headers=auth(admin["token"]), json={"registration": {"mode": "public"}})
    yield requests, responses
    podcasts._cache.clear()
    podcasts._chart_cache.clear()
    podcasts._genre_cache.clear()


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
    detail = (await client.get(f"/api/podcasts/{id}", headers=headers)).json()
    assert (detail["episode_count"], detail["completed_count"]) == (4, 1)
    oldest = (await client.get(f"/api/podcasts/{id}?order=oldest", headers=headers)).json()["episodes"]
    assert [e["id"] for e in oldest] == [e["id"] for e in reversed(detail["episodes"])]
    assert (await client.get(f"/api/podcasts/{id}?order=random", headers=headers)).status_code == 422
    r = await client.put(f"/api/podcasts/{id}/played", headers=headers, json={"completed": True})
    assert r.status_code == 204
    detail = (await client.get(f"/api/podcasts/{id}", headers=headers)).json()
    assert detail["completed_count"] == 4 and all(e["completed"] for e in detail["episodes"])
    # Marking all as heard keeps where an episode was left off.
    assert [e["position_seconds"] for e in detail["episodes"] if e["id"] == second] == [20]
    assert (await client.get(f"/api/podcasts/{id}", headers=auth(other["token"]))).json()["completed_count"] == 0
    await client.put(f"/api/podcasts/{id}/played", headers=headers, json={"completed": False})
    assert (await client.get(f"/api/podcasts/{id}", headers=headers)).json()["completed_count"] == 0
    for episode, position, done in [(first, 120, True), (second, 20, False)]:
        await client.put(f"/api/podcasts/episodes/{episode}/progress", headers=headers,
                         json={"position_seconds": position, "completed": done})
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
            "source": "apple",
        }]
    assert len(feeds[0]) == 2
    apple_request = next(request for request in feeds[0] if request.url.host == "itunes.apple.com")
    assert dict(apple_request.url.params) == {
        "media": "podcast", "limit": "25", "term": "hello world", "country": "DE",
    }
    key = ("DE", "hello world")
    podcasts._cache[key] = (podcasts._cache[key][0] - 601, [])
    await podcasts.search("hello world", "DE")
    assert len(feeds[0]) == 4
    for data in [b"not xml", b"x" * (podcasts.MAX_FEED_BYTES + 1)]:
        feeds[1].append(httpx.Response(200, content=data))
        with pytest.raises(podcasts.PodcastError):
            await podcasts.fetch_feed("https://pod.example/invalid.xml")
    response = await client.put(f"/api/podcasts/episodes/{uuid.uuid4()}/progress", headers=headers,
                                json={"position_seconds": -1, "completed": False})
    assert response.status_code == 422
    assert (await client.get(f"/api/podcasts/episodes/{uuid.uuid4()}", headers=headers)).status_code == 404
    assert (await client.get(f"/api/podcasts/{uuid.uuid4()}", headers=headers)).status_code == 404


async def test_search_merges_dedupes_and_handles_source_failures(client, feeds, monkeypatch):
    user = await register(client, "podcast_sources")
    headers = auth(user["token"])
    requests = []

    def install(apple_status=200, fyyd_status=200):
        def handle(request):
            requests.append(request)
            if request.url.host == "itunes.apple.com":
                if apple_status != 200:
                    return httpx.Response(apple_status)
                return httpx.Response(200, json={"results": [{
                    "collectionId": 10, "collectionName": "Apple", "artistName": "Author",
                    "feedUrl": "https://www.Example.com/feed/", "artworkUrl100": "https://pod.example/a.jpg",
                }]})
            if fyyd_status != 200:
                return httpx.Response(fyyd_status)
            return httpx.Response(200, json={"data": [
                {"title": "Duplicate", "author": "Other", "xmlURL": "http://example.com/feed"},
                {"title": "Fyyd", "author": "Fyyd author", "imgURL": "https://pod.example/f.jpg",
                 "xmlURL": "https://fyyd.example/feed.xml"},
                {"title": "Bad URL", "xmlURL": "file:///tmp/feed.xml"},
            ]})

        monkeypatch.setattr(podcasts, "_client", lambda: httpx.AsyncClient(transport=httpx.MockTransport(handle)))
        podcasts._cache.clear()

    install()
    response = await client.get("/api/podcasts/search?q=coffee", headers=headers)
    assert response.status_code == 200
    assert response.json() == [
        {
            "itunes_id": 10, "title": "Apple", "author": "Author", "image_url": "https://pod.example/a.jpg",
            "feed_url": "https://www.Example.com/feed/", "source": "apple",
        },
        {
            "itunes_id": None, "title": "Fyyd", "author": "Fyyd author", "image_url": "https://pod.example/f.jpg",
            "feed_url": "https://fyyd.example/feed.xml", "source": "fyyd",
        },
    ]
    fyyd_request = next(request for request in requests if request.url.host == "api.fyyd.de")
    assert dict(fyyd_request.url.params) == {"term": "coffee", "count": "25"}

    requests.clear()
    install(apple_status=503)
    response = await client.get("/api/podcasts/search?q=only-fyyd", headers=headers)
    assert response.status_code == 200 and response.json()[0]["source"] == "fyyd"
    assert response.json()[0]["itunes_id"] is None

    install(apple_status=503, fyyd_status=503)
    response = await client.get("/api/podcasts/search?q=unavailable", headers=headers)
    assert response.status_code == 502


async def test_top_podcasts_parses_single_and_list_entries_and_drops_missing_feeds(feeds, monkeypatch):
    requests = []

    def handle(request):
        requests.append(request)
        if request.url.path.endswith("/limit=1/genre=1303/json"):
            return httpx.Response(200, json={"feed": {"entry": {"id": {"attributes": {"im:id": "1"}}}}})
        if request.url.path.endswith("/limit=2/genre=1489/json"):
            return httpx.Response(200, json={"feed": {"entry": [
                {"id": {"attributes": {"im:id": "2"}}}, {"id": {"attributes": {"im:id": "3"}}},
            ]}})
        if request.url.path == "/lookup" and request.url.params["id"] == "1":
            items = [{"collectionId": 1, "collectionName": "Single", "feedUrl": "https://pod.example/1"}]
        else:
            items = [
                {"collectionId": 3, "collectionName": "No feed"},
                {"collectionId": 2, "collectionName": "Kept", "feedUrl": "https://pod.example/2"},
            ]
        return httpx.Response(200, json={"results": items})

    monkeypatch.setattr(podcasts, "_client", lambda: httpx.AsyncClient(transport=httpx.MockTransport(handle)))
    podcasts._chart_cache.clear()
    single = await podcasts.top_podcasts("DE", 1303, limit=1)
    assert [item["title"] for item in single] == ["Single"]
    ordered = await podcasts.top_podcasts("DE", 1489, limit=2)
    assert [item["title"] for item in ordered] == ["Kept"]
    assert all(item["source"] == "apple" for item in single + ordered)
    assert requests[0].url.path == "/de/rss/toppodcasts/limit=1/genre=1303/json"
    assert requests[1].url.path == "/lookup" and requests[1].url.params["country"] == "DE"
    assert requests[2].url.path == "/de/rss/toppodcasts/limit=2/genre=1489/json"


async def test_discover_sections_and_unknown_genre(client, feeds, monkeypatch):
    user = await register(client, "podcast_discover")
    headers = {**auth(user["token"]), "Accept-Language": "en"}
    async with SessionLocal() as db:
        listener = await db.scalar(select(User).where(User.username == "podcast_discover"))
        names = ["Newest", "Prior", "Oldest"]
        rows = [Podcast(feed_url=f"https://subscribed.example/{i}", title=name) for i, name in enumerate(names)]
        db.add_all(rows)
        await db.flush()
        now = datetime.now(UTC)
        db.add_all([
            PodcastSubscription(user_id=listener.id, podcast_id=row.id, created_at=now - timedelta(days=i))
            for i, row in enumerate(rows)
        ])
        await db.commit()
    genres = {str(row.id): 1303 for row in rows}

    async def podcast_genre(podcast, country):
        assert country == "US"
        return genres[str(podcast.id)]

    requests = []

    def handle(request):
        requests.append(request)
        if request.url.path.endswith("/genre=1303/json"):
            ids = [1, 2, 3]
        elif "/rss/toppodcasts/" in request.url.path:
            ids = [10, 11]
        else:
            requested = request.url.params["id"].split(",")
            if requested == ["1", "2", "3"]:
                items = [
                    {"collectionId": 1, "collectionName": "Subscribed", "feedUrl": "http://www.subscribed.example/0/"},
                    {"collectionId": 2, "collectionName": "Recommended", "feedUrl": "https://pod.example/recommend"},
                    {"collectionId": 3, "collectionName": "No feed"},
                ]
            else:
                items = [
                    {"collectionId": 10, "collectionName": "Top subscribed", "feedUrl": "https://subscribed.example/0"},
                    {"collectionId": 11, "collectionName": "Top other", "feedUrl": "https://pod.example/top"},
                ]
            return httpx.Response(200, json={"results": items})
        return httpx.Response(200, json={"feed": {"entry": [
            {"id": {"attributes": {"im:id": str(item_id)}}} for item_id in ids
        ]}})

    monkeypatch.setattr(podcasts, "podcast_genre", podcast_genre)
    monkeypatch.setattr(podcasts, "_client", lambda: httpx.AsyncClient(transport=httpx.MockTransport(handle)))
    podcasts._chart_cache.clear()
    response = await client.get("/api/podcasts/discover", headers=headers)
    assert response.status_code == 200
    data = response.json()
    assert data["genres"][0] == {"id": 1303, "name": "Comedy"}
    assert [section["id"] for section in data["sections"]] == [f"because:{rows[0].id}", "top"]
    assert data["sections"][0]["title"] == "Because you listen to Newest"
    assert [item["title"] for item in data["sections"][0]["items"]] == ["Recommended"]
    assert [item["title"] for item in data["sections"][1]["items"]] == ["Top subscribed", "Top other"]
    assert sum("genre=1303" in request.url.path for request in requests) == 1
    assert (await client.get("/api/podcasts/genres/999", headers=headers)).status_code == 404


async def test_latest_orders_new_episodes_and_excludes_completed(client, feeds):
    user = await register(client, "podcast_latest")
    headers = auth(user["token"])
    async with SessionLocal() as db:
        listener = await db.scalar(select(User).where(User.username == "podcast_latest"))
        podcast = Podcast(feed_url="https://latest.example/feed", title="Latest podcast")
        db.add(podcast)
        await db.flush()
        db.add(PodcastSubscription(user_id=listener.id, podcast_id=podcast.id))
        now = datetime.now(UTC)
        episodes = [
            PodcastEpisode(
                podcast_id=podcast.id, guid=f"latest-{i}", title=title,
                audio_url="https://pod.example/e.mp3", published_at=published,
            )
            for i, (title, published) in enumerate([
                ("Older", now - timedelta(days=2)), ("Newer", now - timedelta(days=1)),
                ("Completed", now), ("Unknown date", None),
            ])
        ]
        db.add_all(episodes)
        await db.flush()
        db.add(EpisodeProgress(user_id=listener.id, episode_id=episodes[2].id, completed=True, position_seconds=30))
        await db.commit()
    response = await client.get("/api/podcasts/latest", headers=headers)
    assert response.status_code == 200
    assert [item["title"] for item in response.json()] == ["Newer", "Older", "Unknown date"]
    assert all(not item["completed"] for item in response.json())
    assert (await client.get("/api/podcasts/latest?limit=51", headers=headers)).status_code == 422


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
