import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from app.db import SessionLocal, engine
from app.models import (
    Album,
    Artist,
    DownloadItem,
    DownloadRequest,
    Playlist,
    PlaylistEntry,
    QualityUpgradeAttempt,
    Track,
    TrackLike,
    User,
)
from app.services import downloads, upgrades
from app.services.deezer import DeezerError, NotFound
from app.services.musicbrainz import TrackMeta
from app.services.scanner import import_file
from app.services.tagger import write_tags
from sqlalchemy import func, select
from sqlalchemy.orm import selectinload

from tests import test_torrents
from tests.conftest import MUSIC_DIR, make_track

torrent_env = test_torrents.env
gateway = test_torrents.gateway


@pytest.mark.parametrize(
    "codec,bitrate,temporary,expected",
    [
        *[
            (codec, bitrate, False, False)
            for codec in ("flac", "alac", "wav", "aiff", "ape", "wavpack")
            for bitrate in (None, 128)
        ],
        *[
            (codec, bitrate, False, expected)
            for codec in ("mp3", "aac", "vorbis", "wma", "unknown", None)
            for bitrate, expected in ((None, True), (255, True), (256, False), (320, False))
        ],
        ("opus", None, False, True),
        ("opus", 320, False, True),
        ("OPUS", 256, False, True),
        ("MP3", 128, False, True),
        ("opus", 128, True, False),
        ("mp3", None, True, False),
    ],
)
def test_needs_upgrade(codec: str | None, bitrate: int | None, temporary: bool, expected: bool) -> None:
    assert upgrades.needs_upgrade(Track(codec=codec, bitrate=bitrate, is_temporary=temporary)) is expected


@pytest.fixture
async def upgrade_env(torrent_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")
    env = torrent_env
    env.searches = []
    env.resolved = []
    env.results = [{"id": 201, "title": "Test Album", "artist": {"name": "Test Artist"}}]
    resolve = downloads.resolve_album

    async def search(query: str, limit: int) -> list[dict]:
        env.searches.append((query, limit))
        return env.results

    async def album(id: str) -> tuple[dict, list[TrackMeta]]:
        env.resolved.append(id)
        catalog, metas = await resolve(id)
        return {**catalog, "cover_medium": "https://cover.test/album.jpg"}, metas

    def no_youtube(cfg: object) -> list:
        raise AssertionError("Quality upgrades must never use YouTube")

    monkeypatch.setattr(upgrades.deezer, "search_albums", search)
    monkeypatch.setattr(upgrades, "resolve_album", album)
    monkeypatch.setattr(downloads.sources, "enabled_sources", no_youtube)
    async with SessionLocal() as db:
        from app.services.server_config import update_config

        await update_config(db, {"downloads": {"quality_upgrade_enabled": True}})
    yield env


async def library(env: SimpleNamespace) -> tuple[uuid.UUID, list[uuid.UUID], list[Path]]:
    ids = []
    paths = []
    for index, meta in enumerate(env.metas):
        path = make_track(f"Test Artist/Test Album/{index + 1:02d}.opus")
        write_tags(path, meta, None)
        async with SessionLocal() as db:
            track = await import_file(db, str(path.relative_to(MUSIC_DIR)))
            ids.append(track.id)
            album_id = track.album_id
        paths.append(path)
    return album_id, ids, paths


async def create_upgrade(album_id: uuid.UUID) -> DownloadRequest | None:
    async with SessionLocal() as db:
        await upgrades.request_upgrade(db, await db.get(Album, album_id))
        return await db.scalar(
            select(DownloadRequest)
            .options(selectinload(DownloadRequest.items))
            .where(DownloadRequest.kind == "upgrade")
        )


async def attempt_result(album_id: uuid.UUID) -> str:
    async with SessionLocal() as db:
        return (await db.get(QualityUpgradeAttempt, album_id)).result


async def test_candidate_selection(upgrade_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    now = datetime.now(UTC)
    expected = []
    async with SessionLocal() as db:
        artist = Artist(name="Candidates", name_key="candidates")
        db.add(artist)
        await db.flush()
        for index, (codec, temporary, days) in enumerate(
            [
                ("opus", True, None),
                ("flac", False, None),
                ("mp3", False, 29),
                ("opus", False, 31),
                ("mp3", False, None),
                ("opus", False, None),
                ("aac", False, None),
            ]
        ):
            album = Album(
                title=str(index), title_key=str(index), artist_id=artist.id, created_at=now - timedelta(days=10 - index)
            )
            db.add(album)
            await db.flush()
            db.add(
                Track(
                    path=str(index),
                    title="Song",
                    album_id=album.id,
                    artist_id=artist.id,
                    artist_credit=artist.name,
                    codec=codec,
                    bitrate=128,
                    is_temporary=temporary,
                )
            )
            if days is not None:
                db.add(
                    QualityUpgradeAttempt(album_id=album.id, tried_at=now - timedelta(days=days), result="no_torrent")
                )
            if index in {3, 4, 5}:
                expected.append(album.id)
        await db.commit()
    calls = []

    async def request(db: object, album: Album) -> None:
        calls.append(album.id)

    monkeypatch.setattr(upgrades, "request_upgrade", request)
    await upgrades.run_once()
    assert calls == expected


@pytest.mark.parametrize(
    "quality_enabled,torrent_enabled,active", [(False, True, False), (True, False, False), (True, True, True)]
)
async def test_skip_run(
    client: httpx.AsyncClient,
    upgrade_env: SimpleNamespace,
    monkeypatch: pytest.MonkeyPatch,
    quality_enabled: bool,
    torrent_enabled: bool,
    active: bool,
) -> None:
    await library(upgrade_env)
    await client.patch(
        "/api/admin/config",
        headers=upgrade_env.admin,
        json={"downloads": {"quality_upgrade_enabled": quality_enabled, "torrent_enabled": torrent_enabled}},
    )
    if active:
        async with SessionLocal() as db:
            admin = await db.scalar(select(User).where(User.username == "torrent-admin"))
            db.add(DownloadRequest(user=admin, kind="upgrade", title="Other", artist="Other", status="active"))
            await db.commit()

    async def forbidden(*args: object) -> None:
        raise AssertionError("Scheduler must skip this run")

    monkeypatch.setattr(upgrades, "request_upgrade", forbidden)
    await upgrades.run_once()
    assert not upgrade_env.searches


@pytest.mark.parametrize("from_item", [False, True])
async def test_request_creation(upgrade_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, from_item: bool) -> None:
    env = upgrade_env
    album_id, ids, _ = await library(env)
    env.results = [
        {"id": 100, "title": "Other", "artist": {"name": "Test Artist"}},
        {"id": 101, "title": "Test Album", "artist": {"name": "Other"}},
        {"id": 201, "title": " TEST  ALBUM ", "artist": {"name": " TEST  ARTIST "}},
        {"id": 202, "title": "Test Album", "artist": {"name": "Test Artist"}},
    ]
    async with SessionLocal() as db:
        admin = await db.scalar(select(User).where(User.username == "torrent-admin"))
        # The second admin must not own the upgrade.
        other = await db.scalar(select(User).where(User.username == "torrent-user"))
        other.role = admin.role
        other.created_at = admin.created_at + timedelta(seconds=1)
        if from_item:
            db.add(
                DownloadRequest(
                    user=admin,
                    kind="track",
                    title="Old",
                    artist="Test Artist",
                    status="done",
                    items=[
                        DownloadItem(
                            position=0,
                            title="Old",
                            artist="Test Artist",
                            meta={"deezer_album_id": "999"},
                            status="failed",
                            track_id=ids[0],
                        ),
                        DownloadItem(
                            position=1,
                            title="Old",
                            artist="Test Artist",
                            meta={"deezer_album_id": "201"},
                            status="done",
                            track_id=ids[0],
                        ),
                    ],
                )
            )
        # High-quality and temporary library tracks must not become upgrade items.
        (await db.get(Track, ids[1])).codec = "flac"
        (await db.get(Track, ids[2])).is_temporary = True
        await db.commit()
        admin_id = admin.id
    env.metas[0].title = "First Song Remastered"
    wakes = []
    monkeypatch.setattr(upgrades.manager, "wake", lambda: wakes.append(True))
    request = await create_upgrade(album_id)
    assert request.kind == "upgrade" and request.catalog_id == "201" and request.user_id == admin_id
    assert request.title == "Test Album" and request.artist == "Test Artist"
    assert request.status == "active" and request.is_temporary is False
    assert request.cover_url == "https://cover.test/album.jpg"
    assert len(request.items) == 1
    item = request.items[0]
    assert item.status == "queued" and item.replace_track_id == ids[0] and item.track_id is None
    assert item.position == 0 and item.meta == env.metas[0].model_dump()
    assert (item.title, item.artist, item.duration) == (env.metas[0].title, "Test Artist", 2)
    assert await attempt_result(album_id) == "requested" and wakes == [True]
    assert env.resolved == ["201"]
    assert env.searches == ([] if from_item else [("Test Artist Test Album", 10)])


@pytest.mark.parametrize("reason", ["no_album", "wrong_title", "duration", "missing_duration", "not_found"])
async def test_no_catalog(upgrade_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, reason: str) -> None:
    env = upgrade_env
    album_id, _, _ = await library(env)
    if reason == "no_album":
        env.results = []
    elif reason == "not_found":

        async def missing(id: str) -> None:
            raise NotFound("Nicht gefunden")

        monkeypatch.setattr(upgrades, "resolve_album", missing)
    else:
        for meta in env.metas:
            if reason == "wrong_title":
                meta.title = "Unrelated"
            else:
                meta.duration = None if reason == "missing_duration" else 8
    assert await create_upgrade(album_id) is None
    assert await attempt_result(album_id) == "no_catalog"


async def test_search_failure_recorded(upgrade_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    album_id, _, _ = await library(upgrade_env)

    async def fail(*args: object) -> None:
        raise DeezerError("Katalog nicht erreichbar")

    monkeypatch.setattr(upgrades.deezer, "search_albums", fail)
    await upgrades.run_once()
    assert await attempt_result(album_id) == "failed"


@pytest.mark.parametrize("file_quality", ["better", "equal", "worse"])
async def test_torrent_import(upgrade_env: SimpleNamespace, file_quality: str) -> None:
    env = upgrade_env
    album_id, ids, paths = await library(env)
    old_bytes = [path.read_bytes() for path in paths]
    async with SessionLocal() as db:
        user = await db.scalar(select(User).where(User.username == "torrent-user"))
        like = TrackLike(user_id=user.id, track_id=ids[0])
        playlist = Playlist(owner_id=user.id, name="Keep")
        db.add_all([like, playlist])
        await db.flush()
        entry = PlaylistEntry(playlist_id=playlist.id, track_id=ids[0], position=0)
        db.add(entry)
        await db.commit()
        like_id, entry_id = like.id, entry.id
    request = await create_upgrade(album_id)
    assert await env.manager.process_one()
    assert len(env.gateway.added) == 1
    original_files = {}
    for index in range(2):
        ext = ".flac" if file_quality == "better" else ".opus" if file_quality == "equal" else ".mp3"
        path = env.gateway.root / f"{index}{ext}"
        path.parent.mkdir(parents=True, exist_ok=True)
        if file_quality == "equal":
            path.write_bytes(paths[index].read_bytes())
        else:
            generated = make_track(f"torrent-source-{index}{ext}")
            write_tags(generated, env.metas[index], None)
            generated.replace(path)
        original_files[path] = (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ino)
        env.gateway.file_entries.append({"name": path.name, "size": path.stat().st_size, "progress": 1})
    env.gateway.progress = 1
    await env.manager._torrent_poll(request.id)
    async with SessionLocal() as db:
        finished = await db.scalar(
            select(DownloadRequest).options(selectinload(DownloadRequest.items)).where(DownloadRequest.id == request.id)
        )
        assert finished.torrent_status == "done" and finished.status == "partial"
        assert [item.status for item in finished.items] == (
            ["done", "done", "failed"] if file_quality == "better" else ["exists", "exists", "failed"]
        )
        assert finished.items[-1].error == "Nicht im Torrent enthalten"
        assert all(item.error is None and item.track_id == ids[index] for index, item in enumerate(finished.items[:2]))
        assert (await db.get(TrackLike, like_id)).track_id == ids[0]
        assert (await db.get(PlaylistEntry, entry_id)).track_id == ids[0]
        assert await db.scalar(select(func.count()).select_from(Track)) == 3
        for index, track_id in enumerate(ids):
            track = await db.get(Track, track_id)
            if file_quality == "better" and index < 2:
                assert track.codec == "flac" and track.path == str(
                    paths[index].relative_to(MUSIC_DIR).with_suffix(".flac")
                )
                assert not paths[index].exists()
            else:
                assert paths[index].read_bytes() == old_bytes[index]
    assert await attempt_result(album_id) == ("upgraded" if file_quality == "better" else "not_better")
    for path, (data, mtime, inode) in original_files.items():
        assert path.read_bytes() == data and path.stat().st_mtime_ns == mtime and path.stat().st_ino == inode
    assert not env.gateway.deleted and not await env.manager.process_one()


@pytest.mark.parametrize("reason", ["no_torrent", "error", "disabled"])
async def test_no_youtube_fallback(client: httpx.AsyncClient, upgrade_env: SimpleNamespace, reason: str) -> None:
    env = upgrade_env
    album_id, _, _ = await library(env)
    request = await create_upgrade(album_id)
    if reason == "no_torrent":
        env.gateway.results = []
    elif reason == "error":
        env.gateway.status_code = 503
    else:
        await client.patch("/api/admin/config", headers=env.admin, json={"downloads": {"torrent_enabled": False}})
    assert await env.manager.process_one()
    async with SessionLocal() as db:
        items = list(await db.scalars(select(DownloadItem).where(DownloadItem.request_id == request.id)))
        assert len(items) == 3 and all(item.status == "failed" and item.error for item in items)
        if reason == "disabled":
            assert all(item.error == "Torrents sind deaktiviert" for item in items)
        assert (await db.get(DownloadRequest, request.id)).status == "failed"
    assert await attempt_result(album_id) == ("no_torrent" if reason == "no_torrent" else "failed")
    assert not await env.manager.process_one()
    if reason == "disabled":
        assert not env.gateway.requests


async def test_admin_run(client: httpx.AsyncClient, upgrade_env: SimpleNamespace) -> None:
    album_id, _, _ = await library(upgrade_env)
    assert (await client.post("/api/admin/upgrades/run")).status_code == 401
    assert (await client.post("/api/admin/upgrades/run", headers=upgrade_env.user)).status_code == 403
    assert not upgrade_env.searches
    response = await client.post("/api/admin/upgrades/run", headers=upgrade_env.admin)
    assert response.status_code == 202 and response.json() == {"started": True}
    assert await attempt_result(album_id) == "requested"
    async with SessionLocal() as db:
        assert (
            await db.scalar(select(func.count()).select_from(DownloadRequest).where(DownloadRequest.kind == "upgrade"))
            == 1
        )
    # An active upgrade blocks the next manual/scheduled run too.
    await client.post("/api/admin/upgrades/run", headers=upgrade_env.admin)
    assert len(upgrade_env.searches) == 1


async def test_scheduler_timing_and_lifecycle(monkeypatch: pytest.MonkeyPatch) -> None:
    sleeps = []
    runs = []

    async def sleep(seconds: float) -> None:
        sleeps.append(seconds)
        if len(sleeps) == 3:
            raise asyncio.CancelledError()

    async def run() -> None:
        runs.append(True)

    with monkeypatch.context() as patch:
        patch.setattr(upgrades.asyncio, "sleep", sleep)
        patch.setattr(upgrades, "run_once", run)
        with pytest.raises(asyncio.CancelledError):
            await upgrades._upgrade_loop()
    assert sleeps == [600, 21600, 21600] and len(runs) == 2
    await upgrades.start()
    task = upgrades._loop_task
    await upgrades.start()
    assert task is upgrades._loop_task
    await upgrades.stop()
    assert task.done() and upgrades._loop_task is None
