import time
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from fastapi import HTTPException
from sqlalchemy import select

from app.api import editor
from app.db import SessionLocal
from app.models import Album, Artist, ImportBatch, Job, Track
from app.services import (
    apple_music,
    artist_info,
    discogs,
    genres,
    importer,
    lastfm,
    tagger,
)
from app.services.musicbrainz import MusicBrainzClient, MusicBrainzError, mb
from app.services.server_config import LibraryConfig, update_config
from app.services.spotify import SpotifyError
from app.services.tags import read_tags
from tests import test_editor
from tests.conftest import auth
from tests.test_editor import image, library_track
from tests.test_imports import audio, meta

env = test_editor.env


def apple_song(id="1", **attrs):
    return {
        "id": id, "type": "songs",
        "attributes": {
            "name": "Song", "artistName": "Singer", "albumName": "Album", "releaseDate": "2024-05-17",
            "trackNumber": 3, "discNumber": 1, "durationInMillis": 123456, "isrc": "TEST00000001",
            "genreNames": ["Musik", "Music", "Hip-Hop"], "composerName": "Composer",
            "artwork": {"url": "https://is1-ssl.mzstatic.com/song/{w}x{h}bb.jpg"}, **attrs,
        },
    }


def apple_album(**attrs):
    return {
        "id": "10", "type": "albums",
        "attributes": {
            "name": "Compilation", "artistName": "Various Artists", "releaseDate": "2024-05-17",
            "trackCount": 3, "genreNames": ["Music", "Pop"],
            "artwork": {"url": "https://is1-ssl.mzstatic.com/album/{w}x{h}bb.jpg"}, **attrs,
        },
    }


def apple_http(monkeypatch, dispatch):
    monkeypatch.setattr(apple_music, "_token", ("test-apple-token", time.time() + 3600))
    monkeypatch.setattr(
        apple_music, "_client_factory", lambda: httpx.AsyncClient(transport=httpx.MockTransport(dispatch))
    )


async def test_apple_mapping_search_and_pagination(monkeypatch):
    seen = []
    album = apple_album()
    album["relationships"] = {"tracks": {
        "data": [apple_song(), {"type": "music-videos", "attributes": {"name": "Video"}}],
        "next": "/v1/catalog/de/albums/10/tracks?offset=1",
    }}

    def dispatch(request):
        seen.append(request)
        assert request.headers["Authorization"] == "Bearer test-apple-token"
        assert "/catalog/de/" in request.url.path
        if request.url.path.endswith("/search"):
            kind = request.url.params["types"]
            return httpx.Response(200, json={"results": {kind: {"data": [apple_song() if kind == "songs" else album]}}})
        if request.url.path.endswith("/songs/1"):
            song = apple_song()
            song["relationships"] = {"albums": {"data": [{"id": "10", "type": "albums"}]}}
            return httpx.Response(200, json={"data": [song]})
        if request.url.path.endswith("/albums/10"):
            return httpx.Response(200, json={"data": [album]})
        assert request.url.params["offset"] == "1"
        return httpx.Response(200, json={"data": [apple_song("2", discNumber=2, trackNumber=1, genreNames=[])]})

    apple_http(monkeypatch, dispatch)
    assert len(await apple_music.search_songs("Singer")) == 1
    assert seen[-1].url.params["limit"] == "15"
    assert len(await apple_music.search_albums("Album")) == 1
    assert seen[-1].url.params["limit"] == "10"
    song = await apple_music.song_meta("1")
    assert (song.title, song.artist, song.album, song.album_artist) == (
        "Song", "Singer", "Compilation", "Various Artists"
    )
    assert (song.year, song.date, song.track_no, song.disc_no) == (2024, "2024-05-17", 3, 1)
    assert (song.genre, song.isrc, song.duration) == ("Hip-Hop", "TEST00000001", 123.456)
    assert song.cover_url == "https://is1-ssl.mzstatic.com/album/1400x1400bb.jpg"
    tracks = await apple_music.album_metas("10")
    assert len(tracks) == 2
    assert [m.disc_total for m in tracks] == [2, 2]
    assert [m.track_total for m in tracks] == [1, 1]
    assert tracks[-1].genre == "Pop"
    assert apple_music._song_meta(apple_song(genreNames=["Music", "Musik"])).genre is None


async def test_apple_album_relationship_and_missing(monkeypatch):
    def dispatch(request):
        if request.url.path.endswith("/albums/10"):
            return httpx.Response(200, json={"data": [apple_album()]})
        return httpx.Response(200, json={"data": [apple_song()]})

    apple_http(monkeypatch, dispatch)
    assert (await apple_music.album_metas("10"))[0].title == "Song"
    apple_http(monkeypatch, lambda request: httpx.Response(200, json={"data": []}))
    with pytest.raises(SpotifyError, match="Song nicht gefunden"):
        await apple_music.song_meta("1")
    with pytest.raises(SpotifyError, match="Album nicht gefunden"):
        await apple_music.album_metas("10")


@pytest.mark.parametrize("position,expected", [
    ("A1", (1, 1)), ("B2", (1, 2)), ("1-03", (1, 3)), ("2.5", (2, 5)), ("3", (1, 3)), ("?", (None, None)),
])
def test_discogs_positions(position, expected):
    assert discogs.position_numbers(position) == expected


def test_discogs_retry_after():
    assert discogs._retry_after("2") == 2
    assert discogs._retry_after("30") == 5
    assert discogs._retry_after("-1") == 0
    assert discogs._retry_after("invalid") == 1
    assert discogs._retry_after("Tue, 01 Jan 2030 00:00:00 GMT") == 5


async def test_discogs_auth_mapping_and_retry(env, monkeypatch):
    async with SessionLocal() as db:
        await update_config(db, {"library": {"discogs_token": "test-discogs-token"}})
    seen, sleeps = [], []

    async def sleep(delay):
        sleeps.append(delay)

    def dispatch(request):
        seen.append(request)
        assert request.headers["User-Agent"] == "Resonance/1.0"
        assert request.headers["Authorization"] == "Discogs token=test-discogs-token"
        if len(seen) == 1:
            return httpx.Response(429, headers={"Retry-After": "30"})
        if request.url.path.endswith("/search"):
            assert dict(request.url.params) == {
                "type": "release", "per_page": "8", "artist": "Singer", "release_title": "LP"
            }
            return httpx.Response(200, json={"results": [{"id": 5}]})
        return httpx.Response(200, json={
            "title": "LP", "artists": [{"name": "Singer (2)"}], "year": 1999,
            "styles": ["Deep House"], "genres": ["Electronic"],
            "images": [{"type": "secondary", "uri": "https://i.discogs.com/other"},
                       {"type": "primary", "uri": "https://i.discogs.com/primary"}],
            "tracklist": [
                {"type_": "heading", "title": "Side A", "position": "A"},
                {"type_": "index", "title": "Suite", "position": "1"},
                *[{"type_": "track", "title": p, "position": p, "duration": "3:04"}
                  for p in ("A1", "B2", "1-03", "2.5", "3")],
            ],
        })

    factory = httpx.AsyncClient
    monkeypatch.setattr(
        discogs.httpx, "AsyncClient", lambda **kw: factory(transport=httpx.MockTransport(dispatch), **kw)
    )
    monkeypatch.setattr(discogs.asyncio, "sleep", sleep)
    assert await discogs.search_releases("Singer", "LP") == [{"id": 5}]
    assert sleeps == [5]
    tracks = await discogs.release_metas("5")
    assert len(tracks) == 5
    assert all(m.album_artist == "Singer" and m.year == 1999 and m.genre == "Deep House" for m in tracks)
    assert tracks[0].cover_url == "https://i.discogs.com/primary"
    assert tracks[0].duration == 184


async def test_lastfm_filters_falls_back_caches_and_limits(monkeypatch):
    seen, started = [], []
    monkeypatch.setattr(lastfm, "_cache", {})
    monkeypatch.setattr(lastfm, "_last_started", 0)

    def dispatch(request):
        seen.append(request)
        started.append(time.monotonic())
        assert request.url.params["api_key"] == "test-lastfm-key"
        if request.url.params["method"] == "track.getTopTags":
            return httpx.Response(200, json={"toptags": {"tag": [
                {"name": "seen live", "count": 100}, {"name": "rock", "count": 19},
                {"name": "pop", "count": "invalid"},
            ]}})
        return httpx.Response(200, json={"toptags": {"tag": [
            {"name": "HIP-HOP", "count": "80"}, {"name": "R&B", "count": 50},
            {"name": "drum and bass", "count": 20}, {"name": "Deutschrap", "count": 35},
            {"name": "my favorites", "count": 100},
        ]}})

    monkeypatch.setattr(lastfm, "_client_factory", lambda: httpx.AsyncClient(transport=httpx.MockTransport(dispatch)))
    assert await lastfm.track_tags("Singer", "Title", api_key="test-lastfm-key") == [
        "Hip-Hop", "R&B", "Deutschrap", "Drum and Bass",
    ]
    assert started[1] - started[0] >= 0.24
    assert len(seen) == 2
    assert "track" not in seen[-1].url.params
    assert await lastfm.track_tags("singer", "title", api_key="test-lastfm-key")
    assert len(seen) == 2
    assert await lastfm.track_tags("Singer", "Title", api_key="") == []


async def test_genre_fallback_order_and_failures(monkeypatch):
    calls = []

    async def tags(*args, **kw):
        calls.append("lastfm")
        return ["Deutschrap"]

    def dispatch(request):
        calls.append(request.url.path)
        assert request.url.params["inc"] == "genres"
        if "/recording/" in request.url.path:
            return httpx.Response(200, json={"genres": []})
        return httpx.Response(200, json={"genres": [{"name": "r&b", "count": 5}, {"name": "pop", "count": 1}]})

    client = MusicBrainzClient()
    client._client = httpx.AsyncClient(
        base_url="https://musicbrainz.org/ws/2/", transport=httpx.MockTransport(dispatch)
    )
    monkeypatch.setattr(lastfm, "track_tags", tags)
    monkeypatch.setattr(mb, "genre", client.genre)
    cfg = LibraryConfig(lastfm_api_key="test-lastfm-key")
    chosen = meta(genre=None)
    await genres.enrich(chosen, cfg)
    assert chosen.genre == "Deutschrap" and calls == ["lastfm"]

    async def empty(*args, **kw):
        return []

    monkeypatch.setattr(lastfm, "track_tags", empty)
    chosen.genre = None
    await genres.enrich(chosen, cfg)
    assert chosen.genre == "R&B"
    chosen.genre = None
    await genres.enrich(chosen, LibraryConfig())
    assert chosen.genre == "R&B"  # no Last.fm key still uses MusicBrainz
    assert len(calls) == 3  # repeated MB lookups used the existing rate-limited cache

    async def failed(*args, **kw):
        raise MusicBrainzError("Nicht erreichbar")

    monkeypatch.setattr(lastfm, "track_tags", failed)
    monkeypatch.setattr(mb, "genre", failed)
    chosen.genre = None
    await genres.enrich(chosen, cfg)
    assert chosen.genre is None
    chosen.genre = "Existing"
    await genres.enrich(chosen, cfg)
    assert chosen.genre == "Existing"
    await client._client.aclose()


async def test_genre_fill_only_empty_and_persists_tags(env, monkeypatch):
    missing, album_id, path, _ = await library_track(env, genre=None)
    existing, _, existing_path, _ = await library_track(env, rel="Old/Old Album/second.mp3", genre="Jazz", track_no=2)
    before = existing_path.read_bytes()
    calls = []

    async def tags(*args, **kw):
        calls.append(args)
        return ["Soul"]

    monkeypatch.setattr(lastfm, "track_tags", tags)
    async with SessionLocal() as db:
        await update_config(db, {"library": {"lastfm_api_key": "test-lastfm-key"}})
        album = await db.get(Album, album_id)
        album.genre = None
        await db.commit()
    result = await env.client.post("/api/admin/genres/fill", headers=env.headers)
    assert result.status_code == 202
    await genres._task
    status = (await env.client.get("/api/admin/genres/fill", headers=env.headers)).json()
    assert (status["status"], status["message"], status["progress"]) == ("done", "1 / 1", 1)
    assert len(calls) == 1
    assert read_tags(path).genre == "Soul"
    assert existing_path.read_bytes() == before
    async with SessionLocal() as db:
        assert (await db.get(Track, missing)).genre == "Soul"
        assert (await db.get(Track, existing)).genre == "Jazz"
        assert (await db.get(Album, album_id)).genre == "Soul"
    assert (await env.client.post("/api/admin/genres/fill", headers=auth(env.user["token"]))).status_code == 403


async def test_genre_fill_requires_key_and_recovers_stale_jobs(env):
    assert (await env.client.post("/api/admin/genres/fill", headers=env.headers)).status_code == 409
    assert (await env.client.get("/api/admin/genres/fill", headers=env.headers)).json() is None
    async with SessionLocal() as db:
        job = Job(kind="genres", status="running", progress=0.5)
        db.add(job)
        await db.commit()
        assert (await genres.start_fill(db)).id == job.id
    await genres.start()
    result = (await env.client.get("/api/admin/genres/fill", headers=env.headers)).json()
    assert result["status"] == "failed"


async def test_match_and_import_enrich_missing_genres(env, monkeypatch):
    track_id, _, _, _ = await library_track(env)

    async def song(*args):
        return meta(genre=None)

    async def cover(*args):
        return None

    async def tags(*args, **kw):
        return ["Funk"]

    monkeypatch.setattr(apple_music, "song_meta", song)
    monkeypatch.setattr(editor, "fetch_cover", cover)
    monkeypatch.setattr(lastfm, "track_tags", tags)
    async with SessionLocal() as db:
        await update_config(db, {"library": {"lastfm_api_key": "test-lastfm-key"}})
    result = await env.client.post(
        f"/api/admin/library/tracks/{track_id}/match", headers=env.headers,
        json={"source": "apple", "apple_id": "1"},
    )
    assert result.status_code == 200
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        assert track.genre == "Funk"
        assert read_tags(env.settings.music_dir / track.path).genre == "Funk"
    source = env.settings.music_dir.parent / "import"
    audio(source / "Artist/Imported/song.mp3", title="Imported", artist="Artist", album="Imported")

    async def identify(*args):
        return meta(title="Imported", album="Imported", genre=None), "recording"

    monkeypatch.setattr(importer, "identify_file", identify)
    async with SessionLocal() as db:
        batch = ImportBatch(kind="import", mode="copy", source_dir=str(source), status="queued")
        db.add(batch)
        await db.commit()
    await importer.run_batch(batch.id)
    async with SessionLocal() as db:
        track = await db.scalar(select(Track).where(Track.title == "Imported"))
        assert track is not None and track.genre == "Funk"
        assert read_tags(env.settings.music_dir / track.path).genre == "Funk"


async def test_artist_exact_match_images_bios_and_locale(env, monkeypatch):
    _, _, _, _ = await library_track(env)
    seen = []

    def dispatch(request):
        seen.append(request)
        if request.url.host == "images.example":
            return httpx.Response(200, content=image())
        return httpx.Response(200, json={"artists": [
            {"strArtist": "Old Band", "strArtistThumb": "https://images.example/wrong"},
            {"strArtist": "OLD", "strArtistThumb": "https://images.example/exact", "strBiographyDE": "Deutsch",
             "strBiographyEN": "English"},
        ]})

    monkeypatch.setattr(
        artist_info, "_client_factory", lambda: httpx.AsyncClient(transport=httpx.MockTransport(dispatch))
    )
    async with SessionLocal() as db:
        artist = await db.scalar(select(Artist).where(Artist.name_key == "old"))
        artist_id = artist.id
        await artist_info.update_artist(db, artist)
        assert artist.image_path.endswith(".jpg")
        assert (env.settings.data_dir / artist.image_path).is_file()
        assert artist.info_checked_at is not None
        old_image = artist.image_path
        await artist_info.update_artist(db, artist)
        assert artist.image_path == old_image
    assert [r.url.path for r in seen].count("/exact") == 1
    assert all(r.url.path != "/wrong" for r in seen)
    for lang, expected in (("de-DE", "Deutsch"), ("en", "English")):
        result = await env.client.get(f"/api/artists/{artist_id}", headers={**env.headers, "Accept-Language": lang})
        assert result.json()["bio"] == expected
        assert result.json()["has_image"]
    picture = await env.client.get(f"/api/artists/{artist_id}/image", headers=env.headers)
    assert picture.status_code == 200 and picture.headers["content-type"] == "image/jpeg"
    async with SessionLocal() as db:
        artist = await db.get(Artist, artist_id)
        artist.bio_de = None
        await db.commit()
        assert artist_info.biography(artist, "de") == "English"
        artist.bio_de, artist.bio_en = "Deutsch", None
        assert artist_info.biography(artist, "en") == "Deutsch"


async def test_artist_fanart_fallback_and_exact_name(env, monkeypatch):
    async with SessionLocal() as db:
        await update_config(db, {"library": {"fanarttv_api_key": "test-fanart-key"}})
    seen = []

    def dispatch(request):
        seen.append(request)
        if request.url.host == "webservice.fanart.tv":
            assert request.url.params["api_key"] == "test-fanart-key"
            return httpx.Response(200, json={"artistthumb": [{"url": "https://images.example/fanart"}]})
        return httpx.Response(200, json={"artists": [{"strArtist": "Different Artist", "strBiographyEN": "Wrong"}]})

    monkeypatch.setattr(
        artist_info, "_client_factory", lambda: httpx.AsyncClient(transport=httpx.MockTransport(dispatch))
    )
    info = await artist_info.fetch("Artist", "test-mbid")
    assert info.image_url == "https://images.example/fanart" and info.bio_en is None
    assert (await artist_info.fetch("Artist")).image_url is None
    assert len(seen) == 3


async def test_artist_loop_only_due_and_max_50(env, monkeypatch):
    now = datetime.now(UTC)
    async with SessionLocal() as db:
        for index in range(55):
            db.add(Artist(name=f"Artist {index}", name_key=f"artist {index}", info_checked_at=None))
        db.add(Artist(name="Recent", name_key="recent", info_checked_at=now))
        await db.commit()
    checked = []

    async def update(db, artist):
        checked.append(artist.name)
        artist.info_checked_at = now
        await db.commit()

    monkeypatch.setattr(artist_info, "update_artist", update)
    await artist_info.run_once()
    assert len(checked) == 50 and "Recent" not in checked
    await artist_info.run_once()
    assert len(checked) == 55
    async with SessionLocal() as db:
        artist = await db.scalar(select(Artist).where(Artist.name == "Recent"))
        artist.info_checked_at = now - timedelta(days=91)
        await db.commit()
    await artist_info.run_once()
    assert checked[-1] == "Recent"


@pytest.mark.parametrize("source,kind", [("apple", "tracks"), ("apple", "albums"), ("discogs", "albums")])
async def test_editor_missing_ids(env, source, kind):
    track_id, album_id, _, _ = await library_track(env)
    id = track_id if kind == "tracks" else album_id
    response = await env.client.post(
        f"/api/admin/library/{kind}/{id}/match", headers=env.headers, json={"source": source}
    )
    assert response.status_code == 422


async def test_editor_search_and_cover_options(env, monkeypatch):
    _, album_id, _, _ = await library_track(env)

    async def empty(*args):
        return []

    async def songs(*args):
        return [apple_song()]

    async def albums(*args):
        return [apple_album() for _ in range(6)]

    async def releases(*args):
        return [{"id": 5, "title": "Singer - LP", "year": "1999", "cover_image": "https://i.discogs.com/search"}]

    async def release(*args):
        return {"images": [{"type": "primary", "uri": "https://i.discogs.com/primary"}]}

    monkeypatch.setattr(editor.deezer, "search_tracks", empty)
    monkeypatch.setattr(editor.deezer, "search_albums", empty)
    monkeypatch.setattr(apple_music, "search_songs", songs)
    monkeypatch.setattr(apple_music, "search_albums", albums)
    monkeypatch.setattr(discogs, "search_releases", releases)
    monkeypatch.setattr(discogs, "release", release)
    search = "/api/admin/library/search"
    result = await env.client.get(search, params={"q": "Singer", "types": "track"}, headers=env.headers)
    assert result.json()["tracks"][0]["source"] == "apple"
    result = await env.client.get(search, params={"q": "LP", "types": "album"}, headers=env.headers)
    assert {a["source"] for a in result.json()["albums"]} == {"apple"}
    async with SessionLocal() as db:
        await update_config(db, {"library": {"discogs_token": "test-discogs-token"}})
    result = await env.client.get(search, params={"q": "LP", "types": "album"}, headers=env.headers)
    assert result.json()["albums"][-1]["source"] == "discogs"
    assert result.json()["albums"][-1]["title"] == "LP"
    result = await env.client.get(f"/api/admin/library/albums/{album_id}/cover-options", headers=env.headers)
    assert len([o for o in result.json() if o["source"] == "apple"]) == 4
    assert result.json()[-1]["url"] == "https://i.discogs.com/primary"
    assert (await env.client.get(search, params={"q": "LP"}, headers=auth(env.user["token"]))).status_code == 403


def test_cover_whitelist():
    for url in ("https://is1-ssl.mzstatic.com/image", "https://i.discogs.com/image"):
        editor._allowed_cover(url)
    for url in ("https://evilmzstatic.com/image", "https://i.discogs.com.evil/image", "http://i.discogs.com/image"):
        with pytest.raises(HTTPException):
            editor._allowed_cover(url)


async def test_apple_cover_is_first_and_cache_is_separate(env, monkeypatch):
    calls = []

    def dispatch(request):
        calls.append(str(request.url))
        return httpx.Response(200, content=request.url.path.encode())

    factory = httpx.AsyncClient
    monkeypatch.setattr(
        tagger.httpx, "AsyncClient", lambda **kw: factory(transport=httpx.MockTransport(dispatch), **kw)
    )
    first = meta(cover_url="https://is1-ssl.mzstatic.com/one/1400x1400.jpg")
    second = meta(cover_url="https://is1-ssl.mzstatic.com/two/1400x1400.jpg")
    assert await tagger.fetch_cover(first) == b"/one/1400x1400.jpg"
    assert await tagger.fetch_cover(second) == b"/two/1400x1400.jpg"
    await tagger.fetch_cover(first)
    assert calls == [first.cover_url, second.cover_url]


async def test_lastfm_artist_tags_are_stored_and_checked_again_after_half_a_year(monkeypatch):
    def dispatch(request):
        assert request.url.params["method"] == "artist.getTopTags"
        if request.url.params["artist"] == "Unknown Tag Artist":
            return httpx.Response(200, json={"error": 6, "message": "The artist you supplied could not be found"})
        return httpx.Response(200, json={"toptags": {"tag": [
            {"name": "Deep House", "count": 100}, {"name": "House", "count": "79"}, {"name": "zero", "count": 0},
        ]}})

    async def sleep(seconds):
        # One second between artists; _get's own spacing of Last.fm requests is shorter.
        assert seconds == 1 or seconds <= 0.25

    monkeypatch.setattr(lastfm, "_last_started", 0)
    monkeypatch.setattr(lastfm, "_client_factory", lambda: httpx.AsyncClient(transport=httpx.MockTransport(dispatch)))
    monkeypatch.setattr(lastfm.asyncio, "sleep", sleep)
    async with SessionLocal() as db:
        await update_config(db, {"library": {"lastfm_api_key": "test-lastfm-key"}})
        old = datetime.now(UTC) - timedelta(days=200)
        for artist in await db.scalars(select(Artist)):
            artist.lastfm_checked_at, artist.lastfm_tags = datetime.now(UTC), {}
        known = Artist(name="Tagged Artist", name_key="tagged artist tags", lastfm_checked_at=old)
        unknown = Artist(name="Unknown Tag Artist", name_key="unknown tag artist")
        db.add_all([known, unknown])
        await db.commit()
        ids = known.id, unknown.id
    assert await lastfm.run_artist_tags_once() == 2
    assert await lastfm.run_artist_tags_once() == 0
    async with SessionLocal() as db:
        known, unknown = await db.get(Artist, ids[0]), await db.get(Artist, ids[1])
        assert known.lastfm_tags == {"deep house": 100, "house": 79} and unknown.lastfm_tags == {}
        assert unknown.lastfm_checked_at is not None
        await db.delete(known)
        await db.delete(unknown)
        await db.commit()
