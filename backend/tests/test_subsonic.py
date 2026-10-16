import hashlib
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import urlencode
from xml.etree import ElementTree as ET

import httpx
import pytest
from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import (
    Album,
    Artist,
    Job,
    PlayEvent,
    Playlist,
    PlaylistShare,
    Role,
    SavedAlbum,
    Track,
    TrackLike,
    User,
)
from app.services import covers
from app.services.server_config import update_config
from PIL import Image
from sqlalchemy import func, select

from tests.conftest import auth, make_track, register


@pytest.fixture
async def env(
    client: httpx.AsyncClient, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    settings = get_settings()
    monkeypatch.setattr(settings, "music_dir", tmp_path / "music")
    monkeypatch.setattr(settings, "data_dir", tmp_path / "data")
    settings.music_dir.mkdir()
    account = await register(client, "subsonic")
    headers = auth(account["token"])
    password = (await client.post("/api/me/subsonic-password", headers=headers)).json()["password"]
    now = datetime.now(UTC)
    async with SessionLocal() as db:
        user = await db.get(User, uuid.UUID(account["user"]["id"]))
        other = User(
            username="other",
            display_name="Other",
            password_hash=user.password_hash,
            role=Role.user,
            subsonic_password="other-secret",
        )
        unset = User(username="unset", display_name="Unset", password_hash=user.password_hash, role=Role.user)
        artists = [
            Artist(name="Alpha", name_key="alpha", sort_name="Baker, Alpha"),
            Artist(name="Zeta", name_key="zeta"),
        ]
        db.add_all([other, unset, *artists])
        await db.flush()
        albums = [
            Album(
                title="Dawn",
                title_key="dawn",
                artist_id=artists[0].id,
                year=2001,
                genre="Rock",
                created_at=now - timedelta(days=3),
            ),
            Album(
                title="Zenith",
                title_key="zenith",
                artist_id=artists[0].id,
                year=2020,
                genre="Jazz",
                created_at=now - timedelta(days=1),
            ),
            Album(
                title="Other",
                title_key="other",
                artist_id=artists[1].id,
                year=1990,
                genre="Pop",
                created_at=now - timedelta(days=2),
            ),
        ]
        db.add_all(albums)
        await db.flush()
        tracks = []
        for i, (album_index, disc, number) in enumerate([(0, 1, 2), (0, 1, 1), (0, 2, 1), (1, 1, 1), (2, 1, 1)]):
            album = albums[album_index]
            path = settings.music_dir / f"track-{i}.flac"
            path.write_bytes(bytes(range(256)) * 4)
            tracks.append(
                Track(
                    path=path.name,
                    title=f"Song {i}",
                    album_id=album.id,
                    artist_id=album.artist_id,
                    artist_credit="Alpha feat. Guest" if album_index < 2 else "Zeta",
                    track_no=number,
                    disc_no=disc,
                    duration=120.5 + i,
                    year=album.year,
                    genre=album.genre,
                    codec="flac",
                    bitrate=900,
                    sample_rate=44100,
                    size=1024,
                    isrc="DEABC1234567" if i == 0 else None,
                    replaygain_track_gain=-5.2 if i == 0 else None,
                    replaygain_album_gain=-4.1 if i == 0 else None,
                    is_temporary=i == 0,
                )
            )
        db.add_all(tracks)
        await db.flush()
        db.add_all(
            [
                PlayEvent(
                    user_id=user.id, track_id=tracks[0].id, seconds_played=120, played_at=now - timedelta(days=2)
                ),
                PlayEvent(
                    user_id=user.id, track_id=tracks[0].id, seconds_played=120, played_at=now - timedelta(days=2)
                ),
                PlayEvent(
                    user_id=user.id, track_id=tracks[3].id, seconds_played=120, played_at=now - timedelta(days=1)
                ),
            ]
        )
        await update_config(db, {"library": {"lyrics_online": False}})
        await db.commit()
    yield SimpleNamespace(
        client=client,
        user=user,
        other=other,
        unset=unset,
        artists=artists,
        albums=albums,
        tracks=tracks,
        password=password,
        headers=headers,
        settings=settings,
        params={"u": user.username, "p": password, "v": "1.16.1", "c": "test", "f": "json"},
    )


async def call(env: SimpleNamespace, endpoint: str, **params: object) -> dict:
    response = await env.client.get(f"/rest/{endpoint}", params={**env.params, **params})
    assert response.status_code == 200, response.text
    result = response.json()["subsonic-response"]
    assert result["status"] == "ok", result
    return result


@pytest.mark.parametrize("mechanism", ["plain", "encoded", "token", "apiKey"])
async def test_authentication(env: SimpleNamespace, mechanism: str) -> None:
    params = {"v": "1.16.1", "c": "test", "f": "json"}
    if mechanism == "apiKey":
        params["apiKey"] = env.password
    else:
        params["u"] = "SUBSONIC"
        if mechanism == "token":
            params.update(t=hashlib.md5((env.password + "salty").encode()).hexdigest(), s="salty")
        else:
            params["p"] = env.password if mechanism == "plain" else "enc:" + env.password.encode().hex()
    response = await env.client.get("/rest/ping", params=params)
    assert response.status_code == 200
    assert response.json()["subsonic-response"]["status"] == "ok"


@pytest.mark.parametrize(
    ("credentials", "code"),
    [
        ({"u": "subsonic", "p": "wrong"}, 40),
        ({"u": "subsonic", "p": "password123"}, 40),
        ({"u": "unset", "p": "anything"}, 40),
        ({"u": "missing", "p": "anything"}, 40),
        ({"u": "subsonic", "p": "enc:xx"}, 40),
        ({"u": "subsonic", "t": "wrong", "s": "salt"}, 40),
        ({"apiKey": "wrong"}, 44),
        ({"apiKey": "key", "u": "subsonic"}, 43),
        ({"u": "subsonic", "p": "pass", "t": "token", "s": "salt"}, 43),
        ({"apiKey": "key", "p": "pass"}, 43),
        ({"u": "subsonic", "t": "token"}, 10),
        ({}, 10),
    ],
)
async def test_authentication_errors(env: SimpleNamespace, credentials: dict, code: int) -> None:
    response = await env.client.get("/rest/ping", params={"v": "1.16.1", "c": "test", "f": "json", **credentials})
    assert response.status_code == 200
    assert response.json()["subsonic-response"]["error"]["code"] == code


async def test_disabled_user(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        user = await db.get(User, env.user.id)
        user.is_disabled = True
        await db.commit()
    for credentials in ({"u": env.user.username, "p": env.password}, {"apiKey": env.password}):
        response = await env.client.get("/rest/ping", params={"f": "json", **credentials})
        assert response.json()["subsonic-response"]["error"]["code"] == 40


async def test_password_lifecycle(env: SimpleNamespace) -> None:
    assert len(env.password) == 24
    response = await env.client.get("/api/me", headers=env.headers)
    assert response.json()["has_subsonic_password"] is True
    assert "subsonic_password" not in response.json()
    replacement = (await env.client.post("/api/me/subsonic-password", headers=env.headers)).json()["password"]
    assert replacement != env.password and len(replacement) == 24
    failed = await env.client.get("/rest/ping", params=env.params)
    assert failed.json()["subsonic-response"]["error"]["code"] == 40
    assert (await call(env, "ping", p=replacement))["status"] == "ok"
    assert (await env.client.delete("/api/me/subsonic-password", headers=env.headers)).status_code == 204
    assert (await env.client.get("/api/me", headers=env.headers)).json()["has_subsonic_password"] is False
    failed = await env.client.get("/rest/ping", params={**env.params, "p": replacement})
    assert failed.json()["subsonic-response"]["error"]["code"] == 40
    assert (await env.client.post("/api/me/subsonic-password")).status_code == 401


async def test_envelopes_xml_lists_and_post(env: SimpleNamespace) -> None:
    ns = {"s": "http://subsonic.org/restapi"}
    ping = await call(env, "ping")
    assert ping == {
        "status": "ok",
        "version": "1.16.1",
        "type": "resonance",
        "serverVersion": "0.1.0",
        "openSubsonic": True,
    }
    for endpoint in ("ping", "getArtists"):
        response = await env.client.get(f"/rest/{endpoint}", params={**env.params, "f": "xml"})
        root = ET.fromstring(response.content)
        assert root.tag == "{http://subsonic.org/restapi}subsonic-response"
        assert root.attrib == {
            **{key: str(value) for key, value in ping.items() if key != "openSubsonic"},
            "openSubsonic": "true",
        }
        if endpoint == "getArtists":
            assert len(root.findall("s:artists/s:index/s:artist", ns)) == 2
    response = await env.client.post("/rest/ping.view", data={**env.params, "f": "jsonp"})
    assert response.json()["subsonic-response"] == ping
    response = await env.client.post("/rest/getAlbum.view", params={"id": str(env.albums[0].id)}, data=env.params)
    assert len(response.json()["subsonic-response"]["album"]["song"]) == 3
    body = urlencode([("id", str(env.tracks[1].id)), *env.params.items()])
    response = await env.client.post(
        "/rest/star.view",
        params={"id": str(env.tracks[0].id)},
        content=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    assert response.json()["subsonic-response"]["status"] == "ok"
    assert len((await call(env, "getStarred2"))["starred2"]["song"]) == 2
    response = await env.client.post("/rest/ping", params=env.params, data={"p": "conflicting"})
    assert response.json()["subsonic-response"]["error"]["code"] == 43


async def test_browsing_objects(env: SimpleNamespace) -> None:
    artists = (await call(env, "getArtists"))["artists"]
    assert artists["ignoredArticles"] == "The El La Los Las Le Les Die Der Das"
    assert [index["name"] for index in artists["index"]] == ["B", "Z"]
    assert artists["index"][0]["artist"][0]["albumCount"] == 2
    assert (await call(env, "getIndexes"))["indexes"] == artists
    artist = (await call(env, "getArtist", id=str(env.artists[0].id)))["artist"]
    assert [album["name"] for album in artist["album"]] == ["Zenith", "Dawn"]
    assert artist["coverArt"] == str(env.albums[0].id)
    assert "starred" not in artist
    album = (await call(env, "getAlbum", id=str(env.albums[0].id)))["album"]
    assert album["songCount"] == 3 and album["duration"] == 364 and album["playCount"] == 2
    assert [song["title"] for song in album["song"]] == ["Song 1", "Song 0", "Song 2"]
    song = (await call(env, "getSong", id=str(env.tracks[0].id)))["song"]
    assert song["isDir"] is False and song["artist"] == "Alpha feat. Guest"
    assert song["parent"] == song["coverArt"] == song["albumId"] == str(env.albums[0].id)
    assert song["duration"] == 120 and song["playCount"] == 2 and "played" in song
    assert song["isrc"] == ["DEABC1234567"]
    assert song["samplingRate"] == 44100 and song["bitRate"] == 900
    assert song["replayGain"] == {"trackGain": -5.2, "albumGain": -4.1}
    assert song["contentType"] == "audio/flac" and song["path"] == "track-0.flac"
    assert "starred" not in song
    unknown = (await call(env, "getSong", id=str(env.tracks[1].id)))["song"]
    assert "isrc" not in unknown and "replayGain" not in unknown and "played" not in unknown
    directory = (await call(env, "getMusicDirectory", id=str(env.artists[0].id)))["directory"]
    assert all(child["isDir"] for child in directory["child"])
    assert {child["title"] for child in directory["child"]} == {"Dawn", "Zenith"}
    directory = (await call(env, "getMusicDirectory", id=str(env.albums[0].id)))["directory"]
    assert [child["id"] for child in directory["child"]] == [song["id"] for song in album["song"]]


@pytest.mark.parametrize(
    ("kind", "extra", "expected"),
    [
        ("newest", {}, ["Zenith", "Other", "Dawn"]),
        ("alphabeticalByName", {}, ["Dawn", "Other", "Zenith"]),
        ("alphabeticalByArtist", {}, ["Dawn", "Zenith", "Other"]),
        ("highest", {}, ["Dawn", "Zenith"]),
        ("frequent", {}, ["Dawn", "Zenith"]),
        ("recent", {}, ["Zenith", "Dawn"]),
        ("byYear", {"fromYear": 1990, "toYear": 2010}, ["Other", "Dawn"]),
        ("byYear", {"fromYear": 2020, "toYear": 2000}, ["Zenith", "Dawn"]),
        ("byGenre", {"genre": "rock"}, ["Dawn"]),
        ("starred", {}, []),
    ],
)
async def test_album_lists(env: SimpleNamespace, kind: str, extra: dict, expected: list[str]) -> None:
    albums = (await call(env, "getAlbumList2", type=kind, **extra))["albumList2"]["album"]
    assert [album["name"] for album in albums] == expected
    legacy = (await call(env, "getAlbumList", type=kind, **extra))["albumList"]["album"]
    assert [album["title"] for album in legacy] == expected
    assert all(album["isDir"] for album in legacy)


async def test_filters_search_and_recommendations(env: SimpleNamespace) -> None:
    random = (await call(env, "getAlbumList2", type="random", size=999))["albumList2"]["album"]
    assert len(random) == 3
    page = (await call(env, "getAlbumList2", type="alphabeticalByName", size=1, offset=1))["albumList2"]["album"]
    assert [album["name"] for album in page] == ["Other"]
    for query in ("", '""'):
        result = (await call(env, "search3", query=query))["searchResult3"]
        assert len(result["artist"]) == 2 and len(result["album"]) == 3 and len(result["song"]) == 5
    result = (await call(env, "search3", query="Song", songCount=2, songOffset=1, artistCount=0, albumCount=0))[
        "searchResult3"
    ]
    assert [song["title"] for song in result["song"]] == ["Song 1", "Song 2"]
    assert result["artist"] == result["album"] == []
    assert len((await call(env, "search3", query="Alpha"))["searchResult3"]["song"]) == 4
    assert (await call(env, "search2", query="Dawn"))["searchResult2"]["album"][0]["isDir"] is True
    random = (await call(env, "getRandomSongs", genre="Rock", fromYear=2000, toYear=2010, size=2))["randomSongs"][
        "song"
    ]
    assert len(random) == 2 and all(song["album"] == "Dawn" for song in random)
    assert len((await call(env, "getRandomSongs", size=999))["randomSongs"]["song"]) == 5
    genre = (await call(env, "getSongsByGenre", genre="Rock", count=1, offset=1))["songsByGenre"]["song"]
    assert [song["title"] for song in genre] == ["Song 1"]
    genres = (await call(env, "getGenres"))["genres"]["genre"]
    assert {genre["value"]: (genre["songCount"], genre["albumCount"]) for genre in genres} == {
        "Jazz": (1, 1),
        "Pop": (1, 1),
        "Rock": (3, 1),
    }
    top = (await call(env, "getTopSongs", artist="Alpha", count=2))["topSongs"]["song"]
    assert [song["title"] for song in top] == ["Song 0", "Song 3"]
    for endpoint in ("getSimilarSongs", "getSimilarSongs2"):
        key = "similarSongs" + ("2" if endpoint.endswith("2") else "")
        similar = (await call(env, endpoint, id=str(env.tracks[0].id)))[key]["song"]
        assert {song["title"] for song in similar} == {"Song 1", "Song 2", "Song 3"}


async def test_playlists(env: SimpleNamespace) -> None:
    a, b, c = [str(track.id) for track in env.tracks[:3]]
    created = (await call(env, "createPlaylist", name="Test", songId=[a, b, a]))["playlist"]
    pid = created["id"]
    assert [song["id"] for song in created["entry"]] == [a, b, a]
    assert created["songCount"] == 3 and created["owner"] == "subsonic"
    assert created["coverArt"] == str(env.albums[0].id)
    assert len((await call(env, "getPlaylists"))["playlists"]["playlist"]) == 1
    await call(
        env,
        "updatePlaylist",
        playlistId=pid,
        name="Renamed",
        comment="Comment",
        public="true",
        songIndexToRemove=[0, 2],
        songIdToAdd=[c, b],
    )
    updated = (await call(env, "getPlaylist", id=pid))["playlist"]
    assert updated["name"] == "Renamed" and updated["comment"] == "Comment" and updated["public"] is True
    assert [song["id"] for song in updated["entry"]] == [b, c, b]
    replaced = (await call(env, "createPlaylist", playlistId=pid, songId=[c]))["playlist"]
    assert [song["id"] for song in replaced["entry"]] == [c]
    assert (await call(env, "createPlaylist", playlistId=pid))["playlist"]["entry"] == []
    invalid = await env.client.get(
        "/rest/updatePlaylist", params={**env.params, "playlistId": pid, "name": "Bad", "songIndexToRemove": 99}
    )
    assert invalid.json()["subsonic-response"]["status"] == "failed"
    assert (await call(env, "getPlaylist", id=pid))["playlist"]["name"] == "Renamed"
    await call(env, "deletePlaylist", id=pid)
    assert (await call(env, "getPlaylists"))["playlists"]["playlist"] == []
    async with SessionLocal() as db:
        track = await db.get(Track, env.tracks[0].id)
        assert track.is_temporary is False


async def test_playlist_permissions_and_mixes(env: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        shared = Playlist(owner_id=env.other.id, name="Shared", kind="user")
        private = Playlist(owner_id=env.other.id, name="Private", kind="user")
        public = Playlist(owner_id=env.other.id, name="Public", kind="user", is_public=True)
        mix = Playlist(owner_id=env.user.id, name="Mix", kind="mix")
        db.add_all([shared, private, public, mix])
        await db.flush()
        db.add(PlaylistShare(playlist_id=shared.id, user_id=env.user.id))
        await db.commit()
    visible = (await call(env, "getPlaylists"))["playlists"]["playlist"]
    assert {playlist["name"] for playlist in visible} == {"Shared", "Public"}
    assert (await call(env, "getPlaylist", id=str(shared.id)))["playlist"]["name"] == "Shared"
    for endpoint, params in (
        ("deletePlaylist", {"id": str(shared.id)}),
        ("updatePlaylist", {"playlistId": str(shared.id), "name": "Bad"}),
        ("createPlaylist", {"playlistId": str(shared.id), "songId": str(env.tracks[0].id)}),
    ):
        response = await env.client.get(f"/rest/{endpoint}", params={**env.params, **params})
        assert response.json()["subsonic-response"]["error"]["code"] == 50
    for playlist in (private, mix):
        response = await env.client.get("/rest/getPlaylist", params={**env.params, "id": str(playlist.id)})
        assert response.json()["subsonic-response"]["error"]["code"] == 70


async def test_stars_and_scrobbles(env: SimpleNamespace) -> None:
    track_id, album_id = str(env.tracks[0].id), str(env.albums[0].id)
    await call(env, "star", id=track_id, albumId=album_id, artistId=str(env.artists[0].id))
    await call(env, "star", id=track_id, albumId=album_id)
    starred = (await call(env, "getStarred2"))["starred2"]
    assert [song["id"] for song in starred["song"]] == [track_id]
    assert [album["id"] for album in starred["album"]] == [album_id]
    assert "starred" in starred["song"][0] and "starred" in starred["album"][0]
    assert (await call(env, "getStarred"))["starred"]["album"][0]["isDir"] is True
    assert len((await call(env, "getAlbumList2", type="starred"))["albumList2"]["album"]) == 1
    await call(env, "scrobble", id=[track_id, str(env.tracks[1].id)], submission="false")
    await call(env, "scrobble", id=[track_id, str(env.tracks[1].id)])
    async with SessionLocal() as db:
        plays = list(await db.scalars(select(PlayEvent).where(PlayEvent.context == "subsonic")))
        assert len(plays) == 2 and plays[0].user_id == env.user.id
        assert sorted(play.seconds_played for play in plays) == [120.5, 121.5]
        assert await db.scalar(select(func.count()).select_from(TrackLike)) == 1
        assert await db.scalar(select(func.count()).select_from(SavedAlbum)) == 1
        assert (await db.get(Track, env.tracks[0].id)).is_temporary is False
    await call(env, "unstar", id=track_id, albumId=album_id)
    starred = (await call(env, "getStarred2"))["starred2"]
    assert starred["song"] == starred["album"] == []
    assert "starred" not in (await call(env, "getSong", id=track_id))["song"]


async def test_media_range_covers_and_lyrics(env: SimpleNamespace, tmp_path: Path) -> None:
    track = env.tracks[0]
    path = env.settings.music_dir / track.path
    for endpoint in ("stream", "download"):
        response = await env.client.get(
            f"/rest/{endpoint}.view", params={**env.params, "id": str(track.id)}, headers={"Range": "bytes=10-109"}
        )
        assert response.status_code == 206 and response.content == path.read_bytes()[10:110]
        assert response.headers["content-type"] == "audio/flac"
        assert response.headers["content-range"] == "bytes 10-109/1024"
    image = tmp_path / "cover.jpg"
    Image.new("RGB", (500, 500), "red").save(image)
    cover = covers.store(image.read_bytes())
    playlist = (await call(env, "createPlaylist", name="Cover", songId=[str(track.id)]))["playlist"]
    async with SessionLocal() as db:
        album = await db.get(Album, track.album_id)
        album.cover_file = cover
        await db.commit()
    for value in (str(track.album_id), str(track.id), playlist["id"]):
        response = await env.client.get("/rest/getCoverArt", params={**env.params, "id": value, "size": 100})
        assert response.status_code == 200 and response.headers["content-type"] == "image/jpeg"
        assert response.content.startswith(b"\xff\xd8")
    path.with_suffix(".lrc").write_text("[ar:Alpha]\n[00:01.25]Hello & world\n[00:02.00]Second line", encoding="utf-8")
    lyrics = (await call(env, "getLyricsBySongId", id=str(track.id)))["lyricsList"]["structuredLyrics"][0]
    assert lyrics == {
        "synced": True,
        "lang": "xxx",
        "displayArtist": "Alpha feat. Guest",
        "displayTitle": "Song 0",
        "line": [{"start": 1250, "value": "Hello & world"}, {"start": 2000, "value": "Second line"}],
    }
    plain = (await call(env, "getLyrics", artist="Alpha", title="Song 0"))["lyrics"]
    assert plain["value"] == "Hello & world\nSecond line"
    response = await env.client.get("/rest/getLyricsBySongId", params={**env.params, "f": "xml", "id": str(track.id)})
    root = ET.fromstring(response.content)
    line = root.find("{*}lyricsList/{*}structuredLyrics/{*}line")
    assert line.text == "Hello & world" and line.attrib == {"start": "1250"}
    for endpoint in ("stream", "download", "getCoverArt"):
        response = await env.client.get(f"/rest/{endpoint}", params={**env.params, "id": "bad-id"})
        assert response.status_code == 200 and response.json()["subsonic-response"]["error"]["code"] == 70
        response = await env.client.get(
            f"/rest/{endpoint}", params={**env.params, "p": "wrong", "id": str(track.id), "f": "xml"}
        )
        assert ET.fromstring(response.content).find("{*}error").get("code") == "40"
    path.unlink()
    response = await env.client.get("/rest/stream", params={**env.params, "id": str(track.id)})
    assert response.json()["subsonic-response"]["error"]["code"] == 70


@pytest.mark.parametrize(("fmt", "signature"), [("opus", b"OggS"), ("mp3", b"ID3"), (None, b"ID3")])
async def test_stream_transcodes(env: SimpleNamespace, fmt: str | None, signature: bytes) -> None:
    original = make_track("subsonic-transcode/song.flac")
    path = env.settings.music_dir / env.tracks[0].path
    path.write_bytes(original.read_bytes())
    response = await env.client.get(
        "/rest/stream",
        params={**env.params, "id": str(env.tracks[0].id), **({"format": fmt} if fmt else {}), "maxBitRate": 96},
    )
    assert response.status_code == 200 and response.content.startswith(signature)


async def test_system_and_errors(env: SimpleNamespace) -> None:
    assert (await call(env, "getLicense"))["license"]["valid"] is True
    assert (await call(env, "getMusicFolders"))["musicFolders"]["musicFolder"] == [{"id": "1", "name": "Resonance"}]
    extensions = (await call(env, "getOpenSubsonicExtensions"))["openSubsonicExtensions"]
    assert extensions == [
        {"name": name, "versions": [1]} for name in ("formPost", "songLyrics", "apiKeyAuthentication")
    ]
    assert (await call(env, "getScanStatus"))["scanStatus"] == {"scanning": False, "count": 5}
    async with SessionLocal() as db:
        db.add(Job(kind="library_scan", status="running"))
        await db.commit()
    assert (await call(env, "getScanStatus"))["scanStatus"]["scanning"] is True
    user = (await call(env, "getUser", username="subsonic"))["user"]
    assert user["adminRole"] is True and user["streamRole"] is True and user["downloadRole"] is True
    assert user["playlistRole"] is True and user["coverArtRole"] is True and user["shareRole"] is False
    assert (await call(env, "getUser", username="other"))["user"]["adminRole"] is False
    response = await env.client.get(
        "/rest/getUser", params={**env.params, "u": "other", "p": "other-secret", "username": "subsonic"}
    )
    assert response.json()["subsonic-response"]["error"]["code"] == 50
    assert (await call(env, "getNowPlaying"))["nowPlaying"]["entry"] == []
    assert (await call(env, "getPlayQueue"))["playQueue"]["entry"] == []
    await call(env, "savePlayQueue")
    await call(env, "setRating", id=str(env.tracks[0].id), rating=5)
    for endpoint, params, code in (
        ("getPodcasts", {}, 0),
        ("getUsers", {}, 0),
        ("getSong", {}, 10),
        ("getSong", {"id": str(uuid.uuid4())}, 70),
        ("getAlbumList2", {"type": "invalid"}, 0),
    ):
        response = await env.client.get(f"/rest/{endpoint}", params={**env.params, **params})
        assert response.status_code == 200 and response.json()["subsonic-response"]["error"]["code"] == code
        if endpoint == "getPodcasts":
            assert response.json()["subsonic-response"]["error"]["message"] == "Nicht unterstützt"
