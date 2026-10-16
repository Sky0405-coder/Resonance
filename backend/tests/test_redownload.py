import asyncio
import io
import shutil
import uuid
from collections.abc import AsyncIterator, Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from PIL import Image
from sqlalchemy import func, select

from app.db import Base, SessionLocal, engine
from app.models import (
    DownloadItem,
    DownloadRequest,
    PlayEvent,
    Playlist,
    PlaylistEntry,
    Track,
    TrackLike,
    TrackLyrics,
    User,
)
from app.services import downloads, sources
from app.services.downloads import DownloadManager
from app.services.musicbrainz import TrackMeta
from app.services.scanner import import_file
from app.services.sources.base import Cancelled, Candidate
from app.services.sources.youtube import YouTubeMusicSource, video_id
from app.services.tagger import write_tags
from app.services.tags import embedded_cover
from tests.conftest import MUSIC_DIR, auth, make_track, register


class FakeSource:
    name = "youtube"

    def __init__(self, audio: Path) -> None:
        self.audio = audio
        self.excludes: list[frozenset[str]] = []
        self.picks: list[str] = []
        self.no_match = False
        self.fail_once = False

    def candidate(self, ref: str) -> Candidate:
        return YouTubeMusicSource.candidate(self, ref)

    async def find(self, meta: TrackMeta, exclude: frozenset[str] = frozenset()) -> Candidate | None:
        self.excludes.append(exclude)
        return None if self.no_match else self.candidate("new_video01")

    async def download(
        self, candidate: Candidate, dest_dir: Path, progress: Callable[[float], None], cancelled: Callable[[], bool]
    ) -> Path:
        self.picks.append(candidate.ref)
        if cancelled():
            raise Cancelled()
        if self.fail_once:
            self.fail_once = False
            raise RuntimeError("Testfehler")
        path = dest_dir / "audio.opus"
        await asyncio.to_thread(shutil.copyfile, self.audio, path)
        progress(1)
        return path


@pytest.fixture
async def env(client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")

    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)
        shutil.rmtree(MUSIC_DIR, ignore_errors=True)

    await reset()
    admin = await register(client, "redownload-admin")
    admin_headers = auth(admin["token"])
    response = await client.patch(
        "/api/admin/config",
        json={"registration": {"mode": "public"}, "downloads": {"auto_approve_requests": False}},
        headers=admin_headers,
    )
    assert response.status_code == 200
    user = await register(client, "redownload-user")
    other = await register(client, "redownload-other")
    original = make_track(
        "Artist/Album/01 - Song.flac",
        title="Song",
        artist="Artist feat. Guest",
        album="Album",
        albumartist="Artist",
        track="1",
        disc="1",
        date="2020",
        genre="Pop",
        isrc="DETEST000001",
    )
    async with SessionLocal() as db:
        track = await import_file(db, str(original.relative_to(MUSIC_DIR)))
        track_id = track.id
    fake = FakeSource(make_track("replacement.opus"))
    monkeypatch.setattr(sources, "enabled_sources", lambda cfg: [fake] if cfg.downloads.youtube_enabled else [])

    async def no_cover(meta: TrackMeta) -> None:
        raise AssertionError("Redownload must reuse the existing cover")

    monkeypatch.setattr(downloads, "fetch_cover", no_cover)
    yield SimpleNamespace(
        admin=admin_headers,
        user=auth(user["token"]),
        user_id=uuid.UUID(user["user"]["id"]),
        other_id=uuid.UUID(other["user"]["id"]),
        track_id=track_id,
        original=original,
        fake=fake,
    )
    await reset()


async def create(client: httpx.AsyncClient, env: SimpleNamespace, **body: object) -> dict:
    response = await client.post(f"/api/tracks/{env.track_id}/redownload", json=body, headers=env.user)
    assert response.status_code == 201, response.text
    return response.json()


async def approve(client: httpx.AsyncClient, env: SimpleNamespace, request: dict) -> None:
    response = await client.post(f"/api/requests/{request['id']}/approve", headers=env.admin)
    assert response.status_code == 200, response.text


async def history(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        request = DownloadRequest(
            user_id=env.other_id,
            kind="track",
            title="Song",
            artist="Artist",
            status="done",
            items=[
                DownloadItem(
                    position=i,
                    title="Song",
                    artist="Artist",
                    meta={},
                    status="failed" if i == 1 else "done",
                    source=source,
                    source_ref=ref,
                    track_id=env.track_id if same_track else None,
                    created_at=datetime.now(UTC) - timedelta(minutes=10 - i),
                )
                for i, (source, ref, same_track) in enumerate(
                    [
                        ("youtube", "old_video01", True),
                        ("youtube", "old_video02", True),
                        ("youtube", "old_video01", True),
                        ("youtube", "", True),
                        ("torrent", "torrent-ref", True),
                        ("youtube", "other_track", False),
                    ]
                )
            ],
        )
        db.add(request)
        await db.commit()


@pytest.mark.parametrize(
    "url",
    [
        "https://music.youtube.com/watch?v=AbCdEf_12-3&list=playlist",
        "https://www.youtube.com/watch?v=AbCdEf_12-3",
        "https://youtube.com/watch?v=AbCdEf_12-3",
        "https://m.youtube.com/watch?v=AbCdEf_12-3",
        "https://youtu.be/AbCdEf_12-3?t=42",
    ],
)
def test_video_id(url: str) -> None:
    assert video_id(url) == "AbCdEf_12-3"


@pytest.mark.parametrize(
    "url",
    [
        "http://youtube.com/watch?v=AbCdEf_12-3",
        "https://youtube.com.evil/watch?v=AbCdEf_12-3",
        "https://www.youtube.com/shorts/AbCdEf_12-3",
        "https://youtu.be/AbCdEf_12-3/extra",
        "https://youtube.com/watch?v=short",
        "https://youtube.com/watch?v=AbCdEf_12-3x",
        "https://youtube.com/watch?v=AbCdEf!12-3",
        "https://youtube.com/watch",
        "https://[invalid",
        "",
    ],
)
def test_invalid_video_id(url: str) -> None:
    assert video_id(url) is None


async def test_creation_excludes_and_meta(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await history(env)
    result = await create(client, env)
    assert result["kind"] == "redownload" and result["replace_track_id"] == str(env.track_id)
    assert result["catalog_id"] is None and result["cover_url"] is None and result["is_temporary"] is False
    assert result["status"] == "pending_approval" and result["items"][0]["status"] == "waiting"
    assert result["items"][0]["track_id"] is None
    async with SessionLocal() as db:
        item = await db.get(DownloadItem, uuid.UUID(result["items"][0]["id"]))
        track = await db.get(Track, env.track_id)
        assert item.exclude_refs == ["old_video01", "old_video02"]
        meta = TrackMeta.model_validate(item.meta)
        for field in ("title", "track_no", "disc_no", "year", "duration", "isrc", "genre", "mb_recording_id"):
            assert getattr(meta, field) == getattr(track, field)
        assert meta.artist == "Artist feat. Guest" and meta.album == "Album" and meta.album_artist == "Artist"
        assert meta.date is None and meta.cover_url is None and meta.deezer_track_id is None


@pytest.mark.parametrize(
    "url",
    [
        "bad link",
        "",
        "https://youtu.be/too-short",
        "x" * 501,
        "https://on.soundcloud.com/short",
        "http://soundcloud.com/artist/song",
        "https://soundcloud.com/artist",
        "https://soundcloud.com/artist/sets/album",
        "https://soundcloud.com.evil.test/artist/song",
        "https://soundcloud.com@evil.test/artist/song",
    ],
)
async def test_invalid_link(client: httpx.AsyncClient, env: SimpleNamespace, url: str) -> None:
    response = await client.post(f"/api/tracks/{env.track_id}/redownload", json={"youtube_url": url}, headers=env.user)
    assert response.status_code == 422
    if len(url) <= 500:
        assert response.json()["detail"] == "Kein gültiger YouTube- oder SoundCloud-Link"


async def test_forced_link_and_retry(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await history(env)
    result = await create(client, env, youtube_url="https://youtu.be/old_video01")
    async with SessionLocal() as db:
        item = await db.get(DownloadItem, uuid.UUID(result["items"][0]["id"]))
        assert item.source == "youtube" and item.source_ref == "old_video01" and item.exclude_refs == []
        item.status = "failed"
        request = await db.get(DownloadRequest, uuid.UUID(result["id"]))
        request.status = "failed"
        await db.commit()
    response = await client.post(f"/api/requests/{result['id']}/retry", headers=env.user)
    assert response.status_code == 200
    assert await DownloadManager().process_one()
    assert env.fake.excludes == [] and env.fake.picks == ["old_video01"]
    detail = (await client.get(f"/api/requests/{result['id']}", headers=env.user)).json()
    assert detail["status"] == "done"


@pytest.mark.parametrize("host", ["soundcloud.com", "m.soundcloud.com"])
async def test_forced_soundcloud_link(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, host: str
) -> None:
    soundcloud = FakeSource(env.fake.audio)
    soundcloud.name = "soundcloud"
    monkeypatch.setattr(sources, "enabled_sources", lambda cfg: [env.fake, soundcloud])
    url = f"https://{host}/artist/song"
    result = await create(client, env, youtube_url=url)
    async with SessionLocal() as db:
        item = await db.get(DownloadItem, uuid.UUID(result["items"][0]["id"]))
        assert item.source == "soundcloud" and item.source_ref == url and item.exclude_refs == []
    await approve(client, env, result)
    assert await DownloadManager().process_one()
    assert soundcloud.picks == [url] and soundcloud.excludes == []
    assert env.fake.picks == [] and env.fake.excludes == []
    detail = (await client.get(f"/api/requests/{result['id']}", headers=env.user)).json()
    assert detail["status"] == "done" and detail["items"][0]["source"] == "soundcloud"


@pytest.mark.parametrize("approved", [False, True])
async def test_dedup_and_approval(client: httpx.AsyncClient, env: SimpleNamespace, approved: bool) -> None:
    await client.patch("/api/admin/config", json={"downloads": {"auto_approve_requests": approved}}, headers=env.admin)
    first = await create(client, env)
    assert first["status"] == ("active" if approved else "pending_approval")
    assert first["items"][0]["status"] == ("queued" if approved else "waiting")
    assert (await create(client, env))["id"] == first["id"]
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(DownloadRequest)) == 1


async def test_daily_limit_and_admin_exemption(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await client.patch(
        "/api/admin/config",
        json={"downloads": {"daily_limit_enabled": True, "daily_limit_per_user": 1}},
        headers=env.admin,
    )
    result = await create(client, env)
    await client.post(f"/api/requests/{result['id']}/reject", json={}, headers=env.admin)
    response = await client.post(f"/api/tracks/{env.track_id}/redownload", json={}, headers=env.user)
    assert response.status_code == 429
    assert response.json()["detail"] == "Tageslimit erreicht (1 von 1 Songs in 24 Stunden)"
    response = await client.post(f"/api/tracks/{env.track_id}/redownload", json={}, headers=env.admin)
    assert response.status_code == 201 and response.json()["status"] == "active"


async def test_unknown_and_authentication(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    response = await client.post(f"/api/tracks/{uuid.uuid4()}/redownload", json={}, headers=env.user)
    assert response.status_code == 404
    response = await client.post(f"/api/tracks/{env.track_id}/redownload", json={})
    assert response.status_code == 401


@pytest.mark.parametrize("same_suffix", [False, True])
@pytest.mark.parametrize("cover_kind", ["embedded", "folder", "none"])
async def test_replace_preserves_library(
    client: httpx.AsyncClient, env: SimpleNamespace, same_suffix: bool, cover_kind: str
) -> None:
    if same_suffix:
        opus = env.original.with_suffix(".opus")
        make_track(str(opus.relative_to(MUSIC_DIR)))
        async with SessionLocal() as db:
            track = await db.get(Track, env.track_id)
            track.path = str(opus.relative_to(MUSIC_DIR))
            await db.commit()
        env.original.unlink()
        env.original = opus
    await history(env)
    result = await create(client, env)
    async with SessionLocal() as db:
        item = await db.get(DownloadItem, uuid.UUID(result["items"][0]["id"]))
        meta = TrackMeta.model_validate(item.meta)
        track = await db.get(Track, env.track_id)
        track.is_temporary = True
        playlist = Playlist(owner_id=env.user_id, name="Keep this song")
        db.add(playlist)
        await db.flush()
        entry = PlaylistEntry(playlist_id=playlist.id, track_id=track.id, position=0)
        like = TrackLike(user_id=env.user_id, track_id=track.id)
        event = PlayEvent(user_id=env.user_id, track_id=track.id)
        db.add_all([entry, like, event, TrackLyrics(track_id=track.id, instrumental=True, source="lrclib")])
        await db.commit()
        entry_id, like_id, event_id = entry.id, like.id, event.id
    buffer = io.BytesIO()
    Image.new("RGB", (4, 4), (100, 30, 20)).save(buffer, format="JPEG")
    cover = buffer.getvalue() if cover_kind != "none" else None
    write_tags(env.original, meta, cover if cover_kind == "embedded" else None)
    if cover_kind in {"embedded", "folder"}:
        (env.original.parent / "cover.jpg").write_bytes(cover if cover_kind == "folder" else b"other art")
    sidecar = env.original.with_suffix(".LRC")
    sidecar.write_text("[00:01.00]Keep these lyrics")
    old_audio = env.original.read_bytes()
    await approve(client, env, result)
    assert await asyncio.wait_for(DownloadManager().process_one(), timeout=10)
    detail = (await client.get(f"/api/requests/{result['id']}", headers=env.user)).json()
    assert detail["status"] == "done", detail
    assert detail["items"][0]["track_id"] == str(env.track_id) and detail["items"][0]["progress"] == 1
    assert env.fake.excludes == [frozenset({"old_video01", "old_video02"})]
    target = env.original.with_suffix(".opus")
    assert target.is_file() and target.read_bytes() != old_audio
    assert embedded_cover(target) == cover
    if same_suffix:
        assert sidecar.read_text() == "[00:01.00]Keep these lyrics"
    else:
        assert not env.original.exists() and not sidecar.exists()
        assert target.with_suffix(".lrc").read_text() == "[00:01.00]Keep these lyrics"
    async with SessionLocal() as db:
        track = await db.get(Track, env.track_id)
        assert track.path == str(target.relative_to(MUSIC_DIR))
        assert track.codec == "opus" and track.duration > 0 and track.size == target.stat().st_size
        assert track.title == "Song" and track.artist_credit == "Artist feat. Guest" and track.is_temporary is True
        assert await db.scalar(select(func.count()).select_from(Track)) == 1
        assert (await db.get(TrackLike, like_id)).track_id == track.id
        assert (await db.get(PlaylistEntry, entry_id)).track_id == track.id
        assert (await db.get(PlayEvent, event_id)).track_id == track.id
        assert await db.get(TrackLyrics, track.id) is None


async def test_no_other_version_and_retry(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await history(env)
    result = await create(client, env)
    await approve(client, env, result)
    env.fake.no_match = True
    assert await DownloadManager().process_one()
    detail = (await client.get(f"/api/requests/{result['id']}", headers=env.user)).json()
    assert detail["status"] == "failed" and detail["items"][0]["error"] == "Keine andere Version gefunden"
    assert (await client.post(f"/api/requests/{result['id']}/retry", headers=env.user)).status_code == 200
    env.fake.no_match = False
    assert await DownloadManager().process_one()
    assert env.fake.excludes == [frozenset({"old_video01", "old_video02"})] * 2


@pytest.mark.parametrize("during_download", [False, True])
async def test_deleted_track(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, during_download: bool
) -> None:
    result = await create(client, env)
    await approve(client, env, result)

    async def delete_track() -> None:
        async with SessionLocal() as db:
            await db.delete(await db.get(Track, env.track_id))
            await db.commit()

    if during_download:
        original_download = env.fake.download

        async def download(*args: object) -> Path:
            path = await original_download(*args)
            await delete_track()
            return path

        monkeypatch.setattr(env.fake, "download", download)
    else:
        await delete_track()
    assert await DownloadManager().process_one()
    detail = (await client.get(f"/api/requests/{result['id']}", headers=env.user)).json()
    assert detail["status"] == "failed" and detail["items"][0]["error"] == "Song wurde gelöscht"
    assert detail["replace_track_id"] is None


async def test_forced_youtube_disabled(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    result = await create(client, env, youtube_url="https://youtu.be/old_video01")
    await approve(client, env, result)
    await client.patch("/api/admin/config", json={"downloads": {"youtube_enabled": False}}, headers=env.admin)
    assert await DownloadManager().process_one()
    detail = (await client.get(f"/api/requests/{result['id']}", headers=env.user)).json()
    assert detail["items"][0]["error"] == "Keine Download-Quelle aktiviert"
    assert env.fake.excludes == [] and env.fake.picks == []


async def test_automatic_retry(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    result = await create(client, env, youtube_url="https://youtu.be/old_video01")
    await approve(client, env, result)
    env.fake.fail_once = True
    worker = DownloadManager()
    assert await worker.process_one() and await worker.process_one()
    detail = (await client.get(f"/api/requests/{result['id']}", headers=env.user)).json()
    assert detail["status"] == "done" and env.fake.picks == ["old_video01", "old_video01"]


@pytest.mark.parametrize("available_filter", ["songs", "videos"])
async def test_source_excludes_both_passes(env: SimpleNamespace, available_filter: str) -> None:
    calls = []

    def search(query: str, *, filter: str, limit: int) -> list[dict]:
        calls.append(filter)
        result = {"title": "Song", "artists": [{"name": "Artist feat. Guest"}], "duration_seconds": 2}
        return [
            {**result, "videoId": "old_video01", "isExplicit": True},
            *([{**result, "videoId": "new_video01"}] if filter == available_filter else []),
        ]

    source = YouTubeMusicSource.__new__(YouTubeMusicSource)
    source._music = SimpleNamespace(search=search)
    async with SessionLocal() as db:
        track = await db.get(Track, env.track_id)
        user = await db.get(User, env.user_id)
        request = await downloads.create_redownload(db, user, track, None)
        meta = TrackMeta.model_validate(request.items[0].meta)
    candidate = await source.find(meta, frozenset({"old_video01"}))
    assert candidate is not None and candidate.ref == "new_video01"
    assert calls == (["songs"] if available_filter == "songs" else ["songs", "videos"])
    assert source.candidate("old_video01") == Candidate("youtube", "old_video01", "", "", None, 100.0)
