"""End-to-end API flow: setup -> invites -> scan -> browse -> stream -> playlists.

Tests share one database and run in file order.
"""

import asyncio

import pytest
from pydantic import ValidationError

from app.services.server_config import IntegrationsConfig, ServerConfig
from tests.conftest import auth, make_track, register

state: dict = {}


def test_discord_config_validation():
    assert ServerConfig().integrations.discord_client_id == ""
    for value in ("", "0", "123456789012345678901234"):
        assert IntegrationsConfig(discord_client_id=value).discord_client_id == value
    for value in ("1234567890123456789012345", "abc", "123 456", "-123", "123\n", 123, None):
        with pytest.raises(ValidationError, match="Discord-Anwendungs-ID"):
            IntegrationsConfig(discord_client_id=value)


async def test_first_user_becomes_admin(client):
    r = await client.get("/api/auth/status")
    assert r.json()["setup_required"] is True
    assert r.json()["registration_mode"] == "invite"

    data = await register(client, "admin")
    assert data["user"]["role"] == "admin"
    assert data["user"]["accent_color"] == "#1DB954"
    state["admin"] = data["token"]


async def test_registration_requires_invite_by_default(client):
    r = await client.post("/api/auth/register", json={"username": "eve", "password": "password123"})
    assert r.status_code == 403


async def test_invite_is_one_time(client):
    r = await client.post("/api/admin/invites", json={"note": "Lisa"}, headers=auth(state["admin"]))
    assert r.status_code == 201
    token = r.json()["token"]

    assert (await client.get(f"/api/auth/invites/{token}")).json() == {"valid": True}
    user = await register(client, "lisa", invite=token)
    assert user["user"]["role"] == "user"
    state["user"] = user["token"]

    assert (await client.get(f"/api/auth/invites/{token}")).json() == {"valid": False}
    r = await client.post(
        "/api/auth/register", json={"username": "mallory", "password": "password123", "invite": token}
    )
    assert r.status_code == 400

    invites = (await client.get("/api/admin/invites", headers=auth(state["admin"]))).json()
    assert invites[0]["used_by_username"] == "lisa"


async def test_admin_endpoints_hidden_from_users(client):
    assert (await client.get("/api/admin/config", headers=auth(state["user"]))).status_code == 403
    assert (await client.get("/api/admin/users", headers=auth(state["user"]))).status_code == 403


async def test_discord_client_config(client):
    assert (await client.get("/api/client-config")).status_code == 401
    assert (await client.get("/api/client-config", headers=auth("invalid"))).status_code == 401
    headers = auth(state["user"])
    assert (await client.get("/api/client-config", headers=headers)).json() == {"discord_client_id": ""}
    patch = {"integrations": {"discord_client_id": "123456789012345678"}}
    assert (await client.patch("/api/admin/config", headers=headers, json=patch)).status_code == 403
    admin = auth(state["admin"])
    result = await client.patch("/api/admin/config", headers=admin, json=patch)
    assert result.status_code == 200
    assert result.json()["integrations"] == patch["integrations"]
    assert (await client.get("/api/client-config", headers=headers)).json() == patch["integrations"]
    result = await client.patch(
        "/api/admin/config", headers=admin, json={"integrations": {"discord_client_id": "invalid"}}
    )
    assert result.status_code == 422
    assert "Discord-Anwendungs-ID" in result.json()["detail"]
    assert (await client.get("/api/client-config", headers=headers)).json() == patch["integrations"]
    await client.patch("/api/admin/config", headers=admin, json={"integrations": {"discord_client_id": ""}})
    assert (await client.get("/api/client-config", headers=headers)).json() == {"discord_client_id": ""}


async def test_public_registration_toggle(client):
    r = await client.patch("/api/admin/config", json={"registration": {"mode": "public"}}, headers=auth(state["admin"]))
    assert r.json()["registration"]["mode"] == "public"
    # Other sections keep their defaults when patching one key.
    assert r.json()["radio"]["temporary_tracks_enabled"] is True
    await register(client, "open")

    await client.patch("/api/admin/config", json={"registration": {"mode": "invite"}}, headers=auth(state["admin"]))
    r = await client.post("/api/auth/register", json={"username": "closed", "password": "password123"})
    assert r.status_code == 403

    r = await client.patch(
        "/api/admin/config", json={"radio": {"temporary_retention_days": 0}}, headers=auth(state["admin"])
    )
    assert r.status_code == 422


async def test_accent_color(client):
    r = await client.patch("/api/me", json={"accent_color": "#ff5500"}, headers=auth(state["user"]))
    assert r.json()["accent_color"] == "#FF5500"
    r = await client.patch("/api/me", json={"accent_color": "red"}, headers=auth(state["user"]))
    assert r.status_code == 422


async def test_scan_library(client):
    make_track(
        "Daft Punk/Discovery (2001)/01 - One More Time.mp3",
        title="One More Time",
        artist="Daft Punk",
        album="Discovery",
        track="1",
        date="2001",
    )
    make_track(
        "Daft Punk/Discovery (2001)/02 - Aerodynamic.flac",
        title="Aerodynamic",
        artist="Daft Punk",
        album="Discovery",
        track="2/14",
        date="2001-03-12",
    )
    make_track(
        "Daft Punk/Random Access Memories/08 - Get Lucky.flac",
        title="Get Lucky",
        artist="Daft Punk feat. Pharrell Williams",
        album="Random Access Memories",
        album_artist="Daft Punk",
        track="8",
    )
    make_track("untagged/Some Folder/song.mp3")
    # Folder cover for Discovery
    from PIL import Image

    from tests.conftest import MUSIC_DIR

    Image.new("RGB", (800, 800), (200, 30, 30)).save(MUSIC_DIR / "Daft Punk/Discovery (2001)/cover.jpg")

    r = await client.post("/api/admin/library/scan", headers=auth(state["admin"]))
    assert r.status_code == 202
    for _ in range(100):
        jobs = (await client.get("/api/admin/jobs", headers=auth(state["admin"]))).json()
        if jobs[0]["status"] in ("done", "failed"):
            break
        await asyncio.sleep(0.1)
    assert jobs[0]["status"] == "done", jobs[0]

    stats = (await client.get("/api/admin/library/stats", headers=auth(state["admin"]))).json()
    assert stats["tracks"] == 4
    assert isinstance(stats["total_bytes"], int) and stats["total_bytes"] > 0
    assert stats["albums"] == 3
    # Daft Punk + "untagged" folder fallback artist; "feat." is folded into Daft Punk.
    assert stats["artists"] == 2


async def test_browse(client):
    h = auth(state["user"])
    albums = (await client.get("/api/albums?sort=title", headers=h)).json()
    discovery = next(a for a in albums["items"] if a["title"] == "Discovery")
    assert discovery["has_cover"] is True
    assert discovery["year"] == 2001
    state["album"] = discovery["id"]

    detail = (await client.get(f"/api/albums/{discovery['id']}", headers=h)).json()
    assert [t["title"] for t in detail["tracks"]] == ["One More Time", "Aerodynamic"]
    state["tracks"] = [t["id"] for t in detail["tracks"]]

    r = await client.get(f"/api/albums/{discovery['id']}/cover?size=100", headers=h)
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"

    res = (await client.get("/api/search?q=lucky", headers=h)).json()
    assert res["tracks"][0]["artist_credit"] == "Daft Punk feat. Pharrell Williams"
    assert res["tracks"][0]["artist"]["name"] == "Daft Punk"

    artist = (await client.get(f"/api/artists/{res['tracks'][0]['artist']['id']}", headers=h)).json()
    assert artist["album_count"] == 2


async def test_stream_supports_range_and_transcode(client):
    track_id = state["tracks"][1]
    r = await client.get(f"/api/tracks/{track_id}/stream?token={state['user']}", headers={"Range": "bytes=0-99"})
    assert r.status_code == 206
    assert len(r.content) == 100
    assert r.headers["content-type"] == "audio/flac"

    r = await client.get(f"/api/tracks/{track_id}/stream?format=opus&bitrate=96", headers=auth(state["user"]))
    assert r.status_code == 200
    assert r.content[:4] == b"OggS"
    full = r.content

    # TVs resume a transcode by byte range: answered from the cached file, with length.
    url = f"/api/tracks/{track_id}/stream?format=opus&bitrate=96"
    r = await client.get(url, headers={**auth(state["user"]), "Range": "bytes=100-199"})
    assert r.status_code == 206 and r.content == full[100:200]
    assert r.headers["content-range"] == f"bytes 100-199/{len(full)}"
    r = await client.get(url, headers=auth(state["user"]))
    assert r.headers["content-length"] == str(len(full)) and r.content == full

    # A range request for a transcode that has not run yet waits for it.
    mp3 = f"/api/tracks/{track_id}/stream?format=mp3&bitrate=128"
    r = await client.get(mp3, headers={**auth(state["user"]), "Range": "bytes=10-"})
    assert r.status_code == 206 and r.headers["content-type"] == "audio/mpeg"

    assert (await client.get(f"/api/tracks/{track_id}/stream")).status_code == 401


async def test_likes_playlists_and_home(client):
    h = auth(state["user"])
    a, b = state["tracks"]
    assert (await client.put(f"/api/me/likes/tracks/{a}", headers=h)).status_code == 204
    liked = (await client.get("/api/me/likes/tracks", headers=h)).json()
    assert [t["id"] for t in liked] == [a] and liked[0]["liked"] is True

    p = (await client.post("/api/playlists", json={"name": "Roadtrip"}, headers=h)).json()
    pid = p["id"]
    await client.post(f"/api/playlists/{pid}/tracks", json={"track_ids": [a, b]}, headers=h)
    entries = (await client.get(f"/api/playlists/{pid}", headers=h)).json()["entries"]
    # Move b before a
    await client.post(
        f"/api/playlists/{pid}/move",
        json={"entry_id": entries[1]["entry_id"], "before_entry_id": entries[0]["entry_id"]},
        headers=h,
    )
    detail = (await client.get(f"/api/playlists/{pid}", headers=h)).json()
    assert [e["track"]["id"] for e in detail["entries"]] == [b, a]
    assert detail["track_count"] == 2 and detail["cover_album_ids"] == [state["album"]]

    # Private playlists are invisible to others
    assert (await client.get(f"/api/playlists/{pid}", headers=auth(state["admin"]))).status_code == 404

    await client.post("/api/me/plays", json={"track_id": a, "seconds_played": 120}, headers=h)
    home = (await client.get("/api/home", headers=h)).json()
    assert home["recently_played"][0]["id"] == state["album"]
    assert home["most_played"][0]["id"] == a
    assert home["playlists"][0]["name"] == "Roadtrip"


async def test_last_admin_cannot_be_demoted(client):
    users = (await client.get("/api/admin/users", headers=auth(state["admin"]))).json()
    admin_id = next(u["id"] for u in users if u["username"] == "admin")
    r = await client.patch(f"/api/admin/users/{admin_id}", json={"role": "user"}, headers=auth(state["admin"]))
    assert r.status_code == 400


async def test_logout_revokes_token(client):
    login = (await client.post("/api/auth/login", json={"username": "LISA", "password": "password123"})).json()
    assert (await client.post("/api/auth/logout", headers=auth(login["token"]))).status_code == 204
    assert (await client.get("/api/me", headers=auth(login["token"]))).status_code == 401
