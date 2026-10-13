import asyncio
import io
import os
import shutil
import subprocess
import uuid
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from PIL import Image
from sqlalchemy import select

from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import ImportBatch, ImportFile, Playlist, PlaylistEntry, Track, TrackLike
from app.services import acoustid, identify, importer, scanner
from app.services.deezer import DeezerError, deezer
from app.services.fingerprint import fingerprint
from app.services.identify import AlbumCtx, Candidate, FileInfo, album_context, assign_releases, candidates, group_key
from app.services.library_paths import target_relpath
from app.services.musicbrainz import MusicBrainzClient, MusicBrainzError, TrackMeta, mb
from app.services.server_config import LibraryConfig, update_config
from app.services.tagger import write_tags
from app.services.tags import TrackTags, embedded_cover, read_tags
from tests.conftest import auth, register


def tags(**updates) -> TrackTags:
    values = dict(
        title="Song",
        artist="Artist",
        artist_credit="Artist",
        album="Album",
        album_artist="Artist",
        has_album_tag=True,
        has_album_artist_tag=False,
        track_no=1,
        disc_no=1,
        year=2001,
        duration=2,
        extra={"has_title_tag": True, "has_artist_tag": True},
    )
    values.update(updates)
    return TrackTags(**values)


def candidate(release="release", **updates) -> Candidate:
    values = dict(
        score=0.95,
        recording_id="recording",
        release_id=release,
        release_group_id="group",
        album="Album",
        disc_no=1,
        track_no=1,
        release_tracks=2,
        year=2001,
    )
    values.update(updates)
    return Candidate(**values)


def meta(**updates) -> TrackMeta:
    values = dict(
        title="Song",
        artist="Artist",
        artist_mbid=str(uuid.uuid4()),
        album="Album",
        album_artist="Artist",
        album_artist_mbid=str(uuid.uuid4()),
        track_no=1,
        track_total=2,
        disc_no=1,
        disc_total=1,
        year=2001,
        date="2001",
        duration=2,
        isrc="DEABC0100001",
        genre="Rock",
        label="Label",
        mb_recording_id=str(uuid.uuid4()),
        mb_release_id=str(uuid.uuid4()),
        mb_release_group_id=str(uuid.uuid4()),
    )
    values.update(updates)
    return TrackMeta(**values)


def lookup_result(recording="recording", release="release", position=1, album="Album", score=0.95) -> list[dict]:
    return [
        {
            "score": score,
            "recordings": [
                {
                    "id": recording,
                    "releasegroups": [
                        {
                            "id": "group",
                            "title": album,
                            "releases": [
                                {
                                    "id": release,
                                    "date": {"year": 2001},
                                    "track_count": 2,
                                    "mediums": [{"position": 1, "tracks": [{"position": position}]}],
                                }
                            ],
                        }
                    ],
                }
            ],
        }
    ]


def audio(path: Path, **metadata) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    codecs = {
        ".ogg": "libvorbis",
        ".oga": "libvorbis",
        ".opus": "libopus",
        ".wav": "pcm_s16le",
        ".aiff": "pcm_s16be",
        ".aif": "pcm_s16be",
        ".wv": "wavpack",
        ".wma": "wmav2",
        ".mp3": "libmp3lame",
        ".m4a": "aac",
        ".mp4": "aac",
        ".flac": "flac",
    }
    output = path if path.suffix not in {".ape", ".mpc"} else path.with_suffix(".wv")
    args = [
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-y",
        "-f",
        "lavfi",
        "-i",
        "sine=duration=2",
        "-c:a",
        codecs[output.suffix],
    ]
    for key, value in metadata.items():
        args.extend(["-metadata", f"{key}={value}"])
    subprocess.run([*args, str(output)], check=True)
    if output != path:
        # ffmpeg has no APE/MPC encoder. Exercise their APEv2 tag path on a copied WavPack file, as §8 allows.
        shutil.copy2(output, path)
        output.unlink()
    return path


@pytest.mark.parametrize(
    ("path", "expected"),
    [
        ("song.flac", ""),
        ("CD1/song.flac", ""),
        ("Artist/Album/CD1/a.mp3", "Artist/Album"),
        ("POP/Male/Beck/Album/disc 02/a.wma", "POP/Male/Beck/Album"),
        ("A/B/DISK3/a.flac", "A/B"),
        ("A/B/CD bonus/a.flac", "A/B/CD bonus"),
    ],
)
def test_group_key(path, expected):
    assert group_key(path) == expected


def test_candidates():
    results = lookup_result()
    results += lookup_result(score=0.79)
    results += [{"score": 0.8, "recordings": [{"id": "loose"}]}, {}, {"score": 0.9}]
    got = candidates(results)
    assert got == [candidate(), Candidate(0.8, "loose", None, None, None, None, None, None, None)]
    expanded = lookup_result()
    expanded[0]["recordings"][0]["releasegroups"][0]["releases"][0]["mediums"].append(
        {"position": 2, "tracks": [{"position": 3}, {"position": 4}]}
    )
    assert [(c.disc_no, c.track_no) for c in candidates(expanded)] == [(1, 1), (2, 3), (2, 4)]
    assert candidates([{"score": 1, "recordings": [{"id": "r", "releasegroups": [{}]}]}]) == []


def releases(files: list[FileInfo]) -> set[str] | None:
    """Release ids chosen for a folder (None when nothing was assigned)."""
    return {c.release_id for c in assign_releases(files).values()} or None


def test_assign_releases_full_partial_and_promo():
    files = [FileInfo([candidate(track_no=i, release_tracks=10)], tags(track_no=i)) for i in range(1, 11)]
    assert releases(files) == {"release"}
    assert len(assign_releases(files)) == 10
    assert releases(files[:3]) == {"release"}
    files[2].candidates = [candidate("other", track_no=3)]
    assert releases(files[:3]) == {"release"}
    files[1].candidates = [candidate("different", track_no=2)]
    assert releases(files[:3]) is None
    promo = [FileInfo([candidate(str(i))], tags(artist=str(i))) for i in range(4)]
    assert releases(promo) is None
    assert releases([FileInfo([], tags())]) is None


def test_assign_releases_single_and_stability():
    assert releases([FileInfo([candidate()], tags(album="  ALBUM "))]) == {"release"}
    assert releases([FileInfo([candidate()], tags(album="Promo"))]) is None
    assert releases([FileInfo([candidate()], tags(has_album_tag=False))]) is None
    files = [
        FileInfo(
            [
                candidate("z", release_tracks=4, year=1990, track_no=i),
                candidate("b", year=2000, track_no=i),
                candidate("a", year=2000, track_no=i),
            ],
            tags(track_no=i),
        )
        for i in (1, 2)
    ]
    assert releases(files) == {"a"}
    for i, file in enumerate(files, 1):
        file.candidates.append(candidate("earlier", year=1999, track_no=i))
    assert releases(files) == {"earlier"}
    assert releases([FileInfo([candidate(), candidate()], tags()), FileInfo([], tags())]) is None


def test_assign_releases_prefers_matching_edition_and_unique_positions():
    # Two editions with different track order; AcoustID links file 2's fingerprint to two recordings.
    files = [
        FileInfo(
            [candidate("vinyl", track_no=3, title="Keep a Secret"), candidate("cd", track_no=1, title="Keep a Secret")],
            tags(track_no=1, title="Keep a Secret"),
        ),
        FileInfo(
            [
                candidate("vinyl", track_no=1, title="Courage"),
                candidate("cd", track_no=3, title="Courage"),
                candidate("vinyl", track_no=2, title="Promise Less or Do More"),
                candidate("cd", track_no=2, title="Promise Less or Do More"),
            ],
            tags(track_no=2, title="Promise Less or Do More"),
        ),
        FileInfo(
            [candidate("vinyl", track_no=1, title="Courage"), candidate("cd", track_no=3, title="Courage")],
            tags(track_no=3, title="Courage"),
        ),
    ]
    got = assign_releases(files)
    assert {c.release_id for c in got.values()} == {"cd"}
    assert [got[f].track_no for f in files] == [1, 2, 3]


def test_assign_releases_two_albums_in_one_folder():
    first = [FileInfo([candidate("one", track_no=i, release_tracks=4)], tags(track_no=i)) for i in range(1, 5)]
    second = [FileInfo([candidate("two", track_no=i, release_tracks=3)], tags(track_no=i)) for i in range(1, 4)]
    got = assign_releases(first + second)
    assert {f: c.release_id for f, c in got.items()} == {**{f: "one" for f in first}, **{f: "two" for f in second}}


def test_album_context_compilation_singles_and_majority():
    files = [
        FileInfo([], tags(artist="A feat. X", artist_credit="A feat. X", year=2001, disc_no=1)),
        FileInfo([], tags(artist="B", artist_credit="B", year=2001, disc_no=2)),
        FileInfo([], tags(artist="C", artist_credit="C", year=2002, disc_no=1)),
    ]
    context = album_context(files)
    assert context[files[0]] == AlbumCtx("Album", "Various Artists", 2001, 2)
    for file in files[:2]:
        file.tags.has_album_artist_tag = True
        file.tags.album_artist = "DJ Mix"
    assert album_context(files)[files[2]].album_artist == "DJ Mix"
    singles = [
        FileInfo([], tags(title="One", artist="A", has_album_tag=False)),
        FileInfo([], tags(title="Two", artist="B", has_album_tag=False, year=1999)),
    ]
    context = album_context(singles)
    assert context[singles[0]] == AlbumCtx("One", "A", 2001, 1)
    assert context[singles[1]] == AlbumCtx("Two", "B", 1999, 1)
    same = [FileInfo([], tags(artist="A feat. X")), FileInfo([], tags(artist="A"))]
    assert album_context(same)[same[0]].album_artist == "A feat. X"


@pytest.mark.parametrize(
    "extension",
    [".ogg", ".oga", ".wav", ".aiff", ".aif", ".ape", ".mpc", ".wv", ".wma", ".mp3", ".flac", ".m4a", ".mp4", ".opus"],
)
def test_tagger_roundtrip_and_clear_missing(tmp_path, extension):
    path = audio(tmp_path / f"audio{extension}")
    before = read_tags(path)
    assert before is not None and not before.has_album_tag and not before.has_album_artist_tag
    buf = io.BytesIO()
    Image.new("RGB", (2, 2), (255, 0, 0)).save(buf, "JPEG")
    cover = buf.getvalue()
    original = meta(disc_no=2, disc_total=3)
    write_tags(path, original, cover)
    got = read_tags(path)
    assert got is not None
    assert (got.title, got.artist_credit, got.album, got.album_artist) == ("Song", "Artist", "Album", "Artist")
    assert got.has_album_tag and got.has_album_artist_tag
    assert (got.track_no, got.track_total, got.disc_no, got.disc_total) == (1, 2, 2, 3)
    assert (got.year, got.genre, got.label, got.isrc) == (2001, "Rock", "Label", original.isrc)
    assert (
        got.mb_recording_id,
        got.mb_album_id,
        got.mb_release_group_id,
        got.mb_artist_id,
        got.mb_album_artist_id,
    ) == (
        original.mb_recording_id,
        original.mb_release_id,
        original.mb_release_group_id,
        original.artist_mbid,
        original.album_artist_mbid,
    )
    assert embedded_cover(path) == cover
    empty = original.model_copy(
        update=dict(
            isrc=None,
            mb_recording_id=None,
            mb_release_id=None,
            mb_release_group_id=None,
            artist_mbid=None,
            album_artist_mbid=None,
        )
    )
    write_tags(path, empty, None)
    assert read_tags(path).mb_recording_id == original.mb_recording_id
    write_tags(path, empty, None, clear_missing=True)
    got = read_tags(path)
    assert (
        got.isrc,
        got.mb_recording_id,
        got.mb_album_id,
        got.mb_release_group_id,
        got.mb_artist_id,
        got.mb_album_artist_id,
    ) == (None,) * 6
    assert embedded_cover(path) == cover


async def test_recording_basic(monkeypatch):
    client = MusicBrainzClient()

    async def get(path, **params):
        assert path == "recording/recording" and params == {"inc": "artist-credits+isrcs+genres"}
        return {
            "title": "Song",
            "artist-credit": [{"name": "A", "artist": {"id": "artist"}, "joinphrase": " & "}, {"name": "B"}],
            "isrcs": ["FIRST", "SECOND"],
            "length": 2345,
            "genres": [{"name": "pop", "count": 1}, {"name": "alternative rock", "count": 4}],
        }

    monkeypatch.setattr(client, "_get", get)
    assert await client.recording_basic("recording") == dict(
        title="Song", artist="A & B", artist_mbid="artist", isrc="FIRST", genre="Alternative Rock", length=2.345
    )


async def test_fingerprint(tmp_path):
    path = audio(tmp_path / "sound.wav")
    assert isinstance(await fingerprint(path), str)
    assert await fingerprint(tmp_path / "missing.wav") is None


@pytest.mark.parametrize("failure", ["http", "json"])
async def test_acoustid_errors(monkeypatch, failure):
    original = httpx.AsyncClient

    def request(req):
        return httpx.Response(400 if failure == "http" else 200, json={"status": "error", "error": "Testfehler"})

    monkeypatch.setattr(
        acoustid.httpx, "AsyncClient", lambda **kwargs: original(transport=httpx.MockTransport(request))
    )
    with pytest.raises(acoustid.AcoustIDError):
        await acoustid.lookup("key", "print", 2)


async def test_acoustid_rate_limit_retries_and_form(monkeypatch):
    original = httpx.AsyncClient
    now = [100.0]
    starts = []
    sleeps = []

    async def sleep(seconds):
        sleeps.append(seconds)
        now[0] += seconds

    def request(req):
        starts.append(now[0])
        from urllib.parse import parse_qs

        form = parse_qs(req.content.decode())
        assert form == {
            "client": ["key"],
            "duration": ["3"],
            "fingerprint": ["print"],
            "meta": ["recordings releasegroups releases tracks compress"],
        }
        assert str(req.url) == "https://api.acoustid.org/v2/lookup" and req.method == "POST"
        return httpx.Response(
            429 if len(starts) == 1 else 503 if len(starts) == 2 else 200,
            json={"status": "ok", "results": [{"score": 1}]},
        )

    monkeypatch.setattr(acoustid, "time", SimpleNamespace(monotonic=lambda: now[0]))
    monkeypatch.setattr(acoustid, "_last_started", 0)
    monkeypatch.setattr(acoustid.asyncio, "sleep", sleep)
    monkeypatch.setattr(
        acoustid.httpx, "AsyncClient", lambda **kwargs: original(transport=httpx.MockTransport(request))
    )
    assert await acoustid.lookup("key", "print", 2.6) == [{"score": 1}]
    assert await acoustid.lookup("key", "print", 2.6) == [{"score": 1}]
    assert len(starts) == 4 and all(b - a >= 0.3399 for a, b in zip(starts, starts[1:]))
    assert sleeps.count(2) == 2


@pytest.fixture
async def env(client, tmp_path, monkeypatch):
    assert engine.url.database.startswith("app_test")
    await importer.stop()
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    settings = get_settings()
    monkeypatch.setattr(settings, "music_dir", tmp_path / "music")
    monkeypatch.setattr(settings, "import_dir", tmp_path / "import")
    monkeypatch.setattr(settings, "data_dir", tmp_path / "data")
    settings.music_dir.mkdir()
    settings.import_dir.mkdir()
    admin = await register(client, "admin")
    invite = (await client.post("/api/admin/invites", json={}, headers=auth(admin["token"]))).json()["token"]
    user = await register(client, "user", invite)

    async def no_results(*args, **kwargs):
        return []

    async def fake_print(path):
        return path.name

    async def no_cover(meta):
        return None

    monkeypatch.setattr(importer, "fingerprint", fake_print)
    monkeypatch.setattr(acoustid, "lookup", no_results)
    monkeypatch.setattr(deezer, "search_tracks", no_results)
    monkeypatch.setattr(importer, "fetch_cover", no_cover)
    yield SimpleNamespace(client=client, settings=settings, admin=admin, user=user)
    await importer.stop()
    importer._cancelled.clear()


async def configure(**patch):
    async with SessionLocal() as db:
        await update_config(db, {"library": patch})


async def batch(env, kind="import"):
    response = await env.client.post("/api/admin/imports", json={"kind": kind}, headers=auth(env.admin["token"]))
    assert response.status_code == 201, response.text
    await importer._running
    result = await env.client.get(f"/api/admin/imports/{response.json()['id']}", headers=auth(env.admin["token"]))
    assert result.status_code == 200
    return result.json()


async def batch_files(env, result):
    return (await env.client.get(f"/api/admin/imports/{result['id']}/files", headers=auth(env.admin["token"]))).json()[
        "items"
    ]


async def test_import_copy_and_no_key(env, monkeypatch):
    await configure(import_mode="copy")
    paths = [
        audio(
            env.settings.import_dir / f"POP/Beck/Album/CD1/{i}.FLAC".lower(),
            title=f"Song {i}",
            artist="Beck",
            album="Album",
            track=str(i),
            date="2001",
        )
        for i in (1, 2)
    ]
    originals = {p: p.read_bytes() for p in paths}

    async def forbidden(*args, **kwargs):
        raise AssertionError("Fingerprint and AcoustID must be skipped without a key")

    monkeypatch.setattr(importer, "fingerprint", forbidden)
    monkeypatch.setattr(acoustid, "lookup", forbidden)
    result = await batch(env)
    assert (result["status"], result["total"], result["processed"], result["imported"], result["unidentified"]) == (
        "done",
        2,
        2,
        2,
        2,
    )
    assert result["identified"] == result["failed"] == result["duplicates"] == 0
    assert result["progress"] == 1
    assert result["message"] == "Kein AcoustID-Schlüssel – Erkennung nur über vorhandene Tags"
    assert all(p.read_bytes() == data for p, data in originals.items())
    rows = await batch_files(env, result)
    assert [r["target"] for r in rows] == ["Beck/Album (2001)/01 - Song 1.flac", "Beck/Album (2001)/02 - Song 2.flac"]
    async with SessionLocal() as db:
        tracks = list(await db.scalars(select(Track)))
        assert {t.path for t in tracks} == {r["target"] for r in rows}
    assert all((env.settings.music_dir / r["target"]).is_file() and r["status"] == "imported" for r in rows)
    assert not list(env.settings.music_dir.rglob("*.part"))


async def test_import_move_removes_empty_directories(env):
    path = audio(env.settings.import_dir / "Genre/Artist/Album/song.flac", title="Song", artist="Artist", album="Album")
    result = await batch(env)
    assert result["imported"] == 1 and not path.exists()
    assert env.settings.import_dir.is_dir() and list(env.settings.import_dir.iterdir()) == []


async def test_import_release_identification(env, monkeypatch):
    await configure(acoustid_api_key="key")
    paths = [
        audio(env.settings.import_dir / f"mess/CD1/{i}.flac", title=f"old {i}", artist="A", album="Old") for i in (1, 2)
    ]
    metas = [meta(title=f"Song {i}", track_no=i) for i in (1, 2)]

    async def lookup(key, print, duration):
        assert key == "key"
        return lookup_result(recording=f"recording-{print}", position=int(Path(print).stem))

    async def release(id):
        assert id == "release"
        return {}

    async def track_meta(data):
        return metas

    async def cover(meta):
        buf = io.BytesIO()
        Image.new("RGB", (2, 2)).save(buf, "JPEG")
        return buf.getvalue()

    monkeypatch.setattr(acoustid, "lookup", lookup)
    monkeypatch.setattr(mb, "release_full", release)
    monkeypatch.setattr(mb, "track_meta_list", track_meta)
    monkeypatch.setattr(importer, "fetch_cover", cover)
    result = await batch(env)
    assert (result["identified"], result["imported"], result["unidentified"]) == (2, 2, 0)
    rows = await batch_files(env, result)
    assert all(r["method"] == "release" and r["acoustid_score"] == 0.95 for r in rows)
    assert (env.settings.music_dir / "Artist/Album (2001)/cover.jpg").is_file()
    assert not any(p.exists() for p in paths)


async def test_import_recording_preserves_compilation(env, monkeypatch):
    await configure(acoustid_api_key="key")
    for i in (1, 2):
        audio(
            env.settings.import_dir / f"Promo/{i}.flac",
            title=f"Old {i}",
            artist=f"Artist {i}",
            album="Promo",
            track=str(i),
            date="1999",
        )

    async def lookup(*args):
        return [{"score": 0.9, "recordings": [{"id": "recording"}]}]

    async def basic(id):
        return {
            "title": "Known",
            "artist": "Known Artist",
            "artist_mbid": None,
            "isrc": "DEABC0100001",
            "genre": "Rock",
            "length": 2,
        }

    monkeypatch.setattr(acoustid, "lookup", lookup)
    monkeypatch.setattr(mb, "recording_basic", basic)
    result = await batch(env)
    assert (result["identified"], result["imported"]) == (2, 2)
    rows = await batch_files(env, result)
    assert all(r["method"] == "recording" and r["target"].startswith("Various Artists/Promo (1999)/") for r in rows)
    async with SessionLocal() as db:
        files = list(await db.scalars(select(ImportFile)))
        assert all(f.meta["mb_release_id"] is None and f.meta["mb_release_group_id"] is None for f in files)


async def test_deezer_keeps_original_album_context(env, monkeypatch):
    audio(
        env.settings.import_dir / "Promo/song.flac",
        title="Song",
        artist="Artist",
        album="My Promo",
        track="7",
        date="1999",
    )
    # A second song of the same promo keeps the album context (a lone song would go to its original album).
    audio(
        env.settings.import_dir / "Promo/other.flac",
        title="Other",
        artist="Artist",
        album="My Promo",
        track="8",
        date="1999",
    )

    async def search(query, limit):
        assert limit == 5
        if query != 'artist:"Artist" track:"Song"':
            return []
        return [
            {"id": 1, "title": "Unrelated", "artist": {"name": "Artist"}, "duration": 2},
            {"id": 2, "title": "Song", "artist": {"name": "Artist"}, "duration": 2},
        ]

    async def resolve(id):
        assert id == "2"
        return meta(album="Wrong Release", album_artist="Wrong", year=2020, track_no=3, disc_no=4)

    monkeypatch.setattr(deezer, "search_tracks", search)
    monkeypatch.setattr(identify, "resolve_track", resolve)
    result = await batch(env)
    row = next(r for r in await batch_files(env, result) if r["path"] == "Promo/song.flac")
    assert row["method"] == "deezer" and row["target"] == "Artist/My Promo (1999)/07 - Song.flac"
    async with SessionLocal() as db:
        file = await db.scalar(select(ImportFile).where(ImportFile.path == "Promo/song.flac"))
        assert file.meta["mb_release_id"] is None and file.meta["album_artist_mbid"] is None
        assert file.meta["deezer_album_id"] is None


async def test_provider_errors_fall_through(env, monkeypatch):
    await configure(acoustid_api_key="key")
    for i in (1, 2):
        audio(
            env.settings.import_dir / f"Album/{i}.flac", title=f"Song {i}", artist="Artist", album="Album", track=str(i)
        )

    async def lookup(key, print, duration):
        return lookup_result(position=int(Path(print).stem))

    async def unavailable(*args):
        raise MusicBrainzError("Testfehler")

    async def unavailable_deezer(*args):
        raise DeezerError("Testfehler")

    monkeypatch.setattr(acoustid, "lookup", lookup)
    monkeypatch.setattr(mb, "release_full", unavailable)
    monkeypatch.setattr(mb, "recording_basic", unavailable)
    monkeypatch.setattr(deezer, "search_tracks", unavailable_deezer)
    result = await batch(env)
    assert result["status"] == "done" and result["imported"] == result["unidentified"] == 2
    assert all(r["method"] == "tags" for r in await batch_files(env, result))


async def test_acoustid_error_and_unidentified_untouched(env, monkeypatch):
    await configure(acoustid_api_key="key", import_unidentified=False)
    path = audio(env.settings.import_dir / "Album/song.flac", title="Song", artist="Artist", album="Album")
    original = path.read_bytes()

    async def unavailable(*args):
        raise acoustid.AcoustIDError("Testfehler")

    monkeypatch.setattr(acoustid, "lookup", unavailable)
    result = await batch(env)
    assert result["status"] == "done" and result["unidentified"] == 1 and result["imported"] == 0
    row = (await batch_files(env, result))[0]
    assert row["status"] == "unidentified" and row["method"] is None
    assert path.read_bytes() == original


@pytest.mark.parametrize("higher", [False, True])
async def test_duplicate_quality_and_existing_track_id(env, monkeypatch, higher):
    # Same extension, different bitrates: quality upgrades replace one canonical path.
    source = audio(env.settings.import_dir / "Album/song.mp3", title="Song", artist="Artist", album="Album", track="1")
    dest = audio(env.settings.music_dir / "Artist/Album/01 - Song.mp3", title="Old", artist="Artist", album="Album")
    source_bytes, dest_bytes = source.read_bytes(), dest.read_bytes()
    async with SessionLocal() as db:
        existing = await scanner.import_file(db, "Artist/Album/01 - Song.mp3")
        original_id = existing.id
    real_read = read_tags

    def measured(path):
        got = real_read(path)
        if got is not None:
            got.bitrate = 320 if path == source and higher else 64 if path == source else 192
        return got

    monkeypatch.setattr(importer, "read_tags", measured)
    result = await batch(env)
    row = (await batch_files(env, result))[0]
    if higher:
        assert result["imported"] == 1 and result["duplicates"] == 0 and not source.exists()
        assert read_tags(dest).title == "Song"
        async with SessionLocal() as db:
            track = await db.get(Track, original_id)
            assert track.title == "Song" and row["status"] == "imported"
    else:
        assert result["duplicates"] == 1 and row["status"] == "duplicate"
        assert source.read_bytes() == source_bytes and dest.read_bytes() == dest_bytes
    async with SessionLocal() as db:
        assert (await db.scalar(select(Track).where(Track.path == "Artist/Album/01 - Song.mp3"))).id == original_id


async def test_cleanup_keeps_ids_likes_playlist_and_copies_cover(env):
    old = "POP/Male/Beck/Old/song.flac"
    path = audio(env.settings.music_dir / old, title="Song", artist="Beck", album="Mutations", track="1", date="1998")
    Image.new("RGB", (2, 2)).save(path.parent / "folder.jpg")
    (path.parent / "desktop.ini").write_text("leftover")
    async with SessionLocal() as db:
        track = await scanner.import_file(db, old)
        original_id = track.id
        owner = uuid.UUID(env.admin["user"]["id"])
        playlist = Playlist(owner_id=owner, name="Favorites")
        db.add(playlist)
        await db.flush()
        entry = PlaylistEntry(playlist_id=playlist.id, track_id=track.id, position=1)
        like = TrackLike(user_id=owner, track_id=track.id)
        db.add_all([entry, like])
        await db.commit()
        entry_id, like_id = entry.id, like.id
    result = await batch(env, "cleanup")
    assert (result["status"], result["mode"], result["imported"]) == ("done", "inplace", 1)
    target = "Beck/Mutations (1998)/01 - Song.flac"
    async with SessionLocal() as db:
        track = await db.get(Track, original_id)
        assert track.path == target
        assert (await db.get(PlaylistEntry, entry_id)).track_id == original_id
        assert (await db.get(TrackLike, like_id)).track_id == original_id
    assert (env.settings.music_dir / target).is_file()
    assert (env.settings.music_dir / "Beck/Mutations (1998)/cover.jpg").is_file()
    assert not (env.settings.music_dir / "POP").exists()
    assert env.settings.music_dir.exists()


async def test_admin_permissions_empty_import_and_info(env):
    for suffix in ("", "/info", f"/{uuid.uuid4()}", f"/{uuid.uuid4()}/files"):
        assert (await env.client.get(f"/api/admin/imports{suffix}", headers=auth(env.user["token"]))).status_code == 403
    assert (
        await env.client.post("/api/admin/imports", json={"kind": "cleanup"}, headers=auth(env.user["token"]))
    ).status_code == 403
    assert (
        await env.client.post(f"/api/admin/imports/{uuid.uuid4()}/cancel", headers=auth(env.user["token"]))
    ).status_code == 403
    response = await env.client.post("/api/admin/imports", json={"kind": "import"}, headers=auth(env.admin["token"]))
    assert response.status_code == 400 and response.json()["detail"] == "Der Import-Ordner ist leer"
    audio(env.settings.import_dir / "song.flac")
    audio(env.settings.import_dir / ".hidden/a.flac")
    (env.settings.import_dir / "song.flac.part").write_bytes(b"partial")
    info = (await env.client.get("/api/admin/imports/info", headers=auth(env.admin["token"]))).json()
    assert info == dict(
        import_dir=str(env.settings.import_dir), pending_files=1, acoustid_configured=False, import_mode="move"
    )
    assert LibraryConfig().model_dump() == dict(
        acoustid_api_key="", import_mode="move", import_unidentified=True, auto_import=True
    )


async def test_second_batch_409_cancel_after_current_group(env, monkeypatch):
    await configure(acoustid_api_key="key")
    for rel in ("A/one.flac", "A/two.flac", "B/three.flac"):
        audio(env.settings.import_dir / rel)
    entered, released = asyncio.Event(), asyncio.Event()

    async def paused(path):
        entered.set()
        await released.wait()
        return None

    monkeypatch.setattr(importer, "fingerprint", paused)
    response = await env.client.post("/api/admin/imports", json={"kind": "import"}, headers=auth(env.admin["token"]))
    assert response.status_code == 201
    id = response.json()["id"]
    await asyncio.wait_for(entered.wait(), 5)
    second = await env.client.post("/api/admin/imports", json={"kind": "cleanup"}, headers=auth(env.admin["token"]))
    assert second.status_code == 409 and second.json()["detail"] == "Es läuft bereits ein Import"
    cancel = await env.client.post(f"/api/admin/imports/{id}/cancel", headers=auth(env.admin["token"]))
    assert cancel.status_code == 200
    released.set()
    await importer._running
    result = (await env.client.get(f"/api/admin/imports/{id}", headers=auth(env.admin["token"]))).json()
    assert result["status"] == "cancelled" and result["processed"] == 2 and result["total"] == 3
    assert (env.settings.import_dir / "B/three.flac").exists()
    again = await env.client.post(f"/api/admin/imports/{id}/cancel", headers=auth(env.admin["token"]))
    assert again.status_code == 409 and again.json()["detail"] == "Import läuft nicht"
    page = (
        await env.client.get(
            f"/api/admin/imports/{id}/files?status=pending&offset=0&limit=1", headers=auth(env.admin["token"])
        )
    ).json()
    assert page["total"] == 1 and page["items"][0]["path"] == "B/three.flac" and page["limit"] == 1


@pytest.mark.parametrize("status", ["queued", "running"])
async def test_resume_only_pending_files(env, status):
    source = audio(env.settings.import_dir / "Album/new.flac", title="New", artist="Artist", album="Album")
    async with SessionLocal() as db:
        row = ImportBatch(kind="import", mode="move", source_dir=str(env.settings.import_dir), status=status, total=2)
        db.add(row)
        await db.flush()
        db.add_all(
            [
                ImportFile(batch_id=row.id, path="done.flac", group_key="", status="duplicate"),
                ImportFile(batch_id=row.id, path="Album/new.flac", group_key="Album", status="pending"),
            ]
        )
        await db.commit()
        id = row.id
    await importer.start()
    assert importer._auto_task is None
    await importer._running
    async with SessionLocal() as db:
        row = await db.get(ImportBatch, id)
        assert (row.status, row.total, row.processed, row.imported, row.duplicates) == ("done", 2, 2, 1, 1)
    assert not source.exists()


async def test_auto_import_conditions(env):
    source = audio(env.settings.import_dir / "Album/song.flac")
    await importer._auto_import_once()
    assert importer._running is None
    os.utime(source, (1, 1))
    await configure(import_mode="copy")
    await importer._auto_import_once()
    assert importer._running is None
    await configure(import_mode="move", auto_import=False)
    await importer._auto_import_once()
    assert importer._running is None
    await configure(auto_import=True)
    await importer._auto_import_once()
    assert importer._running is not None
    await importer._running
    assert not source.exists()


async def test_unexpected_batch_exception(env, monkeypatch):
    audio(env.settings.import_dir / "song.flac")

    def fail(files):
        raise RuntimeError("Testfehler")

    monkeypatch.setattr(importer, "assign_releases", fail)
    result = await batch(env)
    assert result["status"] == "failed" and result["message"] == "Import fehlgeschlagen: Testfehler"
    assert result["finished_at"] is not None


async def test_cleanup_collision_preserves_both_existing_ids(env, monkeypatch):
    source = audio(env.settings.music_dir / "Old/song.mp3", title="Song", artist="Artist", album="Album", track="1")
    dest = audio(
        env.settings.music_dir / "Artist/Album/01 - Song.mp3", title="Song", artist="Artist", album="Album", track="1"
    )
    async with SessionLocal() as db:
        originals = await scanner.import_files(
            db, [str(source.relative_to(env.settings.music_dir)), str(dest.relative_to(env.settings.music_dir))]
        )
        ids = {track.id for track in originals.values()}
    source_bytes = source.read_bytes()

    def measured(path):
        got = read_tags(path)
        got.bitrate = 320 if path == source else 64
        return got

    monkeypatch.setattr(importer, "read_tags", measured)
    result = await batch(env, "cleanup")
    assert result["failed"] == 1 and result["imported"] == 1
    assert source.read_bytes() == source_bytes
    async with SessionLocal() as db:
        assert {t.id for t in await db.scalars(select(Track))} == ids


def test_quality_and_target_extension(tmp_path, monkeypatch):
    monkeypatch.setattr(get_settings(), "music_dir", tmp_path)
    original = meta()
    path = target_relpath(original, ".FLAC", unique=False)
    assert path == "Artist/Album (2001)/01 - Song.flac"
    dest = tmp_path / path
    dest.parent.mkdir(parents=True)
    dest.touch()
    assert target_relpath(original, ".FLAC", unique=False) == path
    assert target_relpath(original, ".FLAC").endswith("Song (2).flac")
    for codec in ("flac", "alac", "ape", "wavpack", "wave", "aiff"):
        assert importer.quality(tags(codec=codec, bitrate=100)) == 10000
    assert importer.quality(tags(codec="mp3", bitrate=128)) == 128
    assert importer.quality(tags(codec="mp3", bitrate=None)) == 0


def test_existing_mp3_replaygain_and_numeric_genre(tmp_path):
    from mutagen.easyid3 import EasyID3

    path = audio(tmp_path / "existing.mp3")
    original = EasyID3(path)
    original["genre"] = ["(17)"]
    original["replaygain_track_gain"] = ["-5.5 dB"]
    original.save()
    got = read_tags(path)
    assert got.genre == "Rock" and got.replaygain_track_gain == -5.5


async def test_lone_song_goes_to_original_album(env, monkeypatch):
    audio(env.settings.import_dir / "NDW/hit.flac", title="Song", artist="Artist", album="Fetenhits", track="12")

    async def search(query, limit):
        return [{"id": 2, "title": "Song", "artist": {"name": "Artist"}, "duration": 2}]

    async def resolve(id):
        return meta(album="Original Album", album_artist="Artist", year=1982, track_no=3, disc_no=1)

    monkeypatch.setattr(deezer, "search_tracks", search)
    monkeypatch.setattr(identify, "resolve_track", resolve)
    result = await batch(env)
    row = (await batch_files(env, result))[0]
    assert row["method"] == "deezer" and row["target"] == "Artist/Original Album (1982)/03 - Song.flac"


def test_album_context_normalizes_various_artists():
    files = [FileInfo([], tags(album_artist="Verschiedene Interpreten", has_album_artist_tag=True)) for _ in range(2)]
    assert {c.album_artist for c in album_context(files).values()} == {"Various Artists"}
