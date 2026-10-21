import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import httpx
import mutagen
import pytest
from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.main import app
from app.models import (
    Album,
    Artist,
    ImportBatch,
    ImportFile,
    PlayEvent,
    Track,
    TrackLyrics,
    User,
)
from app.services import importer, lyrics
from app.services.deletion import delete_tracks
from app.services.musicbrainz import TrackMeta
from app.services.retag import apply_meta
from app.services.server_config import update_config
from app.services.tags import read_tags
from mutagen.id3 import USLT
from sqlalchemy import select

from tests.conftest import auth, make_track, register


def track_meta(**updates: object) -> TrackMeta:
    values = {key: None for key in TrackMeta.model_fields}
    values.update(title="Song", artist="Artist", album="Album", album_artist="Artist", track_no=1)
    values.update(updates)
    return TrackMeta.model_validate(values)


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("[1:02]a\n[01:02.1]b\n[01:02.12]c\n[01:02.123]d", [(62000, "a"), (62100, "b"), (62120, "c"), (62123, "d")]),
        ("[00:02][00:01.50]same\nuntimed\n[00:02]last", [(1500, "same"), (2000, "same"), (2000, "last")]),
        (
            "[ar:Artist]\n[ti:Title]\n[al:Album]\n[by:Me]\n[length:2:00]\n[offset:+500]\n[00:00.20]a\n[00:01]b",
            [(0, "a"), (500, "b")],
        ),
        ("[offset:-120]\n[00:01.234]a", [(1354, "a")]),
        ("[00:01]<00:01.00>Hello <00:01.50>world \t\r\n[00:02]", [(1000, "Hello world"), (2000, "")]),
        ("\n\nFirst  \r\n\nSecond\n\n", [(None, "First"), (None, ""), (None, "Second")]),
        ("[ar:Artist]\nFirst\n\n[ti:Title]\nLast", [(None, "First"), (None, ""), (None, "Last")]),
        ("", []),
    ],
)
def test_parse_lrc(text: str, expected: list[tuple[int | None, str]]) -> None:
    assert lyrics.parse_lrc(text) == expected


@pytest.mark.parametrize("extension", ["flac", "mp3", "m4a", "opus"])
def test_local_lyrics(extension: str) -> None:
    path = make_track(f"lyrics-local/song.{extension}")
    audio = mutagen.File(path)
    if extension == "mp3":
        audio.tags.add(USLT(encoding=3, lang="eng", desc="", text="Embedded"))
    else:
        audio["©lyr" if extension == "m4a" else "LYRICS"] = ["Embedded"]
    audio.save()
    assert lyrics.local_lyrics(path) == "Embedded"
    sidecar = path.with_suffix(".lrc")
    sidecar.write_bytes(b"\xef\xbb\xbf[00:01]Sidecar\xff")
    assert lyrics.local_lyrics(path) == "[00:01]Sidecar\ufffd"
    sidecar.unlink()


def test_local_lyrics_unreadable(tmp_path: Path) -> None:
    assert lyrics.local_lyrics(tmp_path / "missing.mp3") is None


@pytest.fixture
async def env(
    client: httpx.AsyncClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")

    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)

    await reset()
    settings = get_settings()
    monkeypatch.setattr(settings, "music_dir", tmp_path / "music")
    settings.music_dir.mkdir()
    admin = await register(client, "lyricsadmin")
    async with SessionLocal() as db:
        artist = Artist(name="Artist", name_key="artist")
        db.add(artist)
        await db.flush()
        album = Album(title="Album", title_key="album", artist_id=artist.id)
        db.add(album)
        await db.flush()
        track = Track(
            title="Song",
            path="song.flac",
            artist_id=artist.id,
            artist_credit="Artist feat. Guest",
            album_id=album.id,
            duration=120.4,
        )
        db.add(track)
        await db.commit()
    try:
        yield SimpleNamespace(
            client=client,
            headers=auth(admin["token"]),
            track=track,
            path=settings.music_dir / track.path,
            settings=settings,
        )
    finally:
        await reset()


async def test_api_local_and_permissions(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    def no_lookup(*args: object) -> None:
        pytest.fail("Local lyrics must not request LRCLIB")

    monkeypatch.setattr(lyrics, "lrclib_lookup", no_lookup)
    env.path.with_suffix(".lrc").write_text("[00:01]Local\n[00:02]Second")
    url = f"/api/tracks/{env.track.id}/lyrics"
    assert (await env.client.get(url)).status_code == 401
    response = await env.client.get(url, headers=env.headers)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "private, max-age=3600"
    assert response.json() == {
        "synced": True,
        "instrumental": False,
        "source": "file",
        "lines": [{"time_ms": 1000, "text": "Local"}, {"time_ms": 2000, "text": "Second"}],
    }
    async with SessionLocal() as db:
        assert await db.get(TrackLyrics, env.track.id) is None
    response = await env.client.get(f"/api/tracks/{uuid.uuid4()}/lyrics", headers=env.headers)
    assert response.status_code == 404
    await env.client.patch("/api/admin/config", json={"registration": {"mode": "public"}}, headers=env.headers)
    user = await register(env.client, "lyricsuser")
    assert (await env.client.get(url, headers=auth(user["token"]))).json()["source"] == "file"


@pytest.mark.parametrize(
    "data",
    [
        {"syncedLyrics": "[00:01]Online", "plainLyrics": "Online", "instrumental": False},
        {"plainLyrics": "First\n\nLast"},
        {"instrumental": True},
    ],
)
async def test_api_online_cache(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, data: dict) -> None:
    calls = []

    async def lookup(*args: object) -> dict:
        calls.append(args)
        return data

    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    url = f"/api/tracks/{env.track.id}/lyrics"
    first = await env.client.get(url, headers=env.headers)
    assert first.json()["source"] == "lrclib"
    assert first.json()["synced"] == bool(data.get("syncedLyrics"))
    assert first.json()["instrumental"] == bool(data.get("instrumental"))
    assert (await env.client.get(url, headers=env.headers)).json() == first.json()
    assert calls == [("Artist", "Song", "Album", 120.4)]
    async with SessionLocal() as db:
        row = await db.get(TrackLyrics, env.track.id)
        row.fetched_at = datetime.now(UTC) - timedelta(days=100)
        await db.commit()
    assert (await env.client.get(url, headers=env.headers)).json() == first.json()
    assert len(calls) == 1
    env.path.with_suffix(".lrc").write_text("Local overrides cache")
    assert (await env.client.get(url, headers=env.headers)).json()["source"] == "file"


async def test_api_none_retry(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    calls = 0

    async def lookup(*args: object) -> None:
        nonlocal calls
        calls += 1

    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    url = f"/api/tracks/{env.track.id}/lyrics"
    for _ in range(2):
        assert (await env.client.get(url, headers=env.headers)).json() == {
            "synced": False,
            "instrumental": False,
            "source": None,
            "lines": [],
        }
    assert calls == 1
    async with SessionLocal() as db:
        row = await db.get(TrackLyrics, env.track.id)
        assert row.source == "none"
        row.fetched_at = datetime.now(UTC) - timedelta(days=31)
        await db.commit()
    await env.client.get(url, headers=env.headers)
    assert calls == 2


async def test_api_error_and_disabled(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    calls = 0

    async def lookup(*args: object) -> None:
        nonlocal calls
        calls += 1
        raise lyrics.LyricsError("offline")

    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    for _ in range(2):
        assert (await env.client.get(f"/api/tracks/{env.track.id}/lyrics", headers=env.headers)).json()["lines"] == []
    assert calls == 2
    async with SessionLocal() as db:
        assert await db.get(TrackLyrics, env.track.id) is None
        await update_config(db, {"library": {"lyrics_online": False}})
    await env.client.get(f"/api/tracks/{env.track.id}/lyrics", headers=env.headers)
    assert calls == 2


async def add_track(db, env: SimpleNamespace, title: str, **values) -> Track:
    track = Track(
        title=title, path=f"{title}.flac", album_id=env.track.album_id, artist_id=env.track.artist_id,
        artist_credit="Artist", duration=120.4, **values,
    )
    db.add(track)
    await db.flush()
    return track


async def test_background_selection_order_and_expired_misses(env: SimpleNamespace, monkeypatch) -> None:
    now = datetime.now(UTC)
    async with SessionLocal() as db:
        user = await db.scalar(select(User))
        (await db.get(Track, env.track.id)).created_at = now - timedelta(days=20)
        recent = await add_track(db, env, "recent", created_at=now - timedelta(days=10))
        played = await add_track(db, env, "played", created_at=now)
        await add_track(db, env, "new", created_at=now)
        await add_track(db, env, "old", created_at=now - timedelta(days=1))
        stale = await add_track(db, env, "stale", created_at=now)
        stale_played = await add_track(db, env, "stale-played", created_at=now - timedelta(days=40))
        fresh = await add_track(db, env, "fresh")
        cached = await add_track(db, env, "cached")
        await add_track(db, env, "temporary", is_temporary=True)
        db.add_all([
            PlayEvent(user_id=user.id, track_id=recent.id, played_at=now - timedelta(days=50)),
            PlayEvent(user_id=user.id, track_id=recent.id, played_at=now - timedelta(hours=1)),
            PlayEvent(user_id=user.id, track_id=played.id, played_at=now - timedelta(days=1)),
            PlayEvent(user_id=user.id, track_id=stale_played.id, played_at=now),
            TrackLyrics(track_id=stale.id, source="none", fetched_at=now - timedelta(days=31)),
            TrackLyrics(track_id=stale_played.id, source="none", fetched_at=now - timedelta(days=31)),
            TrackLyrics(track_id=fresh.id, source="none", fetched_at=now - timedelta(days=29)),
            TrackLyrics(track_id=cached.id, source="lrclib", plain="Cached", fetched_at=now - timedelta(days=60)),
        ])
        await db.commit()
    lookup = AsyncMock(return_value={"syncedLyrics": "[00:01]Fetched", "plainLyrics": "Fetched"})
    sleep = AsyncMock()
    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    monkeypatch.setattr(lyrics.asyncio, "sleep", sleep)
    # Background fetching fills the remote cache even for songs with a local sidecar.
    env.path.with_suffix(".lrc").write_text("[00:01]Local")
    await lyrics.run_once()
    assert [call.args[1] for call in lookup.await_args_list] == [
        "recent", "played", "new", "old", "Song", "stale-played", "stale",
    ]
    assert [call.args for call in sleep.await_args_list] == [(3,)] * 7
    async with SessionLocal() as db:
        row = await db.get(TrackLyrics, stale.id)
        assert row.source == "lrclib" and row.synced == "[00:01]Fetched" and row.fetched_at > now
    await lyrics.run_once()
    assert lookup.await_count == 7
    env.path.with_suffix(".lrc").unlink()
    response = await env.client.get(f"/api/tracks/{env.track.id}/lyrics", headers=env.headers)
    assert response.json()["synced"] and lookup.await_count == 7


async def test_background_batch_limit_and_negative_cache(env: SimpleNamespace, monkeypatch) -> None:
    async with SessionLocal() as db:
        for i in range(101):
            await add_track(db, env, f"batch-{i}")
        await db.commit()
    lookup = AsyncMock(return_value=None)
    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    monkeypatch.setattr(lyrics.asyncio, "sleep", AsyncMock())
    await lyrics.run_once()
    assert lookup.await_count == 100
    async with SessionLocal() as db:
        rows = list(await db.scalars(select(TrackLyrics)))
        assert len(rows) == 100 and all(row.source == "none" for row in rows)
    await lyrics.run_once()
    assert lookup.await_count == 102
    await lyrics.run_once()
    assert lookup.await_count == 102


@pytest.mark.parametrize("message", ["LRCLIB: HTTP 429", "offline"])
async def test_background_errors_abort_batch_and_back_off(env: SimpleNamespace, monkeypatch, message: str) -> None:
    old = datetime.now(UTC) - timedelta(days=31)
    async with SessionLocal() as db:
        stale = await add_track(db, env, "stale")
        db.add(TrackLyrics(track_id=stale.id, source="none", fetched_at=old))
        await db.commit()
    lookup = AsyncMock(side_effect=[lyrics.LyricsError(message), {"plainLyrics": "Found"}, None])
    delays = []

    async def sleep(seconds):
        delays.append(seconds)
        if seconds == 600:
            assert lookup.await_count == 1
            async with SessionLocal() as db:
                assert await db.get(TrackLyrics, env.track.id) is None
                assert (await db.get(TrackLyrics, stale.id)).fetched_at == old
        if seconds == 60 and 600 in delays:
            raise asyncio.CancelledError

    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    monkeypatch.setattr(lyrics.asyncio, "sleep", sleep)
    with pytest.raises(asyncio.CancelledError):
        await lyrics._loop()
    assert delays == [60, 3, 600, 3, 3, 60]
    assert [call.args[1] for call in lookup.await_args_list] == ["Song", "Song", "stale"]


async def test_background_retry_error_preserves_expired_miss(env: SimpleNamespace, monkeypatch) -> None:
    old = datetime.now(UTC) - timedelta(days=31)
    async with SessionLocal() as db:
        db.add(TrackLyrics(track_id=env.track.id, source="none", fetched_at=old))
        await db.commit()
    monkeypatch.setattr(lyrics, "lrclib_lookup", AsyncMock(side_effect=lyrics.LyricsError("offline")))
    monkeypatch.setattr(lyrics.asyncio, "sleep", AsyncMock())
    with pytest.raises(lyrics.LyricsError):
        await lyrics.run_once()
    async with SessionLocal() as db:
        row = await db.get(TrackLyrics, env.track.id)
        assert row.source == "none" and row.fetched_at == old


@pytest.mark.parametrize("section,field", [("lyrics", "background_fetch"), ("library", "lyrics_online")])
async def test_background_config_switch(env: SimpleNamespace, monkeypatch, section: str, field: str) -> None:
    config = (await env.client.get("/api/admin/config", headers=env.headers)).json()
    assert config["lyrics"]["background_fetch"] is True
    response = await env.client.patch("/api/admin/config", json={section: {field: False}}, headers=env.headers)
    assert response.status_code == 200 and response.json()[section][field] is False
    lookup = AsyncMock(return_value={"plainLyrics": "On demand"})
    sleep = AsyncMock()
    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    monkeypatch.setattr(lyrics.asyncio, "sleep", sleep)
    await lyrics.run_once()
    lookup.assert_not_awaited()
    sleep.assert_not_awaited()
    async with SessionLocal() as db:
        assert await db.get(TrackLyrics, env.track.id) is None
    if section == "lyrics":
        response = await env.client.get(f"/api/tracks/{env.track.id}/lyrics", headers=env.headers)
        assert response.json()["source"] == "lrclib"
    else:
        await env.client.patch("/api/admin/config", json={section: {field: True}}, headers=env.headers)
        await lyrics.run_once()
    assert lookup.await_count == 1


async def test_background_switch_stops_active_batch(env: SimpleNamespace, monkeypatch) -> None:
    async with SessionLocal() as db:
        await add_track(db, env, "second")
        await db.commit()

    async def lookup(*args):
        async with SessionLocal() as db:
            await update_config(db, {"lyrics": {"background_fetch": False}})

    fetch = AsyncMock(side_effect=lookup)
    monkeypatch.setattr(lyrics, "lrclib_lookup", fetch)
    monkeypatch.setattr(lyrics.asyncio, "sleep", AsyncMock())
    await lyrics.run_once()
    assert fetch.await_count == 1


async def test_lyrics_status_counts_permanent_tracks_and_requires_admin(env: SimpleNamespace, monkeypatch) -> None:
    url = "/api/admin/lyrics/status"
    assert (await env.client.get(url)).status_code == 401
    response = await env.client.get(url, headers=env.headers)
    assert response.json() == {"total": 1, "synced": 0, "plain_only": 0, "instrumental": 0, "none": 0, "missing": 1}
    invite = (await env.client.post("/api/admin/invites", json={}, headers=env.headers)).json()["token"]
    user = await register(env.client, "lyrics-listener", invite)
    assert (await env.client.get(url, headers=auth(user["token"]))).status_code == 403
    async with SessionLocal() as db:
        for title in ("synced", "plain", "instrumental", "none"):
            track = await add_track(db, env, title)
            data = {
                "synced": {"syncedLyrics": "[00:01]Synced", "plainLyrics": "Synced"},
                "plain": {"syncedLyrics": "", "plainLyrics": "Plain"},
                "instrumental": {"instrumental": True},
                "none": None,
            }[title]
            monkeypatch.setattr(lyrics, "lrclib_lookup", AsyncMock(return_value=data))
            await lyrics.fetch_online_lyrics(db, track)
        for title, values in (
            ("temp-synced", {"synced": "[00:01]Temporary", "plain": "Temporary", "source": "lrclib"}),
            ("temp-instrumental", {"instrumental": True, "source": "lrclib"}),
            ("temp-none", {"source": "none"}),
            ("temp-missing", None),
        ):
            track = await add_track(db, env, title, is_temporary=True)
            if values:
                db.add(TrackLyrics(track_id=track.id, **values))
        await db.commit()
    lookup = AsyncMock(side_effect=AssertionError("Status must not fetch lyrics"))
    monkeypatch.setattr(lyrics, "lrclib_lookup", lookup)
    response = await env.client.get(url, headers=env.headers)
    assert response.status_code == 200
    assert response.json() == {"total": 5, "synced": 1, "plain_only": 1, "instrumental": 1, "none": 1, "missing": 1}
    lookup.assert_not_awaited()
    async with SessionLocal() as db:
        await delete_tracks(db, list(await db.scalars(select(Track.id))))
    assert (await env.client.get(url, headers=env.headers)).json() == {
        "total": 0, "synced": 0, "plain_only": 0, "instrumental": 0, "none": 0, "missing": 0,
    }


async def test_background_lifecycle(env: SimpleNamespace) -> None:
    await lyrics.start()
    task = lyrics._loop_task
    await lyrics.start()
    assert lyrics._loop_task is task
    await lyrics.stop()
    assert task.cancelled() and lyrics._loop_task is None
    await lyrics.stop()
    async with app.router.lifespan_context(app):
        assert lyrics._loop_task is not None and not lyrics._loop_task.done()
    assert lyrics._loop_task is None


@pytest.mark.parametrize("difference,found", [(3, True), (-3, True), (3.01, False)])
async def test_lrclib_search(monkeypatch: pytest.MonkeyPatch, difference: float, found: bool) -> None:
    requests = []

    async def get(client: httpx.AsyncClient, url: str, **kwargs: object) -> httpx.Response:
        requests.append((url, kwargs["params"]))
        if url == "get":
            assert client.headers["User-Agent"] == "Resonance/0.1.0 (https://github.com/Sky0405-coder/Resonance)"
            assert client.timeout.read == 10
            return httpx.Response(404)
        return httpx.Response(200, json=[{"duration": 200}, {"duration": 120.4 + difference, "plainLyrics": "Match"}])

    monkeypatch.setattr(lyrics, "_client", None)
    monkeypatch.setattr(httpx.AsyncClient, "get", get)
    result = await lyrics.lrclib_lookup("Artist", "Song", "Album", 120.4)
    assert bool(result) == found
    assert requests == [
        ("get", {"artist_name": "Artist", "track_name": "Song", "album_name": "Album", "duration": 120}),
        ("search", {"artist_name": "Artist", "track_name": "Song"}),
    ]


@pytest.mark.parametrize("status", [200, 429, 503, 0])
async def test_lrclib_transport(monkeypatch: pytest.MonkeyPatch, status: int) -> None:
    async def get(*args: object, **kwargs: object) -> httpx.Response:
        if status == 0:
            raise httpx.ConnectError("offline")
        return httpx.Response(status, json={"plainLyrics": "Online"})

    monkeypatch.setattr(httpx.AsyncClient, "get", get)
    if status == 200:
        assert await lyrics.lrclib_lookup("A", "T", "B", 100) == {"plainLyrics": "Online"}
    else:
        with pytest.raises(lyrics.LyricsError):
            await lyrics.lrclib_lookup("A", "T", "B", 100)


@pytest.mark.parametrize("mode,extension", [("move", ".lrc"), ("copy", ".LRC"), ("inplace", ".LrC")])
async def test_import_sidecar(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, mode: str, extension: str) -> None:
    source = make_track("lyrics-import/source.flac", title="Song", artist="Artist", album="Album")
    sidecar = source.with_suffix(extension)
    sidecar.write_text("[00:01]Imported")
    meta = track_meta()
    async with SessionLocal() as db:
        batch = ImportBatch(kind="import", mode=mode, source_dir=str(source.parent), status="running")
        row = ImportFile(
            path=source.name, group_key="Album", status="identified", method="tags", meta=meta.model_dump()
        )
        assert await importer._place(db, batch, row, read_tags(source))
        target = env.settings.music_dir / row.target
        assert target.with_suffix(".lrc").read_text() == "[00:01]Imported"
        assert sidecar.exists() == (mode == "copy")
        if mode == "copy":
            sidecar.write_text("Duplicate")
            assert not await importer._place(db, batch, row, read_tags(source))
            assert target.with_suffix(".lrc").read_text() == "[00:01]Imported"


async def test_delete_sidecar_and_cache(env: SimpleNamespace) -> None:
    env.path.write_bytes(b"audio")
    env.path.with_suffix(".lrc").write_text("Delete me")
    sibling = env.path.with_name("other.flac")
    sibling.write_bytes(b"keep")
    async with SessionLocal() as db:
        db.add(TrackLyrics(track_id=env.track.id, source="none"))
        await db.commit()
        await delete_tracks(db, [env.track.id])
        assert await db.scalar(select(TrackLyrics)) is None
    assert not env.path.exists()
    assert not env.path.with_suffix(".lrc").exists()
    assert sibling.exists()


async def test_retag_moves_sidecar(env: SimpleNamespace) -> None:
    source = make_track("lyrics-retag/source.flac", title="Song", artist="Artist", album="Album")
    env.path.write_bytes(source.read_bytes())
    env.path.with_suffix(".lrc").write_text("[00:01]Relocated")
    async with SessionLocal() as db:
        track = await db.get(Track, env.track.id)
        result = await apply_meta(db, track, track_meta(title="New", album="New Album"), None)
        assert (env.settings.music_dir / result.path).with_suffix(".lrc").read_text() == "[00:01]Relocated"
    assert not env.path.with_suffix(".lrc").exists()
