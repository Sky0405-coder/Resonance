import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import httpx
import mutagen
import pytest
from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import Album, Artist, ImportBatch, ImportFile, Track, TrackLyrics
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
        return None

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
