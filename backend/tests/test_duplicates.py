import subprocess
import uuid
from collections.abc import AsyncIterator, Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import httpx
import pytest
from sqlalchemy import event, insert, select

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
    Track,
    TrackLike,
    TrackLyrics,
)
from app.services import downloads, importer, sources
from app.services.duplicates import (
    _same_stem_track,
    find_groups,
    lossless_twin,
    merge_group,
    merge_new_duplicates,
    track_quality,
)
from app.services.library_paths import target_relpath
from app.services.musicbrainz import TrackMeta
from app.services.sources.base import Candidate
from app.services.tags import read_tags
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
    for name in ("music_dir", "import_dir", "data_dir", "downloads_dir"):
        path = tmp_path / name
        path.mkdir()
        monkeypatch.setattr(settings, name, path)
    admin = await register(client, "admin")
    headers = auth(admin["token"])
    invite = (await client.post("/api/admin/invites", json={}, headers=headers)).json()["token"]
    user = await register(client, "user", invite)
    try:
        yield SimpleNamespace(
            client=client,
            settings=settings,
            headers=headers,
            user_headers=auth(user["token"]),
            user_id=uuid.UUID(user["user"]["id"]),
        )
    finally:
        await reset()


async def library(env: SimpleNamespace, overrides: list[dict[str, Any]] | None = None) -> list[Track]:
    if overrides is None:
        overrides = [{"codec": "flac"}, {"codec": "mp3"}]
    async with SessionLocal() as db:
        artist = Artist(name="Artist", name_key="artist")
        db.add(artist)
        await db.flush()
        albums: dict[str, Album] = {}
        tracks: list[Track] = []
        for index, values in enumerate(overrides):
            values = values.copy()
            album_title = values.pop("album", "Album")
            if album_title not in albums:
                album = Album(title=album_title, title_key=album_title.casefold(), artist_id=artist.id)
                db.add(album)
                await db.flush()
                albums[album_title] = album
            data = {
                "path": f"Artist/{album_title}/{index}.{(values.get('codec') or 'flac').lower()}",
                "title": "Song",
                "album_id": albums[album_title].id,
                "artist_id": artist.id,
                "artist_credit": artist.name,
                "track_no": 1,
                "disc_no": 1,
                "duration": 2.0,
                "bitrate": 192,
                "size": 5,
                **values,
            }
            track = Track(**data)
            path = env.settings.music_dir / track.path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"audio")
            tracks.append(track)
        db.add_all(tracks)
        await db.commit()
        return tracks


@pytest.mark.parametrize(
    ("changes", "expected"),
    [
        ({}, 1),
        ({"track_no": 2}, 0),
        ({"track_no": None}, 0),
        ({"duration": 32}, 0),
        ({"album": "Other"}, 1),
        ({"disc_no": None}, 1),
        ({"disc_no": 2}, 0),
        ({"title": "  SONG  "}, 1),
        ({"title": "Other song"}, 0),
        ({"duration": 7}, 1),
    ],
)
async def test_find_groups(env: SimpleNamespace, changes: dict[str, Any], expected: int) -> None:
    tracks = await library(env, [{"codec": "FLAC"}, {"codec": "mp3", **changes}])
    queries: list[str] = []

    def executed(conn: Any, cursor: Any, statement: str, parameters: Any, context: Any, executemany: bool) -> None:
        queries.append(statement)

    async with SessionLocal() as db:
        event.listen(engine.sync_engine, "before_cursor_execute", executed)
        try:
            groups = await find_groups(db)
            assert len(groups) == expected
            if expected:
                assert [track.id for track in groups[0]] == [track.id for track in tracks]
                assert groups[0][0].album.artist.name == "Artist"
                assert groups[0][0].artist.name == "Artist"
        finally:
            event.remove(engine.sync_engine, "before_cursor_execute", executed)
    assert len(queries) == (3 if changes.get("album") else 2)


async def test_greedy_duration_and_keeper_order(env: SimpleNamespace) -> None:
    oldest = datetime.now(UTC) - timedelta(days=1)
    tracks = await library(
        env,
        [
            {"codec": "flac", "duration": 100, "is_temporary": True, "created_at": oldest},
            {"codec": "flac", "duration": 105, "created_at": oldest},
            {"codec": "flac", "duration": 110},
        ],
    )
    async with SessionLocal() as db:
        groups = await find_groups(db)
        assert [[track.id for track in group] for group in groups] == [[tracks[1].id, tracks[0].id]]


@pytest.mark.parametrize("codec", ["flac", "ALAC", "ape", "wavpack", "wave", "wav", "aiff"])
def test_lossless_quality(codec: str) -> None:
    assert track_quality(Track(codec=codec, bitrate=192)) == 10_000
    assert track_quality(Track(codec="mp3", bitrate=320)) == 320
    assert track_quality(Track(codec=None, bitrate=None)) == 0


@pytest.mark.parametrize("keeper_like", [False, True])
async def test_merge_moves_references_and_deletes_file(env: SimpleNamespace, keeper_like: bool) -> None:
    tracks = await library(env, [{"codec": "flac", "is_temporary": True}, {"codec": "mp3", "reviewed": True}])
    keeper_id, loser_id = [track.id for track in tracks]
    async with SessionLocal() as db:
        playlist = Playlist(owner_id=env.user_id, name="Playlist")
        request = DownloadRequest(
            user_id=env.user_id, kind="track", title="Song", artist="Artist", status="done", replace_track_id=loser_id
        )
        batch = ImportBatch(kind="import", mode="copy", source_dir="import", status="done")
        db.add_all([playlist, request, batch])
        await db.flush()
        entry = PlaylistEntry(playlist_id=playlist.id, track_id=loser_id, position=1)
        history = PlayEvent(user_id=env.user_id, track_id=loser_id)
        item = DownloadItem(
            request_id=request.id,
            position=0,
            title="Song",
            artist="Artist",
            meta={},
            status="done",
            track_id=loser_id,
            replace_track_id=loser_id,
        )
        imported = ImportFile(batch_id=batch.id, path="song", group_key="album", status="done", track_id=loser_id)
        db.add_all([entry, history, item, imported, TrackLike(user_id=env.user_id, track_id=loser_id)])
        if keeper_like:
            db.add(TrackLike(user_id=env.user_id, track_id=keeper_id))
        await db.commit()
        await merge_group(db, await db.get(Track, keeper_id), [await db.get(Track, loser_id)])
    async with SessionLocal() as db:
        assert await db.get(Track, loser_id) is None
        keeper = await db.get(Track, keeper_id)
        assert not keeper.is_temporary and keeper.reviewed
        assert list(await db.scalars(select(TrackLike.track_id))) == [keeper_id]
        assert (await db.get(PlaylistEntry, entry.id)).track_id == keeper_id
        assert (await db.get(PlayEvent, history.id)).track_id == keeper_id
        assert (await db.get(DownloadItem, item.id)).track_id == keeper_id
        assert (await db.get(DownloadItem, item.id)).replace_track_id == keeper_id
        assert (await db.get(DownloadRequest, request.id)).replace_track_id == keeper_id
        assert (await db.get(ImportFile, imported.id)).track_id == keeper_id
    assert (env.settings.music_dir / tracks[0].path).is_file()
    assert not (env.settings.music_dir / tracks[1].path).exists()


@pytest.mark.parametrize("keeper_lyrics", [False, True])
async def test_merge_multiple_losers_preserves_likes_and_lyrics(env: SimpleNamespace, keeper_lyrics: bool) -> None:
    tracks = await library(env, [{"codec": "flac"}, {"codec": "mp3"}, {"codec": "opus"}])
    async with SessionLocal() as db:
        for track in tracks[1:]:
            db.add(TrackLike(user_id=env.user_id, track_id=track.id))
            db.add(TrackLyrics(track_id=track.id, plain=track.path, source="embedded"))
        if keeper_lyrics:
            db.add(TrackLyrics(track_id=tracks[0].id, plain="keeper", source="embedded"))
        await db.commit()
        loaded = [await db.get(Track, track.id) for track in tracks]
        await merge_group(db, loaded[0], loaded[1:])
    async with SessionLocal() as db:
        assert list(await db.scalars(select(TrackLike.track_id))) == [tracks[0].id]
        lyrics = (await db.scalars(select(TrackLyrics))).one()
        assert lyrics.track_id == tracks[0].id
        assert lyrics.plain == ("keeper" if keeper_lyrics else tracks[1].path)


async def test_api_lists_and_merges_server_keeper(env: SimpleNamespace) -> None:
    tracks = await library(env)
    url = "/api/admin/library/duplicates"
    assert (await env.client.get(url, headers=env.user_headers)).status_code == 403
    assert (await env.client.post(f"{url}/merge", headers=env.user_headers, json={"keep_ids": []})).status_code == 403
    response = await env.client.get(url, headers=env.headers)
    assert response.status_code == 200
    group = response.json()[0]
    assert group["album_id"] == str(tracks[0].album_id)
    assert group["album_title"] == "Album" and group["artist_name"] == "Artist"
    assert group["kind"] == "same_album"
    assert [track["keep"] for track in group["tracks"]] == [True, False]
    assert group["tracks"][0] == {
        "id": str(tracks[0].id),
        "title": "Song",
        "album": "Album",
        "path": tracks[0].path,
        "codec": "flac",
        "bitrate": 192,
        "size": 5,
        "duration": 2.0,
        "keep": True,
    }
    response = await env.client.post(f"{url}/merge", headers=env.headers, json={"keep_ids": [str(tracks[1].id)]})
    assert response.json() == {"merged_groups": 0, "deleted_tracks": 0, "freed_bytes": 0}
    response = await env.client.post(f"{url}/merge", headers=env.headers, json={"keep_ids": [str(tracks[0].id)]})
    assert response.status_code == 200
    assert response.json() == {"merged_groups": 1, "deleted_tracks": 1, "freed_bytes": 5}
    assert (await env.client.get(url, headers=env.headers)).json() == []


async def test_stressed_out_cross_album_group(env: SimpleNamespace) -> None:
    tracks = await library(
        env,
        [
            {"album": "Stressed Out", "codec": "opus", "duration": 202.341},
            {"album": "Blurryface", "codec": "flac", "duration": 202.335},
            {"album": "Promo Only: Mainstream Radio, December 2015", "codec": "mp3", "duration": 202.368},
        ],
    )
    async with SessionLocal() as db:
        for track in await db.scalars(select(Track)):
            track.title = "Stressed Out"
            track.artist_credit = "twenty one pilots"
        artist = await db.get(Artist, tracks[0].artist_id)
        artist.name = "twenty one pilots"
        await db.commit()
    response = await env.client.get("/api/admin/library/duplicates", headers=env.headers)
    assert response.status_code == 200
    group, = response.json()
    assert group["kind"] == "cross_album" and group["artist_name"] == "twenty one pilots"
    assert group["tracks"][0]["id"] == str(tracks[1].id)
    assert group["tracks"][0]["album"] == "Blurryface"
    assert {track["album"] for track in group["tracks"]} == {
        "Blurryface", "Stressed Out", "Promo Only: Mainstream Radio, December 2015"
    }


@pytest.mark.parametrize(
    ("first", "second", "expected"),
    [
        ({"isrc": "US1234567890"}, {"isrc": "US1234567890", "title": "Other", "duration": 100}, True),
        ({}, {"duration": 4}, True),
        ({}, {"duration": 5}, False),
        ({}, {"artist_credit": "Other artist"}, False),
        ({}, {"artist_credit": "  ARTIST feat. Guest", "title": " SONG  "}, True),
        ({"title": " "}, {"title": ""}, False),
        ({"isrc": "US1234567890", "title": ""}, {"isrc": "US1234567890", "title": " "}, True),
    ],
)
async def test_cross_album_matching(
    env: SimpleNamespace, first: dict[str, Any], second: dict[str, Any], expected: bool
) -> None:
    tracks = await library(env, [{"album": "Single", **first}, {"album": "Album", **second}])
    async with SessionLocal() as db:
        groups = await find_groups(db)
        assert len(groups) == int(expected)
        if expected:
            assert {track.id for track in groups[0]} == {track.id for track in tracks}


async def test_cross_album_components_connect_duration_and_isrc(env: SimpleNamespace) -> None:
    tracks = await library(
        env,
        [
            {"album": "A", "duration": 100},
            {"album": "B", "duration": 102},
            {"album": "C", "duration": 104, "isrc": "US1234567890"},
            {"album": "D", "duration": 200, "title": "Other", "isrc": "US1234567890"},
        ],
    )
    async with SessionLocal() as db:
        groups = await find_groups(db)
        assert len(groups) == 1
        assert {track.id for track in groups[0]} == {track.id for track in tracks}


async def test_cross_album_excludes_same_album_losers(env: SimpleNamespace) -> None:
    tracks = await library(
        env,
        [
            {"codec": "flac", "album": "A", "duration": 100},
            {"codec": "mp3", "album": "A", "duration": 104},
            {"codec": "mp3", "album": "B", "duration": 100},
            {"codec": "mp3", "album": "C", "duration": 104},
        ],
    )
    async with SessionLocal() as db:
        groups = await find_groups(db)
        assert [[track.id for track in group] for group in groups] == [
            [tracks[0].id, tracks[1].id], [tracks[0].id, tracks[2].id]
        ]


@pytest.mark.parametrize("tie_breaker", ["album_size", "temporary", "created_at", "id"])
async def test_cross_album_keeper_order(env: SimpleNamespace, tie_breaker: str) -> None:
    oldest = datetime.now(UTC) - timedelta(days=1)
    first: dict[str, Any] = {"codec": "flac", "album": "Single", "created_at": oldest}
    second: dict[str, Any] = {"codec": "flac", "album": "Album", "created_at": oldest}
    extra = []
    if tie_breaker == "album_size":
        second["is_temporary"] = True
        second["created_at"] = datetime.now(UTC)
        extra = [{"album": "Album", "title": "Other", "track_no": 2}]
    elif tie_breaker == "temporary":
        first["is_temporary"] = True
        second["created_at"] = datetime.now(UTC)
    elif tie_breaker == "created_at":
        first["created_at"] = datetime.now(UTC)
    else:
        first["id"] = uuid.UUID(int=2)
        second["id"] = uuid.UUID(int=1)
    tracks = await library(env, [first, second, *extra])
    async with SessionLocal() as db:
        group, = await find_groups(db)
        assert [track.id for track in group] == [tracks[1].id, tracks[0].id]


async def test_merge_cross_album_moves_playlist_and_likes(env: SimpleNamespace) -> None:
    tracks = await library(env, [{"album": "Single", "codec": "opus"}, {"album": "Album", "codec": "flac"}])
    async with SessionLocal() as db:
        playlist = Playlist(owner_id=env.user_id, name="Cross album")
        db.add(playlist)
        await db.flush()
        entry = PlaylistEntry(playlist_id=playlist.id, track_id=tracks[0].id, position=0)
        db.add_all([entry, TrackLike(user_id=env.user_id, track_id=tracks[0].id)])
        await db.commit()
    response = await env.client.post(
        "/api/admin/library/duplicates/merge", headers=env.headers, json={"keep_ids": [str(tracks[1].id)]}
    )
    assert response.status_code == 200
    assert response.json() == {"merged_groups": 1, "deleted_tracks": 1, "freed_bytes": 5}
    async with SessionLocal() as db:
        assert list(await db.scalars(select(Track.id))) == [tracks[1].id]
        assert (await db.get(PlaylistEntry, entry.id)).track_id == tracks[1].id
        assert list(await db.scalars(select(TrackLike.track_id))) == [tracks[1].id]
    assert not (env.settings.music_dir / tracks[0].path).exists()


@pytest.mark.parametrize("cross_keeper", [False, True])
async def test_merge_overlapping_groups(env: SimpleNamespace, cross_keeper: bool) -> None:
    tracks = await library(
        env,
        [
            {"album": "Z Single", "codec": "mp3" if cross_keeper else "flac"},
            {"album": "Z Single", "codec": "opus", "bitrate": 128},
            {"album": "A Album", "codec": "flac" if cross_keeper else "mp3"},
        ],
    )
    response = await env.client.get("/api/admin/library/duplicates", headers=env.headers)
    assert len(response.json()) == 2
    response = await env.client.post(
        "/api/admin/library/duplicates/merge",
        headers=env.headers,
        json={"keep_ids": [group["tracks"][0]["id"] for group in response.json()]},
    )
    assert response.status_code == 200
    assert response.json() == {"merged_groups": 2, "deleted_tracks": 2, "freed_bytes": 10}
    async with SessionLocal() as db:
        assert list(await db.scalars(select(Track.id))) == [tracks[2 if cross_keeper else 0].id]


@pytest.mark.parametrize(
    ("changes", "expected"),
    [
        ({}, True),
        ({"duration": 4, "title": " SONG ", "artist_credit": "ARTIST feat. Guest"}, True),
        ({"duration": 5}, False),
        ({"artist_credit": "Other"}, False),
        ({"title": "Other"}, False),
        ({"codec": "mp3"}, False),
        ({"album": "Single"}, False),
        ({"isrc": "US1234567890", "title": "Other", "duration": 100}, True),
    ],
)
async def test_lossless_twin(env: SimpleNamespace, changes: dict[str, Any], expected: bool) -> None:
    tracks = await library(
        env,
        [
            {"album": "Single", "codec": "opus", "isrc": "US1234567890"},
            {"album": "Album", "codec": "FLAC", **changes},
        ],
    )
    async with SessionLocal() as db:
        twin = await lossless_twin(db, await db.get(Track, tracks[0].id))
        assert (twin.id if twin else None) == (tracks[1].id if expected else None)


async def test_find_groups_large_library(env: SimpleNamespace) -> None:
    tracks = await library(env, [{"album": "A", "title": "Seed A"}, {"album": "B", "title": "Seed B"}])
    async with SessionLocal() as db:
        await db.execute(
            insert(Track),
            [
                {
                    "path": f"bulk/{index}.flac",
                    "title": f"Song {index // 2}",
                    "artist_credit": "Artist",
                    "artist_id": tracks[0].artist_id,
                    "album_id": tracks[index % 2].album_id,
                    "track_no": index // 2 + 1,
                    "duration": 200 + index % 2,
                    "codec": "flac",
                }
                for index in range(3000)
            ],
        )
        await db.commit()
        groups = await find_groups(db)
        assert len(groups) == 1500
        assert all(len(group) == 2 and len({track.album_id for track in group}) == 2 for group in groups)


def meta() -> TrackMeta:
    return TrackMeta(
        title="Song",
        artist="Artist",
        artist_mbid=None,
        album="Album",
        album_artist="Artist",
        album_artist_mbid=None,
        track_no=1,
        track_total=1,
        disc_no=1,
        disc_total=1,
        year=2001,
        date="2001",
        duration=2,
        isrc=None,
        genre=None,
        label=None,
        mb_recording_id=None,
        mb_release_id=None,
        mb_release_group_id=None,
    )


def audio(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "sine=duration=2", str(path)],
        check=True,
    )


@pytest.mark.parametrize(("old_codec", "new_codec"), [("mp3", "flac"), ("flac", "mp3")])
@pytest.mark.parametrize("mode", ["copy", "move", "inplace"])
async def test_importer_prevents_other_format(env: SimpleNamespace, old_codec: str, new_codec: str, mode: str) -> None:
    metadata = meta()
    old_rel = target_relpath(metadata, f".{old_codec}", unique=False)
    tracks = await library(env, [{"path": old_rel, "codec": old_codec}])
    source_dir = env.settings.music_dir if mode == "inplace" else env.settings.import_dir
    source = source_dir / f"incoming.{new_codec}"
    audio(source)
    async with SessionLocal() as db:
        db.add(TrackLike(user_id=env.user_id, track_id=tracks[0].id))
        if mode == "inplace":
            db.add(
                Track(
                    path=source.name,
                    title="Song",
                    album_id=tracks[0].album_id,
                    artist_id=tracks[0].artist_id,
                    artist_credit="Artist",
                    codec=new_codec,
                    track_no=1,
                    disc_no=1,
                    duration=2,
                )
            )
        batch = ImportBatch(kind="import", mode=mode, source_dir=str(source_dir), status="running")
        db.add(batch)
        await db.flush()
        row = ImportFile(
            batch_id=batch.id,
            path=source.name,
            group_key="album",
            status="pending",
            method="tags",
            meta=metadata.model_dump(),
        )
        db.add(row)
        await db.commit()
        placed = await importer._place(db, batch, row, read_tags(source))
        await db.commit()
        if old_codec == "mp3":
            assert placed
            remaining = list(await db.scalars(select(Track)))
            assert len(remaining) == 1 and remaining[0].path.endswith(".flac")
            assert await db.scalar(select(TrackLike.track_id)) == remaining[0].id
            assert not (env.settings.music_dir / old_rel).exists()
        else:
            assert not placed and row.status == "duplicate"
            assert not (env.settings.music_dir / target_relpath(metadata, ".mp3", unique=False)).exists()
            assert await db.scalar(select(TrackLike.track_id)) == tracks[0].id


@pytest.mark.parametrize(("old_codec", "new_codec"), [("flac", "mp3"), ("mp3", "flac")])
async def test_downloader_prevents_other_format(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, old_codec: str, new_codec: str
) -> None:
    metadata = meta()
    old_rel = target_relpath(metadata, f".{old_codec}", unique=False)
    tracks = await library(env, [{"path": old_rel, "codec": old_codec, "is_temporary": True}])

    class Source:
        name = "youtube"

        async def find(self, meta: TrackMeta) -> Candidate:
            return Candidate("youtube", "test", meta.title, meta.artist, meta.duration, 100)

        async def download(
            self, candidate: Candidate, dest_dir: Path, progress: Callable[[float], None], cancelled: Callable[[], bool]
        ) -> Path:
            path = dest_dir / f"audio.{new_codec}"
            audio(path)
            return path

    async def no_match(db: Any, tracks: Any) -> None:
        pass

    async def no_cover(meta: TrackMeta) -> None:
        return None

    monkeypatch.setattr(downloads, "match_tracks", no_match)
    monkeypatch.setattr(downloads, "fetch_cover", no_cover)
    monkeypatch.setattr(sources, "enabled_sources", lambda cfg: [Source()])
    monkeypatch.setattr("app.services.spotify.resolve_after_download", lambda: None)
    monkeypatch.setattr("app.services.radio.resolve_after_download", lambda: None)
    async with SessionLocal() as db:
        db.add(TrackLike(user_id=env.user_id, track_id=tracks[0].id))
        request = DownloadRequest(user_id=env.user_id, kind="track", title="Song", artist="Artist", status="active")
        db.add(request)
        await db.flush()
        item = DownloadItem(
            request_id=request.id,
            position=0,
            title="Song",
            artist="Artist",
            meta=metadata.model_dump(),
            status="queued",
        )
        db.add(item)
        await db.commit()
    await downloads.DownloadManager()._run(item)
    async with SessionLocal() as db:
        done = await db.get(DownloadItem, item.id)
        assert done.status == "done", done.error
        remaining = list(await db.scalars(select(Track)))
        assert len(remaining) == 1 and remaining[0].path.endswith(".flac")
        assert not remaining[0].is_temporary
        assert done.track_id == remaining[0].id
        assert await db.scalar(select(TrackLike.track_id)) == remaining[0].id
        if old_codec == "flac":
            assert done.track_id == tracks[0].id
    assert list(env.settings.music_dir.rglob("*.mp3")) == []
    assert len(list(env.settings.music_dir.rglob("*.flac"))) == 1


async def test_stem_check_is_case_insensitive_and_excludes_inplace_row(env: SimpleNamespace) -> None:
    tracks = await library(env, [{"path": "ARTIST/Album/01 - SONG.FLAC", "codec": "flac"}])
    async with SessionLocal() as db:
        assert (await _same_stem_track(db, "artist/album/01 - song.mp3")).id == tracks[0].id
        assert await _same_stem_track(db, "artist/album/01 - song.flac") is None
        assert await _same_stem_track(db, "artist/album/01 - song.mp3", tracks[0].path) is None


async def test_stem_check_escapes_like_wildcards(env: SimpleNamespace) -> None:
    tracks = await library(
        env,
        [
            {"path": "Artist/Album/01 - 100% a_b.flac", "codec": "flac"},
            {"path": "Artist/Album/01 - 100x aXb.flac", "codec": "flac", "track_no": 2},
            {"path": "Artist/Album/01 - 100% a_b (Live).flac", "codec": "flac", "track_no": 3},
        ],
    )
    async with SessionLocal() as db:
        assert (await _same_stem_track(db, "Artist/Album/01 - 100% a_b.mp3")).id == tracks[0].id
        assert await _same_stem_track(db, "Artist/Album/01 - 100x aYb.mp3") is None


@pytest.mark.parametrize("new_codec", ["flac", "mp3"])
async def test_new_import_merges_copy_with_other_name(env: SimpleNamespace, new_codec: str) -> None:
    # Different folder and disc prefix: the file-name check cannot see these, the album rule does.
    old_codec = "mp3" if new_codec == "flac" else "flac"
    tracks = await library(
        env,
        [
            {"path": f"Artist/Album (2003)/01 - Song.{old_codec}", "codec": old_codec},
            {"path": "Artist/Album/1-02 - Other.mp3", "codec": "mp3", "track_no": 2, "title": "Other"},
            {"path": f"Artist/Album/1-01 - Song.{new_codec}", "codec": new_codec, "duration": 4.0},
        ],
    )
    old, other, new = tracks
    async with SessionLocal() as db:
        db.add(TrackLike(user_id=env.user_id, track_id=old.id))
        await db.commit()
        kept = await merge_new_duplicates(db, await db.get(Track, new.id))
        expected, removed = (new, old) if new_codec == "flac" else (old, new)
        assert kept.id == expected.id
        assert {t.id for t in await db.scalars(select(Track))} == {expected.id, other.id}
        assert await db.scalar(select(TrackLike.track_id)) == expected.id
    assert not (env.settings.music_dir / removed.path).exists()
    assert (env.settings.music_dir / expected.path).exists()


async def test_new_import_without_copy_is_kept(env: SimpleNamespace) -> None:
    tracks = await library(env, [{"codec": "flac"}, {"codec": "mp3", "duration": 30.0}])
    async with SessionLocal() as db:
        kept = await merge_new_duplicates(db, await db.get(Track, tracks[1].id))
        assert kept.id == tracks[1].id
        assert len(list(await db.scalars(select(Track)))) == 2
