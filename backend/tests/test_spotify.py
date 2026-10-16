import asyncio
import json
import time
import uuid
from collections import deque
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace
from urllib.parse import parse_qs, urlparse

import httpx
import pytest
from sqlalchemy import func, select

from app.db import Base, SessionLocal, engine
from app.main import app
from app.models import (
    Album,
    Artist,
    DownloadItem,
    DownloadRequest,
    Playlist,
    PlaylistEntry,
    SpotifyAccount,
    SpotifyImport,
    SpotifyPending,
    SpotifyPlaylistLink,
    Track,
    TrackLike,
)
from app.services import spotify
from app.services.deezer import deezer
from app.services.downloads import manager
from app.services.musicbrainz import TrackMeta
from app.services.server_config import ServerConfig, update_config
from tests.conftest import auth, register
from tests.test_downloads import FakeSource

ADDED = datetime(2026, 10, 1, 12, tzinfo=UTC)


@pytest.mark.parametrize(
    "link",
    [
        "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc",
        "https://open.spotify.com/intl-de/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/intl-fr/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc&foo=bar",
        "open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "open.spotify.com/intl-en/playlist/37i9dQZF1DXcBWIGoYBM5M?si=abc",
        "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M",
        "37i9dQZF1DXcBWIGoYBM5M",
    ],
)
def test_playlist_id_from_link(link: str) -> None:
    assert spotify.playlist_id_from_link(link) == "37i9dQZF1DXcBWIGoYBM5M"


@pytest.mark.parametrize(
    "link",
    [
        "",
        "https://example.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com.example.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com@evil.example/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/album/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/track/37i9dQZF1DXcBWIGoYBM5M",
        "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5",
        "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5MM",
        "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5_",
        "https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M/items",
        "http://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M",
        "spotify:album:37i9dQZF1DXcBWIGoYBM5M",
        "spotify:playlist:37i9dQZF1DXcBWIGoYBM5M?si=abc",
        "37i9dQZF1DXcBWIGoYBM5",
        "37i9dQZF1DXcBWIGoYBM5MM",
        "37i9dQZF1DXcBWIGoYBM5_",
    ],
)
def test_playlist_id_from_link_rejects_invalid(link: str) -> None:
    assert spotify.playlist_id_from_link(link) is None


def embed_html(titles: list[str], *, name: str = "Public playlist") -> str:
    entity = {
        "name": name,
        "subtitle": "Spotify",
        "coverArt": {"sources": [{"url": "https://image.example/embed-cover"}]},
        "trackList": [
            {
                "uri": f"spotify:track:{index:022d}",
                "title": title,
                "subtitle": "Artist",
                "duration": 180000,
                "entityType": "track",
            }
            for index, title in enumerate(titles)
        ],
    }
    data = {"props": {"pageProps": {"state": {"data": {"entity": entity}}}}}
    return f'<html><script id="__NEXT_DATA__" type="application/json">{json.dumps(data)}</script></html>'


def song(title="Song", *, isrc="usabc1234567", duration=180000, **extra):
    return {
        "type": "track",
        "id": title,
        "name": title,
        "duration_ms": duration,
        "is_local": False,
        "external_ids": {"isrc": isrc} if isrc else {},
        "artists": [{"name": "Artist"}, {"name": "Guest"}],
        "album": {"name": "Album"},
        **extra,
    }


def entry(item, *, key="track"):
    return {key: item, "added_at": ADDED.isoformat()}


def playlist(id="own", name="My playlist", owner="spotify-user", collaborative=False, **extra):
    return {
        "id": id,
        "name": name,
        "owner": {"id": owner, "display_name": "Owner"},
        "collaborative": collaborative,
        "images": [{"url": "https://image.example/cover"}],
        "items": {"total": 7},
        **extra,
    }


@pytest.fixture
async def env(client, monkeypatch):
    assert engine.url.database.startswith("app_test")
    await spotify.stop()
    spotify._states.clear()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    admin = await register(client, "admin")
    invite = (await client.post("/api/admin/invites", json={}, headers=auth(admin["token"]))).json()["token"]
    user = await register(client, "user", invite)
    env = SimpleNamespace(
        client=client,
        admin=admin,
        user=user,
        headers=auth(admin["token"]),
        user_id=uuid.UUID(admin["user"]["id"]),
        seen=[],
        handler=None,
        playlists=[playlist()],
        liked=[],
        items={"own": []},
        deezer_handler=None,
        factories=[],
        requests=[],
    )

    async def dispatch(request):
        env.seen.append(request)
        assert request.extensions["timeout"]["read"] == (20 if request.url.host == "open.spotify.com" else 30)
        if env.handler:
            response = env.handler(request)
            if response is not None:
                return response
        if request.url.host == "accounts.spotify.com":
            body = parse_qs(request.content.decode())
            assert request.method == "POST"
            assert request.headers["authorization"] == "Basic Y2xpZW50OnNlY3JldA=="
            assert request.headers["content-type"] == "application/x-www-form-urlencoded"
            if body["grant_type"] == ["authorization_code"]:
                assert body["code"] == ["code"]
                assert body["redirect_uri"] == ["http://test/api/spotify/callback"]
                return httpx.Response(
                    200, json={"access_token": "access", "refresh_token": "refresh", "expires_in": 3600}
                )
            assert body == {"grant_type": ["refresh_token"], "refresh_token": ["refresh"]}
            return httpx.Response(
                200, json={"access_token": "rotated", "refresh_token": "rotated-refresh", "expires_in": 3600}
            )
        assert request.url.host == "api.spotify.com"
        if request.url.path == "/v1/me":
            return httpx.Response(200, json={"id": "spotify-user", "display_name": "Spotify reader"})
        if request.url.path == "/v1/me/playlists":
            return httpx.Response(200, json={"items": env.playlists, "next": None})
        if request.url.path == "/v1/me/tracks":
            return httpx.Response(200, json={"items": env.liked, "next": None, "total": len(env.liked)})
        if request.url.path.startswith("/v1/playlists/"):
            assert request.url.path.endswith("/items")
            assert request.url.params["additional_types"] == "track"
            return httpx.Response(200, json={"items": env.items[request.url.path.split("/")[3]], "next": None})
        raise AssertionError(f"Unexpected Spotify request: {request.url}")

    def factory():
        client = httpx.AsyncClient(transport=httpx.MockTransport(dispatch), timeout=30)
        env.factories.append(client)
        return client

    monkeypatch.setattr(spotify, "_client_factory", factory)

    def deezer_dispatch(request):
        if env.deezer_handler:
            return env.deezer_handler(request)
        raise AssertionError(f"Unexpected Deezer request: {request.url}")

    mock_deezer = httpx.AsyncClient(
        transport=httpx.MockTransport(deezer_dispatch), base_url="https://api.deezer.com/", timeout=15
    )
    monkeypatch.setattr(deezer, "_client", mock_deezer)
    monkeypatch.setattr(deezer, "_cache", {})
    monkeypatch.setattr(deezer, "_starts", deque(maxlen=45))

    async def create_request(db, user, kind, catalog_id, temporary):
        env.requests.append((user.id, kind, catalog_id, temporary))
        await db.commit()
        return SimpleNamespace(id=uuid.uuid4())

    monkeypatch.setattr(spotify, "create_request", create_request)
    async with SessionLocal() as db:
        await update_config(db, {"spotify": {"client_id": "client", "client_secret": "secret"}})
    yield env
    await spotify.stop()
    await mock_deezer.aclose()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)


async def connect(env, user=None):
    headers = auth((user or env.admin)["token"])
    result = await env.client.get("/api/spotify/login", headers=headers)
    assert result.status_code == 200, result.text
    state = parse_qs(urlparse(result.json()["url"]).query)["state"][0]
    result = await env.client.get("/api/spotify/callback", params={"code": "code", "state": state})
    assert result.status_code == 200, result.text
    return state


async def library_track(db, title="Song", isrc="USABC1234567", duration=180, temporary=False):
    artist = await db.scalar(select(Artist).where(Artist.name_key == "artist"))
    if artist is None:
        artist = Artist(name="Artist", name_key="artist")
        db.add(artist)
        await db.flush()
    album = await db.scalar(select(Album).where(Album.artist_id == artist.id))
    if album is None:
        album = Album(title="Album", title_key="album", artist_id=artist.id)
        db.add(album)
        await db.flush()
    track = Track(
        title=title,
        isrc=isrc,
        duration=duration,
        is_temporary=temporary,
        path=str(uuid.uuid4()),
        artist_id=artist.id,
        album_id=album.id,
        artist_credit="Artist, Guest",
    )
    db.add(track)
    await db.flush()
    return track


async def run(env, *, liked=True, playlist_ids=None, links=None, download_missing=False):
    async with SessionLocal() as db:
        batch = SpotifyImport(
            user_id=env.user_id,
            status="queued",
            liked=liked,
            playlist_ids=playlist_ids or [],
            links=links or [],
            download_missing=download_missing,
        )
        db.add(batch)
        await db.commit()
        id = batch.id
    before = len(env.factories)
    await spotify.run_import(id)
    assert len(env.factories) > before
    assert all(client.is_closed for client in env.factories[before:])
    async with SessionLocal() as db:
        return await db.get(SpotifyImport, id)


async def test_fetch_embed_playlist(env: SimpleNamespace) -> None:
    html = """<html><script type="application/json" id="__NEXT_DATA__">
    {"props":{"pageProps":{"state":{"data":{"entity":{
      "name":"Editorial playlist","subtitle":"Spotify",
      "coverArt":{"sources":[{"url":"https://image.example/first"},{"url":"https://image.example/second"}]},
      "trackList":[
        {"uri":"spotify:track:0000000000000000000001","title":"Song","subtitle":"Artist,\u00a0Guest",
         "duration":180500,"entityType":"track"},
        {"title":"Episode","entityType":"episode"},
        {"uri":"spotify:track:0000000000000000000002","title":"Second","subtitle":"Another Artist",
         "duration":200000,"entityType":"track"}
      ]
    }}}}}}</script></html>"""

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url == "https://open.spotify.com/embed/playlist/37i9dQZF1DXcBWIGoYBM5M"
        assert request.headers["user-agent"].startswith("Mozilla/5.0")
        return httpx.Response(200, text=html)

    env.handler = handler
    metadata, tracks = await spotify.fetch_embed_playlist("37i9dQZF1DXcBWIGoYBM5M")
    assert metadata == {
        "id": "37i9dQZF1DXcBWIGoYBM5M",
        "name": "Editorial playlist",
        "owner": "Spotify",
        "image_url": "https://image.example/first",
    }
    assert tracks == [
        spotify.SpotifyTrack("Song", "Artist, Guest", None, None, 180.5, None, 0),
        spotify.SpotifyTrack("Second", "Another Artist", None, None, 200, None, 2),
    ]
    assert env.factories[-1].is_closed


async def test_embed_redirect_and_missing_cover(env: SimpleNamespace) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if not request.url.query:
            return httpx.Response(302, headers={"location": str(request.url) + "?redirected=1"})
        return httpx.Response(
            200,
            text='<script id="__NEXT_DATA__">'
            '{"props":{"pageProps":{"state":{"data":{"entity":{"name":"Empty","trackList":[]}}}}}}'
            "</script>",
        )

    env.handler = handler
    metadata, tracks = await spotify.fetch_embed_playlist("37i9dQZF1DXcBWIGoYBM5M")
    assert metadata["name"] == "Empty" and metadata["image_url"] is None and tracks == []
    assert len(env.seen) == 2


@pytest.mark.parametrize(
    "status,html,error_status,message",
    [
        (404, "", 404, "Playlist nicht gefunden oder privat"),
        (200, "<html>Private</html>", 404, "Playlist nicht gefunden oder privat"),
        (200, '<script id="__NEXT_DATA__">{invalid}</script>', 404, "Playlist nicht gefunden oder privat"),
        (200, '<script id="__NEXT_DATA__">{}</script>', 404, "Playlist nicht gefunden oder privat"),
        (
            200,
            '<script id="__NEXT_DATA__">{"props":{"pageProps":{"state":{"data":{"entity":null}}}}}</script>',
            404,
            "Playlist nicht gefunden oder privat",
        ),
        (403, "", 502, "Spotify nicht erreichbar"),
        (500, "", 502, "Spotify nicht erreichbar"),
        (0, "", 502, "Spotify nicht erreichbar"),
    ],
)
async def test_embed_errors(env: SimpleNamespace, status: int, html: str, error_status: int, message: str) -> None:
    def handler(request: httpx.Request) -> httpx.Response:
        if status == 0:
            raise httpx.ConnectError("offline", request=request)
        return httpx.Response(status, text=html)

    env.handler = handler
    with pytest.raises(spotify.SpotifyError) as exc:
        await spotify.fetch_embed_playlist("37i9dQZF1DXcBWIGoYBM5M")
    assert (exc.value.status, exc.value.message) == (error_status, message)
    assert env.factories[-1].is_closed


async def test_link_import_without_account_and_sync(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await update_config(db, {"spotify": {"client_id": "", "client_secret": ""}})
        first = await library_track(db, isrc=None)
        second = await library_track(db, "Second", isrc=None)
        await db.commit()
    id = "37i9dQZF1DXcBWIGoYBM5M"
    env.handler = lambda request: httpx.Response(200, text=embed_html(["Song", "Song", "Missing"]))
    env.deezer_handler = lambda request: httpx.Response(
        200, json={"data": [{"id": 42, "title": "Missing", "duration": 180}]}
    )
    batch = await run(env, liked=False, links=[id], download_missing=True)
    assert (batch.status, batch.total, batch.matched, batch.missing, batch.requested) == ("done", 3, 2, 1, 1)
    assert batch.links == [id] and env.requests == [(env.user_id, "track", "42", False)]
    assert batch.missing_tracks == [{"title": "Missing", "artist": "Artist", "source": "Public playlist"}]
    assert all(request.url.host == "open.spotify.com" for request in env.seen)
    async with SessionLocal() as db:
        link = await db.scalar(select(SpotifyPlaylistLink))
        assert link.spotify_playlist_id == id
        playlist_id = link.playlist_id
        result = await db.get(Playlist, playlist_id)
        assert (result.name, result.description, result.is_public, result.owner_id) == (
            "Public playlist",
            "Von Spotify importiert",
            False,
            env.user_id,
        )
        entries = list(await db.scalars(select(PlaylistEntry).order_by(PlaylistEntry.position)))
        assert [(row.track_id, row.position) for row in entries] == [(first.id, 0), (first.id, 1)]
        pending = await db.scalar(select(SpotifyPending))
        assert (pending.playlist_id, pending.position, pending.deezer_id, pending.isrc, pending.like) == (
            playlist_id,
            2,
            "42",
            None,
            False,
        )
        assert await db.scalar(select(func.count()).select_from(TrackLike)) == 0
    env.handler = lambda request: httpx.Response(200, text=embed_html(["Second"], name="Renamed"))
    batch = await run(env, liked=False, links=[id])
    assert batch.status == "done" and batch.matched == 1
    async with SessionLocal() as db:
        assert (await db.get(Playlist, playlist_id)).name == "Renamed"
        entries = list(await db.scalars(select(PlaylistEntry)))
        assert [(row.track_id, row.position) for row in entries] == [(second.id, 0)]
        assert await db.scalar(select(func.count()).select_from(SpotifyPlaylistLink)) == 1
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0


@pytest.mark.parametrize("count", [99, 100])
async def test_link_import_track_limit_notice(env: SimpleNamespace, count: int) -> None:
    env.handler = lambda request: httpx.Response(200, text=embed_html(["Song"] * count))
    batch = await run(env, liked=False, links=["37i9dQZF1DXcBWIGoYBM5M"])
    assert batch.status == "done" and batch.total == count
    assert batch.message == (
        "„Public playlist“: nur die ersten 100 Songs übernommen "
        "(ohne verbundenes Spotify-Konto liefert Spotify nicht mehr)"
        if count == 100
        else None
    )


@pytest.mark.parametrize("status", [403, 404])
@pytest.mark.parametrize("path", ["", "/items"])
async def test_link_import_api_embed_fallback(env: SimpleNamespace, status: int, path: str) -> None:
    await connect(env)
    id = "37i9dQZF1DXcBWIGoYBM5M"

    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.host == "open.spotify.com":
            return httpx.Response(200, text=embed_html(["Song"]))
        if request.url.path == f"/v1/playlists/{id}{path}":
            return httpx.Response(status)
        assert request.url.path == f"/v1/playlists/{id}"
        assert request.url.params["fields"] == "name,owner(display_name,id)"
        return httpx.Response(200, json={"name": "API playlist"})

    env.handler = handler
    batch = await run(env, liked=False, links=[id])
    assert batch.status == "done" and batch.total == 1 and batch.message is None
    assert env.seen[-1].url.host == "open.spotify.com"
    async with SessionLocal() as db:
        assert await db.scalar(select(Playlist.name)) == "Public playlist"


async def test_link_import_uses_api_and_existing_playlist_link(env: SimpleNamespace) -> None:
    await connect(env)
    env.items["own"] = []
    await run(env, liked=False, playlist_ids=["own"])
    async with SessionLocal() as db:
        playlist_id = await db.scalar(select(Playlist.id))
        await library_track(db)
        await db.commit()

    def handler(request: httpx.Request) -> httpx.Response | None:
        assert request.url.host == "api.spotify.com"
        if request.url.path == "/v1/playlists/own":
            assert request.url.params["fields"] == "name,owner(display_name,id)"
            return httpx.Response(200, json={"name": "API playlist"})
        return None

    env.handler = handler
    env.items["own"] = [entry(song(), key="item")]
    batch = await run(env, liked=False, links=["own"])
    assert batch.status == "done" and batch.matched == 1
    async with SessionLocal() as db:
        assert (await db.get(Playlist, playlist_id)).name == "API playlist"
        assert await db.scalar(select(func.count()).select_from(SpotifyPlaylistLink)) == 1


async def test_link_import_continues_after_embed_error(env: SimpleNamespace) -> None:
    id = "37i9dQZF1DXcBWIGoYBM5M"
    other = "0123456789abcdefghijkl"
    env.handler = lambda request: (
        httpx.Response(404) if request.url.path.endswith(id) else httpx.Response(200, text=embed_html([]))
    )
    batch = await run(env, liked=False, links=[id, other])
    assert batch.status == "done" and batch.message == f"{id}: Playlist nicht gefunden oder privat"
    async with SessionLocal() as db:
        assert await db.scalar(select(SpotifyPlaylistLink.spotify_playlist_id)) == other


async def test_link_import_propagates_other_api_errors(env: SimpleNamespace) -> None:
    await connect(env)
    env.handler = lambda request: httpx.Response(500)
    batch = await run(env, liked=False, links=["37i9dQZF1DXcBWIGoYBM5M"])
    assert batch.status == "failed" and batch.message == "Spotify-Fehler (HTTP 500)"
    assert env.seen[-1].url.host == "api.spotify.com"


async def test_api_links_without_account_validation_and_defaults(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    launched = []
    monkeypatch.setattr(spotify, "launch_import", launched.append)
    async with SessionLocal() as db:
        await update_config(db, {"spotify": {"client_id": "", "client_secret": ""}})
    for body, status, message in [
        ({}, 422, "Nichts ausgewählt"),
        ({"links": ["invalid"]}, 422, "Ungültiger Spotify-Link: invalid"),
        ({"liked": True}, 409, "Kein Spotify-Konto verbunden"),
        ({"playlist_ids": ["own"]}, 409, "Kein Spotify-Konto verbunden"),
    ]:
        response = await env.client.post("/api/spotify/imports", headers=env.headers, json=body)
        assert response.status_code == status and response.json()["detail"] == message
    id = "37i9dQZF1DXcBWIGoYBM5M"
    other = "0123456789abcdefghijkl"
    response = await env.client.post("/api/spotify/imports", headers=env.headers, json={"links": [id] * 51})
    assert response.status_code == 422
    response = await env.client.post(
        "/api/spotify/imports",
        headers=env.headers,
        json={"links": [f"https://open.spotify.com/intl-de/playlist/{id}?si=abc", other, f"spotify:playlist:{id}"]},
    )
    assert response.status_code == 202, response.text
    data = response.json()
    assert data["links"] == [id, other] and data["playlist_ids"] == []
    assert data["liked"] is False and data["download_missing"] is False
    assert launched == [uuid.UUID(data["id"])]
    async with SessionLocal() as db:
        assert (await db.get(SpotifyImport, launched[0])).links == [id, other]
    listing = await env.client.get("/api/spotify/imports", headers=env.headers)
    assert listing.json()[0]["links"] == [id, other]


async def test_login_callback_status_and_disconnect(env):
    assert ServerConfig().spotify.client_id == ""
    response = await env.client.get("/api/spotify/status", headers=env.headers)
    assert response.json() == {"configured": True, "connected": False, "display_name": None}
    response = await env.client.get("/api/spotify/login", headers=env.headers)
    url = urlparse(response.json()["url"])
    query = parse_qs(url.query)
    assert url.netloc == "accounts.spotify.com" and url.path == "/authorize"
    assert query["response_type"] == ["code"] and query["client_id"] == ["client"]
    assert query["scope"] == ["playlist-read-private playlist-read-collaborative user-library-read"]
    assert query["redirect_uri"] == ["http://test/api/spotify/callback"]
    state = query["state"][0]
    assert spotify._states[state][0] == env.user_id and len(state) == 32
    response = await env.client.get("/api/spotify/callback", params={"state": state, "code": "code"})
    assert response.status_code == 200
    assert "Spotify ist verbunden. Du kannst dieses Fenster schließen und zu Resonance zurückkehren." in response.text
    assert "background:#121212" in response.text and state not in spotify._states
    assert (await env.client.get("/api/spotify/callback", params={"state": state, "code": "code"})).status_code == 400
    await connect(env)
    async with SessionLocal() as db:
        account = await db.get(SpotifyAccount, env.user_id)
        assert account.spotify_user_id == "spotify-user" and account.refresh_token == "refresh"
        assert abs((account.expires_at - datetime.now(UTC)).total_seconds() - 3540) < 5
        assert await db.scalar(select(func.count()).select_from(SpotifyAccount)) == 1
    assert (await env.client.get("/api/spotify/status", headers=env.headers)).json()["display_name"] == "Spotify reader"
    assert not (await env.client.get("/api/spotify/status", headers=auth(env.user["token"]))).json()["connected"]
    before = len(env.seen)
    assert (await env.client.delete("/api/spotify/login", headers=env.headers)).status_code == 204
    assert len(env.seen) == before
    async with SessionLocal() as db:
        await update_config(db, {"spotify": {"client_secret": ""}})
    assert (await env.client.get("/api/spotify/login", headers=env.headers)).json()[
        "detail"
    ] == "Spotify ist auf diesem Server nicht eingerichtet"
    assert not (await env.client.get("/api/spotify/status", headers=env.headers)).json()["configured"]


@pytest.mark.parametrize("kind", ["bad", "expired", "error", "token", "profile"])
async def test_callback_errors(env, kind):
    state = "state"
    if kind != "bad":
        spotify._states[state] = (env.user_id, time.monotonic() - (601 if kind == "expired" else 0))
    params = {"state": state, "code": "code"}
    if kind == "error":
        params["error"] = "<access_denied>"
    if kind == "token":
        env.handler = lambda request: httpx.Response(400)
    if kind == "profile":

        def handler(request):
            if request.url.path == "/v1/me":
                return httpx.Response(401)
            if request.url.path == "/api/token" and parse_qs(request.content.decode())["grant_type"] == [
                "refresh_token"
            ]:
                return httpx.Response(400)
            return None

        env.handler = handler
    response = await env.client.get("/api/spotify/callback", params=params)
    assert response.status_code == (401 if kind == "profile" else 400)
    assert "Verbindung fehlgeschlagen:" in response.text
    if kind in {"bad", "expired"}:
        assert "Ungültiger oder abgelaufener Status" in response.text
    if kind == "error":
        assert "&lt;access_denied&gt;" in response.text and "<access_denied>" not in response.text
    assert state not in spotify._states
    async with SessionLocal() as db:
        assert await db.get(SpotifyAccount, env.user_id) is None


@pytest.mark.parametrize("rotate", [False, True])
async def test_refresh(env, rotate):
    await connect(env)
    env.handler = lambda r: (
        httpx.Response(
            200,
            json={"access_token": "new", "expires_in": 1200, **({"refresh_token": "new-refresh"} if rotate else {})},
        )
        if r.url.host == "accounts.spotify.com"
        else None
    )
    async with SessionLocal() as db:
        account = await db.get(SpotifyAccount, env.user_id)
        account.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        await db.commit()
        await spotify.fetch_liked(db, account)
        assert account.access_token == "new"
        assert account.refresh_token == ("new-refresh" if rotate else "refresh")
        assert abs((account.expires_at - datetime.now(UTC)).total_seconds() - 1140) < 5
    assert env.seen[-1].headers["authorization"] == "Bearer new"


@pytest.mark.parametrize("status", [400, 401])
async def test_refresh_failure_deletes_account(env, status):
    await connect(env)
    async with SessionLocal() as db:
        account = await db.get(SpotifyAccount, env.user_id)
        account.expires_at = datetime.now(UTC) - timedelta(seconds=1)
        await db.commit()
    env.handler = lambda r: httpx.Response(status)
    response = await env.client.get("/api/spotify/playlists", headers=env.headers)
    assert response.status_code == 401
    assert response.json()["detail"] == "Spotify-Verbindung abgelaufen – bitte neu verbinden"
    async with SessionLocal() as db:
        assert await db.get(SpotifyAccount, env.user_id) is None


@pytest.mark.parametrize("always", [False, True])
async def test_401_retries_once(env, always):
    await connect(env)
    attempts = []

    def handler(request):
        if request.url.host == "accounts.spotify.com":
            return None
        attempts.append(request.headers["authorization"])
        return httpx.Response(401) if always or len(attempts) == 1 else None

    env.handler = handler
    async with SessionLocal() as db:
        account = await db.get(SpotifyAccount, env.user_id)
        if always:
            with pytest.raises(spotify.SpotifyError) as exc:
                await spotify.fetch_liked(db, account)
            assert exc.value.status == 401
        else:
            assert await spotify.fetch_liked(db, account) == []
    assert attempts == ["Bearer access", "Bearer rotated"]


@pytest.mark.parametrize("retry_after,delay", [("2", 2), ("120", 60), (None, 5)])
async def test_429_retries_and_failure(env, monkeypatch, retry_after, delay):
    await connect(env)
    sleeps = []

    async def sleep(seconds):
        sleeps.append(seconds)

    monkeypatch.setattr(spotify.asyncio, "sleep", sleep)
    env.handler = lambda r: httpx.Response(429, headers={"Retry-After": retry_after} if retry_after else {})
    batch = await run(env)
    assert batch.status == "failed" and batch.message == "Spotify-Limit erreicht – bitte später erneut versuchen"
    assert sleeps == [delay] * 5
    requests = [r for r in env.seen if r.url.path == "/v1/me/tracks"]
    assert len(requests) == 6 and len({str(r.url) for r in requests}) == 1
    env.handler = lambda r: httpx.Response(429) if len(sleeps) == 5 else None
    async with SessionLocal() as db:
        assert await spotify.fetch_liked(db, await db.get(SpotifyAccount, env.user_id)) == []
    assert sleeps[-1] == 5


async def test_pagination_filtering_and_skipped_items(env):
    await connect(env)

    def handler(request):
        offset = int(request.url.params.get("offset", 0))
        if request.url.path == "/v1/me/playlists":
            assert request.url.params["limit"] == "50"
            items = [
                playlist(),
                playlist("other", owner="other"),
                playlist("collab", owner="other", collaborative=True),
            ]
            if offset:
                assert offset == 3
                return httpx.Response(
                    200, json={"items": [playlist("last", items=None, tracks={"total": 9}, images=[])], "next": None}
                )
            return httpx.Response(200, json={"items": items, "next": "next"})
        if request.url.path in {"/v1/me/tracks", "/v1/playlists/own/items"}:
            key = "track" if request.url.path.endswith("tracks") else "item"
            assert request.url.params["limit"] == ("50" if key == "track" else "100")
            if offset:
                assert offset == 4
                return httpx.Response(200, json={"items": [entry(song("Last"), key=key)], "next": None})
            items = [
                entry(None, key=key),
                entry(song(type="episode"), key=key),
                entry(song(is_local=True), key=key),
                entry(song(), key=key),
            ]
            return httpx.Response(200, json={"items": items, "next": "next"})

    env.handler = handler
    async with SessionLocal() as db:
        account = await db.get(SpotifyAccount, env.user_id)
        playlists = await spotify.fetch_playlists(db, account)
        assert [p["id"] for p in playlists] == ["own", "collab", "last"]
        assert playlists[0]["owner"] == "Owner" and playlists[0]["track_count"] == 7
        assert playlists[0]["image_url"] == "https://image.example/cover"
        assert playlists[-1]["track_count"] == 9 and playlists[-1]["image_url"] is None
        for tracks in (await spotify.fetch_liked(db, account), await spotify.fetch_playlist_tracks(db, account, "own")):
            assert [t.position for t in tracks] == [3, 4]
            assert tracks[0] == spotify.SpotifyTrack("Song", "Artist, Guest", "Album", "USABC1234567", 180, ADDED, 3)


async def test_matching_isrc_duration_guard_and_chunks(env, monkeypatch):
    async with SessionLocal() as db:
        exact = await library_track(db, "Different title", duration=300)
        named = await library_track(db, "Named", isrc=None, duration=180)
        await db.commit()
        tracks = [
            spotify.SpotifyTrack("Unknown", "Nobody", None, exact.isrc, 180, None, 0),
            spotify.SpotifyTrack("Named", "Artist", None, None, 190, None, 1),
            spotify.SpotifyTrack("Named", "Artist", None, None, 191, None, 2),
            spotify.SpotifyTrack("Named", "Artist", None, None, None, None, 3),
        ]
        assert await spotify.match(db, tracks) == [exact.id, named.id, None, named.id]
        sizes = []
        original = spotify.matching.match_tracks

        async def matching(db, catalog):
            sizes.append(len(catalog))
            assert all(t.id == "" and t.artist_id is None and t.preview_url is None for t in catalog)
            await original(db, catalog)

        monkeypatch.setattr(spotify.matching, "match_tracks", matching)
        assert await spotify.match(db, [tracks[0]] * 1001) == [exact.id] * 1001
        assert sizes == [500, 500, 1]


async def test_import_likes_preserves_existing_and_timestamps(env):
    await connect(env)
    async with SessionLocal() as db:
        first = await library_track(db)
        existing = await library_track(db, "Existing", "EXISTING")
        old = ADDED - timedelta(days=10)
        db.add(TrackLike(user_id=env.user_id, track_id=existing.id, created_at=old))
        await db.commit()
    env.liked = [entry(song()), entry(song("Existing", isrc="EXISTING")), entry(song("Missing", isrc=None))]
    batch = await run(env)
    assert (batch.status, batch.total, batch.matched, batch.missing, batch.requested) == ("done", 3, 2, 1, 0)
    assert batch.finished_at and batch.missing_tracks == [
        {"title": "Missing", "artist": "Artist, Guest", "source": "Lieblingssongs"}
    ]
    async with SessionLocal() as db:
        likes = {r.track_id: r.created_at for r in await db.scalars(select(TrackLike))}
        assert likes == {first.id: ADDED, existing.id: old}


async def test_playlist_creation_and_sync(env):
    await connect(env)
    async with SessionLocal() as db:
        first = await library_track(db)
        second = await library_track(db, "Second", "SECOND")
        await db.commit()
    env.items["own"] = [
        entry(song(), key="item"),
        entry(None, key="item"),
        entry(song(), key="item"),
        entry(song("Second", isrc="SECOND"), key="item"),
    ]
    batch = await run(env, liked=False, playlist_ids=["own"])
    assert batch.status == "done" and batch.matched == 3
    async with SessionLocal() as db:
        link = await db.scalar(select(SpotifyPlaylistLink))
        playlist_id = link.playlist_id
        result = await db.get(Playlist, playlist_id)
        assert result.name == "My playlist" and result.description == "Von Spotify importiert"
        assert not result.is_public and result.owner_id == env.user_id
        entries = list(await db.scalars(select(PlaylistEntry).order_by(PlaylistEntry.position)))
        assert [(e.track_id, e.position) for e in entries] == [(first.id, 0), (first.id, 2), (second.id, 3)]
        db.add(
            SpotifyPending(
                user_id=env.user_id, title="Old", artist="Artist", like=False, playlist_id=playlist_id, position=99
            )
        )
        await db.commit()
    env.playlists[0]["name"] = "Renamed"
    env.items["own"] = [entry(song("Second", isrc="SECOND"), key="item")]
    batch = await run(env, liked=False, playlist_ids=["own"])
    assert batch.total == 1
    async with SessionLocal() as db:
        assert (await db.get(Playlist, playlist_id)).name == "Renamed"
        entries = list(await db.scalars(select(PlaylistEntry)))
        assert [(e.track_id, e.position) for e in entries] == [(second.id, 0)]
        assert await db.scalar(select(func.count()).select_from(SpotifyPlaylistLink)) == 1
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0
    result = (await env.client.get("/api/spotify/playlists", headers=env.headers)).json()
    assert result["playlists"][0]["imported"] and result["liked_count"] == 0
    assert dict(next(r for r in reversed(env.seen) if r.url.path == "/v1/me/tracks").url.params) == {"limit": "1"}


async def test_unknown_and_forbidden_playlists(env):
    await connect(env)
    env.handler = lambda r: httpx.Response(403) if r.url.path == "/v1/playlists/own/items" else None
    batch = await run(env, liked=False, playlist_ids=["unknown", "own"])
    assert batch.status == "done" and batch.total == 0
    assert (
        batch.message
        == "unknown: Playlist nicht verfügbar\n„My playlist“: Spotify gibt die Songs dieser Playlist nicht frei"
    )
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(Playlist)) == 0


async def test_missing_deezer_requests_and_pending(env):
    await connect(env)
    env.liked = [
        entry(song()),
        entry(song("Search", isrc=None)),
        entry(song("Fallback", isrc="MISSING")),
        entry(song("Unavailable", isrc=None)),
    ]
    env.items["own"] = [entry(song(), key="item")]
    searches = []

    def handler(request):
        assert request.url.host == "api.deezer.com"
        if request.url.path == "/track/isrc:USABC1234567":
            return httpx.Response(200, json={"id": 1})
        if request.url.path == "/track/isrc:MISSING":
            return httpx.Response(200, json={"error": {"code": 800}})
        assert request.url.path == "/search/track" and request.url.params["limit"] == "5"
        searches.append(request.url.params["q"])
        if 'track:"' not in request.url.params["q"]:
            assert request.url.params["q"] == "Artist Unavailable"
            return httpx.Response(200, json={"data": []})
        title = request.url.params["q"].split('track:"')[1][:-1]
        results = (
            []
            if title == "Unavailable"
            else [
                {"id": 9, "title": "Unrelated", "duration": 180},
                {"id": 8, "title": title, "duration": 186},
                {"id": 2 if title == "Search" else 3, "title": title, "duration": 185},
            ]
        )
        return httpx.Response(200, json={"data": results})

    env.deezer_handler = handler
    batch = await run(env, playlist_ids=["own"], download_missing=True)
    assert (batch.total, batch.missing, batch.requested) == (5, 5, 5) and batch.status == "done"
    assert [r[2] for r in env.requests] == ["1", "2", "3", "1"]
    assert all(r[0] == env.user_id and r[1] == "track" and r[3] is False for r in env.requests)
    assert searches[0] == 'artist:"Artist" track:"Search"'
    async with SessionLocal() as db:
        rows = list(await db.scalars(select(SpotifyPending).order_by(SpotifyPending.created_at)))
        assert len(rows) == 5
        likes = [r for r in rows if r.like]
        assert len(likes) == 4 and all(r.like_at == ADDED and r.playlist_id is None for r in likes)
        search_row = next(r for r in rows if r.download_item_id is not None)
        assert search_row.deezer_id is None and search_row.title == "Unavailable"
        item = await db.get(DownloadItem, search_row.download_item_id)
        assert (await db.get(DownloadRequest, item.request_id)).kind == "search"
        playlist_row = next(r for r in rows if not r.like)
        assert playlist_row.position == 0 and playlist_row.playlist_id and playlist_row.like_at is None
        assert playlist_row.isrc == likes[0].isrc


@pytest.mark.parametrize("status", [429, 404])
async def test_download_request_errors(env, monkeypatch, status):
    from fastapi import HTTPException

    await connect(env)
    env.liked = [entry(song(str(i), isrc=None)) for i in range(3)]
    env.deezer_handler = lambda r: httpx.Response(200, json={"data": [{"id": 1, "title": "0 1 2", "duration": 180}]})
    attempts = []

    async def request(*args, **kwargs):
        attempts.append(args)
        raise HTTPException(status, "limit")

    monkeypatch.setattr(spotify, "create_request", request)
    batch = await run(env, download_missing=True)
    assert batch.status == "done" and batch.missing == 3 and batch.requested == 0
    assert len(attempts) == (1 if status == 429 else 3)
    assert batch.message == (
        "Tageslimit erreicht – weitere fehlende Songs wurden nicht angefragt" if status == 429 else None
    )
    async with SessionLocal() as db:
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0


@pytest.mark.parametrize("isrc", [None, "USNICHE00001"])
async def test_niche_search_download_resolves_playlist(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, isrc: str | None
) -> None:
    from app.services import downloads, sources

    await connect(env)
    env.items["own"] = [entry(song("Underground", isrc=isrc, duration=3000), key="item")]
    env.deezer_handler = lambda request: httpx.Response(
        200, json={"error": {"code": 800}} if request.url.path.startswith("/track/isrc:") else {"data": []}
    )
    fake = FakeSource()
    fake.name = "soundcloud"
    monkeypatch.setattr(sources, "enabled_sources", lambda cfg: [fake])
    monkeypatch.setattr(spotify, "resolve_after_download", lambda: None)

    async def cover(meta: TrackMeta) -> bytes | None:
        return None

    monkeypatch.setattr(downloads, "fetch_cover", cover)
    batch = await run(env, liked=False, playlist_ids=["own"], download_missing=True)
    assert (batch.status, batch.total, batch.missing, batch.requested) == ("done", 1, 1, 1)
    assert env.requests == []
    async with SessionLocal() as db:
        pending = await db.scalar(select(SpotifyPending))
        assert pending.download_item_id is not None and pending.deezer_id is None
        item_id, playlist_id = pending.download_item_id, pending.playlist_id
        item = await db.get(DownloadItem, item_id)
        request = await db.get(DownloadRequest, item.request_id)
        assert request.kind == "search" and request.title == "Underground" and request.is_temporary is False
        assert item.meta["artist"] == item.meta["album_artist"] == "Artist"
        assert item.meta["album"] == "Album" and item.meta["duration"] == 3
        assert await spotify.resolve_pending(db) == 0
    assert await downloads.DownloadManager().process_one()
    async with SessionLocal() as db:
        item = await db.get(DownloadItem, item_id)
        track = await db.get(Track, item.track_id)
        assert item.status == "done" and item.source == "soundcloud" and not track.is_temporary
        track.is_temporary = True
        await db.commit()
        assert await spotify.resolve_pending(db) == 0
        track.is_temporary = False
        await db.commit()
        assert await spotify.resolve_pending(db) == 1
        assert await spotify.resolve_pending(db) == 0
        entries = list(await db.scalars(select(PlaylistEntry).where(PlaylistEntry.playlist_id == playlist_id)))
        assert len(entries) == 1 and entries[0].track_id == track.id and entries[0].position == 0
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0


async def test_niche_search_daily_limit_stops_requests(env: SimpleNamespace) -> None:
    await connect(env, env.user)
    env.liked = [entry(song(str(i), isrc=None)) for i in range(3)]
    env.deezer_handler = lambda request: httpx.Response(200, json={"data": []})
    async with SessionLocal() as db:
        await update_config(db, {"downloads": {"daily_limit_per_user": 1}})
        user_id = uuid.UUID(env.user["user"]["id"])
        batch = SpotifyImport(user_id=user_id, status="queued", liked=True, playlist_ids=[], download_missing=True)
        db.add(batch)
        await db.commit()
        batch_id = batch.id
    await spotify.run_import(batch_id)
    async with SessionLocal() as db:
        batch = await db.get(SpotifyImport, batch_id)
        assert batch.status == "done" and batch.missing == 3 and batch.requested == 1
        assert batch.message == "Tageslimit erreicht – weitere fehlende Songs wurden nicht angefragt"
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 1
        assert await db.scalar(select(func.count()).select_from(DownloadRequest)) == 1


async def test_resolve_pending_isrc_deezer_positions_expiry_and_duplicates(env):
    async with SessionLocal() as db:
        playlist = Playlist(owner_id=env.user_id, name="Imported")
        db.add(playlist)
        await db.flush()
        first = await library_track(db)
        second = await library_track(db, "Downloaded", isrc=None)
        temporary = await library_track(db, "Temporary", isrc="TEMP", temporary=True)
        request = DownloadRequest(user_id=env.user_id, kind="track", title="Downloaded", artist="Artist", status="done")
        db.add(request)
        await db.flush()
        db.add(
            DownloadItem(
                request_id=request.id,
                position=0,
                title="Downloaded",
                artist="Artist",
                meta={"deezer_track_id": "42"},
                status="done",
                track_id=second.id,
            )
        )
        for position in [2, 2, 5]:
            db.add(
                SpotifyPending(
                    user_id=env.user_id,
                    title="Song",
                    artist="Artist",
                    isrc=first.isrc,
                    like=True,
                    like_at=ADDED,
                    playlist_id=playlist.id,
                    position=position,
                )
            )
        db.add(
            SpotifyPending(
                user_id=env.user_id,
                title="Downloaded",
                artist="Artist",
                deezer_id="42",
                like=False,
                playlist_id=playlist.id,
                position=1,
            )
        )
        db.add(
            SpotifyPending(
                user_id=env.user_id,
                title="Old",
                artist="Artist",
                like=True,
                created_at=datetime.now(UTC) - timedelta(days=31),
            )
        )
        db.add(SpotifyPending(user_id=env.user_id, title="Temporary", artist="Artist", isrc=temporary.isrc, like=True))
        db.add(
            SpotifyPending(
                user_id=env.user_id, title="Unresolved ISRC", artist="Artist", isrc="UNKNOWN", deezer_id="42", like=True
            )
        )
        await db.commit()
        assert await spotify.resolve_pending(db) == 4
        assert await spotify.resolve_pending(db) == 0
        likes = list(await db.scalars(select(TrackLike)))
        assert len(likes) == 1 and likes[0].track_id == first.id and likes[0].created_at == ADDED
        rows = list(await db.scalars(select(PlaylistEntry).order_by(PlaylistEntry.position)))
        assert [(r.track_id, r.position) for r in rows] == [(second.id, 1), (first.id, 2), (first.id, 5)]
        remaining = list(await db.scalars(select(SpotifyPending)))
        assert {r.title for r in remaining} == {"Temporary", "Unresolved ISRC"}


async def test_pending_resolves_after_track_appears_and_newest_item(env):
    async with SessionLocal() as db:
        db.add(
            SpotifyPending(
                user_id=env.user_id, title="Song", artist="Artist", isrc="USABC1234567", like=True, like_at=ADDED
            )
        )
        db.add(SpotifyPending(user_id=env.user_id, title="Newest", artist="Artist", deezer_id="42", like=True))
        await db.commit()
        assert await spotify.resolve_pending(db) == 0
        first = await library_track(db)
        newer = await library_track(db, "Newest", isrc=None)
        request = DownloadRequest(user_id=env.user_id, kind="track", title="Track", artist="Artist", status="done")
        db.add(request)
        await db.flush()
        for index, track in enumerate([first, newer]):
            db.add(
                DownloadItem(
                    request_id=request.id,
                    position=index,
                    title="Track",
                    artist="Artist",
                    meta={"deezer_track_id": "42"},
                    status="done",
                    track_id=track.id,
                    updated_at=ADDED + timedelta(days=index),
                )
            )
        await db.commit()
        assert await spotify.resolve_pending(db) == 2
        assert set(await db.scalars(select(TrackLike.track_id))) == {first.id, newer.id}


async def test_api_imports_conflicts_listing_and_isolation(env, monkeypatch):
    launched = []
    monkeypatch.setattr(spotify, "launch_import", launched.append)
    body = {"liked": True, "playlist_ids": [], "download_missing": False}
    assert (await env.client.get("/api/spotify/playlists", headers=env.headers)).json()[
        "detail"
    ] == "Kein Spotify-Konto verbunden"
    assert (await env.client.post("/api/spotify/imports", headers=env.headers, json=body)).status_code == 409
    await connect(env)
    nothing = await env.client.post("/api/spotify/imports", headers=env.headers, json={**body, "liked": False})
    assert nothing.status_code == 422 and nothing.json()["detail"] == "Nichts ausgewählt"
    assert (
        await env.client.post("/api/spotify/imports", headers=env.headers, json={**body, "playlist_ids": ["p"] * 201})
    ).status_code == 422
    created = await env.client.post("/api/spotify/imports", headers=env.headers, json=body)
    assert created.status_code == 202, created.text
    id = created.json()["id"]
    assert created.json()["missing_tracks"] == [] and launched == [uuid.UUID(id)]
    conflict = await env.client.post("/api/spotify/imports", headers=env.headers, json=body)
    assert conflict.status_code == 409 and conflict.json()["detail"] == "Es läuft bereits ein Import"
    async with SessionLocal() as db:
        batch = await db.get(SpotifyImport, uuid.UUID(id))
        batch.status = "running"
        await db.commit()
    assert (await env.client.post("/api/spotify/imports", headers=env.headers, json=body)).status_code == 409
    assert (await env.client.get("/api/spotify/imports/" + id, headers=env.headers)).json()["id"] == id
    other_headers = auth(env.user["token"])
    assert (await env.client.get("/api/spotify/imports/" + id, headers=other_headers)).status_code == 404
    assert (await env.client.get("/api/spotify/imports", headers=other_headers)).json() == []
    await connect(env, env.user)
    assert (await env.client.post("/api/spotify/imports", headers=other_headers, json=body)).status_code == 202
    async with SessionLocal() as db:
        for i in range(25):
            db.add(
                SpotifyImport(
                    user_id=env.user_id,
                    status="done",
                    liked=True,
                    playlist_ids=[],
                    download_missing=False,
                    created_at=ADDED + timedelta(days=i),
                )
            )
        await db.commit()
    listing = (await env.client.get("/api/spotify/imports", headers=env.headers)).json()
    assert len(listing) == 20 and all("missing_tracks" not in row for row in listing)
    assert [row["created_at"] for row in listing] == sorted([row["created_at"] for row in listing], reverse=True)


async def test_startup_recovery_and_shutdown(env):
    async with SessionLocal() as db:
        for status in ["queued", "running", "done"]:
            db.add(
                SpotifyImport(user_id=env.user_id, status=status, liked=True, playlist_ids=[], download_missing=False)
            )
        await db.commit()
    async with app.router.lifespan_context(app):
        assert spotify._loop_task and not spotify._loop_task.done()
        async with SessionLocal() as db:
            rows = list(await db.scalars(select(SpotifyImport)))
            assert sorted(r.status for r in rows) == ["done", "failed", "failed"]
            assert all(
                r.message == "Durch Neustart abgebrochen" and r.finished_at for r in rows if r.status == "failed"
            )
    assert spotify._loop_task is None and not spotify._tasks


async def test_download_completion_launches_resolution(env):
    async with SessionLocal() as db:
        track = await library_track(db)
        db.add(
            SpotifyPending(
                user_id=env.user_id, title="Song", artist="Artist", isrc=track.isrc, like=True, like_at=ADDED
            )
        )
        request = DownloadRequest(user_id=env.user_id, kind="track", title="Track", artist="Artist", status="active")
        db.add(request)
        await db.flush()
        item = DownloadItem(
            request_id=request.id, position=0, title="Track", artist="Artist", meta={}, status="processing"
        )
        db.add(item)
        await db.commit()
    await manager._change(item.id, status="done", track_id=track.id)
    tasks = list(spotify._tasks)
    assert tasks
    await asyncio.gather(*tasks)
    async with SessionLocal() as db:
        assert await db.scalar(select(TrackLike.track_id)) == track.id
        assert await db.scalar(select(func.count()).select_from(SpotifyPending)) == 0


async def test_background_loop_interval(env, monkeypatch):
    delays = []
    resolved = []

    async def sleep(seconds):
        delays.append(seconds)
        if len(delays) > 1:
            raise asyncio.CancelledError

    async def resolve():
        resolved.append(True)

    monkeypatch.setattr(spotify.asyncio, "sleep", sleep)
    monkeypatch.setattr(spotify, "_resolve", resolve)
    with pytest.raises(asyncio.CancelledError):
        await spotify._resolve_loop()
    assert delays == [60, 60] and resolved == [True]


async def test_generic_import_failure_and_missing_cap(env):
    await connect(env)
    env.liked = [entry(song("Missing", isrc=None))] * 2001
    batch = await run(env)
    assert batch.total == batch.missing == 2001 and len(batch.missing_tracks) == 2000
    env.handler = lambda r: httpx.Response(200, json={})
    batch = await run(env)
    assert batch.status == "failed" and batch.message == "Import fehlgeschlagen" and batch.finished_at


async def test_api_launches_import_task(env):
    await connect(env)
    result = await env.client.post(
        "/api/spotify/imports",
        headers=env.headers,
        json={"liked": True, "playlist_ids": [], "download_missing": False},
    )
    assert result.status_code == 202
    tasks = list(spotify._tasks)
    assert tasks
    await asyncio.gather(*tasks)
    detail = await env.client.get("/api/spotify/imports/" + result.json()["id"], headers=env.headers)
    assert detail.json()["status"] == "done" and not spotify._tasks


async def test_resolution_errors_are_only_logged(env, monkeypatch, caplog):
    async def fail(db):
        raise RuntimeError("test failure")

    monkeypatch.setattr(spotify, "resolve_pending", fail)
    spotify.resolve_after_download()
    await asyncio.gather(*spotify._tasks)
    assert "Spotify pending resolution failed" in caplog.text
