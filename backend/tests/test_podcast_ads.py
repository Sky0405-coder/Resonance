import os
import uuid
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from sqlalchemy import select

from app.db import SessionLocal
from app.models import PodcastAd, PodcastEpisode
from app.services import podcast_ads
from tests.conftest import auth, register
from tests.test_podcasts import feeds  # noqa: F401

# MPEG-1 layer III, 128 kbit/s, 44.1 kHz: 417-byte frames of 26 ms.
HEADER = b"\xff\xfb\x90\x00"


def chunk(count: int) -> list[bytes]:
    return [HEADER + os.urandom(413) for _ in range(count)]


def parse(*parts: list[bytes]) -> list[podcast_ads.Frame]:
    return podcast_ads.frames(b"".join(frame for part in parts for frame in part))


def seconds(frames: int) -> float:
    return frames * 1152 / 44100


def test_frames_skip_tags_and_vbr_header():
    xing = HEADER + b"\x00" * 32 + b"Xing" + b"\x00" * 377
    tag = b"ID3\x04\x00\x00\x00\x00\x00\x05" + b"\xff\xfb\x90\x00\x00"
    show = chunk(3)
    frames = podcast_ads.frames(tag + xing + show[0] + show[1] + show[2] + b"TAG" + b"\x00" * 125)
    assert len(frames) == 3
    assert frames[0].seconds == pytest.approx(seconds(1))
    assert frames[0].start == len(tag) + len(xing)


def test_spliced_ads_are_cut_and_learned():
    show, ad_a, ad_b, post = chunk(2000), chunk(300), chunk(200), chunk(250)
    main = parse(show[:500], ad_a, show[500:], post)
    other = parse(show[:500], ad_b, show[500:])
    same_spot = parse(show[:500], ad_a, show[500:], post)
    result = podcast_ads.analyze(main, [other, same_spot], set())
    assert result.cut == [(500, 800), (2300, 2550)]
    assert result.removed == pytest.approx(seconds(550))
    assert result.duration == pytest.approx(seconds(2000))
    assert [round(s, 1) for _, s in result.learned] == [round(seconds(300), 1), round(seconds(250), 1)]

    # The next episode got the same spot in every download: only the remembered hashes find it.
    known = {h for hashes, _ in result.learned for h in podcast_ads.known_hashes(hashes)}
    later = chunk(1000)
    again = parse(later[:400], ad_a, later[400:])
    assert podcast_ads.analyze(again, [again], set()).cut == []
    found = podcast_ads.analyze(again, [again], known)
    assert found.cut == [(400, 700)] and found.learned == []


def test_short_differences_stay_and_unrelated_downloads_fail():
    show = chunk(1000)
    # A re-encoded frame or two around a splice is no ad.
    main = parse(show[:500], chunk(2), show[500:])
    assert podcast_ads.analyze(main, [parse(show)], set()).cut == []
    with pytest.raises(podcast_ads.AdError):
        podcast_ads.analyze(main, [parse(chunk(1000))], set())
    # Never more than 40 % of the episode.
    long_ad = chunk(800)
    with pytest.raises(podcast_ads.AdError):
        podcast_ads.analyze(parse(show[:500], long_ad, show[500:]), [parse(show)], set())


async def _subscribed_episode(client) -> tuple[dict, dict, str]:
    user = await register(client, f"ads_{uuid.uuid4().hex[:8]}")
    other = await register(client, f"ads_{uuid.uuid4().hex[:8]}")
    for account in (user, other):
        r = await client.post("/api/podcasts/subscriptions", headers=auth(account["token"]),
                              json={"feed_url": "https://pod.example/feed.xml"})
        assert r.status_code == 201
    return user, other, r.json()["id"]


async def test_remove_ads_setting_stream_and_episode(client, feeds, monkeypatch):  # noqa: F811
    podcast_ads._pending.clear()
    user, other, podcast_id = await _subscribed_episode(client)
    headers = auth(user["token"])
    outsider = await register(client, "ads_outsider")
    r = await client.put(f"/api/podcasts/{podcast_id}/remove-ads", headers=auth(outsider["token"]),
                         json={"enabled": True})
    assert r.status_code == 409
    assert (await client.put(f"/api/podcasts/{podcast_id}/remove-ads", headers=headers,
                             json={"enabled": True})).status_code == 204

    detail = (await client.get(f"/api/podcasts/{podcast_id}", headers=headers)).json()
    assert detail["remove_ads"] is True
    episode = detail["episodes"][0]
    assert episode["ad_status"] == "pending" and episode["ads_removed_seconds"] is None
    other_detail = (await client.get(f"/api/podcasts/{podcast_id}", headers=auth(other["token"]))).json()
    assert other_detail["remove_ads"] is False and other_detail["episodes"][0]["ad_status"] is None

    stream = f"/api/podcasts/episodes/{episode['id']}/stream"
    r = await client.get(f"{stream}?token={user['token']}")
    assert r.status_code == 302 and r.headers["location"] == episode["audio_url"]
    assert uuid.UUID(episode["id"]) in podcast_ads._pending

    path = podcast_ads.episode_path(uuid.UUID(episode["id"]))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"clean audio")
    async with SessionLocal() as db:
        row = await db.get(PodcastEpisode, uuid.UUID(episode["id"]))
        row.ad_status, row.ad_seconds, row.ad_duration = "done", 67.0, 3888.0
        await db.commit()
    r = await client.get(f"{stream}?token={user['token']}")
    assert r.status_code == 200 and r.content == b"clean audio" and r.headers["content-type"] == "audio/mpeg"
    r = await client.get(f"{stream}?token={user['token']}", headers={"Range": "bytes=0-4"})
    assert r.status_code == 206 and r.content == b"clean"
    # Without the setting the host's file (with its ads) plays.
    assert (await client.get(f"{stream}?token={other['token']}")).status_code == 302

    cleaned = (await client.get(f"/api/podcasts/episodes/{episode['id']}", headers=headers)).json()
    assert cleaned["ads_removed_seconds"] == 67.0 and cleaned["duration_seconds"] == 3888.0
    assert cleaned["ad_status"] == "done"
    plain = (await client.get(f"/api/podcasts/episodes/{episode['id']}", headers=auth(other["token"]))).json()
    assert plain["ads_removed_seconds"] is None and plain["duration_seconds"] == episode["duration_seconds"]

    assert (await client.put(f"/api/podcasts/{podcast_id}/remove-ads", headers=headers,
                             json={"enabled": False})).status_code == 204
    assert (await client.get(f"{stream}?token={user['token']}")).status_code == 302
    path.unlink()
    podcast_ads._pending.clear()


async def test_process_downloads_compares_and_cleans_up(client, feeds, monkeypatch, tmp_path):  # noqa: F811
    user, _, podcast_id = await _subscribed_episode(client)
    await client.put(f"/api/podcasts/{podcast_id}/remove-ads", headers=auth(user["token"]), json={"enabled": True})
    async with SessionLocal() as db:
        episodes = list(await db.scalars(select(PodcastEpisode).where(PodcastEpisode.podcast_id == podcast_id)))
        for index, row in enumerate(episodes):
            row.published_at = datetime.now(UTC) - timedelta(days=index * 20)
        await db.commit()
    candidates = await podcast_ads._candidates()
    assert len(candidates) == 2 and set(candidates) <= {e.id for e in episodes}
    # An older episode someone is in the middle of comes first.
    oldest = max(episodes, key=lambda e: datetime.now(UTC) - e.published_at)
    await client.put(f"/api/podcasts/episodes/{oldest.id}/progress", headers=auth(user["token"]),
                     json={"position_seconds": 600, "completed": False})
    assert await podcast_ads._candidates() == [oldest.id, *candidates]
    await client.put(f"/api/podcasts/episodes/{oldest.id}/progress", headers=auth(user["token"]),
                     json={"position_seconds": 600, "completed": True})
    assert await podcast_ads._candidates() == candidates

    show, intro, ads = chunk(1500), chunk(100), [chunk(200), chunk(160), chunk(240)]
    bodies = {
        agent: b"".join([*intro, *ad, *show])
        for agent, ad in zip(podcast_ads.AGENTS, ads, strict=True)
    }
    agents = []

    def handle(request):
        agents.append(request.headers["user-agent"])
        return httpx.Response(200, content=bodies[request.headers["user-agent"]])

    original = httpx.AsyncClient
    monkeypatch.setattr(podcast_ads.httpx, "AsyncClient",
                        lambda **kwargs: original(transport=httpx.MockTransport(handle), **kwargs))
    episode_id = candidates[0]
    await podcast_ads.process(episode_id)
    assert agents == list(podcast_ads.AGENTS)
    async with SessionLocal() as db:
        row = await db.get(PodcastEpisode, episode_id)
        assert row.ad_status == "done"
        assert row.ad_seconds == pytest.approx(seconds(200), abs=0.01)
        assert row.ad_duration == pytest.approx(seconds(1600), abs=0.1)
        learned = list(await db.scalars(select(PodcastAd)))
        assert len(learned) == 1 and learned[0].podcast_id == uuid.UUID(podcast_id)
    path = podcast_ads.episode_path(episode_id)
    assert path.exists()
    assert len(podcast_ads.frames(path.read_bytes())) == 1600
    assert not any((path.parent / "tmp").glob("*/*"))

    # Done episodes are not fetched again; old files go away unless someone is in the middle of it.
    await podcast_ads.process(episode_id)
    assert len(agents) == 3
    async with SessionLocal() as db:
        row = await db.get(PodcastEpisode, episode_id)
        row.ad_processed_at = datetime.now(UTC) - timedelta(days=60)
        await db.commit()
    await podcast_ads.cleanup()
    assert not path.exists()
    async with SessionLocal() as db:
        assert (await db.get(PodcastEpisode, episode_id)).ad_status is None

    # A host that serves the same file every time has no inserted ads.
    bodies = dict.fromkeys(podcast_ads.AGENTS, b"".join(show))
    await podcast_ads.process(candidates[1])
    async with SessionLocal() as db:
        row = await db.get(PodcastEpisode, candidates[1])
        assert row.ad_status == "none" and row.ad_seconds == 0
    assert not podcast_ads.episode_path(candidates[1]).exists()
