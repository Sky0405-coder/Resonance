import asyncio
import copy
import io
import json
import shutil
import subprocess
import uuid
from collections.abc import AsyncIterator, Callable
from pathlib import Path
from types import SimpleNamespace
from typing import Self

import httpx
import pytest
from fastapi import HTTPException
from PIL import Image
from sqlalchemy import select

from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import Album, Artist, DownloadItem, DownloadRequest, Job, Track, User
from app.services import downloads, scanner, sources
from app.services.deezer import DeezerClient, DeezerError, artist_string, deezer
from app.services.deezer import NotFound as DeezerNotFound
from app.services.downloads import DownloadManager, manager, request_status
from app.services.library_paths import target_relpath
from app.services.musicbrainz import MusicBrainzClient, MusicBrainzError, NotFound, TrackMeta, mb
from app.services.resolve import meta_from_deezer, resolve_album, resolve_track
from app.services.scanner import import_file
from app.services.server_config import ServerConfig, update_config
from app.services.sources import enabled_sources
from app.services.sources.base import Cancelled, Candidate
from app.services.sources.soundcloud import SoundCloudSource
from app.services.sources.youtube import YouTubeMusicSource, score_candidate
from app.services.tagger import write_tags
from app.services.tags import embedded_cover, read_tags
from tests.conftest import MUSIC_DIR, auth, make_track, register

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.fixture
def deezer_data() -> dict:
    return {
        name: json.loads((FIXTURES / f"deezer_{name}.json").read_text())
        for name in (
            "search_tracks",
            "search_albums",
            "search_artists",
            "track",
            "album",
            "album_tracks",
            "artist",
            "artist_top",
            "artist_albums",
        )
    }


@pytest.fixture
def release() -> dict:
    return json.loads((FIXTURES / "release.json").read_text())


@pytest.fixture
def recording() -> dict:
    return json.loads((FIXTURES / "recording.json").read_text())


@pytest.fixture
def cover() -> bytes:
    buffer = io.BytesIO()
    Image.new("RGB", (4, 4), (100, 30, 20)).save(buffer, format="JPEG")
    return buffer.getvalue()


@pytest.fixture
async def meta(release: dict) -> TrackMeta:
    return (await mb.track_meta_list(release))[0]


class FakeSource:
    name = "youtube"

    def __init__(self) -> None:
        self.fail_once = False
        self.error = "Testfehler"
        self.no_match = False
        self.on_find: Callable[[], None] | None = None

    async def find(self, meta: TrackMeta, exclude: frozenset[str] = frozenset()) -> Candidate | None:
        if self.on_find:
            self.on_find()
        if self.no_match:
            return None
        ref = next(r for r in ("fake-video", "fake-video-2", "fake-video-3") if r not in exclude)
        return Candidate(self.name, ref, meta.title, meta.artist, meta.duration, 100)

    async def download(
        self, candidate: Candidate, dest_dir: Path, progress: Callable[[float], None], cancelled: Callable[[], bool]
    ) -> Path:
        if cancelled():
            raise Cancelled()
        if self.fail_once:
            self.fail_once = False
            raise RuntimeError(self.error)
        path = dest_dir / "audio.opus"
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
                "sine=frequency=440:duration=3",
                "-c:a",
                "libopus",
                str(path),
            ],
            check=True,
        )
        progress(1)
        return path


@pytest.fixture
async def env(
    client: httpx.AsyncClient,
    release: dict,
    recording: dict,
    cover: bytes,
    deezer_data: dict,
    monkeypatch: pytest.MonkeyPatch,
) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")

    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)
        shutil.rmtree(MUSIC_DIR, ignore_errors=True)

    await reset()
    client_mb = MusicBrainzClient()

    async def get(path: str, **params: object) -> dict:
        if path == "release":
            return json.loads((FIXTURES / "release_by_barcode.json").read_text())
        if path == f"release/{release['id']}":
            return copy.deepcopy(release)
        if path == f"recording/{recording['id']}":
            return copy.deepcopy(recording)
        if path.startswith("isrc/"):
            return json.loads((FIXTURES / "isrc_recordings.json").read_text())
        raise AssertionError(path)

    async def get_deezer(path: str, **params: object) -> dict:
        paths = {
            "search/track": "search_tracks",
            "search/album": "search_albums",
            "search/artist": "search_artists",
            "track/301": "track",
            "album/201": "album",
            "album/201/tracks": "album_tracks",
            "artist/101": "artist",
            "artist/101/top": "artist_top",
            "artist/101/albums": "artist_albums",
        }
        assert path in paths, path
        return copy.deepcopy(deezer_data[paths[path]])

    monkeypatch.setattr(deezer, "_get", get_deezer)
    monkeypatch.setattr(client_mb, "_get", get)
    for method in ("release_full", "recording_meta", "isrc_recordings", "release_by_barcode"):
        monkeypatch.setattr(mb, method, getattr(client_mb, method))
    fake = FakeSource()
    monkeypatch.setattr(sources, "enabled_sources", lambda cfg: [fake] if cfg.downloads.youtube_enabled else [])

    async def fetch(meta: TrackMeta) -> bytes:
        return cover

    monkeypatch.setattr(downloads, "fetch_cover", fetch)
    admin = await register(client, "download-admin")
    await client.patch("/api/admin/config", json={"registration": {"mode": "public"}}, headers=auth(admin["token"]))
    user = await register(client, "download-user")
    other = await register(client, "download-other")
    yield SimpleNamespace(
        admin=auth(admin["token"]),
        user=auth(user["token"]),
        other=auth(other["token"]),
        fake=fake,
        album="201",
        track="301",
        artist="101",
    )
    await reset()


async def test_score_candidate(meta: TrackMeta) -> None:
    assert score_candidate(meta, meta.title, [meta.artist], 3, False) == 100
    assert score_candidate(meta, meta.title, ["Unrelated Singer"], 3, False) is None
    assert score_candidate(meta, meta.title + " (Live)", [meta.artist], 3, False) is None
    assert score_candidate(meta, meta.title, [meta.artist], 23, False) is None
    assert score_candidate(meta, meta.title, [meta.artist], 6, True) < 100
    assert score_candidate(meta, meta.title, [meta.artist], 9, True) < 100
    assert score_candidate(meta, meta.title, [meta.artist], 14, True) is None
    assert score_candidate(meta, meta.title + " (Remastered)", [meta.artist], 3, False) == 100
    # Featured artists and accents: the result may be credited to any of the song's artists.
    featured = meta.model_copy(update={"artist": "Ćelo feat. Fler"})
    assert score_candidate(featured, meta.title, ["Fler"], 3, False) == 100
    assert score_candidate(featured, meta.title, ["Celo"], 3, False) == 100
    assert score_candidate(featured, meta.title, ["Unrelated Singer"], 3, False) is None


async def test_target_relpath(meta: TrackMeta, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(get_settings(), "music_dir", tmp_path)
    assert target_relpath(meta, ".opus") == "Test Artist/Test Album (2020)/1-01 - First Song.opus"
    changed = meta.model_copy(
        update={
            "album_artist": ' /A\\:*?"<>|\x01. ',
            "album": "   ",
            "title": "a/b",
            "year": None,
            "track_no": None,
            "disc_total": 1,
        }
    )
    assert target_relpath(changed, ".flac") == "_A_________/_/a_b.flac"
    path = tmp_path / target_relpath(meta, ".opus")
    path.parent.mkdir(parents=True)
    path.touch()
    assert target_relpath(meta, ".opus").endswith("First Song (2).opus")
    path.with_name("1-01 - First Song (2).opus").touch()
    assert target_relpath(meta, ".opus").endswith("First Song (3).opus")


@pytest.mark.parametrize(
    ("statuses", "current", "expected"),
    [
        (["exists"], "pending_approval", "pending_approval"),
        (["cancelled"], "rejected", "rejected"),
        (["queued", "done"], "active", "active"),
        (["waiting"], "active", "active"),
        (["searching"], "active", "active"),
        (["downloading"], "active", "active"),
        (["processing"], "active", "active"),
        (["done", "exists"], "active", "done"),
        (["cancelled", "cancelled"], "active", "cancelled"),
        (["done", "failed"], "active", "partial"),
        (["exists", "cancelled"], "active", "partial"),
        (["failed", "cancelled"], "active", "failed"),
        (["failed"], "active", "failed"),
    ],
)
def test_request_status(statuses: list[str], current: str, expected: str) -> None:
    assert request_status(statuses, current) == expected


@pytest.mark.parametrize("ext", [".opus", ".m4a", ".mp3", ".flac"])
async def test_tag_roundtrip(ext: str, meta: TrackMeta, cover: bytes, tmp_path: Path) -> None:
    path = tmp_path / f"audio{ext}"
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=3",
            str(path),
        ],
        check=True,
    )
    write_tags(path, meta, cover)
    tags = read_tags(path)
    assert tags is not None
    for field, value in {
        "title": meta.title,
        "artist": meta.artist,
        "album": meta.album,
        "album_artist": meta.album_artist,
        "track_no": meta.track_no,
        "disc_no": meta.disc_no,
        "year": meta.year,
        "mb_recording_id": meta.mb_recording_id,
        "isrc": meta.isrc,
        "mb_album_id": meta.mb_release_id,
        "mb_artist_id": meta.artist_mbid,
        "mb_album_artist_id": meta.album_artist_mbid,
    }.items():
        assert getattr(tags, field) == value, (ext, field, tags)
    assert embedded_cover(path) == cover


async def post_request(client: httpx.AsyncClient, headers: dict, kind: str, catalog_id: str, **kwargs: object) -> dict:
    response = await client.post("/api/requests", json={"kind": kind, "id": catalog_id, **kwargs}, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


@pytest.mark.parametrize("fallback", [False, True])
async def test_album_pipeline(
    client: httpx.AsyncClient, env: SimpleNamespace, release: dict, monkeypatch: pytest.MonkeyPatch, fallback: bool
) -> None:
    if fallback:

        async def no_release(*args: object) -> None:
            return None

        monkeypatch.setattr(mb, "release_by_barcode", no_release)
    request = await post_request(client, env.admin, "album", env.album, temporary=True)
    assert request["catalog_id"] == env.album
    assert request["mb_id"] == (None if fallback else release["release-group"]["id"])
    assert request["title"] == "Test Album" and request["artist"] == "Test Artist"
    assert request["cover_url"] == "https://example.test/medium.jpg"
    assert request["status"] == "active" and [i["status"] for i in request["items"]] == ["queued"] * 3
    duplicate = await client.post("/api/requests", json={"kind": "album", "id": env.album}, headers=env.admin)
    assert duplicate.status_code == 200 and duplicate.json()["id"] == request["id"]
    summary = (await client.get("/api/requests/summary", headers=env.admin)).json()
    assert summary == {"active": 0, "queued": 3, "failed": 0, "pending_approval": 0}
    assert (await client.delete(f"/api/requests/{request['id']}", headers=env.admin)).status_code == 409
    for _ in range(3):
        assert await manager.process_one()
    assert not await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
    assert detail["status"] == "done" and detail["progress"] == 1 and detail["done_count"] == 3
    async with SessionLocal() as db:
        tracks = list(await db.scalars(select(Track).order_by(Track.disc_no, Track.track_no)))
        assert len(tracks) == 3 and all(t.is_temporary for t in tracks)
        assert [t.path for t in tracks] == [
            "Test Artist/Test Album (2020)/1-01 - First Song.opus",
            "Test Artist/Test Album (2020)/1-02 - Second Song.opus",
            "Test Artist/Test Album (2020)/2-01 - Third Song.opus",
        ]
        assert all((MUSIC_DIR / t.path).is_file() for t in tracks)
        for track in tracks:
            tags = read_tags(MUSIC_DIR / track.path)
            assert tags.title == track.title and tags.album == "Test Album" and tags.year == 2020
            assert (tags.disc_no, tags.track_no) == (track.disc_no, track.track_no)
            if fallback:
                assert track.mb_recording_id is None and tags.mb_recording_id is None
                assert tags.mb_album_id is tags.mb_artist_id is tags.mb_album_artist_id is None
                import mutagen

                comments = mutagen.File(MUSIC_DIR / track.path)
                assert not any(key.startswith("musicbrainz_") for key in comments)
                assert comments["totaldiscs"] == ["2"]
                assert comments["totaltracks"] == (["2"] if track.disc_no == 1 else ["1"])
        assert (MUSIC_DIR / tracks[0].path).with_name("cover.jpg").is_file()
        album_id = tracks[0].album_id
    album = (await client.get(f"/api/albums/{album_id}", headers=env.admin)).json()
    assert [t["title"] for t in album["tracks"]] == ["First Song", "Second Song", "Third Song"]
    again = await post_request(client, env.admin, "album", env.album)
    assert again["status"] == "done" and all(i["status"] == "exists" for i in again["items"])
    assert not any(get_settings().downloads_dir.glob("resonance/*"))
    page = (await client.get("/api/requests?state=finished&limit=1", headers=env.admin)).json()
    assert page["total"] == 2 and page["items"][0]["id"] == again["id"]
    assert "items" not in page["items"][0]
    assert (await client.delete(f"/api/requests/{again['id']}", headers=env.admin)).status_code == 204


async def test_approval_rejection(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await client.patch("/api/admin/config", json={"downloads": {"auto_approve_requests": False}}, headers=env.admin)
    request = await post_request(client, env.user, "album", env.album, temporary=True)
    assert request["status"] == "pending_approval" and not request["is_temporary"]
    assert all(i["status"] == "waiting" for i in request["items"])
    approved = await client.post(f"/api/requests/{request['id']}/approve", headers=env.admin)
    assert approved.json()["status"] == "active" and all(i["status"] == "queued" for i in approved.json()["items"])
    assert (await client.post(f"/api/requests/{request['id']}/approve", headers=env.admin)).status_code == 409
    rejected = await post_request(client, env.other, "album", env.album)
    response = await client.post(
        f"/api/requests/{rejected['id']}/reject", json={"note": "Kein Bedarf"}, headers=env.admin
    )
    assert response.json()["status"] == "rejected" and response.json()["note"] == "Kein Bedarf"
    assert all(i["status"] == "cancelled" for i in response.json()["items"])
    assert (await client.post(f"/api/requests/{rejected['id']}/reject", json={}, headers=env.admin)).status_code == 409


async def test_daily_limit(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await client.patch("/api/admin/config", json={"downloads": {"daily_limit_per_user": 2}}, headers=env.admin)
    response = await client.post("/api/requests", json={"kind": "album", "id": env.album}, headers=env.user)
    assert response.status_code == 429
    assert response.json()["detail"] == "Tageslimit erreicht (0 von 2 Songs in 24 Stunden)"
    await post_request(client, env.admin, "album", env.album)


async def test_automatic_retry(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await post_request(client, env.user, "track", env.track)
    env.fake.fail_once = True
    assert await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()
    assert detail["status"] == "active" and detail["items"][0]["status"] == "queued"
    assert await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()
    assert detail["status"] == "done" and detail["items"][0]["error"] is None


async def test_bot_check_pauses(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    request = await post_request(client, env.user, "track", env.track)
    env.fake.fail_once = True
    env.fake.error = "ERROR: [youtube] abc: Sign in to confirm you're not a bot. Use --cookies-from-browser"
    monkeypatch.setattr(manager, "_paused_until", 0.0)
    assert await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()
    item = detail["items"][0]
    assert detail["status"] == "active" and item["status"] == "queued"
    assert item["error"] == "YouTube blockiert gerade – neuer Versuch in 30 Minuten"
    async with SessionLocal() as db:
        assert (await db.get(DownloadItem, uuid.UUID(item["id"]))).attempts == 0
    assert not await manager.process_one()
    manager._paused_until = 0.0
    assert await manager.process_one()
    assert (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()["status"] == "done"


async def test_age_restricted_video_tries_another_version(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await post_request(client, env.user, "track", env.track)
    env.fake.fail_once = True
    env.fake.error = "ERROR: [youtube] fake-video: Sign in to confirm your age. This video may be inappropriate"
    assert await manager.process_one()
    item = (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()["items"][0]
    assert item["status"] == "queued"
    async with SessionLocal() as db:
        stored = await db.get(DownloadItem, uuid.UUID(item["id"]))
        assert stored.exclude_refs == ["fake-video"] and stored.attempts == 0
    assert await manager.process_one()
    async with SessionLocal() as db:
        stored = await db.get(DownloadItem, uuid.UUID(item["id"]))
        assert stored.status == "done" and stored.source_ref == "fake-video-2"


async def test_cancel_and_retry(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr("app.services.downloads.MAX_ATTEMPTS", 1)
    request = await post_request(client, env.user, "album", env.album)
    cancelled = (await client.post(f"/api/requests/{request['id']}/cancel", headers=env.user)).json()
    assert cancelled["status"] == "cancelled" and cancelled["progress"] == 1
    assert all(i["status"] == "cancelled" for i in cancelled["items"])
    assert not await manager.process_one()
    request = await post_request(client, env.user, "track", env.track)
    env.fake.fail_once = True
    assert await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()
    assert detail["status"] == "failed" and detail["failed_count"] == 1
    assert detail["items"][0]["error"] == "Download fehlgeschlagen: Testfehler"
    async with SessionLocal() as db:
        item = await db.get(DownloadItem, uuid.UUID(detail["items"][0]["id"]))
        assert item.attempts == 1
    retried = (await client.post(f"/api/requests/{request['id']}/retry", headers=env.user)).json()
    assert retried["status"] == "active" and retried["items"][0]["error"] is None and retried["progress"] == 0
    assert await manager.process_one()
    assert (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()["status"] == "done"


async def test_permissions(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await post_request(client, env.user, "track", env.track)
    url = f"/api/requests/{request['id']}"
    assert (await client.get(url, headers=env.other)).status_code == 404
    for action in ("cancel", "retry"):
        assert (await client.post(f"{url}/{action}", headers=env.other)).status_code == 404
    assert (await client.post(f"{url}/approve", headers=env.user)).status_code == 403
    assert (await client.delete(url, headers=env.user)).status_code == 403
    response = await client.get("/api/requests?scope=all", headers=env.user)
    assert response.status_code == 403 and response.json()["detail"] == "Nur für Admins"
    assert (await client.get("/api/requests/summary", headers=env.other)).json()["queued"] == 0
    assert (await client.get("/api/requests/summary", headers=env.admin)).json()["queued"] == 1


async def test_catalog_matching(client: httpx.AsyncClient, env: SimpleNamespace, meta: TrackMeta) -> None:
    path = make_track("Test Artist/Test Album/song.flac")
    write_tags(path, meta, None)
    async with SessionLocal() as db:
        track = await import_file(db, str(path.relative_to(MUSIC_DIR)))
        track_id, album_id, artist_id = str(track.id), str(track.album_id), str(track.artist_id)
    result = (await client.get("/api/catalog/search?q=test", headers=env.user)).json()
    assert result["tracks"][0]["library_id"] == track_id
    assert result["tracks"][0]["id"] == env.track
    assert result["tracks"][0]["preview_url"] == "https://example.test/301.mp3"
    assert result["tracks"][0]["disc_no"] is result["tracks"][0]["track_no"] is None
    assert result["albums"][0]["library_id"] == album_id
    assert result["artists"][0]["library_id"] == artist_id
    result = (await client.get("/api/catalog/search?q=test&types=track", headers=env.user)).json()
    assert result["artists"] == result["albums"] == []
    album = (await client.get(f"/api/catalog/albums/{env.album}", headers=env.user)).json()
    assert album["library_id"] == album_id
    assert [(t["disc_no"], t["track_no"]) for t in album["tracks"]] == [(1, 1), (1, 2), (2, 1)]
    artist = (await client.get(f"/api/catalog/artists/{env.artist}", headers=env.user)).json()
    assert artist["artist"]["library_id"] == artist_id and artist["albums"][-1]["library_id"] == album_id
    assert artist["top_tracks"][0]["library_id"] == track_id
    assert [a["id"] for a in artist["albums"]] == ["205", "204", "201"]
    assert [a["title"] for a in artist["albums"]] == ["Alpha", "Zulu", "Test Album"]
    assert all(a["artist"] == "Test Artist" and a["artist_id"] == "101" for a in artist["albums"])
    assert artist["artist"]["picture_url"] == "https://example.test/artist-medium.jpg"


async def test_missing_source_and_cancellation(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    await client.patch("/api/admin/config", json={"downloads": {"youtube_enabled": False}}, headers=env.admin)
    request = await post_request(client, env.admin, "track", env.track)
    await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
    assert detail["items"][0]["error"] == "Keine Download-Quelle aktiviert"
    await client.patch("/api/admin/config", json={"downloads": {"youtube_enabled": True}}, headers=env.admin)
    env.fake.no_match = True
    await client.post(f"/api/requests/{request['id']}/retry", headers=env.admin)
    await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
    assert detail["items"][0]["error"] == "Keine passende Quelle gefunden"
    env.fake.no_match = False
    await client.post(f"/api/requests/{request['id']}/retry", headers=env.admin)
    env.fake.on_find = lambda: manager._cancelled.add(uuid.UUID(request["items"][0]["id"]))
    await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
    assert detail["status"] == "cancelled"


async def test_library_check_at_processing(client: httpx.AsyncClient, env: SimpleNamespace, meta: TrackMeta) -> None:
    request = await post_request(client, env.admin, "track", env.track)
    path = make_track("Test Artist/Test Album/first.flac")
    write_tags(path, meta, None)
    async with SessionLocal() as db:
        track = await import_file(db, str(path.relative_to(MUSIC_DIR)))
        track_id = str(track.id)
    assert await manager.process_one()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
    assert detail["status"] == "done" and detail["items"][0]["status"] == "exists"
    assert detail["items"][0]["track_id"] == track_id


async def test_concurrent_workers(client: httpx.AsyncClient, env: SimpleNamespace) -> None:
    request = await post_request(client, env.admin, "album", env.album)
    results = await asyncio.gather(*(manager.process_one() for _ in range(3)))
    assert results == [True] * 3
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
    assert detail["status"] == "done" and detail["done_count"] == 3


async def test_cancel_searching(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    request = await post_request(client, env.user, "track", env.track)
    searching = asyncio.Event()
    release_search = asyncio.Event()

    async def find(meta: TrackMeta, exclude: frozenset[str] = frozenset()) -> Candidate:
        searching.set()
        await release_search.wait()
        return Candidate("youtube", "test", meta.title, meta.artist, meta.duration, 100)

    monkeypatch.setattr(env.fake, "find", find)
    task = asyncio.create_task(manager.process_one())
    await asyncio.wait_for(searching.wait(), timeout=5)
    try:
        response = await client.post(f"/api/requests/{request['id']}/cancel", headers=env.user)
        assert response.status_code == 200
    finally:
        release_search.set()
        await task
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.user)).json()
    assert detail["status"] == "cancelled"


async def test_manager_restart(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    request = await post_request(client, env.admin, "album", env.album)
    async with SessionLocal() as db:
        items = list(await db.scalars(select(DownloadItem).order_by(DownloadItem.position)))
        for item, status in zip(items, ("searching", "downloading", "processing"), strict=True):
            item.status = status
        await db.commit()
    restarted = DownloadManager()
    await restarted.start()
    await restarted.stop()
    detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
    assert [i["status"] for i in detail["items"]] == ["queued"] * 3
    monkeypatch.setattr(get_settings(), "download_workers", 2)
    await restarted.start()
    try:
        for _ in range(100):
            detail = (await client.get(f"/api/requests/{request['id']}", headers=env.admin)).json()
            if detail["status"] == "done":
                break
            await asyncio.sleep(0.02)
        assert detail["status"] == "done"
    finally:
        await restarted.stop()


async def test_musicbrainz_transport(monkeypatch: pytest.MonkeyPatch) -> None:
    from app.services import musicbrainz

    clock = SimpleNamespace(now=100.0)
    sleeps = []
    seen = []

    async def sleep(delay: float) -> None:
        sleeps.append(delay)
        clock.now += delay

    def respond(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        path = request.url.path
        if path.endswith("retry") and sum(r.url.path == path for r in seen) == 1:
            return httpx.Response(503)
        if path.endswith("missing"):
            return httpx.Response(404)
        if path.endswith("error"):
            return httpx.Response(500)
        return httpx.Response(200, json={"ok": True})

    original = httpx.AsyncClient

    def client(**kwargs: object) -> httpx.AsyncClient:
        return original(transport=httpx.MockTransport(respond), **kwargs)

    monkeypatch.setattr(musicbrainz, "time", SimpleNamespace(monotonic=lambda: clock.now))
    monkeypatch.setattr(musicbrainz.asyncio, "sleep", sleep)
    monkeypatch.setattr(musicbrainz.httpx, "AsyncClient", client)
    monkeypatch.setattr(get_settings(), "musicbrainz_contact", "test@example.org")
    instance = MusicBrainzClient()
    try:
        assert await instance._get("retry", query="test") == {"ok": True}
        assert len(seen) == 2 and 2 in sleeps
        assert seen[0].headers["user-agent"] == "Resonance/0.1.0 ( test@example.org )"
        assert seen[0].url.params["fmt"] == "json"
        await instance._get("retry", query="test")
        assert len(seen) == 2
        await instance._get("other", b=2, a=1)
        await instance._get("other", a=1, b=2)
        assert len(seen) == 3 and sleeps[-1] == pytest.approx(1.1)
        clock.now += 3601
        await instance._get("other", a=1, b=2)
        assert len(seen) == 4
        with pytest.raises(NotFound):
            await instance._get("missing")
        with pytest.raises(MusicBrainzError):
            await instance._get("error")
        for index in range(2001):
            await instance._get("cache", index=index)
        assert len(instance._cache) == 2000
        assert ("cache", (("fmt", "json"), ("index", 0))) not in instance._cache
    finally:
        await instance._client.aclose()


async def test_musicbrainz_metadata(release: dict, recording: dict, monkeypatch: pytest.MonkeyPatch) -> None:
    from app.services.musicbrainz import _choose

    official = copy.deepcopy(release)
    unofficial = copy.deepcopy(official)
    unofficial.update(id="00000000-0000-0000-0000-000000000001", status="Bootleg", date="1990")
    cd = copy.deepcopy(official)
    cd.update(id="20000000-0000-0000-0000-000000000002", date="1990")
    cd["media"][0]["format"] = "CD"
    assert _choose([unofficial, cd, official])["id"] == official["id"]
    secondary = copy.deepcopy(official)
    secondary["release-group"]["secondary-types"] = ["Live"]
    assert _choose([secondary, cd], recording=True)["id"] == cd["id"]
    single = copy.deepcopy(official)
    single["release-group"]["primary-type"] = "Single"
    assert _choose([single, cd], recording=True)["id"] == cd["id"]
    with pytest.raises(NotFound):
        _choose([])
    release["media"][1]["tracks"].append({"title": "Video", "position": 2, "recording": {"id": "video", "video": True}})
    release["media"][0]["tracks"][0]["artist-credit"] = [
        {"name": "A", "artist": {"id": "a"}, "joinphrase": " feat. "},
        {"name": "B", "artist": {"id": "b"}},
    ]
    metas = await mb.track_meta_list(release)
    assert len(metas) == 3 and metas[0].artist == "A feat. B" and metas[0].artist_mbid == "a"
    assert metas[0].genre == "Art Rock" and metas[0].label == "Test Label"
    assert metas[2].disc_total == 2 and metas[2].track_total == 2
    instance = MusicBrainzClient()

    async def get(path: str, **params: object) -> dict:
        if path.startswith("recording/"):
            return recording
        return release

    monkeypatch.setattr(instance, "_get", get)
    assert (await instance.recording_meta(recording["id"])).mb_recording_id == recording["id"]
    with pytest.raises(NotFound):
        await instance.recording_meta("unknown")


async def test_youtube_find_fallback(meta: TrackMeta, monkeypatch: pytest.MonkeyPatch) -> None:
    from app.services.sources import youtube

    seen = []

    class Music:
        def search(self, query: str, filter: str, limit: int) -> list[dict]:
            seen.append(filter)
            if filter == "songs":
                return [{"videoId": "wrong", "title": meta.title, "artists": [{"name": "Other"}]}]
            return [{"videoId": "right", "title": meta.title, "artists": [{"name": meta.artist}], "duration": "0:03"}]

    monkeypatch.setattr(youtube, "YTMusic", Music)
    source = YouTubeMusicSource()
    candidate = await source.find(meta)
    assert candidate.ref == "right" and candidate.score == 90 and seen == ["songs", "videos"]


@pytest.mark.parametrize(
    ("codec", "extension", "expected"),
    [
        ("opus", ".webm", ".opus"),
        ("mp4a.40.2", ".m4a", ".m4a"),
        ("mp3", ".mp3", ".opus"),
    ],
)
async def test_youtube_download(
    codec: str, extension: str, expected: str, meta: TrackMeta, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.services.sources import youtube

    options_seen = {}
    source_file = tmp_path / f"source{extension}"
    encoder = {"opus": "libopus", "mp4a.40.2": "aac", "mp3": "libmp3lame"}[codec]
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=3",
            "-c:a",
            encoder,
            str(source_file),
        ],
        check=True,
    )

    class Downloader:
        def __init__(self, options: dict) -> None:
            options_seen.update(options)

        def __enter__(self) -> "Downloader":
            return self

        def __exit__(self, *args: object) -> None:
            pass

        def extract_info(self, url: str, download: bool) -> dict:
            assert url == "https://music.youtube.com/watch?v=ref" and download
            options_seen["progress_hooks"][0]({"downloaded_bytes": 5, "total_bytes_estimate": 10})
            return {"acodec": codec}

        def prepare_filename(self, info: dict) -> str:
            return str(source_file)

    monkeypatch.setattr(youtube, "YTMusic", lambda: object())
    monkeypatch.setattr(youtube.yt_dlp, "YoutubeDL", Downloader)
    cookies = tmp_path / "cookies.txt"
    monkeypatch.setattr(get_settings(), "ytdlp_cookies_file", cookies)
    seen_progress = []
    source = YouTubeMusicSource()
    candidate = Candidate("youtube", "ref", meta.title, meta.artist, 3, 100)
    path = await source.download(candidate, tmp_path, seen_progress.append, lambda: False)
    assert path.name == f"audio{expected}" and path.is_file() and not source_file.exists()
    assert read_tags(path).codec == ("aac" if expected == ".m4a" else "opus")
    assert seen_progress == [0.5]
    assert options_seen["format"] == "bestaudio[acodec=opus]/bestaudio[ext=m4a]/bestaudio"
    assert options_seen["cookiefile"] == str(cookies)
    with pytest.raises(Cancelled):
        await source.download(candidate, tmp_path, seen_progress.append, lambda: True)


@pytest.mark.parametrize("split", [False, True])
async def test_soundcloud_find_scoring(meta: TrackMeta, monkeypatch: pytest.MonkeyPatch, split: bool) -> None:
    ref = "https://soundcloud.com/artist/song"

    class Downloader:
        def __init__(self, options: dict) -> None:
            assert options == {"quiet": True, "no_warnings": True, "extract_flat": True}

        def __enter__(self) -> Self:
            return self

        def __exit__(self, *args: object) -> None:
            pass

        def extract_info(self, query: str, download: bool) -> dict:
            assert query == f"scsearch10:{meta.artist} {meta.title}" and download is False
            return {
                "entries": [
                    None,
                    {"title": meta.title},
                    {"url": "wrong", "title": "Unrelated", "uploader": meta.artist, "duration": 3},
                    {"url": "live", "title": f"{meta.title} (Live)", "uploader": meta.artist},
                    {"url": "long", "title": meta.title, "uploader": meta.artist, "duration": 60},
                    {"url": "near", "title": meta.title, "uploader": meta.artist, "duration": 10},
                    {
                        "url": ref,
                        "title": f"{meta.artist} - {meta.title}" if split else meta.title,
                        "uploader": "Repost channel" if split else meta.artist,
                        "duration": 3,
                    },
                ]
            }

    monkeypatch.setattr("app.services.sources.soundcloud.yt_dlp.YoutubeDL", Downloader)
    source = SoundCloudSource()
    assert await source.find(meta) == Candidate("soundcloud", ref, meta.title, meta.artist, 3, 100)
    excluded = await source.find(meta, frozenset({ref}))
    assert excluded is not None and excluded.ref == "near" and excluded.score < 100
    assert await source.find(meta, frozenset({ref, "near"})) is None
    assert source.candidate(ref) == Candidate("soundcloud", ref, "", "", None, 100)


async def test_soundcloud_find_extractor_error(
    meta: TrackMeta, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    def fail(options: dict) -> None:
        raise RuntimeError("offline")

    monkeypatch.setattr("app.services.sources.soundcloud.yt_dlp.YoutubeDL", fail)
    with caplog.at_level("DEBUG", logger="app.services.sources.soundcloud"):
        assert await SoundCloudSource().find(meta) is None
    assert "SoundCloud search failed" in caplog.text


@pytest.mark.parametrize(
    "codec,extension,expected",
    [
        ("opus", ".opus", ".opus"),
        ("mp3", ".mp3", ".mp3"),
        ("aac", ".aac", ".m4a"),
        ("mp4a.40.2", ".m4a", ".m4a"),
        ("flac", ".flac", ".opus"),
    ],
)
async def test_soundcloud_download(
    codec: str, extension: str, expected: str, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    source_file = make_track(f"soundcloud-source{extension}")
    options_seen = {}
    ref = "https://soundcloud.com/artist/song"

    class Downloader:
        def __init__(self, options: dict) -> None:
            options_seen.update(options)

        def __enter__(self) -> Self:
            return self

        def __exit__(self, *args: object) -> None:
            pass

        def extract_info(self, url: str, download: bool) -> dict:
            assert url == ref and download
            options_seen["progress_hooks"][0]({"downloaded_bytes": 5, "total_bytes_estimate": 10})
            return {"acodec": codec}

        def prepare_filename(self, info: dict) -> str:
            return str(source_file)

    monkeypatch.setattr("app.services.sources.soundcloud.yt_dlp.YoutubeDL", Downloader)
    seen_progress = []
    source = SoundCloudSource()
    candidate = source.candidate(ref)
    path = await source.download(candidate, tmp_path, seen_progress.append, lambda: False)
    assert path.name == f"audio{expected}" and path.is_file() and not source_file.exists()
    assert read_tags(path).codec == {".mp3": "mp3", ".m4a": "aac", ".opus": "opus"}[expected]
    assert seen_progress == [0.5]
    assert options_seen["format"] == "bestaudio[ext=opus]/bestaudio[ext=mp3]/bestaudio"
    assert "cookiefile" not in options_seen
    with pytest.raises(Cancelled):
        await source.download(candidate, tmp_path, seen_progress.append, lambda: True)

    # Cancellation during a progress callback must abort before conversion.
    with pytest.raises(Cancelled):
        await source.download(candidate, tmp_path, seen_progress.append, iter([False, True]).__next__)


@pytest.mark.parametrize(
    "youtube_enabled,soundcloud_enabled", [(True, True), (True, False), (False, True), (False, False)]
)
async def test_soundcloud_source_order(
    client: httpx.AsyncClient,
    env: SimpleNamespace,
    monkeypatch: pytest.MonkeyPatch,
    youtube_enabled: bool,
    soundcloud_enabled: bool,
) -> None:
    youtube = FakeSource()
    youtube.no_match = True
    soundcloud = FakeSource()
    soundcloud.name = "soundcloud"
    calls = []
    youtube.on_find = lambda: calls.append("youtube")
    soundcloud.on_find = lambda: calls.append("soundcloud")
    monkeypatch.setattr(sources, "_youtube", youtube)
    monkeypatch.setattr(sources, "_soundcloud", soundcloud)
    monkeypatch.setattr(sources, "enabled_sources", enabled_sources)
    cfg = ServerConfig()
    cfg.downloads.youtube_enabled = youtube_enabled
    cfg.downloads.soundcloud_enabled = soundcloud_enabled
    expected = ([youtube] if youtube_enabled else []) + ([soundcloud] if soundcloud_enabled else [])
    assert enabled_sources(cfg) == expected
    assert enabled_sources(cfg) == expected
    async with SessionLocal() as db:
        await update_config(
            db,
            {
                "downloads": {
                    "youtube_enabled": youtube_enabled,
                    "soundcloud_enabled": soundcloud_enabled,
                    "torrent_enabled": True,
                }
            },
        )
        user = await db.scalar(select(User).where(User.username == "download-user"))
        request = await downloads.create_search_request(
            db, user, title="Underground", artist="Niche Artist", album=None, duration=3, temporary=False
        )
    assert await DownloadManager().process_one()
    assert calls == (["youtube"] if youtube_enabled else []) + (["soundcloud"] if soundcloud_enabled else [])
    response = await client.get(f"/api/requests/{request.id}", headers=env.user)
    detail = response.json()
    assert detail["kind"] == "search" and detail["torrent_status"] is None
    assert detail["status"] == ("done" if soundcloud_enabled else "failed")
    if soundcloud_enabled:
        assert detail["items"][0]["source"] == "soundcloud"
        assert detail["items"][0]["track_id"] is not None


@pytest.mark.parametrize("approved,admin", [(False, False), (True, False), (False, True)])
async def test_search_request_dedupe_metadata_approval(env: SimpleNamespace, approved: bool, admin: bool) -> None:
    async with SessionLocal() as db:
        await update_config(db, {"downloads": {"auto_approve_requests": approved}})
        user = await db.scalar(select(User).where(User.username == ("download-admin" if admin else "download-user")))
        request = await downloads.create_search_request(
            db, user, title="Underground", artist="Niche Artist, Guest", album=None, duration=None, temporary=True
        )
        duplicate = await downloads.create_search_request(
            db, user, title="UNDERGROUND", artist="niche  artist, guest", album="Other", duration=10, temporary=False
        )
        assert duplicate.id == request.id
        assert request.kind == "search" and request.catalog_id == "search:niche artist, guest:underground"
        assert request.cover_url is None and request.mb_id is None and request.mb_release_id is None
        assert (request.title, request.artist) == ("Underground", "Niche Artist, Guest")
        assert request.status == ("active" if approved or admin else "pending_approval")
        assert request.is_temporary is admin
        assert len(request.items) == 1
        item = request.items[0]
        assert item.position == 0 and item.status == ("queued" if approved or admin else "waiting")
        meta = TrackMeta.model_validate(item.meta)
        assert meta.artist == meta.album_artist == "Niche Artist"
        assert meta.album == meta.title == "Underground"
        assert meta.track_no == meta.track_total == meta.disc_no == meta.disc_total == 1
        assert all(
            value is None
            for key, value in item.meta.items()
            if key
            not in {"title", "artist", "album", "album_artist", "track_no", "track_total", "disc_no", "disc_total"}
        )


async def test_search_request_limit_existing_and_long_key(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await update_config(db, {"downloads": {"daily_limit_per_user": 1}})
        user = await db.scalar(select(User).where(User.username == "download-user"))
        title = "Niche song " * 10
        request = await downloads.create_search_request(
            db, user, title=title, artist="Niche Artist", album="Underground Album", duration=3, temporary=False
        )
        assert request.catalog_id == f"search:niche artist:{title.casefold().strip()}"[:64]
        assert request.items[0].meta["album"] == "Underground Album"
        assert (
            await downloads.create_search_request(
                db, user, title=title, artist="Niche Artist", album=None, duration=3, temporary=False
            )
        ).id == request.id
        with pytest.raises(HTTPException) as error:
            await downloads.create_search_request(
                db, user, title="Another", artist="Niche Artist", album=None, duration=3, temporary=False
            )
        assert error.value.status_code == 429
        assert error.value.detail == "Tageslimit erreicht (1 von 1 Songs in 24 Stunden)"
        path = make_track("Niche Artist/Album/existing.opus", title="Existing", artist="Niche Artist", album="Album")
        track = await import_file(db, str(path.relative_to(MUSIC_DIR)))
        existing = await downloads.create_search_request(
            db, user, title="Existing", artist="Niche Artist", album=None, duration=2, temporary=False
        )
        assert existing.status == "done" and existing.items[0].status == "exists"
        assert existing.items[0].track_id == track.id
        admin = await db.scalar(select(User).where(User.username == "download-admin"))
        assert (
            await downloads.create_search_request(
                db, admin, title=title, artist="Niche Artist", album=None, duration=3, temporary=False
            )
        ).id != request.id


async def test_fetch_cover_cache(
    meta: TrackMeta, cover: bytes, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.services import tagger

    monkeypatch.setattr(get_settings(), "data_dir", tmp_path)
    seen = []

    def respond(request: httpx.Request) -> httpx.Response:
        seen.append(request.url.path)
        if "/release/" in request.url.path:
            return httpx.Response(404)
        return httpx.Response(200, content=cover)

    original = httpx.AsyncClient

    def client(**kwargs: object) -> httpx.AsyncClient:
        return original(transport=httpx.MockTransport(respond), **kwargs)

    monkeypatch.setattr(tagger.httpx, "AsyncClient", client)
    assert await tagger.fetch_cover(meta) == cover
    # The release group's cover comes first; the exact release is only the fallback.
    assert seen == [f"/release-group/{meta.mb_release_group_id}/front-1200"]
    assert await tagger.fetch_cover(meta) == cover and len(seen) == 1
    (tmp_path / "caa" / f"rg-{meta.mb_release_group_id}.jpg").unlink()
    monkeypatch.setattr(
        tagger.httpx,
        "AsyncClient",
        lambda **kwargs: original(transport=httpx.MockTransport(lambda request: httpx.Response(500)), **kwargs),
    )
    assert await tagger.fetch_cover(meta) is None


async def test_deezer_api_errors(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def missing(*args: object, **kwargs: object) -> None:
        raise DeezerNotFound("missing")

    async def unavailable(*args: object, **kwargs: object) -> None:
        raise DeezerError("unavailable")

    for error, status, message in (
        (missing, 404, "Nicht im Katalog gefunden"),
        (unavailable, 502, "Katalog nicht erreichbar"),
    ):
        for method in ("album", "artist", "search_artists", "track"):
            monkeypatch.setattr(deezer, method, error)
        for url in (
            f"/api/catalog/albums/{env.album}",
            f"/api/catalog/artists/{env.artist}",
            "/api/catalog/search?q=test&types=artist",
        ):
            response = await client.get(url, headers=env.user)
            assert response.status_code == status and response.json()["detail"] == message
        for kind, id in (("track", env.track), ("album", env.album)):
            response = await client.post("/api/requests", json={"kind": kind, "id": id}, headers=env.user)
            assert response.status_code == status and response.json()["detail"] == message


@pytest.mark.parametrize(
    ("names", "expected"),
    [
        (["Daft Punk"], "Daft Punk"),
        (["Daft Punk", "Pharrell Williams"], "Daft Punk feat. Pharrell Williams"),
        (["Daft Punk", "Pharrell Williams", "Nile Rodgers"], "Daft Punk feat. Pharrell Williams & Nile Rodgers"),
        (["A", "B", "C", "D"], "A feat. B, C & D"),
    ],
)
def test_deezer_artist_string(names: list[str], expected: str) -> None:
    track = {
        "artist": {"name": "Fallback"},
        "contributors": [{"name": name, "role": "Main"} for name in names] + [{"name": "Producer", "role": "Producer"}],
    }
    assert artist_string(track) == expected
    assert artist_string({"artist": {"name": "Fallback"}}) == "Fallback"


async def test_catalog_isrc_matching(
    client: httpx.AsyncClient, env: SimpleNamespace, meta: TrackMeta, deezer_data: dict
) -> None:
    path = make_track("Test Artist/Test Album/isrc.flac")
    write_tags(path, meta.model_copy(update={"title": "Different title", "artist": "Different Artist"}), None)
    async with SessionLocal() as db:
        track = await import_file(db, str(path.relative_to(MUSIC_DIR)))
        track_id = str(track.id)
    response = await client.get("/api/catalog/search?q=test&types=track", headers=env.user)
    assert response.json()["tracks"][0]["library_id"] == track_id
    # Without an ISRC the original track/album artist name rules still match.
    deezer_data["search_tracks"]["data"][0].pop("isrc")
    deezer_data["search_tracks"]["data"][0]["title"] = "Different title"
    response = await client.get("/api/catalog/search?q=test&types=track", headers=env.user)
    assert response.json()["tracks"][0]["library_id"] == track_id
    # Request creation also checks the resolved ISRC before the names.
    deezer_data["track"]["title"] = "Deezer title"
    deezer_data["track"]["contributors"] = [{"name": "Deezer Artist", "role": "Main"}]
    request = await post_request(client, env.admin, "track", env.track)
    assert request["items"][0]["status"] == "exists" and request["items"][0]["track_id"] == track_id
    assert request["title"] == "Deezer title" and request["artist"] == "Deezer Artist"


@pytest.mark.parametrize("id", ["", "abc", "12a", "-1", "1.5", "1" * 21, "１２３", "12\n"])
async def test_catalog_id_validation(client: httpx.AsyncClient, env: SimpleNamespace, id: str) -> None:
    for kind in ("track", "album"):
        response = await client.post("/api/requests", json={"kind": kind, "id": id}, headers=env.user)
        assert response.status_code == 422
    if id:
        from urllib.parse import quote

        for kind in ("artists", "albums"):
            response = await client.get(f"/api/catalog/{kind}/{quote(id, safe='')}", headers=env.user)
            assert response.status_code == 422


async def test_catalog_search_concurrent(
    client: httpx.AsyncClient, env: SimpleNamespace, deezer_data: dict, monkeypatch: pytest.MonkeyPatch
) -> None:
    started = set()
    ready = asyncio.Event()

    def method(kind: str):
        async def search(q: str, limit: int) -> list[dict]:
            assert q == "query" and limit == 7
            started.add(kind)
            if len(started) == 3:
                ready.set()
            await asyncio.wait_for(ready.wait(), timeout=2)
            return deezer_data[f"search_{kind}"]["data"]

        return search

    for kind in ("artists", "albums", "tracks"):
        monkeypatch.setattr(deezer, f"search_{kind}", method(kind))
    response = await client.get("/api/catalog/search?q=query&limit=7", headers=env.user)
    assert response.status_code == 200 and len(started) == 3


async def test_resolve_track_match(env: SimpleNamespace, meta: TrackMeta, monkeypatch: pytest.MonkeyPatch) -> None:
    calls = []

    async def recording_meta(id: str, prefer_album: str | None = None) -> TrackMeta:
        calls.append((id, prefer_album))
        return meta.model_copy(update={"isrc": None})

    monkeypatch.setattr(mb, "recording_meta", recording_meta)
    result = await resolve_track(env.track)
    assert calls == [(meta.mb_recording_id, "Test Album")]
    assert result.mb_release_id == meta.mb_release_id
    assert result.deezer_track_id == env.track and result.deezer_album_id == env.album
    assert result.cover_url == "https://example.test/xl.jpg" and result.isrc == "DEABC2000001"


@pytest.mark.parametrize(
    "reason", ["no_isrc", "empty", "isrc_not_found", "isrc_error", "recording_not_found", "recording_error"]
)
async def test_resolve_track_fallback(
    env: SimpleNamespace, deezer_data: dict, reason: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def failure(*args: object, **kwargs: object) -> None:
        raise NotFound("missing") if reason.endswith("not_found") else MusicBrainzError("unavailable")

    async def empty(*args: object) -> list:
        return []

    if reason == "no_isrc":
        deezer_data["track"].pop("isrc")
    elif reason == "empty":
        monkeypatch.setattr(mb, "isrc_recordings", empty)
    else:
        monkeypatch.setattr(mb, "isrc_recordings" if reason.startswith("isrc") else "recording_meta", failure)
    result = await resolve_track(env.track)
    assert result.mb_recording_id is result.mb_release_id is result.mb_release_group_id is None
    assert result.artist_mbid is result.album_artist_mbid is None
    assert (result.title, result.artist, result.album, result.album_artist) == (
        "First Song",
        "Test Artist",
        "Test Album",
        "Test Artist",
    )
    assert (result.disc_no, result.disc_total, result.track_no, result.track_total) == (1, 1, 1, 3)
    assert result.date == "2020-05-03" and result.year == 2020 and result.duration == 3
    assert result.genre == "Art Rock" and result.label == "Test Label"
    assert result.isrc == (None if reason == "no_isrc" else "DEABC2000001")
    assert (result.deezer_track_id, result.deezer_album_id, result.cover_url) == (
        env.track,
        env.album,
        "https://example.test/xl.jpg",
    )


async def test_resolve_album_barcode(env: SimpleNamespace, release: dict, monkeypatch: pytest.MonkeyPatch) -> None:
    seen = []

    async def barcode(value: str, count: int) -> str | None:
        seen.append((value, count))
        return release["id"] if len(seen) == 3 else None

    monkeypatch.setattr(mb, "release_by_barcode", barcode)
    album, metas = await resolve_album(env.album)
    assert seen == [("001234567890", 3), ("1234567890", 3), ("0001234567890", 3)]
    assert album["id"] == 201 and len(metas) == 3
    assert [m.deezer_track_id for m in metas] == ["301", "302", "303"]
    assert all(
        m.mb_release_id == release["id"]
        and m.deezer_album_id == env.album
        and m.cover_url == "https://example.test/xl.jpg"
        for m in metas
    )
    assert [(m.disc_no, m.track_no, m.track_total, m.disc_total) for m in metas] == [
        (1, 1, 2, 2),
        (1, 2, 2, 2),
        (2, 1, 1, 2),
    ]


@pytest.mark.parametrize("reason", ["no_upc", "no_hit", "mismatch", "not_found", "error"])
async def test_resolve_album_fallback(
    env: SimpleNamespace, deezer_data: dict, reason: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    seen = []

    async def barcode(value: str, count: int) -> None:
        seen.append(value)
        if reason in {"not_found", "error"}:
            raise NotFound("missing") if reason == "not_found" else MusicBrainzError("unavailable")
        return None

    if reason == "no_upc":
        deezer_data["album"].pop("upc")
    elif reason == "mismatch":

        async def metas(*args: object) -> list:
            return []

        monkeypatch.setattr(mb, "track_meta_list", metas)
    else:
        monkeypatch.setattr(mb, "release_by_barcode", barcode)
    album, metas = await resolve_album(env.album)
    assert len(metas) == 3 and all(m.mb_recording_id is m.mb_release_id is m.mb_release_group_id is None for m in metas)
    assert [(m.disc_no, m.track_no, m.track_total, m.disc_total) for m in metas] == [
        (1, 1, 2, 2),
        (1, 2, 2, 2),
        (2, 1, 1, 2),
    ]
    assert [m.deezer_track_id for m in metas] == ["301", "302", "303"]
    assert all(m.deezer_album_id == env.album and m.cover_url == "https://example.test/xl.jpg" for m in metas)
    if reason == "no_upc":
        assert seen == []
    elif reason == "no_hit":
        assert seen == ["001234567890", "1234567890", "0001234567890"]


async def test_barcode_deduplication(env: SimpleNamespace, deezer_data: dict, monkeypatch: pytest.MonkeyPatch) -> None:
    deezer_data["album"]["upc"] = "12345"
    seen = []

    async def barcode(value: str, count: int) -> None:
        seen.append(value)
        return None

    monkeypatch.setattr(mb, "release_by_barcode", barcode)
    await resolve_album(env.album)
    assert seen == ["12345", "012345"]


async def test_musicbrainz_resolution_helpers(monkeypatch: pytest.MonkeyPatch, release: dict, recording: dict) -> None:
    from app.services.musicbrainz import _choose

    instance = MusicBrainzClient()
    seen = []

    async def get(path: str, **params: object) -> dict:
        seen.append((path, params))
        if path.startswith("isrc/"):
            if path.endswith("missing"):
                raise NotFound("missing")
            return json.loads((FIXTURES / "isrc_recordings.json").read_text())
        if path == "release":
            return json.loads((FIXTURES / "release_by_barcode.json").read_text())
        if path.startswith("recording/"):
            return recording
        return release

    monkeypatch.setattr(instance, "_get", get)
    assert len(await instance.isrc_recordings("DEABC2000001")) == 3
    assert await instance.isrc_recordings("missing") == []
    assert await instance.release_by_barcode("001234567890", 3) == release["id"]
    assert seen[-1] == ("release", {"query": "barcode:001234567890", "limit": 5})
    assert await instance.release_by_barcode("001234567890", 4) == "wrong"
    assert await instance.release_by_barcode("001234567890", 9) is None
    other = copy.deepcopy(recording["releases"][0])
    other.update(id="other", title="Different Album", date="1990")
    preferred = copy.deepcopy(recording["releases"][0])
    preferred.update(status="Bootleg", title="  TEST   ALBUM  ")
    assert _choose([other, preferred], recording=True)["id"] == "other"
    assert _choose([other, preferred], recording=True, prefer_album="Test Album")["id"] == preferred["id"]
    recording["releases"] = [other, preferred]
    assert (await instance.recording_meta(recording["id"], prefer_album="Test Album")).mb_release_id == release["id"]
    assert seen[-1][0] == f"release/{preferred['id']}"


@pytest.mark.parametrize("ext", [".opus", ".m4a", ".mp3", ".flac"])
async def test_fallback_tags(ext: str, deezer_data: dict, tmp_path: Path) -> None:
    import mutagen

    meta = meta_from_deezer(deezer_data["track"], deezer_data["album"], 1, 3)
    path = tmp_path / f"fallback{ext}"
    subprocess.run(
        [
            "ffmpeg",
            "-nostdin",
            "-loglevel",
            "error",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "sine=frequency=440:duration=3",
            str(path),
        ],
        check=True,
    )
    write_tags(path, meta, None)
    tags = read_tags(path)
    assert tags.title == meta.title and tags.isrc == meta.isrc
    assert tags.mb_recording_id is tags.mb_album_id is tags.mb_artist_id is tags.mb_album_artist_id is None
    assert not any("musicbrainz" in key.casefold() for key in mutagen.File(path))


async def test_scan_concurrent_import(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    first = make_track("Initial/Album/first.flac", title="First", artist="Initial", album="Album")
    second = make_track("Concurrent/Shared/second.flac", title="Second", artist="Concurrent", album="Shared")
    third = make_track("Concurrent/Shared/third.flac", title="Third", artist="Concurrent", album="Shared")
    paths = [first, second, third]
    files = [(str(p.relative_to(MUSIC_DIR)), p.stat().st_mtime, p.stat().st_size) for p in paths]
    monkeypatch.setattr(scanner, "BATCH", 1)
    monkeypatch.setattr(scanner, "_walk", lambda root: files)
    boundary = asyncio.Event()
    imported = asyncio.Event()
    scanned = asyncio.Event()
    original_set_job = scanner._set_job
    original_load = scanner._Syncer.load
    loads = {}

    async def load(syncer: scanner._Syncer) -> None:
        loads[syncer] = loads.get(syncer, 0) + 1
        await original_load(syncer)

    async def set_job(id: uuid.UUID, **values: object) -> None:
        await original_set_job(id, **values)
        if values.get("progress") == 1 / 3:
            assert not scanner.library_lock.locked()
            boundary.set()
            await asyncio.wait_for(imported.wait(), timeout=3)

    monkeypatch.setattr(scanner._Syncer, "load", load)
    monkeypatch.setattr(scanner, "_set_job", set_job)
    async with SessionLocal() as db:
        job = Job(kind="library_scan", status="queued")
        db.add(job)
        await db.commit()
        job_id = job.id

    async def import_during_scan() -> None:
        await asyncio.wait_for(boundary.wait(), timeout=3)
        extra = make_track("Concurrent/Shared/imported.flac", title="Imported", artist="Concurrent", album="Shared")
        async with SessionLocal() as db:
            await import_file(db, str(extra.relative_to(MUSIC_DIR)))
            await import_file(db, str(third.relative_to(MUSIC_DIR)))
        assert not scanned.is_set()
        imported.set()

    scan_task = asyncio.create_task(scanner.run_scan(job_id))
    importer = asyncio.create_task(import_during_scan())
    try:
        await asyncio.wait_for(asyncio.gather(scan_task, importer), timeout=10)
        scanned.set()
    finally:
        for task in (scan_task, importer):
            if not task.done():
                task.cancel()
        await asyncio.gather(scan_task, importer, return_exceptions=True)
    async with SessionLocal() as db:
        job = await db.get(Job, job_id)
        assert job.status == "done", job.message
        tracks = list(await db.scalars(select(Track)))
        assert len(tracks) == 4 and len({t.path for t in tracks}) == 4
        artists = list(await db.scalars(select(Artist)))
        albums = list(await db.scalars(select(Album)))
        assert len(artists) == len(albums) == 2
    assert sorted(loads.values()) == [1, 1, 2]


async def test_deezer_transport(monkeypatch: pytest.MonkeyPatch) -> None:
    from app.services import deezer as deezer_module

    clock = SimpleNamespace(now=100.0)
    sleeps = []
    seen = []
    starts = []

    async def sleep(delay: float) -> None:
        sleeps.append(delay)
        clock.now += delay

    def respond(request: httpx.Request) -> httpx.Response:
        seen.append(request)
        starts.append(clock.now)
        path = request.url.path
        count = sum(r.url.path == path for r in seen)
        if path.endswith("quota") or path.endswith("retry") and count <= 3:
            return httpx.Response(200, json={"error": {"code": 4, "message": "quota"}})
        if path.endswith("missing"):
            return httpx.Response(200, json={"error": {"code": 800, "message": "missing"}})
        if path.endswith("api_error"):
            return httpx.Response(200, json={"error": {"code": 100, "message": "error"}})
        if path.endswith("http_error"):
            return httpx.Response(500)
        if path.endswith("http_missing"):
            return httpx.Response(404)
        if path.endswith("network_error"):
            raise httpx.ConnectError("connection failed", request=request)
        if path.endswith("json_error"):
            return httpx.Response(200, text="not JSON")
        return httpx.Response(200, json={"ok": True})

    original = httpx.AsyncClient

    def client(**kwargs: object) -> httpx.AsyncClient:
        assert kwargs == {"base_url": "https://api.deezer.com/", "timeout": 15}
        return original(transport=httpx.MockTransport(respond), **kwargs)

    monkeypatch.setattr(deezer_module, "time", SimpleNamespace(monotonic=lambda: clock.now))
    monkeypatch.setattr(deezer_module.asyncio, "sleep", sleep)
    monkeypatch.setattr(deezer_module.httpx, "AsyncClient", client)
    instance = DeezerClient()
    assert instance._client is None
    try:
        assert await instance._get("retry", q="test", limit=10) == {"ok": True}
        assert len(seen) == 4 and sleeps.count(1) == 3
        assert seen[0].url.host == "api.deezer.com"
        assert dict(seen[0].url.params) == {"q": "test", "limit": "10"}
        await instance._get("retry", limit=10, q="test")
        assert len(seen) == 4
        await instance._get("other", a=1, b=2)
        await instance._get("other", b=2, a=1)
        assert len(seen) == 5
        clock.now += 3601
        await instance._get("other", a=1, b=2)
        assert len(seen) == 6
        with pytest.raises(DeezerNotFound):
            await instance._get("missing")
        for path in ("quota", "api_error", "http_error", "http_missing", "network_error", "json_error"):
            with pytest.raises(DeezerError):
                await instance._get(path)
        assert sum(r.url.path.endswith("quota") for r in seen) == 4
        assert sleeps.count(1) == 6
        for index in range(2001):
            await instance._get("cache", index=index)
        assert len(instance._cache) == 2000
        assert ("cache", (("index", 0),)) not in instance._cache
        # At most 45 request starts in any 5 s window.
        assert all(starts[i + 45] - starts[i] >= 5 - 1e-9 for i in range(len(starts) - 45))
    finally:
        await instance._client.aclose()


async def test_deezer_methods(monkeypatch: pytest.MonkeyPatch) -> None:
    instance = DeezerClient()
    seen = []

    async def get(path: str, **params: object) -> dict:
        seen.append((path, params))
        return {"data": [{"id": 1}], "id": 2}

    monkeypatch.setattr(instance, "_get", get)
    for method, args, path, params in (
        (instance.search_tracks, ("q", 7), "search/track", {"q": "q", "limit": 7}),
        (instance.search_albums, ("q", 8), "search/album", {"q": "q", "limit": 8}),
        (instance.search_artists, ("q", 9), "search/artist", {"q": "q", "limit": 9}),
        (instance.album_tracks, ("2",), "album/2/tracks", {"limit": 500}),
        (instance.artist_top, ("3",), "artist/3/top", {"limit": 10}),
        (instance.artist_top, ("3", 8), "artist/3/top", {"limit": 8}),
        (instance.artist_albums, ("3",), "artist/3/albums", {"limit": 100}),
    ):
        assert await method(*args) == [{"id": 1}]
        assert seen[-1] == (path, params)
    for method, path in ((instance.track, "track/1"), (instance.album, "album/1"), (instance.artist, "artist/1")):
        assert (await method("1"))["id"] == 2
        assert seen[-1] == (path, {})


async def test_deezer_cover_fallback(
    meta: TrackMeta, cover: bytes, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    from app.services import tagger

    monkeypatch.setattr(get_settings(), "data_dir", tmp_path)
    meta = meta.model_copy(update={"deezer_album_id": "201", "cover_url": "https://example.test/xl.jpg"})
    seen = []

    def respond(request: httpx.Request) -> httpx.Response:
        seen.append(str(request.url))
        if request.url.host == "coverartarchive.org":
            return httpx.Response(404)
        return httpx.Response(200, content=cover)

    original = httpx.AsyncClient
    monkeypatch.setattr(
        tagger.httpx, "AsyncClient", lambda **kwargs: original(transport=httpx.MockTransport(respond), **kwargs)
    )
    # Deezer's standard artwork wins over the Cover Art Archive.
    assert await tagger.fetch_cover(meta) == cover
    assert seen == [meta.cover_url]
    assert (tmp_path / "caa" / "dz-201.jpg").read_bytes() == cover
    fallback = meta.model_copy(update={"mb_release_id": None, "mb_release_group_id": None})
    assert await tagger.fetch_cover(fallback) == cover and len(seen) == 1
    (tmp_path / "caa" / "dz-201.jpg").unlink()
    seen.clear()
    assert await tagger.fetch_cover(fallback) == cover and seen == [meta.cover_url]
    assert await tagger.fetch_cover(fallback.model_copy(update={"cover_url": None})) is None


async def test_duplicate_catalog_id(
    client: httpx.AsyncClient, env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    await client.patch("/api/admin/config", json={"downloads": {"auto_approve_requests": False}}, headers=env.admin)
    request = await post_request(client, env.user, "track", env.track)
    assert request["status"] == "pending_approval" and request["catalog_id"] == env.track

    async def unexpected(*args: object, **kwargs: object) -> None:
        raise AssertionError("Duplicate requests must not fetch catalog metadata")

    original_resolve_track = downloads.resolve_track
    monkeypatch.setattr(downloads, "resolve_track", unexpected)
    duplicate = await client.post("/api/requests", json={"kind": "track", "id": env.track}, headers=env.user)
    assert duplicate.status_code == 200 and duplicate.json()["id"] == request["id"]
    async with SessionLocal() as db:
        row = await db.get(DownloadRequest, uuid.UUID(request["id"]))
        row.catalog_id = "999"
        await db.commit()
    monkeypatch.setattr(downloads, "resolve_track", original_resolve_track)
    # Same canonical MB id with another Deezer id is a separate request.
    new = await post_request(client, env.user, "track", env.track)
    assert new["id"] != request["id"] and new["mb_id"] == request["mb_id"]
