import io
import uuid
from types import SimpleNamespace

import httpx
import pytest
from PIL import Image
from sqlalchemy import select

from app.api import editor
from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import (
    Album,
    Artist,
    PlayEvent,
    Playlist,
    PlaylistEntry,
    Track,
    TrackLike,
)
from app.schemas import ManualMetaIn
from app.services import acoustid, scanner
from app.services.musicbrainz import mb
from app.services.retag import (
    apply_meta,
    assign_tracks,
    manual_meta,
    prune_dir,
    replace_cover,
)
from app.services.server_config import update_config
from app.services.tagger import write_tags
from app.services.tags import embedded_cover, read_tags
from tests.conftest import auth, register
from tests.test_imports import audio, lookup_result, meta, tags


def image(color: str = "red", format: str = "JPEG") -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (20, 20), color).save(buf, format)
    return buf.getvalue()


@pytest.fixture
async def env(client, tmp_path, monkeypatch):
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    settings = get_settings()
    monkeypatch.setattr(settings, "music_dir", tmp_path / "music")
    monkeypatch.setattr(settings, "data_dir", tmp_path / "data")
    settings.music_dir.mkdir()
    admin = await register(client, "admin")
    invite = (await client.post("/api/admin/invites", json={}, headers=auth(admin["token"]))).json()["token"]
    user = await register(client, "user", invite)
    yield SimpleNamespace(client=client, settings=settings, admin=admin, user=user, headers=auth(admin["token"]))
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)


async def library_track(env, rel="Old/Old Album/old.mp3", **updates):
    path = audio(env.settings.music_dir / rel)
    metadata = meta(title="Old Song", artist="Old", album="Old Album", album_artist="Old", **updates)
    write_tags(path, metadata, image())
    async with SessionLocal() as db:
        track = await scanner.import_file(db, rel)
        return track.id, track.album_id, path, metadata


def test_manual_meta():
    original = tags(
        title="Artist",
        artist="Song",
        artist_credit="Song",
        album_artist="Song",
        mb_recording_id=str(uuid.uuid4()),
        mb_artist_id=str(uuid.uuid4()),
        mb_album_id=str(uuid.uuid4()),
        mb_album_artist_id=str(uuid.uuid4()),
        mb_release_group_id=str(uuid.uuid4()),
        isrc="DEABC0100001",
        label="Label",
        track_total=10,
    )
    fixed = manual_meta(original, ManualMetaIn(title="Song", artist="Artist"))
    assert (fixed.title, fixed.artist) == ("Song", "Artist")
    assert fixed.mb_recording_id is fixed.isrc is fixed.artist_mbid is None
    assert fixed.mb_release_id == original.mb_album_id
    album = manual_meta(original, ManualMetaIn(album="New", album_artist="New artist", year=2002))
    assert album.mb_release_id is album.mb_release_group_id is album.label is album.track_total is None
    assert album.album_artist_mbid is None
    assert album.mb_recording_id == original.mb_recording_id
    assert album.date == "2002"
    same = manual_meta(
        original, ManualMetaIn(title=" artist ", artist=" SONG ", album=" album ", album_artist=" song ")
    )
    assert same.mb_recording_id == original.mb_recording_id
    assert same.artist_mbid == original.mb_artist_id
    assert same.mb_release_id == original.mb_album_id
    assert same.album_artist_mbid == original.mb_album_artist_id
    assert manual_meta(tags(album_artist="Artist"), ManualMetaIn()).album_artist == "Artist"


def test_assign_tracks():
    ids = [uuid.uuid4() for _ in range(3)]
    source = [
        (ids[0], tags(title="First", track_no=1)),
        (ids[1], tags(title="Second", track_no=3)),
        (ids[2], tags(title="Unrelated ZZZ", track_no=2)),
    ]
    metas = [
        meta(title="First", track_no=1),
        meta(title="Second", track_no=2),
        meta(title="Other XYZ", track_no=3),
        meta(title="Fourth", track_no=4),
    ]
    assignment = assign_tracks(source, metas)
    assert set(assignment) == set(ids[:2])
    assert assignment[ids[1]] is metas[1]
    assert assign_tracks([(ids[0], tags())], [meta(duration=8)]) == {}
    one_meta = meta(duration=None)
    assert len(assign_tracks([(ids[0], tags()), (ids[1], tags())], [one_meta])) == 1
    assert len(assign_tracks([(ids[0], tags(title="First version"))], [meta(title="First edit")])) == 1


async def test_manual_match_preserves_identity(env):
    track_id, album_id, path, _ = await library_track(env)
    old_picture = embedded_cover(path)
    (path.parent / "cover.jpg").write_bytes(image())
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        old_artist_id = track.artist_id
        playlist = Playlist(owner_id=uuid.UUID(env.admin["user"]["id"]), name="List")
        db.add(playlist)
        await db.flush()
        db.add_all(
            [
                TrackLike(user_id=playlist.owner_id, track_id=track_id),
                PlaylistEntry(playlist_id=playlist.id, track_id=track_id, position=1),
                PlayEvent(user_id=playlist.owner_id, track_id=track_id, seconds_played=2),
            ]
        )
        await db.commit()
    result = await env.client.post(
        f"/api/admin/library/tracks/{track_id}/match",
        headers=env.headers,
        json={
            "source": "manual",
            "meta": {
                "title": "Correct",
                "artist": "New Artist",
                "album_artist": "New Artist",
                "album": "New Album",
                "year": 2005,
                "track_no": 2,
            },
        },
    )
    assert result.status_code == 200, result.text
    assert result.json()["id"] == str(track_id)
    assert result.json()["liked"]
    target = env.settings.music_dir / "New Artist/New Album (2005)/02 - Correct.mp3"
    assert target.is_file()
    assert not path.parent.exists() and not path.parent.parent.exists()
    assert embedded_cover(target) == old_picture
    async with SessionLocal() as db:
        assert (await db.get(Track, track_id)).reviewed is True
        assert (await db.scalar(select(TrackLike))).track_id == track_id
        assert (await db.scalar(select(PlaylistEntry))).track_id == track_id
        assert (await db.scalar(select(PlayEvent))).track_id == track_id
        assert await db.get(Album, album_id) is None
        assert await db.get(Artist, old_artist_id) is None
    file = await env.client.get(f"/api/admin/library/tracks/{track_id}/file", headers=env.headers)
    assert file.json()["query"] == "New Artist Correct"
    assert file.json()["mb_recording_id"] is None
    review = await env.client.get("/api/editor/review", headers=env.headers)
    assert review.json()["total"] == 0
    empty = await env.client.post(
        f"/api/admin/library/tracks/{track_id}/match",
        headers=env.headers,
        json={"source": "manual", "meta": {"title": ""}},
    )
    assert empty.status_code == 422
    missing = await env.client.post(
        f"/api/admin/library/tracks/{track_id}/match", headers=env.headers, json={"source": "manual"}
    )
    assert missing.status_code == 422 and missing.json()["detail"] == "Unvollständige Angaben"


async def test_mark_reviewed(env: SimpleNamespace) -> None:
    track_id, album_id, _, _ = await library_track(env)
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        assert track.reviewed is False
        track.mb_recording_id = None
        track.isrc = "DEUM71400001"
        album = await db.get(Album, album_id)
        album.cover_file = None
        await db.commit()
    # An ISRC (e.g. from Deezer) identifies the song well enough without a MusicBrainz link.
    result = await env.client.get("/api/editor/review", headers=env.headers)
    assert result.status_code == 200 and result.json()["total"] == 0
    async with SessionLocal() as db:
        (await db.get(Track, track_id)).isrc = None
        await db.commit()
    result = await env.client.get("/api/editor/review", headers=env.headers)
    assert result.status_code == 200 and result.json()["total"] == 1
    endpoint = f"/api/editor/tracks/{track_id}/reviewed"
    assert (await env.client.post(endpoint, headers=auth(env.user["token"]))).status_code == 403
    result = await env.client.post(f"/api/editor/tracks/{uuid.uuid4()}/reviewed", headers=env.headers)
    assert result.status_code == 404 and result.json()["detail"] == "Song nicht gefunden"
    assert (await env.client.post(endpoint, headers=env.headers)).status_code == 204
    assert (await env.client.post(endpoint, headers=env.headers)).status_code == 204
    async with SessionLocal() as db:
        assert (await db.get(Track, track_id)).reviewed is True
    for path in ("/api/editor/review", "/api/admin/library/review"):
        result = await env.client.get(path, headers=env.headers)
        assert result.json()["total"] == 0 and result.json()["items"] == []
    result = await env.client.get("/api/editor/review", headers=env.headers, params={"kind": "no_cover"})
    assert result.json()["total"] == 1
    assert (await env.client.get("/api/editor/review", headers=auth(env.user["token"]))).status_code == 403


@pytest.mark.parametrize("source", ["deezer", "musicbrainz"])
async def test_catalog_match(env, monkeypatch, source):
    track_id, _, _, _ = await library_track(env)
    chosen = meta(title="Identified")

    async def resolve(*args):
        return chosen

    async def release(*args):
        return {}

    async def metas(*args):
        return [chosen]

    async def cover(*args):
        return image("blue", "PNG")

    monkeypatch.setattr(editor, "resolve_track", resolve)
    monkeypatch.setattr(mb, "release_full", release)
    monkeypatch.setattr(mb, "track_meta_list", metas)
    monkeypatch.setattr(editor, "fetch_cover", cover)
    body = {"source": source, "deezer_id": "1", "recording_id": chosen.mb_recording_id, "release_id": "release"}
    result = await env.client.post(f"/api/admin/library/tracks/{track_id}/match", headers=env.headers, json=body)
    assert result.status_code == 200, result.text
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        target = env.settings.music_dir / track.path
    read = read_tags(target)
    assert read.mb_recording_id == chosen.mb_recording_id
    assert read.mb_album_id == chosen.mb_release_id
    assert (target.parent / "cover.jpg").read_bytes().startswith(b"\xff\xd8")
    assert embedded_cover(target).startswith(b"\xff\xd8")
    body.update(source="musicbrainz", recording_id="missing")
    result = await env.client.post(f"/api/admin/library/tracks/{track_id}/match", headers=env.headers, json=body)
    assert result.status_code == 422 and result.json()["detail"] == "Song nicht auf dieser Veröffentlichung"


async def test_collision_and_failure(env, monkeypatch):
    track_id, _, _, _ = await library_track(env)
    target = env.settings.music_dir / "Artist/Album (2001)/01 - Song.mp3"
    audio(target)
    original = target.read_bytes()
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        await apply_meta(db, track, meta(), None)
        assert track.path == "Artist/Album (2001)/01 - Song (2).mp3"
    assert target.read_bytes() == original
    from app.services import retag

    def failed(*args, **kwargs):
        raise ValueError("broken")

    monkeypatch.setattr(retag, "write_tags", failed)
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        before = (env.settings.music_dir / track.path).read_bytes()
        with pytest.raises(ValueError, match="broken"):
            await apply_meta(db, track, meta(title="Failure"), None)
        assert (env.settings.music_dir / track.path).read_bytes() == before
        assert not list(target.parent.glob(".*.part*"))
        (env.settings.music_dir / track.path).unlink()
        with pytest.raises(ValueError, match="Datei nicht gefunden"):
            await apply_meta(db, track, meta(), None)


async def test_album_match(env, monkeypatch):
    tracks = []
    for position, title in enumerate(["First", "Second", "Unrelated ZZZ"], 1):
        rel = f"Old/Old Album/{position}.mp3"
        path = audio(env.settings.music_dir / rel)
        write_tags(
            path,
            meta(
                title=title,
                album="Old Album",
                album_artist="Old",
                artist="Old",
                track_no=3 if position == 2 else position,
            ),
            None,
        )
        async with SessionLocal() as db:
            tracks.append(await scanner.import_file(db, rel))
    metas = [
        meta(title="First", track_no=1),
        meta(title="Second", track_no=2),
        meta(title="Other XYZ", track_no=3),
        meta(title="Fourth", track_no=4),
    ]
    calls = []

    async def resolve(*args):
        return {}, metas

    async def cover(chosen):
        calls.append(chosen)
        return image()

    monkeypatch.setattr(editor, "resolve_album", resolve)
    monkeypatch.setattr(editor, "fetch_cover", cover)
    result = await env.client.post(
        f"/api/admin/library/albums/{tracks[0].album_id}/match",
        headers=env.headers,
        json={"source": "deezer", "id": "1"},
    )
    assert result.status_code == 200, result.text
    assert result.json()["matched"] == 2
    assert [t["id"] for t in result.json()["unmatched"]] == [str(tracks[2].id)]
    assert result.json()["album"]["title"] == "Album"
    assert len(calls) == 1


@pytest.mark.parametrize("ext", [".mp3", ".flac", ".ogg", ".m4a", ".opus", ".wma", ".ape"])
def test_replace_cover(tmp_path, ext):
    path = audio(tmp_path / f"song{ext}")
    write_tags(path, meta(), image())
    before = read_tags(path)
    replace_cover(path, image("blue"))
    after = read_tags(path)
    assert (after.title, after.artist, after.mb_recording_id) == (before.title, before.artist, before.mb_recording_id)
    assert embedded_cover(path) == image("blue")


async def test_cover_upload_and_urls(env, monkeypatch):
    track_id, album_id, path, _ = await library_track(env)
    for name in ("cover.png", "folder.jpg", "folder.png"):
        (path.parent / name).write_bytes(image())
    result = await env.client.post(
        f"/api/admin/library/albums/{album_id}/cover",
        headers=env.headers,
        files={"file": ("cover.png", image("blue", "PNG"), "image/png")},
    )
    assert result.status_code == 200 and result.json()["has_cover"], result.text
    assert (path.parent / "cover.jpg").read_bytes() == embedded_cover(path)
    assert all(not (path.parent / name).exists() for name in ("cover.png", "folder.jpg", "folder.png"))
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        assert (track.mtime, track.size) == (path.stat().st_mtime, path.stat().st_size)
    factory = httpx.AsyncClient
    requested = []

    def handle(request):
        requested.append(str(request.url))
        if request.url.path == "/redirect":
            return httpx.Response(302, headers={"location": "https://evil.example/image.jpg"})
        return httpx.Response(200, content=image("green", "PNG"))

    monkeypatch.setattr(
        editor.httpx, "AsyncClient", lambda **kwargs: factory(transport=httpx.MockTransport(handle), **kwargs)
    )
    for url in (
        "https://evil.example/x",
        "http://dzcdn.net/x",
        "https://evildzcdn.net/x",
        "https://dzcdn.net/redirect",
    ):
        result = await env.client.post(
            f"/api/admin/library/albums/{album_id}/cover", headers=env.headers, json={"url": url}
        )
        assert result.status_code == 422 and result.json()["detail"] == "Bildquelle nicht erlaubt"
    assert requested == ["https://dzcdn.net/redirect"]
    result = await env.client.post(
        f"/api/admin/library/albums/{album_id}/cover", headers=env.headers, json={"url": "https://cdn.dzcdn.net/cover"}
    )
    assert result.status_code == 200
    invalid = await env.client.post(
        f"/api/admin/library/albums/{album_id}/cover", headers=env.headers, files={"file": ("bad", b"not an image")}
    )
    assert invalid.status_code == 422
    oversized = await env.client.post(
        f"/api/admin/library/albums/{album_id}/cover",
        headers=env.headers,
        files={"file": ("large", b"x" * (10 * 1024 * 1024 + 1))},
    )
    assert oversized.status_code == 413


async def test_options_fingerprint_and_review(env, monkeypatch):
    track_id, album_id, _, _ = await library_track(env)

    async def albums(*args):
        return [
            {"title": "Option", "artist": {"name": "Artist"}, "cover_xl": "https://dzcdn.net/cover"},
            {"title": "No cover"},
        ]

    monkeypatch.setattr(editor.deezer, "search_albums", albums)
    options = await env.client.get(f"/api/admin/library/albums/{album_id}/cover-options", headers=env.headers)
    assert [o["source"] for o in options.json()] == ["musicbrainz", "deezer"]
    assert options.json()[1]["label"] == "Option – Artist"
    no_key = await env.client.get(f"/api/admin/library/tracks/{track_id}/fingerprint", headers=env.headers)
    assert no_key.status_code == 409
    async with SessionLocal() as db:
        await update_config(db, {"library": {"acoustid_api_key": "key"}})
        track = await db.get(Track, track_id)
        track.mb_recording_id = None
        track.isrc = None
        album = await db.get(Album, album_id)
        album.cover_file = None
        await db.commit()
    results = lookup_result()
    results[0]["recordings"][0].update(title="Title", artists=[{"name": "A", "joinphrase": " & "}, {"name": "B"}])
    results += lookup_result(release="later", score=0.9)

    async def fingerprint(*args):
        return "fingerprint"

    async def lookup(*args):
        return results

    monkeypatch.setattr(editor, "fingerprint", fingerprint)
    monkeypatch.setattr(acoustid, "lookup", lookup)
    result = await env.client.get(f"/api/admin/library/tracks/{track_id}/fingerprint", headers=env.headers)
    assert result.status_code == 200
    assert len(result.json()) == 1
    assert result.json()[0]["artist"] == "A & B"
    assert len(result.json()[0]["releases"]) == 2
    for kind in ("unidentified", "no_cover"):
        result = await env.client.get(
            "/api/admin/library/review", params={"kind": kind, "limit": 1}, headers=env.headers
        )
        assert result.status_code == 200, result.text
        assert result.json()["total"] == 1
        assert result.json()["items"][0]["path"] == track.path
        result = await env.client.get(
            "/api/admin/library/review", params={"kind": kind, "offset": 1}, headers=env.headers
        )
        assert result.json()["total"] == 1 and result.json()["items"] == []


@pytest.mark.parametrize(
    "method,path,body",
    [
        ("GET", "/tracks/{id}/file", None),
        ("GET", "/tracks/{id}/fingerprint", None),
        ("POST", "/tracks/{id}/match", {"source": "manual", "meta": {}}),
        ("POST", "/albums/{id}/match", {"source": "deezer", "id": "1"}),
        ("GET", "/albums/{id}/cover-options", None),
        ("POST", "/albums/{id}/cover", {"url": "https://dzcdn.net/x"}),
        ("GET", "/review", None),
    ],
)
async def test_admin_only(env, method, path, body):
    response = await env.client.request(
        method, "/api/admin/library" + path.format(id=uuid.uuid4()), json=body, headers=auth(env.user["token"])
    )
    assert response.status_code == 403


async def test_unreadable_unknown_and_pruning(env):
    missing = uuid.uuid4()
    for path in (f"/tracks/{missing}/file", f"/albums/{missing}/cover-options"):
        assert (await env.client.get("/api/admin/library" + path, headers=env.headers)).status_code == 404
    track_id, _, path, _ = await library_track(env)
    path.unlink()
    result = await env.client.get(f"/api/admin/library/tracks/{track_id}/file", headers=env.headers)
    assert result.status_code == 409 and result.json()["detail"] == "Audiodatei nicht lesbar"
    (path.parent / "cover.jpg").write_bytes(image())
    (path.parent / "keep.txt").write_text("keep")
    prune_dir(path.parent)
    assert path.parent.exists()
    (path.parent / "keep.txt").unlink()
    prune_dir(path.parent)
    assert not path.parent.exists() and env.settings.music_dir.exists()


async def test_fingerprint_empty_errors_and_limits(env, monkeypatch):
    track_id, _, _, _ = await library_track(env)
    async with SessionLocal() as db:
        await update_config(db, {"library": {"acoustid_api_key": "key"}})

    async def empty(*args):
        return None

    monkeypatch.setattr(editor, "fingerprint", empty)
    endpoint = f"/api/admin/library/tracks/{track_id}/fingerprint"
    assert (await env.client.get(endpoint, headers=env.headers)).json() == []

    async def failed(*args):
        raise OSError("fingerprint failed")

    monkeypatch.setattr(editor, "fingerprint", failed)
    result = await env.client.get(endpoint, headers=env.headers)
    assert result.status_code == 502 and result.json()["detail"] == "AcoustID nicht erreichbar"

    async def fingerprint(*args):
        return "fingerprint"

    results = []
    for index in range(12):
        for release in range(20):
            item = lookup_result(recording=str(index), release=f"{index}-{release}", score=0.99 - index / 100)
            item[0]["recordings"][0]["releasegroups"][0]["releases"][0]["date"] = (
                {"year": 2000 + release} if release else {}
            )
            results.extend(item)

    async def lookup(*args):
        return results

    monkeypatch.setattr(editor, "fingerprint", fingerprint)
    monkeypatch.setattr(acoustid, "lookup", lookup)
    result = (await env.client.get(endpoint, headers=env.headers)).json()
    assert len(result) == 10
    assert [r["recording_id"] for r in result] == [str(index) for index in range(10)]
    assert all(len(r["releases"]) == 15 for r in result)
    assert result[0]["releases"][0]["year"] == 2001


async def test_review_counts_albums_once(env):
    track_id, album_id, _, _ = await library_track(env)
    path = audio(env.settings.music_dir / "Old/Old Album/second.mp3")
    write_tags(path, meta(title="Second", album="Old Album", album_artist="Old", artist="Old", track_no=2), None)
    async with SessionLocal() as db:
        second = await scanner.import_file(db, str(path.relative_to(env.settings.music_dir)))
        for id in (track_id, second.id):
            track = await db.get(Track, id)
            track.mb_recording_id = track.isrc = None
        (await db.get(Album, album_id)).cover_file = None
        await db.commit()
    unidentified = (await env.client.get("/api/admin/library/review", headers=env.headers, params={"limit": 1})).json()
    assert unidentified["total"] == 2 and len(unidentified["items"]) == 1
    uncovered = (
        await env.client.get("/api/admin/library/review", headers=env.headers, params={"kind": "no_cover"})
    ).json()
    assert uncovered["total"] == 1 and uncovered["items"][0]["id"] == str(track_id)


async def test_rematch_replaces_the_albums_existing_cover(env):
    track_id, album_id, _, metadata = await library_track(env)
    async with SessionLocal() as db:
        old_cover = (await db.get(Album, album_id)).cover_file
        assert old_cover is not None
        track = await db.get(Track, track_id)
        track = await apply_meta(db, track, metadata, image("blue", "PNG"))
        album = await db.get(Album, track.album_id, populate_existing=True)
        assert album.cover_file not in {None, old_cover}


async def test_fetch_cover_prefers_deezer_then_release_group(env, monkeypatch):
    from app.services import tagger

    requested = []

    def dispatch(request: httpx.Request) -> httpx.Response:
        requested.append(str(request.url))
        if "release-group" in request.url.path and "missing" in request.url.path:
            return httpx.Response(404)
        return httpx.Response(200, content=request.url.path.encode())

    real = httpx.AsyncClient
    monkeypatch.setattr(
        tagger.httpx, "AsyncClient", lambda **kwargs: real(transport=httpx.MockTransport(dispatch), **kwargs)
    )
    monkeypatch.setattr(get_settings(), "data_dir", env.settings.music_dir.parent / "cover-test")
    deezer_meta = meta(mb_release_id="rel", mb_release_group_id="group")
    deezer_meta.cover_url, deezer_meta.deezer_album_id = "https://cdn-images.dzcdn.net/x.jpg", "42"
    assert await tagger.fetch_cover(deezer_meta) == b"/x.jpg"
    assert await tagger.fetch_cover(meta(mb_release_id="rel", mb_release_group_id="group")) == (
        b"/release-group/group/front-1200"
    )
    assert await tagger.fetch_cover(meta(mb_release_id="rel", mb_release_group_id="missing")) == (
        b"/release/rel/front-1200"
    )
    assert await tagger.fetch_cover(meta(mb_release_id="only", mb_release_group_id=None)) == b"/release/only/front-1200"
    # Cached per source: no second download.
    count = len(requested)
    await tagger.fetch_cover(deezer_meta)
    assert len(requested) == count
