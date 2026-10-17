import asyncio
import json
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException
from sqlalchemy import delete, func, select

from app.db import SessionLocal
from app.main import app
from app.models import (
    DownloadRequest,
    Playlist,
    PlaylistEntry,
    SpotifyAccount,
    SpotifyPending,
    SpotifySync,
    SpotifyTrackMap,
    Track,
)
from app.services import spotify, spotify_sync
from tests import test_spotify
from tests.conftest import auth
from tests.test_spotify import connect, entry, library_track, playlist, song

env = test_spotify.env


@pytest.fixture
async def sync_env(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> AsyncIterator[SimpleNamespace]:
    await spotify_sync.stop()
    env.write_calls = []
    env.search_results = {}
    env.searches = []
    env.sync_handler = None
    env.launched = []
    env.real_launch = spotify_sync.launch_sync

    def dispatch(request: httpx.Request) -> httpx.Response | None:
        if env.sync_handler:
            response = env.sync_handler(request)
            if response is not None:
                return response
        if request.url.host == "accounts.spotify.com":
            return httpx.Response(
                200,
                json={
                    "access_token": "access",
                    "refresh_token": "refresh",
                    "expires_in": 3600,
                    "scope": "playlist-modify-private playlist-modify-public",
                },
            )
        if request.url.path == "/v1/search":
            assert request.url.params["type"] == "track" and request.url.params["limit"] == "10"
            query = request.url.params["q"]
            env.searches.append(query)
            return httpx.Response(200, json={"tracks": {"items": env.search_results.get(query, [])}})
        if request.method in {"POST", "DELETE"}:
            body = json.loads(request.content)
            env.write_calls.append((request.method, request.url.path, body))
            if request.url.path == "/v1/me/playlists":
                env.items["exported"] = []
                env.playlists.append(playlist("exported"))
                return httpx.Response(
                    201,
                    json={
                        "id": "exported",
                        "external_urls": {"spotify": "https://open.spotify.com/playlist/exported"},
                        "snapshot_id": "snapshot",
                    },
                )
            assert request.url.path.endswith("/items")
            id = request.url.path.split("/")[3]
            if request.method == "POST":
                assert 0 < len(body["uris"]) <= 100
                env.items[id].extend(entry(song(uri, uri=uri, isrc=None), key="item") for uri in body["uris"])
            else:
                assert 0 < len(body["items"]) <= 100
                removed = {item["uri"] for item in body["items"]}
                env.items[id] = [item for item in env.items[id] if item["item"].get("uri") not in removed]
            return httpx.Response(200, json={"snapshot_id": "snapshot"})
        return None

    env.handler = dispatch
    env.deezer_handler = lambda request: httpx.Response(
        200, json={"error": {"code": 800}} if request.url.path.startswith("/track/isrc:") else {"data": []}
    )
    monkeypatch.setattr(spotify_sync, "launch_sync", lambda id, *, pull: env.launched.append((id, pull)))
    await connect(env)
    yield env
    await spotify_sync.stop()


async def make_playlist(
    env: SimpleNamespace, titles: list[str], *, kind: str = "user"
) -> tuple[uuid.UUID, list[uuid.UUID]]:
    async with SessionLocal() as db:
        row = Playlist(owner_id=env.user_id, name="Export", kind=kind)
        db.add(row)
        await db.flush()
        tracks = []
        for position, title in enumerate(titles):
            track = await library_track(db, title, isrc=None)
            tracks.append(track.id)
            db.add(PlaylistEntry(playlist_id=row.id, track_id=track.id, position=position))
        await db.commit()
        return row.id, tracks


async def export(env: SimpleNamespace, playlist_id: uuid.UUID, *, two_way: bool = False) -> SpotifySync:
    response = await env.client.post(
        f"/api/playlists/{playlist_id}/spotify",
        headers=env.headers,
        json={"spotify_playlist_id": None, "two_way": two_way},
    )
    assert response.status_code == 201, response.text
    assert response.json()["status"] == "running"
    async with SessionLocal() as db:
        sync = await db.scalar(select(SpotifySync).where(SpotifySync.playlist_id == playlist_id))
        sync_id = sync.id
    assert env.launched[-1] == (sync_id, two_way)
    await spotify_sync.run_sync(sync_id, pull=two_way)
    async with SessionLocal() as db:
        return await db.get(SpotifySync, sync_id)


def found(title: str, uri: str | None = None, *, duration: int | None = 180000, artist: str = "Artist") -> dict:
    return song(title, uri=uri or f"spotify:track:{title}", duration=duration, artists=[{"name": artist}])


def text_result(env: SimpleNamespace, title: str) -> None:
    env.search_results[f'track:"{title}" artist:"Artist"'] = [found(title)]


async def test_export_new(sync_env: SimpleNamespace) -> None:
    env = sync_env
    playlist_id, ids = await make_playlist(env, ["ISRC", "Text", "Missing"])
    async with SessionLocal() as db:
        (await db.get(Track, ids[0])).isrc = "USABC1234567"
        await db.commit()
    env.search_results["isrc:USABC1234567"] = [found("Too long", duration=200000), found("ISRC")]
    text_result(env, "Text")
    sync = await export(env, playlist_id)
    assert env.write_calls == [
        ("POST", "/v1/me/playlists", {"name": "Export", "public": False, "description": "Aus Resonance exportiert"}),
        ("POST", "/v1/playlists/exported/items", {"uris": ["spotify:track:ISRC", "spotify:track:Text"]}),
    ]
    assert sync.status == "idle" and sync.error is None and sync.last_synced_at
    assert sync.prev_tracks == sorted(map(str, ids))
    assert sync.prev_spotify == ["spotify:track:ISRC", "spotify:track:Text"]
    assert sync.unmatched == [{"title": "Missing", "artist": "Artist, Guest"}]
    async with SessionLocal() as db:
        rows = {row.track_id: row for row in await db.scalars(select(SpotifyTrackMap))}
        assert rows[ids[0]].spotify_uri == "spotify:track:ISRC"
        assert rows[ids[1]].spotify_uri == "spotify:track:Text"
        assert rows[ids[2]].spotify_uri is None and rows[ids[2]].checked_at
    await spotify_sync.run_sync(sync.id, pull=False)
    async with SessionLocal() as db:
        assert (await db.get(SpotifySync, sync.id)).unmatched == sync.unmatched
        await db.execute(delete(PlaylistEntry).where(PlaylistEntry.track_id == ids[2]))
        await db.commit()
    await spotify_sync.run_sync(sync.id, pull=False)
    async with SessionLocal() as db:
        assert (await db.get(SpotifySync, sync.id)).unmatched == []


async def test_two_way_and_unchanged_run(sync_env: SimpleNamespace) -> None:
    env = sync_env
    playlist_id, ids = await make_playlist(env, ["RemovedSpotify", "RemovedResonance", "Keep"])
    for title in ["RemovedSpotify", "RemovedResonance", "Keep", "New"]:
        text_result(env, title)
    sync = await export(env, playlist_id, two_way=True)
    assert sync.status == "idle"
    async with SessionLocal() as db:
        remote = await library_track(db, "Remote", isrc="REMOTE")
        new = await library_track(db, "New", isrc=None)
        await db.execute(delete(PlaylistEntry).where(PlaylistEntry.track_id == ids[1]))
        db.add(PlaylistEntry(playlist_id=playlist_id, track_id=new.id, position=5))
        await db.commit()
        remote_id, new_id = remote.id, new.id
    env.items["exported"] = [
        entry(found("RemovedResonance"), key="item"),
        entry(found("Keep"), key="item"),
        entry(song("Remote", isrc="REMOTE", uri="spotify:track:Remote"), key="item"),
    ]
    env.write_calls.clear()
    await spotify_sync.run_sync(sync.id, pull=True)
    assert env.write_calls == [
        ("DELETE", "/v1/playlists/exported/items", {"items": [{"uri": "spotify:track:RemovedResonance"}]}),
        ("POST", "/v1/playlists/exported/items", {"uris": ["spotify:track:New"]}),
    ]
    async with SessionLocal() as db:
        rows = list(
            await db.scalars(
                select(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist_id).order_by(PlaylistEntry.position)
            )
        )
        assert [row.track_id for row in rows] == [ids[2], new_id, remote_id]
        assert rows[-1].position == 6
        assert (await db.get(SpotifyTrackMap, remote_id)).spotify_uri == "spotify:track:Remote"
        saved = await db.get(SpotifySync, sync.id)
        assert saved.status == "idle" and saved.prev_tracks == sorted(str(row.track_id) for row in rows)
    env.write_calls.clear()
    await spotify_sync.run_sync(sync.id, pull=True)
    assert env.write_calls == []


@pytest.mark.parametrize("deezer_id", [None, "42"])
async def test_missing_spotify_addition_requests_once(
    sync_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, deezer_id: str | None
) -> None:
    env = sync_env
    playlist_id, _ = await make_playlist(env, [])
    sync = await export(env, playlist_id, two_way=True)
    requested = []

    async def lookup(track: spotify.SpotifyTrack) -> str | None:
        return deezer_id

    async def request(db: object, user: object, kind: str, catalog_id: str, temporary: bool) -> SimpleNamespace:
        requested.append((kind, catalog_id, temporary))
        return SimpleNamespace()

    monkeypatch.setattr(spotify, "_deezer_id", lookup)
    monkeypatch.setattr(spotify_sync, "create_request", request)
    remote = entry(song("Missing", isrc="MISSING", uri="spotify:track:missing"), key="item")
    env.items["exported"] = [remote, remote]
    await spotify_sync.run_sync(sync.id, pull=True)
    async with SessionLocal() as db:
        rows = list(await db.scalars(select(SpotifyPending)))
        assert len(rows) == 1 and rows[0].playlist_id == playlist_id and rows[0].like is False
        assert rows[0].position == 0 and rows[0].deezer_id == deezer_id
        if deezer_id is None:
            assert rows[0].download_item_id
            assert await db.scalar(select(func.count()).select_from(DownloadRequest)) == 1
        else:
            assert requested == [("track", "42", False)]
        # A pending request also prevents duplicates if Spotify reports the URI as new again.
        (await db.get(SpotifySync, sync.id)).prev_spotify = []
        await db.commit()
    await spotify_sync.run_sync(sync.id, pull=True)
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 1
        assert (await db.get(SpotifySync, sync.id)).status == "idle"
        assert await db.scalar(select(func.count()).select_from(DownloadRequest)) == (1 if deezer_id is None else 0)
    assert len(requested) == (1 if deezer_id else 0)


async def test_one_way_does_not_pull(sync_env: SimpleNamespace) -> None:
    env = sync_env
    playlist_id, ids = await make_playlist(env, ["Original"])
    text_result(env, "Original")
    sync = await export(env, playlist_id)
    env.items["exported"] = [entry(found("Remote"), key="item")]
    env.write_calls.clear()
    await spotify_sync.run_sync(sync.id, pull=False)
    async with SessionLocal() as db:
        assert list(await db.scalars(select(PlaylistEntry.track_id))) == ids
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0
    assert env.write_calls == []


async def test_api_permissions_validation_and_lifecycle(sync_env: SimpleNamespace) -> None:
    env = sync_env
    playlist_id, _ = await make_playlist(env, [])
    mix_id, _ = await make_playlist(env, [], kind="mix")
    path = f"/api/playlists/{playlist_id}/spotify"
    body = {"spotify_playlist_id": "foreign", "two_way": True}
    for method, suffix, data in [
        ("GET", "", None),
        ("POST", "", body),
        ("PATCH", "", {"two_way": True}),
        ("DELETE", "", None),
        ("POST", "/sync", None),
    ]:
        response = await env.client.request(method, path + suffix, headers=auth(env.user["token"]), json=data)
        assert response.status_code == 404 and response.json()["detail"] == "Playlist nicht gefunden"
        response = await env.client.request(
            method, f"/api/playlists/{mix_id}/spotify" + suffix, headers=env.headers, json=data
        )
        assert response.status_code == 409
        assert response.json()["detail"] == "Diese Playlist kann nicht mit Spotify verknüpft werden"
    assert (await env.client.get(path, headers=env.headers)).json() is None
    response = await env.client.post(path + "/sync", headers=env.headers)
    assert response.status_code == 404 and response.json()["detail"] == "Nicht mit Spotify verknüpft"
    assert (await env.client.get("/api/spotify/status", headers=env.headers)).json()["can_write"] is True
    async with SessionLocal() as db:
        account = await db.get(SpotifyAccount, env.user_id)
        account.scope = "playlist-modify-private"
        await db.commit()
    response = await env.client.post(path, headers=env.headers, json=body)
    assert response.status_code == 409 and response.json()["detail"].startswith("Spotify-Schreibrechte fehlen")
    assert (await env.client.get("/api/spotify/status", headers=env.headers)).json()["can_write"] is False
    async with SessionLocal() as db:
        await db.delete(await db.get(SpotifyAccount, env.user_id))
        await db.commit()
    response = await env.client.post(path, headers=env.headers, json=body)
    assert response.status_code == 409 and response.json()["detail"] == "Kein Spotify-Konto verbunden"
    await connect(env)
    env.playlists.append(playlist("foreign", owner="other"))
    response = await env.client.post(path, headers=env.headers, json=body)
    assert response.status_code == 422 and response.json()["detail"] == "Spotify-Playlist nicht verfügbar"
    body["spotify_playlist_id"] = "own"
    response = await env.client.post(path, headers=env.headers, json=body)
    assert response.status_code == 201 and response.json()["spotify_url"] == "https://open.spotify.com/playlist/own"
    assert (await env.client.post(path, headers=env.headers, json=body)).status_code == 409
    assert (await env.client.post(path + "/sync", headers=env.headers)).status_code == 202
    assert len(env.launched) == 1
    sync_id = env.launched[0][0]
    await spotify_sync.run_sync(sync_id, pull=True)
    response = await env.client.patch(path, headers=env.headers, json={"two_way": False})
    assert response.status_code == 200 and response.json()["two_way"] is False
    assert (await env.client.post(path + "/sync", headers=env.headers)).status_code == 202
    assert env.launched[-1] == (sync_id, False)
    writes = env.write_calls.copy()
    assert (await env.client.delete(path, headers=env.headers)).status_code == 204
    assert (await env.client.get(path, headers=env.headers)).json() is None and env.write_calls == writes
    await spotify_sync.run_sync(sync_id, pull=True)


@pytest.mark.parametrize(
    "method,status,message",
    [
        ("POST", 403, "Spotify-Schreibrechte fehlen – bitte Spotify in den Einstellungen neu verbinden"),
        ("GET", 404, "Spotify-Playlist nicht gefunden – Verknüpfung bitte neu anlegen"),
        ("GET", 403, "Spotify gibt die Songs dieser Playlist nicht frei"),
        ("DELETE", 403, "Spotify-Schreibrechte fehlen – bitte Spotify in den Einstellungen neu verbinden"),
        ("POST", 404, "Spotify-Playlist nicht gefunden – Verknüpfung bitte neu anlegen"),
    ],
)
async def test_sync_errors(sync_env: SimpleNamespace, method: str, status: int, message: str) -> None:
    env = sync_env
    playlist_id, ids = await make_playlist(env, ["Original"])
    text_result(env, "Original")
    sync = await export(env, playlist_id, two_way=True)
    async with SessionLocal() as db:
        if method == "DELETE":
            await db.execute(delete(PlaylistEntry).where(PlaylistEntry.track_id == ids[0]))
        elif method == "POST":
            track = await library_track(db, "New", isrc=None)
            db.add(PlaylistEntry(playlist_id=playlist_id, track_id=track.id, position=1))
            text_result(env, "New")
        await db.commit()
    env.sync_handler = lambda request: (
        httpx.Response(status)
        if request.method == method and request.url.path == "/v1/playlists/exported/items"
        else None
    )
    await spotify_sync.run_sync(sync.id, pull=True)
    async with SessionLocal() as db:
        failed = await db.get(SpotifySync, sync.id)
        assert failed.status == "failed" and failed.error == message
        assert failed.prev_tracks == sync.prev_tracks and failed.prev_spotify == sync.prev_spotify
    response = await env.client.get(
        f"/api/playlists/{playlist_id}/spotify", headers={**env.headers, "Accept-Language": "en"}
    )
    assert response.json()["error"] != message


@pytest.mark.parametrize("age,searches", [(1, 0), (8, 1)])
async def test_null_map_cache(sync_env: SimpleNamespace, age: int, searches: int) -> None:
    env = sync_env
    _, ids = await make_playlist(env, ["Cached"])
    async with SessionLocal() as db, spotify._client_factory() as client:
        db.add(SpotifyTrackMap(track_id=ids[0], spotify_uri=None, checked_at=datetime.now(UTC) - timedelta(days=age)))
        await db.commit()
        account = await db.get(SpotifyAccount, env.user_id)
        track = await db.get(Track, ids[0])
        assert await spotify_sync.spotify_uri(db, account, client, track) is None
        await db.commit()
    assert len(env.searches) == searches


async def test_matching_scores_artist_split_and_cache(sync_env: SimpleNamespace) -> None:
    env = sync_env
    _, ids = await make_playlist(env, ['"Best"'])
    async with SessionLocal() as db, spotify._client_factory() as client:
        track = await db.get(Track, ids[0])
        track.artist_credit = '"Artist" FeAt. Guest'
        track.isrc = "NORESULT"
        env.search_results['track:"Best" artist:"Artist"'] = [
            found('"Best"', "spotify:track:wrong-duration", duration=191000),
            found("Unrelated", "spotify:track:wrong-title"),
            found('"Best"', "spotify:track:wrong-artist", artist="Unrelated"),
            found('"Best"', "spotify:track:far", duration=185000, artist='"Artist"'),
            found('"Best"', "spotify:track:best", duration=180500, artist='"Artist"'),
            found('"Best"', "spotify:track:tie", duration=180500, artist='"Artist"'),
        ]
        account = await db.get(SpotifyAccount, env.user_id)
        assert await spotify_sync.spotify_uri(db, account, client, track) == "spotify:track:best"
        await db.commit()
        assert await spotify_sync.spotify_uri(db, account, client, track) == "spotify:track:best"
    assert env.searches == ["isrc:NORESULT", 'track:"Best" artist:"Artist"']


async def test_request_limit_and_transaction_rollback(
    sync_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    env = sync_env
    playlist_id, _ = await make_playlist(env, [])
    sync = await export(env, playlist_id, two_way=True)
    env.items["exported"] = [entry(found(f"Missing {i}"), key="item") for i in range(3)]
    attempts = []

    async def limited(*args: object, **kwargs: object) -> None:
        attempts.append(True)
        raise HTTPException(429, "limit")

    real_request = spotify_sync.create_search_request
    monkeypatch.setattr(spotify_sync, "create_search_request", limited)
    await spotify_sync.run_sync(sync.id, pull=True)
    assert attempts == [True]
    async with SessionLocal() as db:
        assert (await db.get(SpotifySync, sync.id)).status == "idle"
        track = await library_track(db, "New", isrc=None)
        await library_track(db, "Remote", isrc="REMOTE")
        db.add(PlaylistEntry(playlist_id=playlist_id, track_id=track.id, position=0))
        await db.commit()
    text_result(env, "New")
    monkeypatch.setattr(spotify_sync, "create_search_request", real_request)
    env.items["exported"] = [
        entry(song("Remote", isrc="REMOTE", uri="spotify:track:remote"), key="item"),
        entry(found("Another missing"), key="item"),
    ]
    env.sync_handler = lambda request: (
        httpx.Response(403) if request.method == "POST" and request.url.path.endswith("/items") else None
    )
    await spotify_sync.run_sync(sync.id, pull=True)
    async with SessionLocal() as db:
        assert (await db.get(SpotifySync, sync.id)).status == "failed"
        assert await db.scalar(select(func.count()).select_from(DownloadRequest)) == 0
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0
        assert await db.scalar(select(func.count()).select_from(SpotifyTrackMap)) == 0
        assert list(await db.scalars(select(PlaylistEntry.track_id))) == [track.id]


async def test_concurrency_and_background_launch(sync_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    env = sync_env
    playlist_id, _ = await make_playlist(env, [])
    sync = await export(env, playlist_id)
    entered = asyncio.Event()
    release = asyncio.Event()
    calls = []
    original = spotify_sync._sync

    async def blocked(*args: object, **kwargs: object) -> None:
        calls.append(True)
        entered.set()
        await release.wait()
        await original(*args, **kwargs)

    monkeypatch.setattr(spotify_sync, "_sync", blocked)
    monkeypatch.setattr(spotify_sync, "launch_sync", env.real_launch)
    response = await env.client.post(f"/api/playlists/{playlist_id}/spotify/sync", headers=env.headers)
    assert response.status_code == 202
    await entered.wait()
    await spotify_sync.run_sync(sync.id, pull=False)
    assert calls == [True]
    release.set()
    await asyncio.gather(*spotify_sync._tasks)
    assert not spotify_sync._running and not spotify_sync._tasks


async def test_startup_recovery_and_loop(sync_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    env = sync_env
    playlist_id, _ = await make_playlist(env, [])
    sync = await export(env, playlist_id, two_way=True)
    async with SessionLocal() as db:
        (await db.get(SpotifySync, sync.id)).status = "running"
        await db.commit()
    async with app.router.lifespan_context(app):
        assert spotify_sync._loop_task and not spotify_sync._loop_task.done()
        async with SessionLocal() as db:
            saved = await db.get(SpotifySync, sync.id)
            assert saved.status == "failed" and saved.error == "Durch Neustart abgebrochen"
    assert spotify_sync._loop_task is None
    delays, calls = [], []

    async def sleep(seconds: int) -> None:
        delays.append(seconds)
        if len(delays) > 1:
            raise asyncio.CancelledError

    async def run(id: uuid.UUID, *, pull: bool) -> None:
        calls.append((id, pull))
        raise RuntimeError("loop test")

    monkeypatch.setattr(spotify_sync.asyncio, "sleep", sleep)
    monkeypatch.setattr(spotify_sync, "run_sync", run)
    with pytest.raises(asyncio.CancelledError):
        await spotify_sync._sync_loop()
    assert delays == [600, 600] and calls == [(sync.id, True)]


@pytest.mark.parametrize("status,always", [(401, False), (401, True), (429, False), (429, True)])
async def test_send_retries(
    sync_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, status: int, always: bool
) -> None:
    env = sync_env
    attempts, delays = [], []

    def handler(request: httpx.Request) -> httpx.Response | None:
        if request.url.host == "api.spotify.com":
            attempts.append(request.headers["authorization"])
            if always or len(attempts) == 1:
                return httpx.Response(status, headers={"Retry-After": "120"})
        return None

    async def sleep(seconds: float) -> None:
        delays.append(seconds)

    env.sync_handler = handler
    monkeypatch.setattr(spotify.asyncio, "sleep", sleep)
    async with SessionLocal() as db, spotify._client_factory() as client:
        account = await db.get(SpotifyAccount, env.user_id)
        if always:
            with pytest.raises(spotify.SpotifyError) as exc:
                await spotify._send(db, account, client, "POST", "me/playlists", {"name": "Export"})
            assert exc.value.status == status
        else:
            result = await spotify._send(db, account, client, "POST", "me/playlists", {"name": "Export"})
            assert result["id"] == "exported"
    assert len(attempts) == (6 if always and status == 429 else 2)
    assert delays == ([60] * (5 if always else 1) if status == 429 else [])


@pytest.mark.parametrize("scope", [None, "user-library-read"])
async def test_refresh_scope(sync_env: SimpleNamespace, scope: str | None) -> None:
    env = sync_env
    env.sync_handler = lambda request: (
        httpx.Response(
            200, json={"access_token": "new", "expires_in": 3600, **({"scope": scope} if scope is not None else {})}
        )
        if request.url.host == "accounts.spotify.com"
        else None
    )
    async with SessionLocal() as db, spotify._client_factory() as client:
        account = await db.get(SpotifyAccount, env.user_id)
        original = account.scope
        account.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        await db.commit()
        await spotify._send(db, account, client, "POST", "me/playlists", {"name": "Export"})
        assert account.scope == (original if scope is None else scope)
        assert account.access_token == "new"


@pytest.mark.parametrize("reason", ["account", "exception", "cancel"])
async def test_failure_cleanup(sync_env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, reason: str) -> None:
    env = sync_env
    playlist_id, _ = await make_playlist(env, [])
    sync = await export(env, playlist_id)
    if reason == "account":
        async with SessionLocal() as db:
            await db.delete(await db.get(SpotifyAccount, env.user_id))
            await db.commit()
    else:

        async def fail(*args: object, **kwargs: object) -> None:
            if reason == "cancel":
                raise asyncio.CancelledError
            raise RuntimeError("sync test")

        monkeypatch.setattr(spotify_sync, "_sync", fail)
    if reason == "cancel":
        with pytest.raises(asyncio.CancelledError):
            await spotify_sync.run_sync(sync.id, pull=False)
    else:
        await spotify_sync.run_sync(sync.id, pull=False)
    assert not spotify_sync._running
    async with SessionLocal() as db:
        saved = await db.get(SpotifySync, sync.id)
        assert saved.status == "failed"
        assert saved.error == ("Kein Spotify-Konto verbunden" if reason == "account" else "Abgleich fehlgeschlagen")


async def test_chunks_deduplication_skips_and_cascades(sync_env: SimpleNamespace) -> None:
    env = sync_env
    playlist_id, ids = await make_playlist(env, [f"Song {i}" for i in range(101)])
    async with SessionLocal() as db:
        db.add_all(
            SpotifyTrackMap(track_id=id, spotify_uri=f"spotify:track:{i}", checked_at=datetime.now(UTC))
            for i, id in enumerate(ids)
        )
        db.add(PlaylistEntry(playlist_id=playlist_id, track_id=ids[0], position=102))
        await db.commit()
    sync = await export(env, playlist_id, two_way=True)
    assert sync.status == "idle" and len(sync.prev_spotify) == 101
    additions = [body["uris"] for method, path, body in env.write_calls if path.endswith("/items")]
    assert list(map(len, additions)) == [100, 1]
    assert [uri for chunk in additions for uri in chunk] == [f"spotify:track:{i}" for i in range(101)]
    env.items["exported"].extend(
        [entry(song("Missing URI", isrc=None), key="item"), entry(found("Local", "spotify:local:song"), key="item")]
    )
    async with SessionLocal() as db:
        await db.execute(delete(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist_id))
        await db.commit()
    env.write_calls.clear()
    await spotify_sync.run_sync(sync.id, pull=True)
    assert [len(body["items"]) for method, path, body in env.write_calls] == [100, 1]
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0
        assert (await db.get(SpotifySync, sync.id)).prev_spotify == []
        await db.execute(delete(Track).where(Track.id.in_(ids)))
        await db.delete(await db.get(Playlist, playlist_id))
        await db.commit()
        assert await db.scalar(select(func.count()).select_from(SpotifyTrackMap)) == 0
        assert await db.get(SpotifySync, sync.id) is None
