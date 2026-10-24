import asyncio
import hashlib
import io
import shutil
import subprocess
import time
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs

import httpx
import pytest
from PIL import Image
from sqlalchemy import select

from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import DownloadItem, DownloadRequest, Track
from app.services import downloads
from app.services.downloads import DownloadManager
from app.services.musicbrainz import TrackMeta
from app.services.server_config import DownloadConfig, ServerConfig
from app.services.tags import read_tags
from app.services.torrents import TorrentError, prowlarr
from app.services.torrents.qbittorrent import QBittorrent, info_hash
from app.services.torrents.select import choose, clean_album, search_query
from tests.conftest import MUSIC_DIR, auth, register
from tests.test_downloads import FakeSource


def result(**updates: object) -> dict:
    value = {
        "title": "Test Artist Test Album FLAC",
        "size": 10_000_000,
        "seeders": 5,
        "protocol": "torrent",
        "magnetUrl": "magnet:?xt=urn:btih:test",
        "downloadUrl": "http://prowlarr.test/download",
        "indexer": "Public",
        "guid": "test",
    }
    value.update(updates)
    return value


def test_choose_ranking() -> None:
    releases = [
        result(title=f"Test Artist Test Album {format}", seeders=seeders)
        for format, seeders in (("", 100), ("MP3", 100), ("V0", 100), ("320", 100), ("FLAC", 1))
    ]
    assert choose(releases, "Test Artist", "Test Album", 100, 1) is releases[-1]
    assert choose(releases[:-1], "Test Artist", "Test Album", 100, 1) is releases[-2]
    capped = [result(seeders=100, size=20_000_000), result(seeders=50)]
    assert choose(capped, "Test Artist", "Test Album", 100, 1) is capped[1]
    assert choose([result(seeders=0)], "Test Artist", "Test Album", 100, 1) is None
    assert choose([result(seeders=0)], "Test Artist", "Test Album", 100, 0) is not None
    assert choose([result(protocol="usenet")], "Test Artist", "Test Album", 100, 1) is None


@pytest.mark.parametrize("word", ["discography", "collection", "anthology", "box set", "boxset", "complete works"])
def test_choose_collection_rejection(word: str) -> None:
    release = result(title=f"Test Artist Test Album {word.upper()}")
    assert choose([release], "Test Artist", "Test Album", 100, 1) is None
    assert choose([release], "Test Artist", f"Test Album {word}", 100, 1) is release
    assert choose([result(title="Test Artist Test Album Collections")], "Test Artist", "Test Album", 100, 1)


@pytest.mark.parametrize(
    "size,valid", [(1_599_999, False), (1_600_000, True), (3 * 1024**3, True), (3 * 1024**3 + 1, False)]
)
def test_choose_size(size: int, valid: bool) -> None:
    assert (choose([result(size=size)], "Test Artist", "Test Album", 100, 1) is not None) == valid


def test_choose_fuzzy_title() -> None:
    release = result(title="TEST ARTIST Test Albumm FLAC")
    assert choose([release], "Test Artist", "Test Album", 100, 1) is release
    assert choose([result(title="Unrelated Singer Other Release")], "Test Artist", "Test Album", 100, 1) is None


class Gateway:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.results = [result()]
        self.progress = 0.0
        self.present = True
        self.state = "downloading"
        self.login_body = "Ok."
        self.status_code = 200
        self.add_code = 200
        self.info_code = 200
        self.delete_code = 200
        self.forbid_once = False
        self.forbid_always = False
        self.redirect_magnet = False
        self.file_entries: list[dict] = []
        self.requests: list[httpx.Request] = []
        self.added: list[bytes] = []
        self.deleted: list[dict] = []
        self.all_rows: list[dict] = []
        self.logins = 0
        self.tagged: list[dict] = []

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        if path == "/api/v1/search":
            assert request.headers["X-Api-Key"] == "key"
            assert dict(request.url.params) == {
                "query": "Test Artist Test Album",
                "categories": "3000",
                "type": "search",
            }
            assert request.extensions["timeout"]["read"] == 60
            return httpx.Response(self.status_code, json=self.results)
        if path == "/api/v1/system/status":
            assert request.headers["X-Api-Key"] == "key"
            return httpx.Response(self.status_code, json={"version": "2.0"})
        if path == "/download":
            return httpx.Response(302, headers={"Location": "/redirected"})
        if path == "/redirected":
            if self.redirect_magnet:
                return httpx.Response(302, headers={"Location": "magnet:?xt=urn:btih:redirect"})
            return httpx.Response(200, content=b"fake-torrent-bytes")
        if path == "/api/v2/auth/login":
            assert parse_qs(request.content.decode()) == {"username": ["admin"], "password": ["secret"]}
            self.logins += 1
            if self.login_body == "":
                return httpx.Response(204, headers={"Set-Cookie": "SID=session; Path=/"})
            if self.login_body == "401":
                return httpx.Response(401, text="Unauthorized")
            return httpx.Response(200, text=self.login_body, headers={"Set-Cookie": "SID=session; Path=/"})
        assert "SID=session" in request.headers.get("Cookie", "")
        if self.forbid_once or self.forbid_always:
            self.forbid_once = False
            return httpx.Response(403)
        if path == "/api/v2/torrents/add":
            assert request.method == "POST"
            assert request.headers["Content-Type"].startswith("multipart/form-data;")
            assert b"/data/downloads/torrents" in request.content
            assert b"resonance" in request.content
            self.added.append(request.content)
            return httpx.Response(self.add_code, text="Ok.")
        if path in {"/api/v2/torrents/setCategory", "/api/v2/torrents/addTags"}:
            self.tagged.append({"path": path, **parse_qs(request.content.decode())})
            return httpx.Response(200)
        if path == "/api/v2/torrents/info" and "hashes" in request.url.params:
            return httpx.Response(200, json=[{"hash": request.url.params["hashes"]}] if self.add_code == 409 else [])
        if path == "/api/v2/torrents/info":
            assert request.url.params["category"] == "resonance"
            if "tag" not in request.url.params:
                return httpx.Response(self.info_code, json=self.all_rows)
            return httpx.Response(
                self.info_code,
                json=[{"hash": "hash", "progress": self.progress, "save_path": str(self.root), "state": self.state}]
                if self.present
                else [],
            )
        if path == "/api/v2/torrents/files":
            assert request.url.params["hash"] == "hash"
            return httpx.Response(200, json=self.file_entries)
        if path == "/api/v2/torrents/delete":
            assert request.method == "POST"
            self.deleted.append(parse_qs(request.content.decode()))
            return httpx.Response(self.delete_code)
        if path == "/api/v2/app/version":
            return httpx.Response(200, text="v5.0")
        raise AssertionError(str(request.url))


@pytest.fixture
def gateway(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Gateway:
    gateway = Gateway(tmp_path / "torrent")
    original_client = httpx.AsyncClient

    def client(**kwargs: object) -> httpx.AsyncClient:
        kwargs.setdefault("transport", httpx.MockTransport(gateway.handle))
        return original_client(**kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", client)
    monkeypatch.setattr(get_settings(), "prowlarr_url", "http://prowlarr.test")
    monkeypatch.setattr(get_settings(), "qbittorrent_url", "http://qbittorrent.test")
    return gateway


def config() -> ServerConfig:
    return ServerConfig(
        downloads=DownloadConfig(torrent_enabled=True, prowlarr_api_key="key", qbittorrent_password="secret")
    )


@pytest.fixture
async def env(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, gateway: Gateway
) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")

    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)
        shutil.rmtree(MUSIC_DIR, ignore_errors=True)

    await reset()
    metas = [
        TrackMeta(
            title=title,
            artist="Test Artist",
            artist_mbid=None,
            album="Test Album",
            album_artist="Test Artist",
            album_artist_mbid=None,
            track_no=index,
            track_total=3,
            disc_no=1,
            disc_total=1,
            year=2020,
            date="2020",
            duration=2,
            isrc=None,
            genre=None,
            label=None,
            mb_recording_id=None,
            mb_release_id=None,
            mb_release_group_id=None,
            deezer_track_id=str(300 + index),
            deezer_album_id="201",
        )
        for index, title in enumerate(("First Song", "Second Song", "Third Song"), 1)
    ]

    async def album(id: str) -> tuple[dict, list[TrackMeta]]:
        return {"title": "Test Album", "artist": {"name": "Test Artist"}}, metas

    async def track(id: str) -> TrackMeta:
        return metas[0]

    async def deezer_track(id: str) -> dict:
        return {"title": "First Song", "artist": {"name": "Test Artist"}, "album": {"id": 201}}

    async def deezer_album(id: str) -> dict:
        return {"title": "Test Album", "artist": {"name": "Test Artist"}}

    buffer = io.BytesIO()
    Image.new("RGB", (4, 4), (100, 30, 20)).save(buffer, format="JPEG")
    cover = buffer.getvalue()

    async def fetch(meta: TrackMeta) -> bytes:
        return cover

    monkeypatch.setattr(downloads, "resolve_album", album)
    monkeypatch.setattr(downloads, "resolve_track", track)
    monkeypatch.setattr(downloads.deezer, "track", deezer_track)
    monkeypatch.setattr(downloads.deezer, "album", deezer_album)
    monkeypatch.setattr(downloads, "fetch_cover", fetch)
    fake = FakeSource()
    monkeypatch.setattr(
        downloads.sources, "enabled_sources", lambda cfg: [fake] if cfg.downloads.youtube_enabled else []
    )
    admin = auth((await register(client, "torrent-admin"))["token"])
    response = await client.patch(
        "/api/admin/config",
        json={"registration": {"mode": "public"}, "downloads": config().downloads.model_dump()},
        headers=admin,
    )
    assert response.status_code == 200
    user = auth((await register(client, "torrent-user"))["token"])
    yield SimpleNamespace(admin=admin, user=user, manager=DownloadManager(), metas=metas, fake=fake, gateway=gateway)
    await reset()


async def request_album(client: httpx.AsyncClient, env: SimpleNamespace, kind: str = "album") -> dict:
    response = await client.post(
        "/api/requests",
        json={"kind": kind, "id": "201" if kind == "album" else "301", "temporary": True},
        headers=env.admin,
    )
    assert response.status_code == 201, response.text
    return response.json()


async def detail(client: httpx.AsyncClient, env: SimpleNamespace, request: dict) -> dict:
    response = await client.get(f"/api/requests/{request['id']}", headers=env.admin)
    assert response.status_code == 200, response.text
    return response.json()


@pytest.mark.parametrize("source", ["magnet", "bytes", "redirect"])
async def test_album_torrent_pipeline(client: httpx.AsyncClient, env: SimpleNamespace, source: str) -> None:
    gateway = env.gateway
    if source != "magnet":
        gateway.results[0]["magnetUrl"] = None
    gateway.redirect_magnet = source == "redirect"
    request = await request_album(client, env)
    assert request["torrent_status"] is None and request["torrent_progress"] == 0
    assert await env.manager.process_one()
    started = await detail(client, env, request)
    assert started["torrent_status"] == "downloading" and started["torrent_name"] == gateway.results[0]["title"]
    assert [item["status"] for item in started["items"]] == ["downloading"] * 3
    assert [item["source"] for item in started["items"]] == ["torrent"] * 3
    assert len(gateway.added) == 1 and request["id"].encode() in gateway.added[0]
    if source == "bytes":
        assert b'filename="file.torrent"' in gateway.added[0] and b"fake-torrent-bytes" in gateway.added[0]
    else:
        assert (
            b'name="urls"' in gateway.added[0]
            and (b"magnet:?xt=urn:btih:redirect" if source == "redirect" else b"magnet:?xt=urn:btih:test")
            in gateway.added[0]
        )
    request_id = uuid.UUID(request["id"])
    async with SessionLocal() as db:
        initial_time = (await db.get(DownloadRequest, request_id)).torrent_progress_at
    gateway.progress = 0.5
    await env.manager._torrent_poll(request_id)
    progress = await detail(client, env, request)
    assert progress["torrent_progress"] == 0.5
    assert [item["progress"] for item in progress["items"]] == [0.5] * 3
    async with SessionLocal() as db:
        increased_time = (await db.get(DownloadRequest, request_id)).torrent_progress_at
        assert increased_time > initial_time
    await env.manager._torrent_poll(request_id)
    async with SessionLocal() as db:
        assert (await db.get(DownloadRequest, request_id)).torrent_progress_at == increased_time
    originals = {}
    for name, title, duration in (
        ("album/first.flac", "First Song", 5),
        ("album/duplicate.mp3", "First Song", 2),
        ("album/second.flac", "Second Song", 2),
        ("album/wrong.flac", "Third Song", 10),
    ):
        path = gateway.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        await asyncio.to_thread(
            subprocess.run,
            [
                "ffmpeg",
                "-nostdin",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"sine=frequency=440:duration={duration}",
                "-metadata",
                f"title={title}",
                "-metadata",
                "artist=Original Artist",
                "-metadata",
                "album=Original Album",
                "-metadata",
                f"musicbrainz_trackid={uuid.uuid4()}",
                str(path),
            ],
            check=True,
        )
        originals[path] = (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ino)
        gateway.file_entries.append({"name": name, "size": path.stat().st_size, "progress": 1})
    gateway.file_entries.append({"name": "album/readme.txt", "size": 10, "progress": 1})
    gateway.progress = 1
    await env.manager._torrent_poll(request_id)
    finished = await detail(client, env, request)
    assert finished["torrent_status"] == "done" and finished["status"] == "active"
    assert [item["status"] for item in finished["items"]] == ["done", "done", "queued"]
    assert [item["source"] for item in finished["items"]] == ["torrent", "torrent", None]
    assert [item["progress"] for item in finished["items"]] == [1, 1, 0]
    async with SessionLocal() as db:
        tracks = list(await db.scalars(select(Track).order_by(Track.track_no)))
        assert len(tracks) == 2 and all(track.path.endswith(".flac") for track in tracks)
        assert all(track.is_temporary for track in tracks)
        assert abs(tracks[0].duration - 5) < 0.1
        for track in tracks:
            target = MUSIC_DIR / track.path
            tags = read_tags(target)
            assert tags.artist == "Test Artist" and tags.album == "Test Album" and tags.mb_recording_id is None
            assert target.stat().st_ino not in {values[2] for values in originals.values()}
            assert target.with_name("cover.jpg").is_file()
    for path, (data, mtime, inode) in originals.items():
        assert path.read_bytes() == data and path.stat().st_mtime_ns == mtime and path.stat().st_ino == inode
    assert not gateway.deleted
    assert await env.manager.process_one()
    final = await detail(client, env, request)
    assert final["status"] == "done" and final["items"][-1]["source"] == "youtube"
    assert len([r for r in gateway.requests if r.url.path == "/api/v1/search"]) == 1


@pytest.mark.parametrize("reason", ["empty", "search_error", "add_error", "missing", "stalled", "info_error"])
async def test_torrent_fallback(client: httpx.AsyncClient, env: SimpleNamespace, reason: str) -> None:
    gateway = env.gateway
    if reason == "empty":
        gateway.results = []
    elif reason == "search_error":
        gateway.status_code = 503
    elif reason == "add_error":
        gateway.add_code = 500
    request = await request_album(client, env)
    request_id = uuid.UUID(request["id"])
    assert await env.manager.process_one()
    if reason in {"missing", "stalled", "info_error"}:
        if reason == "missing":
            gateway.present = False
        elif reason == "info_error":
            gateway.info_code = 503
            # A brief outage (VPN reconnect, redeploy) keeps the torrent; only the stall timeout gives up.
            await env.manager._torrent_poll(request_id)
            assert (await detail(client, env, request))["torrent_status"] == "downloading"
        if reason in {"stalled", "info_error"}:
            async with SessionLocal() as db:
                row = await db.get(DownloadRequest, request_id)
                row.torrent_progress_at = datetime.now(UTC) - timedelta(minutes=61)
                await db.commit()
        await env.manager._torrent_poll(request_id)
    failed = await detail(client, env, request)
    assert failed["torrent_status"] == "failed" and failed["torrent_error"]
    assert [item["status"] for item in failed["items"]] == ["queued"] * 3
    assert all(item["source"] is None and item["progress"] == 0 for item in failed["items"])
    if reason == "stalled":
        assert failed["torrent_error"] == "Torrent ohne Fortschritt"
        assert gateway.deleted == [{"hashes": ["hash"], "deleteFiles": ["true"]}]
    elif reason == "missing":
        assert failed["torrent_error"] == "Torrent verschwunden"
    searches = len([r for r in gateway.requests if r.url.path == "/api/v1/search"])
    for _ in range(3):
        assert await env.manager.process_one()
    assert (await detail(client, env, request))["status"] == "done"
    assert len([r for r in gateway.requests if r.url.path == "/api/v1/search"]) == searches


@pytest.mark.parametrize("delete_error", [False, True])
async def test_cancel_deletes_torrent(client: httpx.AsyncClient, env: SimpleNamespace, delete_error: bool) -> None:
    request = await request_album(client, env)
    assert await env.manager.process_one()
    if delete_error:
        env.gateway.delete_code = 500
    cancelled = await client.post(f"/api/requests/{request['id']}/cancel", headers=env.admin)
    assert cancelled.status_code == 200
    row = cancelled.json()
    assert row["torrent_status"] == "failed" and row["torrent_error"] == "Abgebrochen"
    assert row["status"] == "cancelled" and all(item["status"] == "cancelled" for item in row["items"])
    assert not await env.manager.process_one()
    assert env.gateway.deleted == [{"hashes": ["hash"], "deleteFiles": ["true"]}]


@pytest.mark.parametrize("torrent_status", [None, "searching", "downloading", "importing", "failed", "done"])
async def test_startup_recovery(client: httpx.AsyncClient, env: SimpleNamespace, torrent_status: str | None) -> None:
    request = await request_album(client, env)
    async with SessionLocal() as db:
        row = await db.get(DownloadRequest, uuid.UUID(request["id"]))
        row.torrent_status = torrent_status
        items = list(
            await db.scalars(
                select(DownloadItem).where(DownloadItem.request_id == row.id).order_by(DownloadItem.position)
            )
        )
        for item, status in zip(items, ["searching", "downloading", "processing"], strict=True):
            item.status = status
        await db.commit()
    await env.manager.start()
    assert len(env.manager._workers) == 1
    await env.manager.stop()
    recovered = await detail(client, env, request)
    assert recovered["torrent_status"] == (None if torrent_status in {"searching", "importing"} else torrent_status)
    assert [item["status"] for item in recovered["items"]] == (
        ["searching", "downloading", "processing"] if torrent_status == "downloading" else ["queued"] * 3
    )
    assert not env.gateway.requests


async def test_torrent_without_link_tries_the_next_one(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    broken = result(title="Test Artist Test Album FLAC", seeders=50, magnetUrl=None, downloadUrl=None, guid="x")
    env.gateway.results = [broken, result(title="Test Artist Test Album 320")]
    request = await request_album(client, env)
    assert await env.manager.process_one()
    started = await detail(client, env, request)
    assert started["torrent_status"] == "downloading"
    assert started["torrent_name"] == "Test Artist Test Album 320"


async def test_track_never_uses_torrents(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await request_album(client, env, "track")
    assert await env.manager.process_one()
    row = await detail(client, env, request)
    assert row["status"] == "done" and row["torrent_status"] is None and row["items"][0]["source"] == "youtube"
    assert not env.gateway.requests


async def test_disabled_torrents(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await client.patch("/api/admin/config", json={"downloads": {"torrent_enabled": False}}, headers=env.admin)
    request = await request_album(client, env)
    assert await env.manager.process_one()
    assert (await detail(client, env, request))["torrent_status"] is None
    assert not env.gateway.requests


async def test_retry_stays_on_youtube(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    env.gateway.results = []
    request = await request_album(client, env)
    assert await env.manager.process_one()
    await client.patch("/api/admin/config", json={"downloads": {"youtube_enabled": False}}, headers=env.admin)
    for _ in range(3):
        assert await env.manager.process_one()
    assert (await detail(client, env, request))["status"] == "failed"
    await client.patch("/api/admin/config", json={"downloads": {"youtube_enabled": True}}, headers=env.admin)
    response = await client.post(f"/api/requests/{request['id']}/retry", headers=env.admin)
    assert response.status_code == 200 and response.json()["torrent_status"] == "failed"
    for _ in range(3):
        assert await env.manager.process_one()
    assert (await detail(client, env, request))["status"] == "done"
    assert len([r for r in env.gateway.requests if r.url.path == "/api/v1/search"]) == 1


async def test_retry_after_torrent_outage_searches_again(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await request_album(client, env)
    assert await env.manager.process_one()
    env.gateway.present = False
    await env.manager._torrent_poll(uuid.UUID(request["id"]))
    await client.patch("/api/admin/config", json={"downloads": {"youtube_enabled": False}}, headers=env.admin)
    for _ in range(3):
        assert await env.manager.process_one()
    assert (await detail(client, env, request))["status"] == "failed"
    env.gateway.present = True
    response = await client.post(f"/api/requests/{request['id']}/retry", headers=env.admin)
    assert response.status_code == 200 and response.json()["torrent_status"] is None
    assert await env.manager.process_one()
    retried = await detail(client, env, request)
    assert retried["torrent_status"] == "downloading" and retried["torrent_error"] is None
    assert len([r for r in env.gateway.requests if r.url.path == "/api/v1/search"]) == 2


async def test_monitor_loop(client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    request = await request_album(client, env)
    assert await env.manager.process_one()
    env.gateway.progress = 0.25
    sleeps = 0

    async def sleep(delay: float) -> None:
        nonlocal sleeps
        assert delay == 10
        sleeps += 1
        if sleeps == 2:
            raise asyncio.CancelledError()

    with monkeypatch.context() as patch:
        patch.setattr(downloads.asyncio, "sleep", sleep)
        with pytest.raises(asyncio.CancelledError):
            await env.manager._torrent_monitor()
    row = await detail(client, env, request)
    assert row["torrent_progress"] == 0.25 and all(item["progress"] == 0.25 for item in row["items"])


async def test_queued_torrent_is_not_stalled(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await request_album(client, env)
    assert await env.manager.process_one()
    request_id = uuid.UUID(request["id"])
    async with SessionLocal() as db:
        row = await db.get(DownloadRequest, request_id)
        row.torrent_progress_at = datetime.now(UTC) - timedelta(minutes=61)
        await db.commit()
    env.gateway.state = "queuedDL"
    await env.manager._torrent_poll(request_id)
    assert (await detail(client, env, request))["torrent_status"] == "downloading"
    async with SessionLocal() as db:
        row = await db.get(DownloadRequest, request_id)
        assert datetime.now(UTC) - row.torrent_progress_at < timedelta(minutes=1)
    assert not env.gateway.deleted


async def test_existing_torrent_is_adopted(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    digest = "ab" * 20
    env.gateway.results[0]["magnetUrl"] = f"magnet:?xt=urn:btih:{digest}&dn=x"
    env.gateway.add_code = 409
    request = await request_album(client, env)
    assert await env.manager.process_one()
    assert (await detail(client, env, request))["torrent_status"] == "downloading"
    assert env.gateway.tagged == [
        {"path": "/api/v2/torrents/setCategory", "hashes": [digest], "category": ["resonance"]},
        {"path": "/api/v2/torrents/addTags", "hashes": [digest], "tags": [request["id"]]},
    ]


def test_info_hash() -> None:
    assert info_hash("magnet:?xt=urn:btih:" + "AB" * 20) == "ab" * 20
    assert info_hash("magnet:?dn=x&xt=urn:btih:" + "A" * 32) == "00" * 20
    info = b"d6:lengthi5e4:name1:x12:piece lengthi16384e6:pieces20:" + b"p" * 20 + b"e"
    torrent = b"d8:announce3:url4:info" + info + b"e"
    assert info_hash(torrent) == hashlib.sha1(info).hexdigest()
    assert info_hash(b"not bencode") is None and info_hash("https://x/y.torrent") is None


async def test_torrent_cleanup(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    busy = await request_album(client, env)
    assert await env.manager.process_one()
    now = time.time()

    def row(hash: str, tag: str, days: float, state: str = "uploading", progress: float = 1) -> dict:
        return {"hash": hash, "tags": tag, "progress": progress, "completion_on": now - days * 86400, "state": state}

    env.gateway.all_rows = [
        row("old", "a", 8),
        row("fresh", "b", 1),
        row("stopped", "c", 1, "stoppedUP"),
        row("busy", busy["id"], 30),
        row("incomplete", "d", 30, "downloading", 0.5),
        {"hash": "never", "tags": "e", "progress": 1, "completion_on": -1, "state": "uploading"},
        {"hash": "orphan", "tags": "f", "progress": 0, "completion_on": -1, "added_on": now - 7200, "state": "metaDL"},
        {"hash": "new", "tags": "g", "progress": 0, "completion_on": -1, "added_on": now - 60, "state": "metaDL"},
        {"hash": "busy-dl", "tags": busy["id"], "progress": 0, "completion_on": -1, "added_on": now - 3600},
    ]
    assert await env.manager.torrent_cleanup() == 3
    assert env.gateway.deleted == [
        {"hashes": ["old"], "deleteFiles": ["true"]},
        {"hashes": ["stopped"], "deleteFiles": ["true"]},
        {"hashes": ["orphan"], "deleteFiles": ["true"]},
    ]
    response = await client.patch("/api/admin/config", json={"downloads": {"torrent_seed_days": 0}}, headers=env.admin)
    assert response.status_code == 200
    env.gateway.deleted.clear()
    env.gateway.all_rows = env.gateway.all_rows[:6]
    assert await env.manager.torrent_cleanup() == 3
    assert [d["hashes"] for d in env.gateway.deleted] == [["old"], ["fresh"], ["stopped"]]
    response = await client.patch("/api/admin/config", json={"downloads": {"torrent_enabled": False}}, headers=env.admin)
    assert response.status_code == 200
    assert await env.manager.torrent_cleanup() == 0


async def test_concurrent_claim_runs_one_search(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await request_album(client, env)
    await asyncio.wait_for(asyncio.gather(env.manager.process_one(), env.manager.process_one()), timeout=5)
    assert (await detail(client, env, request))["torrent_status"] == "downloading"
    assert len(env.gateway.added) == 1
    assert len([r for r in env.gateway.requests if r.url.path == "/api/v1/search"]) == 1


async def test_status_endpoint(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    response = await client.get("/api/admin/torrents/status", headers=env.admin)
    assert response.status_code == 200
    assert response.json() == {
        "prowlarr": {"ok": True, "message": "Version 2.0"},
        "qbittorrent": {"ok": True, "message": "Version v5.0"},
    }
    assert (await client.get("/api/admin/torrents/status", headers=env.user)).status_code == 403
    assert (await client.get("/api/admin/torrents/status")).status_code == 401
    env.gateway.status_code = 503
    env.gateway.login_body = "Fails."
    response = await client.get("/api/admin/torrents/status", headers=env.admin)
    assert response.json() == {
        "prowlarr": {"ok": False, "message": "Prowlarr-Anfrage fehlgeschlagen (HTTP 503)"},
        "qbittorrent": {"ok": False, "message": "qBittorrent-Anmeldung fehlgeschlagen"},
    }


async def test_qbittorrent_relogin_once(gateway: Gateway) -> None:
    gateway.forbid_once = True
    async with QBittorrent(config()) as qb:
        assert await qb.version() == "v5.0"
        assert gateway.logins == 2
        assert await qb.version() == "v5.0"
        assert gateway.logins == 2
        gateway.forbid_always = True
        with pytest.raises(TorrentError, match="HTTP 403"):
            await qb.version()
        assert gateway.logins == 3


async def test_prowlarr_transport_error(monkeypatch: pytest.MonkeyPatch, gateway: Gateway) -> None:
    def fail(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("offline", request=request)

    original_client = httpx.AsyncClient

    def client(**kwargs: object) -> httpx.AsyncClient:
        kwargs["transport"] = httpx.MockTransport(fail)
        return original_client(**kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", client)
    with pytest.raises(TorrentError, match="Prowlarr nicht erreichbar"):
        await prowlarr.search(config(), "Test Artist Test Album")


@pytest.mark.parametrize(("body", "ok"), [("", True), ("Ok.", True), ("Fails.", False), ("401", False)])
async def test_qbittorrent_login_variants(gateway: Gateway, body: str, ok: bool) -> None:
    # qBittorrent >= 5.1 answers a successful login with 204 and no body.
    gateway.login_body = body
    async with QBittorrent(config()) as qb:
        if ok:
            assert await qb.version() == "v5.0"
        else:
            with pytest.raises(TorrentError, match="Anmeldung fehlgeschlagen"):
                await qb.version()


def test_clean_album_and_query() -> None:
    assert clean_album("Radio-Aktivität (2009 Remaster, German Version)") == "Radio-Aktivität"
    assert clean_album("Abbey Road [Super Deluxe]") == "Abbey Road"
    assert clean_album("Rumours - 2004 Remaster") == "Rumours"
    assert clean_album("Live - Bootleg") == "Live - Bootleg"
    assert clean_album("(What's the Story) Morning Glory?") == "Morning Glory?"
    assert clean_album("(Untitled)") == "(Untitled)"
    assert search_query("Kraftwerk", "Radio-Aktivität (2009 Remaster)") == "Kraftwerk Radio-Aktivität"
    assert search_query("Various Artists", "Trainspotting (Music From the Motion Picture)") == "Trainspotting"


def test_choose_edition_and_html_entities() -> None:
    found = result(title="Kraftwerk - Radio-Aktivit&auml;t / Radio-Activity 1975 / 2004", size=91_000_000, seeders=1)
    chosen = choose([found], "Kraftwerk", "Radio-Aktivität (2009 Remaster, German Version)", 2300, 1)
    assert chosen is not None
    assert chosen["title"] == "Kraftwerk - Radio-Aktivität / Radio-Activity 1975 / 2004"
    compilation = result(title="Trainspotting Soundtrack FLAC", size=300_000_000)
    assert choose([compilation], "Various Artists", "Trainspotting (Music From the Motion Picture)", 3600, 1)


async def test_obtain_source_prowlarr_link_variants() -> None:
    from app.services.torrents import obtain_source

    magnet = "magnet:?xt=urn:btih:ABC"
    # Some indexers only put the magnet link into guid (magnetUrl is Prowlarr's http proxy link).
    assert await obtain_source({"guid": magnet, "magnetUrl": "http://prowlarr/5/download"}) == magnet
    # No usable link at all: build the magnet link from the info hash.
    assert await obtain_source({"infoHash": "ABC", "title": "Pride and Prejudice"}) == (
        "magnet:?xt=urn:btih:ABC&dn=Pride%20and%20Prejudice"
    )
    with pytest.raises(TorrentError):
        await obtain_source({"title": "x"})
