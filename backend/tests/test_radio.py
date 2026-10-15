import asyncio
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.main import app
from app.models import (
    Album,
    Artist,
    DownloadItem,
    DownloadRequest,
    Playlist,
    PlaylistEntry,
    PlaylistShare,
    RadioPending,
    Track,
    TrackLike,
    User,
)
from app.services import downloads, radio
from app.services.deezer import DeezerClient, DeezerError, deezer
from app.services.matching import name_key
from app.services.resolve import meta_from_deezer
from app.services.server_config import RadioConfig, update_config
from tests.conftest import auth, register


def song(id: int, title: str, artist: str = "Related", **extra: object) -> dict:
    return {"id": id, "title": title, "artist": {"id": 2, "name": artist}, **extra}


@pytest.fixture
async def env(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")
    await radio.stop()

    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)

    await reset()
    monkeypatch.setattr(get_settings(), "music_dir", tmp_path / "music")
    monkeypatch.setattr(get_settings(), "data_dir", tmp_path / "data")
    admin = await register(client, "admin")
    response = await client.patch(
        "/api/admin/config", json={"registration": {"mode": "public"}}, headers=auth(admin["token"])
    )
    assert response.status_code == 200
    user = await register(client, "radio-user")
    other = await register(client, "other")
    state = SimpleNamespace(
        client=client,
        headers=auth(user["token"]),
        other_headers=auth(other["token"]),
        user_id=uuid.UUID(user["user"]["id"]),
        other_id=uuid.UUID(other["user"]["id"]),
        radio=[],
        related=[],
        tops={},
        calls=[],
        requests=[],
        request_errors={},
        isrc_track={"artist": {"id": 1}},
        artists=[{"id": 99, "name": "Wrong"}, {"id": 1, "name": "  SEED   Artist "}],
        failures=set(),
    )

    async def call(method: str, *args: object) -> None:
        state.calls.append((method, *args))
        if method in state.failures:
            raise DeezerError("offline")

    async def by_isrc(isrc: str) -> dict | None:
        await call("isrc", isrc)
        return state.isrc_track

    async def artists(q: str, limit: int) -> list[dict]:
        await call("search", q, limit)
        return state.artists

    async def artist_radio(id: str) -> list[dict]:
        await call("radio", id)
        return state.radio

    async def related(id: str, limit: int) -> list[dict]:
        await call("related", id, limit)
        return state.related

    async def top(id: str, limit: int) -> list[dict]:
        await call("top", id, limit)
        return state.tops.get(id, [])

    async def request(
        db: AsyncSession, user: User, kind: str, id: str, temporary: bool, *, radio: bool = False
    ) -> SimpleNamespace:
        state.requests.append((user.id, kind, id, temporary, radio))
        if id in state.request_errors:
            raise HTTPException(state.request_errors[id], "Fehler")
        await db.commit()
        return SimpleNamespace(id=uuid.uuid4())

    monkeypatch.setattr(deezer, "track_by_isrc", by_isrc)
    monkeypatch.setattr(deezer, "search_artists", artists)
    monkeypatch.setattr(deezer, "artist_radio", artist_radio)
    monkeypatch.setattr(deezer, "artist_related", related)
    monkeypatch.setattr(deezer, "artist_top", top)
    monkeypatch.setattr(radio, "create_request", request)
    try:
        yield state
    finally:
        await radio.stop()
        await reset()


async def library_track(
    db: AsyncSession,
    title: str = "Seed",
    *,
    artist_name: str = "Seed Artist",
    album: Album | None = None,
    temporary: bool = False,
    created_at: datetime | None = None,
    isrc: str | None = None,
) -> Track:
    artist = await db.scalar(select(Artist).where(Artist.name_key == name_key(artist_name)))
    if artist is None:
        artist = Artist(name=artist_name, name_key=name_key(artist_name))
        db.add(artist)
        await db.flush()
    if album is None:
        album = await db.scalar(select(Album).where(Album.artist_id == artist.id, Album.title_key == "seed album"))
        if album is None:
            album = Album(title="Seed Album", title_key="seed album", artist_id=artist.id)
            db.add(album)
            await db.flush()
    track = Track(
        title=title,
        artist_id=artist.id,
        album_id=album.id,
        artist_credit=f"{artist_name} feat. Guest",
        path=f"{uuid.uuid4()}.flac",
        is_temporary=temporary,
        isrc=isrc,
        created_at=created_at or datetime.now(UTC),
    )
    db.add(track)
    await db.flush()
    path = get_settings().music_dir / track.path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"audio")
    return track


async def start_radio(env: SimpleNamespace, id: uuid.UUID, seed_type: str = "track") -> dict:
    response = await env.client.post("/api/radio", json={"seed_type": seed_type, "id": str(id)}, headers=env.headers)
    assert response.status_code == 200, response.text
    return response.json()


async def entry_ids(db: AsyncSession, playlist_id: uuid.UUID) -> list[uuid.UUID]:
    return list(
        await db.scalars(
            select(PlaylistEntry.track_id)
            .where(PlaylistEntry.playlist_id == playlist_id)
            .order_by(PlaylistEntry.position)
        )
    )


async def test_track_radio_matching_fill_downloads_and_order(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        seed = await library_track(db, isrc="SEEDISRC")
        seed_fill = await library_track(db, "Own fill", album=await db.get(Album, seed.album_id))
        matched = await library_track(db, "Matched", artist_name="Related", temporary=True)
        fill = await library_track(
            db, "Library fill", artist_name="Related", album=await db.get(Album, matched.album_id)
        )
        await update_config(db, {"radio": {"max_downloads_per_radio": 1}})
    env.radio = [song(10, "Matched"), song(11, "Missing"), song(12, "Also missing")]
    result = await start_radio(env, seed.id)
    assert result["requested"] == 1
    assert result["playlist"]["name"] == "Seed Radio"
    assert result["playlist"]["kind"] == "radio"
    assert result["playlist"]["is_public"] is False
    playlist_id = uuid.UUID(result["playlist"]["id"])
    async with SessionLocal() as db:
        ids = await entry_ids(db, playlist_id)
        assert ids[0] == seed.id
        assert set(ids) == {seed.id, seed_fill.id, matched.id, fill.id}
        assert len(ids) == len(set(ids))
        assert list(
            await db.scalars(
                select(PlaylistEntry.position)
                .where(PlaylistEntry.playlist_id == playlist_id)
                .order_by(PlaylistEntry.position)
            )
        ) == list(range(1, len(ids) + 1))
        assert (await db.get(Playlist, playlist_id)).radio_seed == f"track:{seed.id}"
        assert (await db.get(Track, matched.id)).is_temporary
        pending = list(await db.scalars(select(RadioPending)))
        assert [(row.playlist_id, row.deezer_id) for row in pending] == [(playlist_id, "11")]
    assert env.requests == [(env.user_id, "track", "11", True, True)]
    assert ("isrc", "SEEDISRC") in env.calls
    assert not any(call[0] == "search" for call in env.calls)


async def test_candidate_round_robin_deduplication_artist_limit_and_related_limit(env: SimpleNamespace) -> None:
    env.radio = [song(1, "One", "A"), song(2, "Two", "A"), song(3, "Three", "A"), song(4, "Four", "A")]
    env.tops["1"] = [song(1, "Same id", "Other"), song(20, "  ONE ", " a "), song(21, "Own", "B")]
    env.related = [{"id": id} for id in range(2, 12)]
    env.tops.update({str(id): [song(100 + id, f"Top {id}", f"Artist {id}")] for id in range(2, 12)})
    candidates = await radio._candidates("1")
    assert [track["id"] for track in candidates] == [1, *range(102, 110), 2, 3, 21]
    assert ("radio", "1") in env.calls and ("related", "1", 10) in env.calls
    assert all(("top", str(id), 5) in env.calls for id in range(2, 10))
    assert ("top", "10", 5) not in env.calls
    assert ("top", "1", 10) in env.calls


async def test_candidate_cap_and_partial_failure(env: SimpleNamespace) -> None:
    env.radio = [song(id, str(id), str(id)) for id in range(100)]
    env.failures.add("related")
    assert [track["id"] for track in await radio._candidates("1")] == list(range(80))


async def test_seed_lookup_fallback_uses_primary_artist_and_exact_name(env: SimpleNamespace) -> None:
    env.isrc_track = None
    async with SessionLocal() as db:
        seed = await library_track(db, isrc="UNKNOWN")
        await db.commit()
    await start_radio(env, seed.id)
    assert ("search", "Seed Artist", 5) in env.calls
    assert ("radio", "1") in env.calls


@pytest.mark.parametrize("failure", ["isrc", "search", "radio", "no_match"])
async def test_deezer_failure_or_missing_artist_uses_library_only(env: SimpleNamespace, failure: str) -> None:
    async with SessionLocal() as db:
        seed = await library_track(db, isrc="SEEDISRC" if failure == "isrc" else None)
        fill = await library_track(db, "Library", album=await db.get(Album, seed.album_id))
        await db.commit()
    if failure == "no_match":
        env.artists = [{"id": 99, "name": "Wrong"}]
    else:
        env.failures.add(failure)
    result = await start_radio(env, seed.id)
    async with SessionLocal() as db:
        assert await entry_ids(db, uuid.UUID(result["playlist"]["id"])) == [seed.id, fill.id]
    assert result["requested"] == 0 and env.requests == []


async def test_reuse_updates_last_use_and_expired_radio_is_rebuilt(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        seed = await library_track(db)
        await db.commit()
    env.radio = [song(1, "Missing")]
    first = await start_radio(env, seed.id)
    playlist_id = uuid.UUID(first["playlist"]["id"])
    earlier = datetime.now(UTC) - timedelta(hours=2)
    async with SessionLocal() as db:
        playlist = await db.get(Playlist, playlist_id)
        playlist.last_used_at = earlier
        await db.commit()
    env.calls.clear()
    again = await start_radio(env, seed.id)
    assert again["playlist"]["id"] == str(playlist_id) and again["requested"] == 0
    assert env.calls == [] and len(env.requests) == 1
    async with SessionLocal() as db:
        playlist = await db.get(Playlist, playlist_id)
        assert playlist.last_used_at > earlier
        playlist.created_at = datetime.now(UTC) - timedelta(hours=25)
        await db.commit()
    rebuilt = await start_radio(env, seed.id)
    assert rebuilt["playlist"]["id"] != str(playlist_id)
    async with SessionLocal() as db:
        assert await db.get(Playlist, playlist_id) is None
        assert await db.scalar(select(RadioPending.id).where(RadioPending.playlist_id == playlist_id)) is None
        assert await db.scalar(select(PlaylistEntry.id).where(PlaylistEntry.playlist_id == playlist_id)) is None


@pytest.mark.parametrize("config", [{"auto_download_enabled": False}, {"max_downloads_per_radio": 0}])
async def test_downloads_can_be_disabled(env: SimpleNamespace, config: dict) -> None:
    async with SessionLocal() as db:
        seed = await library_track(db)
        await update_config(db, {"radio": config})
    env.radio = [song(1, "Missing")]
    result = await start_radio(env, seed.id)
    assert result["requested"] == 0 and env.requests == []
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(RadioPending)) == 0


async def test_download_errors_skip_single_tracks_and_stop_at_daily_limit(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        seed = await library_track(db)
        await update_config(db, {"radio": {"temporary_tracks_enabled": False}})
    env.radio = [song(id, f"Missing {id}", f"Artist {id}") for id in range(1, 6)]
    env.request_errors = {1: 404, 3: 429}
    env.request_errors = {str(id): status for id, status in env.request_errors.items()}
    result = await start_radio(env, seed.id)
    assert result["requested"] == 1
    assert [(request[2], request[3], request[4]) for request in env.requests] == [
        ("1", False, True),
        ("2", False, True),
        ("3", False, True),
    ]
    async with SessionLocal() as db:
        assert list(await db.scalars(select(RadioPending.deezer_id))) == ["2"]


async def test_album_radio_starts_with_up_to_three_album_tracks(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        first = await library_track(db)
        album = await db.get(Album, first.album_id)
        tracks = [first, *[await library_track(db, f"Album {i}", album=album) for i in range(1, 5)]]
        other = await library_track(db, "Related", artist_name="Related")
        await db.commit()
    env.radio = [song(10, "Related")]
    result = await start_radio(env, album.id, "album")
    assert result["playlist"]["name"] == "Seed Album Radio"
    async with SessionLocal() as db:
        ids = await entry_ids(db, uuid.UUID(result["playlist"]["id"]))
        assert len(set(ids[:3])) == 3
        assert set(ids[:3]) <= {track.id for track in tracks}
        assert {track.id for track in tracks} | {other.id} == set(ids)
    assert ("search", "Seed Artist", 5) in env.calls


async def test_library_only_seed_and_empty_album_fallback(env: SimpleNamespace) -> None:
    env.artists = []
    async with SessionLocal() as db:
        seed = await library_track(db)
        empty = Album(title="Empty", title_key="empty", artist_id=seed.artist_id)
        db.add(empty)
        await db.commit()
    result = await start_radio(env, seed.id)
    async with SessionLocal() as db:
        assert await entry_ids(db, uuid.UUID(result["playlist"]["id"])) == [seed.id]
    result = await start_radio(env, empty.id, "album")
    async with SessionLocal() as db:
        assert await entry_ids(db, uuid.UUID(result["playlist"]["id"])) == [seed.id]


async def test_shuffle_uses_specified_seed(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    async with SessionLocal() as db:
        seed = await library_track(db)
        await library_track(db, "Other", album=await db.get(Album, seed.album_id))
        await db.commit()
    actual = radio.random.Random
    seeds: list[str] = []

    def random(value: str) -> object:
        seeds.append(value)
        return actual(value)

    monkeypatch.setattr(radio.random, "Random", random)
    await start_radio(env, seed.id)
    assert seeds == [f"{env.user_id}:track:{seed.id}:{date.today()}"]


async def test_pending_resolution_newest_duplicates_expiry_and_keep(env: SimpleNamespace) -> None:
    old = datetime.now(UTC) - timedelta(days=8)
    async with SessionLocal() as db:
        seed = await library_track(db)
        downloaded = await library_track(db, "Downloaded", temporary=True)
        previous = await library_track(db, "Previous", temporary=True)
        playlist = Playlist(owner_id=env.user_id, name="Radio", kind="radio", radio_seed=f"track:{seed.id}")
        request = DownloadRequest(user_id=env.user_id, kind="track", title="Downloaded", artist="Artist", status="done")
        db.add_all([playlist, request])
        await db.flush()
        db.add_all(
            [
                PlaylistEntry(playlist_id=playlist.id, track_id=seed.id, position=4),
                DownloadItem(
                    request_id=request.id,
                    position=0,
                    title="Previous",
                    artist="Artist",
                    status="done",
                    meta={"deezer_track_id": "1"},
                    track_id=previous.id,
                    updated_at=old,
                ),
                DownloadItem(
                    request_id=request.id,
                    position=1,
                    title="Downloaded",
                    artist="Artist",
                    status="done",
                    meta={"deezer_track_id": "1"},
                    track_id=downloaded.id,
                ),
                DownloadItem(
                    request_id=request.id,
                    position=2,
                    title="Exists",
                    artist="Artist",
                    status="exists",
                    meta={"deezer_track_id": "2"},
                    track_id=seed.id,
                ),
                DownloadItem(
                    request_id=request.id,
                    position=3,
                    title="Expired",
                    artist="Artist",
                    status="done",
                    meta={"deezer_track_id": "3"},
                    track_id=previous.id,
                ),
                RadioPending(playlist_id=playlist.id, deezer_id="1"),
                RadioPending(playlist_id=playlist.id, deezer_id="1"),
                RadioPending(playlist_id=playlist.id, deezer_id="2"),
                RadioPending(playlist_id=playlist.id, deezer_id="3", created_at=old),
                RadioPending(playlist_id=playlist.id, deezer_id="4"),
            ]
        )
        await db.commit()
        assert await radio.resolve_radio_pending(db) == 3
        assert await entry_ids(db, playlist.id) == [seed.id, downloaded.id]
        assert await db.scalar(select(PlaylistEntry.position).where(PlaylistEntry.track_id == downloaded.id)) == 5
        assert list(await db.scalars(select(RadioPending.deezer_id))) == ["4"]
        assert (await db.get(Track, downloaded.id)).is_temporary
    response = await env.client.post(f"/api/playlists/{playlist.id}/keep", headers=env.other_headers)
    assert response.status_code == 404
    response = await env.client.post(f"/api/playlists/{playlist.id}/keep", headers=env.headers)
    assert response.status_code == 200 and response.json()["kind"] == "user"
    async with SessionLocal() as db:
        assert (await db.get(Playlist, playlist.id)).radio_seed is None
        assert not (await db.get(Track, downloaded.id)).is_temporary
        assert (await db.get(Track, previous.id)).is_temporary
        assert await db.scalar(select(RadioPending.id)) is None
    response = await env.client.post(f"/api/playlists/{playlist.id}/keep", headers=env.headers)
    assert response.status_code == 400 and response.json()["detail"] == "Keine Radio-Playlist"


@pytest.mark.parametrize("forever", [False, True])
async def test_cleanup_radios_temporary_tracks_and_protection(env: SimpleNamespace, forever: bool) -> None:
    now = datetime.now(UTC)
    old = now - timedelta(days=40)
    async with SessionLocal() as db:
        deleted = await library_track(db, "Deleted", temporary=True, created_at=old)
        radio_only = await library_track(db, "Radio only", temporary=True, created_at=old)
        liked = await library_track(db, "Liked", temporary=True, created_at=old)
        saved = await library_track(db, "Saved", temporary=True, created_at=old)
        recent = await library_track(db, "Recent", temporary=True)
        permanent = await library_track(db, "Permanent", created_at=old)
        expired = Playlist(owner_id=env.user_id, name="Expired", kind="radio", last_used_at=old)
        fallback = Playlist(owner_id=env.user_id, name="Fallback", kind="radio", created_at=old)
        active = Playlist(owner_id=env.user_id, name="Active", kind="radio", created_at=old, last_used_at=now)
        user_playlist = Playlist(owner_id=env.user_id, name="User", created_at=old)
        db.add_all([expired, fallback, active, user_playlist])
        await db.flush()
        db.add_all(
            [
                PlaylistEntry(playlist_id=active.id, track_id=radio_only.id, position=1),
                PlaylistEntry(playlist_id=user_playlist.id, track_id=saved.id, position=1),
                TrackLike(user_id=env.other_id, track_id=liked.id),
                RadioPending(playlist_id=expired.id, deezer_id="10"),
            ]
        )
        await update_config(db, {"radio": {"playlist_retention_days": 0 if forever else 30}})
        assert await radio.cleanup(db) == (0 if forever else 2, 2)
    async with SessionLocal() as db:
        for track in (deleted, radio_only):
            assert await db.get(Track, track.id) is None
            assert not (get_settings().music_dir / track.path).exists()
        for track in (liked, saved, recent, permanent):
            assert await db.get(Track, track.id) is not None
            assert (get_settings().music_dir / track.path).exists()
        assert (await db.get(Playlist, expired.id) is not None) is forever
        assert (await db.get(Playlist, fallback.id) is not None) is forever
        assert await db.get(Playlist, active.id) is not None
        assert await db.get(Playlist, user_playlist.id) is not None
        assert await db.scalar(select(func.count()).select_from(RadioPending)) == int(forever)
        assert await radio.cleanup(db) == (0, 0)


async def test_radio_visibility_sharing_home_and_track_permanence(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        temporary = await library_track(db, temporary=True)
        playlist = Playlist(owner_id=env.user_id, kind="radio", name="Radio", is_public=True)
        normal = Playlist(owner_id=env.user_id, name="Normal")
        db.add_all([playlist, normal])
        await db.flush()
        db.add(PlaylistShare(playlist_id=playlist.id, user_id=env.other_id))
        await db.commit()
    response = await env.client.get(f"/api/playlists/{playlist.id}", headers=env.other_headers)
    assert response.status_code == 404
    response = await env.client.get("/api/playlists", headers=env.other_headers)
    assert str(playlist.id) not in {row["id"] for row in response.json()}
    response = await env.client.get("/api/playlists", headers=env.headers)
    assert {row["kind"] for row in response.json()} == {"radio", "user"}
    response = await env.client.get("/api/home", headers=env.headers)
    assert [row["id"] for row in response.json()["playlists"]] == [str(normal.id)]
    for method, suffix, body in (
        ("patch", "", {"is_public": True}),
        ("put", "/shares", {"user_ids": [str(env.other_id)]}),
        ("put", "/shares", {"user_ids": []}),
    ):
        response = await getattr(env.client, method)(
            f"/api/playlists/{playlist.id}{suffix}", json=body, headers=env.headers
        )
        assert (
            response.status_code == 400 and response.json()["detail"] == "Radios und Mixe können nicht geteilt werden"
        )
    response = await env.client.patch(
        f"/api/playlists/{playlist.id}", json={"name": "Renamed", "is_public": False}, headers=env.headers
    )
    assert response.status_code == 200
    for row, expected in ((playlist, True), (normal, False)):
        response = await env.client.post(
            f"/api/playlists/{row.id}/tracks", json={"track_ids": [str(temporary.id)]}, headers=env.headers
        )
        assert response.status_code == 204
        async with SessionLocal() as db:
            assert (await db.get(Track, temporary.id)).is_temporary is expected


async def test_radio_requires_auth_and_valid_existing_seed(env: SimpleNamespace) -> None:
    body = {"seed_type": "track", "id": str(uuid.uuid4())}
    assert (await env.client.post("/api/radio", json=body)).status_code == 401
    for seed_type in ("track", "album"):
        response = await env.client.post("/api/radio", json={**body, "seed_type": seed_type}, headers=env.headers)
        assert response.status_code == 404 and response.json()["detail"] == "Nicht gefunden"
    for patch in ({"seed_type": "artist"}, {"id": "invalid"}):
        response = await env.client.post("/api/radio", json={**body, **patch}, headers=env.headers)
        assert response.status_code == 422


@pytest.mark.parametrize(
    "temporary,radio_request,expected", [(True, True, True), (True, False, False), (False, True, False)]
)
async def test_non_admin_download_request_temporary_flag(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, temporary: bool, radio_request: bool, expected: bool
) -> None:
    track = song(123, "Missing", "Seed Artist", album={"id": 5})
    album = {"id": 5, "title": "Album", "artist": {"name": "Seed Artist"}}

    async def resolve(id: str) -> object:
        return meta_from_deezer(track, album, 1, 1)

    async def get_track(id: str) -> dict:
        return track

    async def get_album(id: str) -> dict:
        return album

    monkeypatch.setattr(downloads, "resolve_track", resolve)
    monkeypatch.setattr(deezer, "track", get_track)
    monkeypatch.setattr(deezer, "album", get_album)
    async with SessionLocal() as db:
        user = await db.get(User, env.user_id)
        assert not user.is_admin
        request = await downloads.create_request(db, user, "track", "123", temporary, radio=radio_request)
        assert request.is_temporary is expected


async def test_deezer_radio_methods(monkeypatch: pytest.MonkeyPatch) -> None:
    client = DeezerClient()
    calls: list[tuple[str, dict]] = []

    async def get(path: str, **params: object) -> dict:
        calls.append((path, params))
        return {"data": [{"id": 1}]}

    monkeypatch.setattr(client, "_get", get)
    assert await client.artist_radio("1") == [{"id": 1}]
    assert await client.artist_related("1") == [{"id": 1}]
    assert await client.artist_related("1", 7) == [{"id": 1}]
    assert calls == [
        ("artist/1/radio", {"limit": 50}),
        ("artist/1/related", {"limit": 10}),
        ("artist/1/related", {"limit": 7}),
    ]


@pytest.mark.parametrize("field,max_value", [("playlist_retention_days", 3650), ("max_downloads_per_radio", 50)])
def test_radio_config_bounds(field: str, max_value: int) -> None:
    assert getattr(RadioConfig(**{field: 0}), field) == 0
    assert getattr(RadioConfig(**{field: max_value}), field) == max_value
    for value in (-1, max_value + 1):
        with pytest.raises(ValueError):
            RadioConfig(**{field: value})


async def test_background_loop_resolution_and_hourly_cleanup(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    clock = SimpleNamespace(now=0)
    resolutions: list[int] = []
    cleanups: list[int] = []

    async def sleep(delay: float) -> None:
        assert delay == 60
        clock.now += 60
        if clock.now > 3720:
            raise asyncio.CancelledError

    async def resolve() -> None:
        resolutions.append(clock.now)

    async def cleanup(db: AsyncSession) -> tuple[int, int]:
        cleanups.append(clock.now)
        return 0, 0

    monkeypatch.setattr(radio.asyncio, "sleep", sleep)
    monkeypatch.setattr(radio.time, "monotonic", lambda: clock.now)
    monkeypatch.setattr(radio, "_resolve", resolve)
    monkeypatch.setattr(radio, "cleanup", cleanup)
    with pytest.raises(asyncio.CancelledError):
        await radio._resolve_loop()
    assert resolutions == list(range(60, 3721, 60))
    assert cleanups == [60, 3660]


async def test_background_tasks_start_stop_and_resolution_trigger(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    resolved = asyncio.Event()

    async def resolve() -> None:
        resolved.set()

    monkeypatch.setattr(radio, "_resolve", resolve)
    await radio.start()
    task = radio._loop_task
    await radio.start()
    assert radio._loop_task is task
    radio.resolve_after_download()
    await asyncio.wait_for(resolved.wait(), 1)
    await radio.stop()
    assert task.cancelled() and radio._loop_task is None and radio._tasks == set()


async def test_download_completion_resolves_radio_pending(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        track = await library_track(db, temporary=True)
        playlist = Playlist(owner_id=env.user_id, name="Radio", kind="radio")
        request = DownloadRequest(user_id=env.user_id, kind="track", title="Track", artist="Artist", status="active")
        db.add_all([playlist, request])
        await db.flush()
        item = DownloadItem(
            request_id=request.id,
            position=0,
            title="Track",
            artist="Artist",
            status="processing",
            meta={"deezer_track_id": "1"},
        )
        db.add_all([item, RadioPending(playlist_id=playlist.id, deezer_id="1")])
        await db.commit()
    await downloads.manager._change(item.id, status="done", track_id=track.id)
    await asyncio.gather(*radio._tasks)
    from app.services import spotify

    await asyncio.gather(*spotify._tasks)
    async with SessionLocal() as db:
        assert await entry_ids(db, playlist.id) == [track.id]
        assert await db.scalar(select(RadioPending)) is None


async def test_app_lifespan_starts_and_stops_radio(env: SimpleNamespace) -> None:
    async with app.router.lifespan_context(app):
        assert radio._loop_task is not None and not radio._loop_task.done()
    assert radio._loop_task is None and not radio._tasks


async def test_pending_resolution_errors_are_logged(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    async def fail(db: AsyncSession) -> int:
        raise RuntimeError("resolution failed")

    monkeypatch.setattr(radio, "resolve_radio_pending", fail)
    await radio._resolve()
    assert "Radio pending resolution failed" in caplog.text
