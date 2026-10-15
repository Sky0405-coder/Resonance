import json
import logging
import uuid
from collections.abc import AsyncIterator
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from sqlalchemy import select

from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import (
    Album,
    Artist,
    DownloadItem,
    DownloadRequest,
    ImportBatch,
    ImportFile,
    PlayEvent,
    Playlist,
    PlaylistEntry,
    PlaylistShare,
    SavedAlbum,
    Track,
    TrackLike,
)
from app.services.deezer import DeezerError, deezer
from app.services.matching import name_key
from app.services.musicbrainz import mb
from tests.conftest import auth, register


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
    monkeypatch.setattr(settings, "data_dir", tmp_path / "data")
    settings.music_dir.mkdir()
    settings.cover_cache_dir.mkdir(parents=True)
    admin = await register(client, "admin")
    headers = auth(admin["token"])
    response = await client.patch("/api/admin/config", json={"registration": {"mode": "public"}}, headers=headers)
    assert response.status_code == 200
    users = [await register(client, username) for username in ("bravo", "charlie", "disabled")]
    for user, name in zip([admin, *users], ["Owner", "zulu", "Alpha", "Hidden"], strict=True):
        response = await client.patch("/api/me", json={"display_name": name}, headers=auth(user["token"]))
        assert response.status_code == 200
    response = await client.patch(
        f"/api/admin/users/{users[2]['user']['id']}", json={"is_disabled": True}, headers=headers
    )
    assert response.status_code == 200
    try:
        yield SimpleNamespace(
            client=client,
            settings=settings,
            admin=admin,
            headers=headers,
            b=users[0],
            c=users[1],
            disabled=users[2],
        )
    finally:
        await reset()


async def library(
    env: SimpleNamespace,
    *,
    title: str = "Album",
    artist_name: str = "Artist",
    paths: tuple[str, ...] = ("Artist/Album/01.flac", "Artist/Album/02.flac"),
    cover_file: str | None = None,
) -> SimpleNamespace:
    files = [env.settings.music_dir / relative for relative in paths]
    for path in files:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"audio")
    async with SessionLocal() as db:
        artist = await db.scalar(select(Artist).where(Artist.name_key == name_key(artist_name)))
        if artist is None:
            artist = Artist(name=artist_name, name_key=name_key(artist_name))
            db.add(artist)
            await db.flush()
        album = Album(artist_id=artist.id, title=title, title_key=name_key(title), cover_file=cover_file)
        db.add(album)
        await db.flush()
        tracks = [
            Track(path=path, title=Path(path).stem, artist_id=artist.id, artist_credit=artist.name, album_id=album.id)
            for path in paths
        ]
        db.add_all(tracks)
        await db.commit()
        return SimpleNamespace(artist=artist.id, album=album.id, tracks=[track.id for track in tracks], files=files)


async def test_delete_track_keeps_album_and_cascades(env: SimpleNamespace) -> None:
    rows = await library(env)
    track_id = rows.tracks[0]
    user_id = uuid.UUID(env.admin["user"]["id"])
    async with SessionLocal() as db:
        playlist = Playlist(owner_id=user_id, name="Playlist")
        request = DownloadRequest(user_id=user_id, kind="album", title="Album", artist="Artist", status="done")
        batch = ImportBatch(kind="album", mode="copy", source_dir="import", status="done")
        db.add_all([playlist, request, batch])
        await db.flush()
        download = DownloadItem(
            request_id=request.id, position=0, title="01", artist="Artist", meta={}, status="done", track_id=track_id
        )
        imported = ImportFile(batch_id=batch.id, path="01.flac", group_key="Album", status="done", track_id=track_id)
        db.add_all(
            [
                TrackLike(user_id=user_id, track_id=track_id),
                PlaylistEntry(playlist_id=playlist.id, track_id=track_id, position=1),
                PlayEvent(user_id=user_id, track_id=track_id),
                download,
                imported,
            ]
        )
        await db.commit()
    response = await env.client.delete(f"/api/admin/library/tracks/{track_id}", headers=env.headers)
    assert response.status_code == 204, response.text
    assert response.content == b""
    assert not rows.files[0].exists()
    assert rows.files[1].is_file() and rows.files[0].parent.is_dir()
    async with SessionLocal() as db:
        assert await db.get(Track, track_id) is None
        assert await db.get(Album, rows.album) is not None
        assert await db.get(Artist, rows.artist) is not None
        assert await db.scalar(select(TrackLike)) is None
        assert await db.scalar(select(PlaylistEntry)) is None
        assert await db.scalar(select(PlayEvent)) is None
        assert (await db.get(DownloadItem, download.id)).track_id is None
        assert (await db.get(ImportFile, imported.id)).track_id is None


async def test_delete_album_removes_files_and_orphans(env: SimpleNamespace) -> None:
    rows = await library(env, cover_file="cached.jpg")
    folder = rows.files[0].parent
    for name in ("cover.jpg", "album.nfo", "disc.cue", "rip.log"):
        (folder / name).write_bytes(b"sidecar")
    cached = env.settings.cover_cache_dir / "cached.jpg"
    cached.write_bytes(b"cover")
    image = env.settings.data_dir / "artist.jpg"
    image.write_bytes(b"artist")
    guest_image = env.settings.data_dir / "guest.jpg"
    guest_image.write_bytes(b"guest")
    async with SessionLocal() as db:
        artist = await db.get(Artist, rows.artist)
        artist.image_path = str(image)
        guest = Artist(name="Guest", name_key="guest", image_path="guest.jpg")
        db.add(guest)
        await db.flush()
        (await db.get(Track, rows.tracks[0])).artist_id = guest.id
        db.add(SavedAlbum(user_id=uuid.UUID(env.admin["user"]["id"]), album_id=rows.album))
        await db.commit()
    response = await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)
    assert response.status_code == 204, response.text
    assert not folder.exists() and not folder.parent.exists()
    assert env.settings.music_dir.is_dir()
    assert not cached.exists() and not image.exists() and not guest_image.exists()
    async with SessionLocal() as db:
        assert await db.get(Album, rows.album) is None
        assert await db.get(Artist, rows.artist) is None
        assert await db.get(Artist, guest.id) is None
        assert await db.scalar(select(Track)) is None
        assert await db.scalar(select(SavedAlbum)) is None


async def test_delete_last_track_keeps_artist_and_shared_cover(env: SimpleNamespace) -> None:
    rows = await library(env, paths=("Artist/Album/01.flac",), cover_file="shared.jpg")
    other = await library(env, title="Other", paths=("Artist/Other/01.flac",), cover_file="shared.jpg")
    cached = env.settings.cover_cache_dir / "shared.jpg"
    cached.write_bytes(b"cover")
    response = await env.client.delete(f"/api/admin/library/tracks/{rows.tracks[0]}", headers=env.headers)
    assert response.status_code == 204
    assert cached.is_file() and other.files[0].is_file()
    async with SessionLocal() as db:
        assert await db.get(Album, rows.album) is None
        assert await db.get(Album, other.album) is not None
        assert await db.get(Artist, rows.artist) is not None


async def test_delete_album_keeps_artist_referenced_by_other_track(env: SimpleNamespace) -> None:
    rows = await library(env)
    other = await library(env, title="Other", artist_name="Other", paths=("Other/Other/01.flac",))
    async with SessionLocal() as db:
        (await db.get(Track, other.tracks[0])).artist_id = rows.artist
        await db.commit()
    assert (await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)).status_code == 204
    async with SessionLocal() as db:
        assert await db.get(Artist, rows.artist) is not None
        assert await db.get(Track, other.tracks[0]) is not None


async def test_delete_empty_album(env: SimpleNamespace) -> None:
    rows = await library(env, paths=(), cover_file="empty.jpg")
    cached = env.settings.cover_cache_dir / "empty.jpg"
    cached.touch()
    response = await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)
    assert response.status_code == 204
    assert not cached.exists()
    async with SessionLocal() as db:
        assert await db.get(Album, rows.album) is None
        assert await db.get(Artist, rows.artist) is None


@pytest.mark.parametrize("resource", ["tracks", "albums"])
async def test_delete_requires_admin_and_known_id(env: SimpleNamespace, resource: str) -> None:
    url = f"/api/admin/library/{resource}/{uuid.uuid4()}"
    assert (await env.client.delete(url, headers=auth(env.b["token"]))).status_code == 403
    response = await env.client.delete(url, headers=env.headers)
    assert response.status_code == 404 and response.json()["detail"] == "Nicht gefunden"


@pytest.mark.parametrize("kind", ["relative", "absolute", "symlink"])
async def test_delete_skips_paths_outside_music(
    env: SimpleNamespace, tmp_path: Path, caplog: pytest.LogCaptureFixture, kind: str
) -> None:
    outside = tmp_path / "outside.flac"
    outside.write_bytes(b"keep")
    rows = await library(env, paths=("Artist/Album/01.flac",))
    if kind == "symlink":
        rows.files[0].unlink()
        rows.files[0].symlink_to(outside)
        path = "Artist/Album/01.flac"
    else:
        path = str(outside) if kind == "absolute" else "../outside.flac"
    async with SessionLocal() as db:
        (await db.get(Track, rows.tracks[0])).path = path
        await db.commit()
    with caplog.at_level(logging.WARNING):
        response = await env.client.delete(f"/api/admin/library/tracks/{rows.tracks[0]}", headers=env.headers)
    assert response.status_code == 204
    assert outside.read_bytes() == b"keep"
    assert "outside music directory" in caplog.text


@pytest.mark.parametrize("remaining", ["untracked.MP3", "subfolder"])
async def test_delete_keeps_folder_with_audio_or_subdirectory(env: SimpleNamespace, remaining: str) -> None:
    rows = await library(env, paths=("Artist/Album/01.flac",))
    folder = rows.files[0].parent
    leftover = folder / remaining
    if remaining == "subfolder":
        leftover.mkdir()
    else:
        leftover.touch()
    (folder / "cover.jpg").touch()
    response = await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)
    assert response.status_code == 204
    assert leftover.exists() and (folder / "cover.jpg").is_file()


async def test_delete_cleans_multiple_disc_folders(env: SimpleNamespace) -> None:
    rows = await library(env, paths=("Artist/Album/CD1/01.flac", "Artist/Album/CD2/01.flac"))
    response = await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)
    assert response.status_code == 204
    assert not (env.settings.music_dir / "Artist").exists()
    assert env.settings.music_dir.is_dir()


async def test_delete_logs_file_errors_after_committing(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    rows = await library(env, paths=("Artist/Album/01.flac",), cover_file="cache.jpg")
    (env.settings.cover_cache_dir / "cache.jpg").touch()
    original = Path.unlink

    def unlink(path: Path, missing_ok: bool = False) -> None:
        if path in [rows.files[0], env.settings.cover_cache_dir / "cache.jpg"]:
            raise PermissionError("test file error")
        original(path, missing_ok=missing_ok)

    monkeypatch.setattr(Path, "unlink", unlink)
    with caplog.at_level(logging.WARNING):
        response = await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)
    assert response.status_code == 204
    assert "Could not delete track file" in caplog.text and "Could not delete cover cache file" in caplog.text
    async with SessionLocal() as db:
        assert await db.get(Track, rows.tracks[0]) is None
        assert await db.get(Album, rows.album) is None


async def test_delete_keeps_artist_image_outside_data(env: SimpleNamespace, tmp_path: Path) -> None:
    rows = await library(env)
    image = tmp_path / "outside.jpg"
    image.write_bytes(b"keep")
    async with SessionLocal() as db:
        (await db.get(Artist, rows.artist)).image_path = str(image)
        await db.commit()
    response = await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)
    assert response.status_code == 204 and image.read_bytes() == b"keep"


async def test_request_album_again_after_deletion(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    fixtures = Path(__file__).parent / "fixtures"
    album = json.loads((fixtures / "deezer_album.json").read_text())
    tracks = json.loads((fixtures / "deezer_album_tracks.json").read_text())["data"]

    async def get_album(catalog_id: str) -> dict:
        assert catalog_id == str(album["id"])
        return album

    async def get_tracks(catalog_id: str) -> list[dict]:
        assert catalog_id == str(album["id"])
        return tracks

    async def release_by_barcode(barcode: str, track_count: int) -> None:
        return None

    monkeypatch.setattr(deezer, "album", get_album)
    monkeypatch.setattr(deezer, "album_tracks", get_tracks)
    monkeypatch.setattr(mb, "release_by_barcode", release_by_barcode)
    rows = await library(
        env,
        title=album["title"],
        artist_name=album["artist"]["name"],
        paths=tuple(f"Artist/Album/{track['title']}.flac" for track in tracks),
    )
    async with SessionLocal() as db:
        for track_id, track in zip(rows.tracks, tracks, strict=True):
            (await db.get(Track, track_id)).title = track["title"]
        await db.commit()
    body = {"kind": "album", "id": str(album["id"])}
    previous = await env.client.post("/api/requests", json=body, headers=env.headers)
    assert previous.status_code == 201, previous.text
    assert previous.json()["status"] == "done"
    assert all(item["status"] == "exists" for item in previous.json()["items"])
    assert (await env.client.delete(f"/api/admin/library/albums/{rows.album}", headers=env.headers)).status_code == 204
    response = await env.client.post("/api/requests", json=body, headers=env.headers)
    assert response.status_code == 201, response.text
    assert response.json()["id"] != previous.json()["id"]
    assert response.json()["status"] == "active"
    assert all(item["status"] == "queued" for item in response.json()["items"])


@pytest.mark.parametrize(
    ("title", "results", "expected"),
    [
        (
            "Album",
            [
                {"id": 1, "title": "Album (Deluxe)", "artist": {"name": "Artist"}},
                {"id": 2, "title": "  ALBUM  ", "artist": {"name": " ARTIST "}},
                {"id": 3, "title": "Album", "artist": {"name": "Artist"}},
            ],
            "2",
        ),
        (
            "2001",
            [
                {"id": 1, "title": "Other", "artist": {"name": "Artist"}},
                {"id": 2, "title": "2001 (Deluxe)", "artist": {"name": "Artist"}},
                {"id": 3, "title": "2001 (Remaster)", "artist": {"name": "Artist"}},
            ],
            "2",
        ),
        ("2001 (Deluxe)", [{"id": 1, "title": "2001", "artist": {"name": "Artist"}}], "1"),
        ("Album", [{"id": 1, "title": "Album", "artist": {"name": "Other"}}], None),
        ("Album", [{"id": 1, "title": "Other", "artist": {"name": "Artist"}}], None),
        ("Album", [], None),
    ],
)
async def test_library_album_catalog_match(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, title: str, results: list[dict], expected: str | None
) -> None:
    rows = await library(env, title=title)

    async def search_albums(query: str, limit: int) -> list[dict]:
        assert query == f"Artist {title}" and limit == 10
        return results

    monkeypatch.setattr(deezer, "search_albums", search_albums)
    response = await env.client.get(f"/api/library/albums/{rows.album}/catalog", headers=auth(env.b["token"]))
    if expected is None:
        assert response.status_code == 404 and response.json()["detail"] == "Album nicht im Katalog gefunden"
    else:
        assert response.status_code == 200 and response.json() == {"catalog_id": expected}


async def test_library_album_catalog_error_and_unknown(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    rows = await library(env)

    async def search_albums(query: str, limit: int) -> list[dict]:
        raise DeezerError("test error")

    monkeypatch.setattr(deezer, "search_albums", search_albums)
    response = await env.client.get(f"/api/library/albums/{rows.album}/catalog", headers=env.headers)
    assert response.status_code == 502 and response.json()["detail"] == "Katalog nicht erreichbar"
    response = await env.client.get(f"/api/library/albums/{uuid.uuid4()}/catalog", headers=env.headers)
    assert response.status_code == 404 and response.json()["detail"] == "Nicht gefunden"
    assert (await env.client.get(f"/api/library/albums/{rows.album}/catalog")).status_code == 401


async def test_library_album_missing_tracks(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    rows = await library(env)
    async with SessionLocal() as db:
        # "02" carries a tag variant of the catalog title but sits at the same position.
        track = await db.get(Track, rows.tracks[1])
        track.track_no = 2
        await db.commit()

    def entry(id: int, title: str, position: int) -> dict:
        return {
            "id": id,
            "title": title,
            "artist": {"id": 1, "name": "Artist"},
            "track_position": position,
            "disk_number": 1,
        }

    async def search_albums(query: str, limit: int) -> list[dict]:
        return [{"id": 99, "title": "Album", "artist": {"name": "Artist"}}]

    async def album(id: str) -> dict:
        assert id == "99"
        return {"id": 99, "title": "Album", "cover_medium": "https://cover"}

    async def album_tracks(id: str) -> list[dict]:
        return [entry(10, "01", 1), entry(11, "02 (Remastered)", 2), entry(12, "New Song", 3)]

    monkeypatch.setattr(deezer, "search_albums", search_albums)
    monkeypatch.setattr(deezer, "album", album)
    monkeypatch.setattr(deezer, "album_tracks", album_tracks)
    response = await env.client.get(f"/api/library/albums/{rows.album}/missing", headers=env.headers)
    assert response.status_code == 200
    body = response.json()
    assert body["catalog_id"] == "99"
    assert [(t["id"], t["title"], t["track_no"]) for t in body["tracks"]] == [("12", "New Song", 3)]


async def create_playlist(env: SimpleNamespace, *, is_public: bool = False) -> str:
    response = await env.client.post(
        "/api/playlists", json={"name": "Shared", "is_public": is_public}, headers=env.headers
    )
    assert response.status_code == 201
    assert response.json()["shared_with"] == []
    return response.json()["id"]


async def test_playlist_sharing_visibility_and_replacement(env: SimpleNamespace) -> None:
    playlist_id = await create_playlist(env)
    url = f"/api/playlists/{playlist_id}"
    b_headers, c_headers = auth(env.b["token"]), auth(env.c["token"])
    assert (await env.client.get(url, headers=b_headers)).status_code == 404
    response = await env.client.put(f"{url}/shares", json={"user_ids": [env.b["user"]["id"]]}, headers=env.headers)
    assert response.status_code == 200, response.text
    expected = [{"id": env.b["user"]["id"], "name": "zulu"}]
    assert response.json()["shared_with"] == expected
    for headers, shares in [(env.headers, expected), (b_headers, [])]:
        response = await env.client.get(url, headers=headers)
        assert response.status_code == 200 and response.json()["shared_with"] == shares
        assert response.json()["editable"] == (headers == env.headers)
        listed = (await env.client.get("/api/playlists", headers=headers)).json()
        assert next(item for item in listed if item["id"] == playlist_id)["shared_with"] == shares
    home = (await env.client.get("/api/home", headers=env.headers)).json()
    assert home["playlists"][0]["shared_with"] == expected
    assert (await env.client.get(url, headers=c_headers)).status_code == 404
    assert not (await env.client.get("/api/playlists", headers=c_headers)).json()
    response = await env.client.put(f"{url}/shares", json={"user_ids": [env.c["user"]["id"]]}, headers=env.headers)
    assert response.status_code == 200
    assert (await env.client.get(url, headers=b_headers)).status_code == 404
    assert (await env.client.get(url, headers=c_headers)).status_code == 200
    response = await env.client.put(f"{url}/shares", json={"user_ids": []}, headers=env.headers)
    assert response.status_code == 200 and response.json()["shared_with"] == []
    assert (await env.client.get(url, headers=c_headers)).status_code == 404
    assert not (await env.client.get("/api/playlists", headers=c_headers)).json()


async def test_playlist_sharing_stays_owner_only(env: SimpleNamespace) -> None:
    rows = await library(env)
    playlist_id = await create_playlist(env)
    url = f"/api/playlists/{playlist_id}"
    await env.client.post(f"{url}/tracks", json={"track_ids": [str(rows.tracks[0])]}, headers=env.headers)
    detail = (await env.client.get(url, headers=env.headers)).json()
    entry_id = detail["entries"][0]["entry_id"]
    response = await env.client.put(f"{url}/shares", json={"user_ids": [env.b["user"]["id"]]}, headers=env.headers)
    assert response.status_code == 200
    requests = [
        ("PATCH", url, {"name": "Changed"}),
        ("DELETE", url, None),
        ("PUT", f"{url}/shares", {"user_ids": []}),
        ("POST", f"{url}/tracks", {"track_ids": [str(rows.tracks[1])]}),
        ("POST", f"{url}/move", {"entry_id": entry_id}),
        ("DELETE", f"{url}/entries/{entry_id}", None),
    ]
    for method, target, body in requests:
        response = await env.client.request(method, target, json=body, headers=auth(env.b["token"]))
        assert response.status_code == 403, (method, target, response.text)
    response = await env.client.put(f"{url}/shares", json={"user_ids": []}, headers=auth(env.c["token"]))
    assert response.status_code == 404
    response = await env.client.put(f"/api/playlists/{uuid.uuid4()}/shares", json={"user_ids": []}, headers=env.headers)
    assert response.status_code == 404


async def test_playlist_shares_sort_deduplicate_and_hide_from_public_view(env: SimpleNamespace) -> None:
    playlist_id = await create_playlist(env, is_public=True)
    url = f"/api/playlists/{playlist_id}"
    body = {"user_ids": [env.b["user"]["id"], env.c["user"]["id"], env.b["user"]["id"]]}
    for _ in range(2):
        response = await env.client.put(f"{url}/shares", json=body, headers=env.headers)
        assert response.status_code == 200
        assert [user["name"] for user in response.json()["shared_with"]] == ["Alpha", "zulu"]
    await env.client.put(f"{url}/shares", json={"user_ids": [env.b["user"]["id"]]}, headers=env.headers)
    response = await env.client.get(url, headers=auth(env.c["token"]))
    assert response.status_code == 200 and response.json()["shared_with"] == []
    assert any(
        item["id"] == playlist_id
        for item in (await env.client.get("/api/playlists", headers=auth(env.c["token"]))).json()
    )


@pytest.mark.parametrize("invalid", ["unknown", "disabled", "owner"])
async def test_invalid_playlist_share_keeps_existing_set(env: SimpleNamespace, invalid: str) -> None:
    playlist_id = await create_playlist(env)
    url = f"/api/playlists/{playlist_id}"
    body = {"user_ids": [env.b["user"]["id"]]}
    assert (await env.client.put(f"{url}/shares", json=body, headers=env.headers)).status_code == 200
    invalid_id = {
        "unknown": str(uuid.uuid4()),
        "disabled": env.disabled["user"]["id"],
        "owner": env.admin["user"]["id"],
    }[invalid]
    response = await env.client.put(
        f"{url}/shares", json={"user_ids": [env.c["user"]["id"], invalid_id]}, headers=env.headers
    )
    assert response.status_code == 400 and response.json()["detail"] == "Unbekannter Nutzer"
    assert (await env.client.get(url, headers=auth(env.b["token"]))).status_code == 200
    assert (await env.client.get(url, headers=auth(env.c["token"]))).status_code == 404
    detail = (await env.client.get(url, headers=env.headers)).json()
    assert detail["shared_with"] == [{"id": env.b["user"]["id"], "name": "zulu"}]


async def test_playlist_share_limit_and_cascades(env: SimpleNamespace) -> None:
    playlist_id = await create_playlist(env)
    url = f"/api/playlists/{playlist_id}"
    body = {"user_ids": [env.b["user"]["id"]] * 101}
    assert (await env.client.put(f"{url}/shares", json=body, headers=env.headers)).status_code == 422
    body = {"user_ids": [env.b["user"]["id"], env.c["user"]["id"]]}
    assert (await env.client.put(f"{url}/shares", json=body, headers=env.headers)).status_code == 200
    assert (await env.client.delete(f"/api/admin/users/{env.c['user']['id']}", headers=env.headers)).status_code == 204
    async with SessionLocal() as db:
        shares = list(await db.scalars(select(PlaylistShare)))
        assert len(shares) == 1 and str(shares[0].user_id) == env.b["user"]["id"]
    assert (await env.client.delete(url, headers=env.headers)).status_code == 204
    async with SessionLocal() as db:
        assert await db.scalar(select(PlaylistShare)) is None


async def test_users_exclude_self_and_disabled_sorted_by_display_name(env: SimpleNamespace) -> None:
    response = await env.client.get("/api/users", headers=env.headers)
    assert response.status_code == 200
    assert response.json() == [
        {"id": env.c["user"]["id"], "name": "Alpha"},
        {"id": env.b["user"]["id"], "name": "zulu"},
    ]
    response = await env.client.get("/api/users", headers=auth(env.b["token"]))
    assert response.status_code == 200
    assert response.json() == [
        {"id": env.c["user"]["id"], "name": "Alpha"},
        {"id": env.admin["user"]["id"], "name": "Owner"},
    ]
    assert (await env.client.get("/api/users")).status_code == 401
