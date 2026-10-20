import io
from datetime import UTC, date, datetime, timedelta
from types import SimpleNamespace
from unittest.mock import ANY, AsyncMock

import httpx
import pytest
from PIL import Image
from pydantic import ValidationError
from sqlalchemy import select

from app.db import SessionLocal
from app.i18n import translate
from app.models import DownloadItem, Playlist, User
from app.services import apple_music, covers, editorial, mixes, radio
from app.services.deezer import DeezerError, deezer
from app.services.server_config import MixesConfig, update_config
from app.services.spotify import SpotifyError, SpotifyTrack
from tests.test_mixes import chart_pending, entries, generated, library
from tests.test_mixes import charts as charts  # noqa: PLC0414
from tests.test_mixes import env as env  # noqa: PLC0414


@pytest.fixture(autouse=True)
def caches(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(editorial, "_refs", {})
    monkeypatch.setattr(editorial, "_cache", {})


def song(title: str, isrc: str | None, artist: str = "Library") -> SpotifyTrack:
    return SpotifyTrack(title=title, artist=artist, album=None, isrc=isrc, duration=180, added_at=None, position=0)


def cached(key: str, tracks: list[SpotifyTrack], cover_file: str | None = None) -> editorial.EditorialPlaylist:
    result = editorial.EditorialPlaylist(tracks, None, cover_file)
    editorial._cache[key] = (date.today(), result)
    return result


def artwork(color: str = "red") -> bytes:
    out = io.BytesIO()
    Image.new("RGB", (640, 640), color).save(out, "JPEG")
    return out.getvalue()


async def test_resolve_exact_name_apple_curator_apostrophe_and_weekly_cache(monkeypatch: pytest.MonkeyPatch) -> None:
    entry = editorial.BY_KEY["editorial:00s-deutschpop"]
    get = AsyncMock(return_value={"results": {"playlists": {"data": [
        {"id": "wrong-curator", "attributes": {"name": entry.apple_name, "curatorName": "A listener"}},
        {"id": "wrong-name", "attributes": {"name": entry.apple_name + " Mix", "curatorName": "Apple Music"}},
        {"id": "exact", "attributes": {"name": "’00S DEUTSCHPOP ESSENTIALS", "curatorName": "Apple Music Pop"}},
    ]}}})
    monkeypatch.setattr(apple_music, "_get", get)
    assert await editorial.resolve(entry) == "apple:de:exact"
    get.assert_awaited_once_with(ANY, "/catalog/de/search", term=entry.apple_name, types="playlists", limit=10)
    editorial._refs[entry.key] = (date.today() - timedelta(days=6), "apple:de:exact")
    assert await editorial.resolve(entry) == "apple:de:exact"
    assert get.await_count == 1
    editorial._refs[entry.key] = (date.today() - timedelta(days=7), "apple:de:exact")
    get.return_value = {"results": {"playlists": {"data": []}}}
    assert await editorial.resolve(entry) is None
    assert await editorial.resolve(entry) is None
    assert get.await_count == 2


@pytest.mark.parametrize("key,days", [("editorial:80s-hits", 7), ("editorial:deutschrap-100", 1)])
async def test_playlist_cache_refresh_and_failure(key: str, days: int, monkeypatch: pytest.MonkeyPatch) -> None:
    entry = editorial.BY_KEY[key]
    resolve = AsyncMock(return_value="apple:de:exact")
    fetch = AsyncMock(return_value=({"image_url": None}, [song("First", "FIRST")]))
    monkeypatch.setattr(editorial, "resolve", resolve)
    monkeypatch.setattr(apple_music, "fetch_playlist", fetch)
    first = await editorial.playlist_tracks(entry)
    editorial._cache[key] = (date.today() - timedelta(days=days - 1), first)
    assert await editorial.playlist_tracks(entry) is first
    assert fetch.await_count == 1
    editorial._cache[key] = (date.today() - timedelta(days=days), first)
    fetch.return_value = ({"image_url": None}, [song("Second", "SECOND")])
    second = await editorial.playlist_tracks(entry)
    assert second.tracks[0].title == "Second"
    assert fetch.await_count == 2
    old = date.today() - timedelta(days=days)
    editorial._cache[key] = (old, second)
    fetch.side_effect = SpotifyError(502, "Apple Music nicht erreichbar")
    assert await editorial.playlist_tracks(entry) is second
    assert editorial._cache[key][0] == old
    editorial._cache.clear()
    assert await editorial.playlist_tracks(entry) is None


async def test_apple_cover_refresh_retains_deezer_ids_and_previous_cover_on_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    entry = editorial.BY_KEY["editorial:80s-hits"]
    monkeypatch.setattr(editorial, "resolve", AsyncMock(return_value="apple:de:exact"))
    monkeypatch.setattr(apple_music, "fetch_playlist", AsyncMock(return_value=(
        {"image_url": "https://artwork.test/640.jpg"}, [song("Track", "ISRC")],
    )))
    responses = [httpx.Response(200, content=artwork()), httpx.Response(503)]
    urls = []

    def respond(request: httpx.Request) -> httpx.Response:
        urls.append(str(request.url))
        return responses.pop(0)

    client = httpx.AsyncClient
    monkeypatch.setattr(httpx, "AsyncClient", lambda **kwargs: client(transport=httpx.MockTransport(respond), **kwargs))
    first = await editorial.playlist_tracks(entry)
    assert first.cover_file and covers.resized(first.cover_file, None).exists()
    first.deezer_ids["ISRC"] = "123"
    editorial._cache[entry.key] = (date.today() - timedelta(days=7), first)
    second = await editorial.playlist_tracks(entry)
    assert second.cover_file == first.cover_file
    assert second.deezer_ids == {"ISRC": "123"}
    assert urls == ["https://artwork.test/640.jpg"] * 2


@pytest.mark.parametrize("temporary", [True, False])
async def test_generation_order_pending_positions_admin_requester_and_apple_cover(
    charts: SimpleNamespace, monkeypatch: pytest.MonkeyPatch, temporary: bool,
) -> None:
    key = "editorial:80s-hiphop"
    apple_cover = covers.store(artwork())
    async with SessionLocal() as db:
        tracks = await library(db, "Library", None, 3)
        tracks[2].isrc = "MATCH"
        data = cached(key, [
            song("Different title", "MATCH", "Different artist"), song("Missing", "MISSING"),
            song("No ISRC", None), song(tracks[0].title, None), song("Missing too", "MISSING2"),
            song(tracks[1].title, None), song("Duplicate", "MATCH"),
        ], apple_cover)
        await update_config(db, {"mixes": {"charts_enabled": False}, "radio": {"temporary_tracks_enabled": temporary}})
        lookup = AsyncMock(side_effect=lambda isrc: {"id": {"MISSING": "201", "MISSING2": "202"}[isrc]})
        monkeypatch.setattr(deezer, "track_by_isrc", lookup)
        for user_id in (charts.user_id, charts.other_id):
            await mixes.generate_mixes(db, await db.get(User, user_id), chart_downloads=False)
            playlist = (await generated(db, user_id))[key]
            assert [(row.track_id, row.position) for row in await entries(db, playlist)] == [
                (tracks[2].id, 1), (tracks[0].id, 4), (tracks[1].id, 6),
            ]
            assert playlist.cover_file == apple_cover and playlist.cover_key is None
        assert charts.downloads == []
        lookup.assert_not_awaited()
    await mixes.refresh_chart_downloads()
    assert charts.downloads == [(id, charts.user_id, temporary, True) for id in ("201", "202")]
    assert data.deezer_ids == {"MISSING": "201", "MISSING2": "202"}
    async with SessionLocal() as db:
        for user_id in (charts.user_id, charts.other_id):
            playlist = (await generated(db, user_id))[key]
            assert await chart_pending(db, playlist) == [("201", 2), ("202", 5)]
        downloaded = (await library(db, "Downloaded", None, 1, temporary=True))[0]
        item = await db.scalar(select(DownloadItem).where(DownloadItem.meta["deezer_track_id"].astext == "201"))
        item.track_id, item.status = downloaded.id, "done"
        await db.commit()
        assert await radio.resolve_radio_pending(db) == 2
        playlist = (await generated(db, charts.user_id))[key]
        assert [(row.track_id, row.position) for row in await entries(db, playlist)] == [
            (tracks[2].id, 1), (downloaded.id, 2), (tracks[0].id, 4), (tracks[1].id, 6),
        ]
    response = await charts.client.get(f"/api/playlists/{playlist.id}", headers=charts.headers)
    assert [row["rank"] for row in response.json()["entries"]] == [1, 2, 4, 6]
    response = await charts.client.get(f"/api/playlists/{playlist.id}/cover", headers=charts.headers)
    assert response.status_code == 200 and response.headers["content-type"] == "image/jpeg"
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 2


async def test_editorial_config_toggles_and_zero_downloads(charts: SimpleNamespace) -> None:
    keys = ["editorial:80s-hits", "editorial:80s-rock", "editorial:year-1985"]
    async with SessionLocal() as db:
        track = (await library(db, "Library", None, 1))[0]
        for key in keys:
            cached(key, [song(track.title, None), song("Missing", "MISSING")])
        await update_config(db, {"mixes": {"charts_enabled": False, "editorial_downloads": 0}})
        user = await db.get(User, charts.user_id)
        await mixes.generate_mixes(db, user)
        assert set(await generated(db, user.id)) == set(keys)
        await mixes.refresh_chart_downloads()
        assert charts.downloads == [] and mixes._chart_requested == {}
        await update_config(db, {"mixes": {"editorial_years": False}})
        await mixes.generate_mixes(db, user)
        assert set(await generated(db, user.id)) == set(keys[:2])
        await update_config(db, {"mixes": {"editorial_enabled": False}})
        await mixes.generate_mixes(db, user)
        assert await generated(db, user.id) == {}
        await mixes.refresh_chart_downloads()
        assert charts.downloads == []


async def test_editorial_request_limit_spread_and_refresh_periods(
    charts: SimpleNamespace, monkeypatch: pytest.MonkeyPatch,
) -> None:
    chosen = [*editorial.EDITORIAL[:5], editorial.BY_KEY["editorial:deutschrap-100"]]
    for index, entry in enumerate(chosen):
        cached(entry.key, [song(f"Missing {index}-{i}", f"{index}{i}") for i in range(4)])
    lookup = AsyncMock(side_effect=lambda isrc: {"id": str(1000 + int(isrc))})
    monkeypatch.setattr(deezer, "track_by_isrc", lookup)
    async with SessionLocal() as db:
        await update_config(db, {"mixes": {"charts_enabled": False, "editorial_downloads": 2}})
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 8
    assert set(mixes._chart_requested) == {entry.key for entry in chosen[:4]}
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 12
    assert set(mixes._chart_requested) == {entry.key for entry in chosen}
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 12
    mixes._chart_requested = {entry.key: date.today() - timedelta(days=1) for entry in chosen}
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 14  # Only Deutschrap 100 is due after one day.
    mixes._chart_requested = {entry.key: date.today() - timedelta(days=6) for entry in chosen[:5]}
    mixes._chart_requested[chosen[-1].key] = date.today()
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 14
    mixes._chart_requested[chosen[0].key] = date.today() - timedelta(days=7)
    await mixes.refresh_chart_downloads()
    assert len(charts.downloads) == 16
    assert len({call[0] for call in charts.downloads}) == 16


async def test_missing_songs_skip_absent_isrc_deezer_misses_and_errors(
    charts: SimpleNamespace, monkeypatch: pytest.MonkeyPatch,
) -> None:
    key = "editorial:80s-hits"
    cached(key, [song("No ISRC", None), song("Not on Deezer", "NONE"), song("Error", "ERROR"), song("OK", "OK")])
    lookup = AsyncMock(side_effect=[None, DeezerError("offline"), {"id": "201"}])
    monkeypatch.setattr(deezer, "track_by_isrc", lookup)
    async with SessionLocal() as db:
        await update_config(db, {"mixes": {"charts_enabled": False}})
        await mixes.generate_mixes(db, await db.get(User, charts.other_id))
        playlist = (await generated(db, charts.other_id))[key]
        assert await chart_pending(db, playlist) == [("201", 4)]
        assert await entries(db, playlist) == []
    assert charts.downloads == [("201", charts.user_id, True, True)]
    assert [call.args[0] for call in lookup.await_args_list] == ["NONE", "ERROR", "OK"]


async def test_shared_pending_songs_beyond_the_request_limit(
    charts: SimpleNamespace, monkeypatch: pytest.MonkeyPatch,
) -> None:
    key = "editorial:80s-hits"
    data = cached(key, [song("First", "FIRST"), song("Second", "SECOND"), song("Shared", "SHARED")])
    data.deezer_ids["SECOND"] = "203"
    monkeypatch.setattr(deezer, "track_by_isrc", AsyncMock(side_effect=lambda isrc: {
        "id": {"FIRST": "201", "SECOND": "203", "SHARED": "202"}[isrc],
    }))
    async with SessionLocal() as db:
        admin = await db.get(User, charts.user_id)
        await mixes.create_request(db, admin, "track", "202", temporary=True, radio=True)
        charts.downloads.clear()
        await update_config(db, {"mixes": {"charts_enabled": False, "editorial_downloads": 1}})
        await mixes.generate_mixes(db, await db.get(User, charts.other_id))
        playlist = (await generated(db, charts.other_id))[key]
        assert await chart_pending(db, playlist) == [("201", 1), ("202", 3)]
    assert charts.downloads == [("201", charts.user_id, True, True)]


async def test_api_grouping_order_translations_and_search(env: SimpleNamespace) -> None:
    now = datetime.now(UTC)
    async with SessionLocal() as db:
        await update_config(db, {"mixes": {"discover_enabled": False}})
        db.add_all([
            Playlist(owner_id=env.user_id, kind="mix", mix_key=key, name=name, generated_at=now)
            for key, name in [
                *((entry.key, entry.name) for entry in reversed(editorial.EDITORIAL)),
                ("era:1980:rock", "80er Rock"), ("decade:1980", "80er Mix"),
                *((key, name) for key, (name, _) in reversed(mixes.CHARTS.items())),
            ]
        ])
        await db.commit()
    response = await env.client.get("/api/mixes", headers={**env.headers, "Accept-Language": "en"})
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["made_for_you"] == [] and body["genres"] == []
    assert [row["mix_key"] for row in body["decades"]] == [
        *(entry.key for entry in editorial.EDITORIAL if entry.group == "decades"),
        "decade:1980", "era:1980:rock",
        *(entry.key for entry in editorial.EDITORIAL if entry.group == "eras"),
    ]
    assert [row["mix_key"] for row in body["charts"]] == [
        "chart:de", "chart:global", "editorial:deutschrap-100",
        *sorted(entry.key for entry in editorial.EDITORIAL if entry.group == "years"),
    ]
    assert body["charts"][2]["name"] == "German Rap 100"
    assert [row["name"] for row in body["decades"][:6]] == [
        "60s Hits", "70s Hits", "80s Hits", "90s Hits", "00s Hits", "10s Hits",
    ]
    for query, expected in [("80er hip hop", "editorial:80s-hiphop"), ("1985", "editorial:year-1985")]:
        response = await env.client.get("/api/search", params={"q": query}, headers=env.headers)
        assert response.status_code == 200, response.text
        assert [row["mix_key"] for row in response.json()["playlists"]] == [expected]
    for german, english in [
        ("80er Hip-Hop Hits", "80s Hip-Hop Hits"), ("90er Deutschrap", "90s German Rap"),
        ("00er Deutschpop", "00s German Pop"), ("10er Deutschpop", "10s German Pop"),
        ("Hits 1985", "Hits 1985"), ("Hip-Hop Hits 1994", "Hip-Hop Hits 1994"),
        ("Kuratiert von Apple Music – wöchentlich aktualisiert", "Curated by Apple Music – updated weekly"),
        ("Kuratiert von Apple Music – täglich aktualisiert", "Curated by Apple Music – updated daily"),
    ]:
        assert translate(german, "en") == english
    terms = mixes.mix_search_terms("editorial:80s-hiphop")
    assert {"80er", "80s", "1980", "achtziger", "eighties", "hip-hop", "hiphop", "rap", "80er hip hop"} <= set(terms)
    assert {"1985", "hits 1985", "charts 1985"} <= set(mixes.mix_search_terms("editorial:year-1985"))


def test_config_bounds_and_fixed_catalog() -> None:
    assert MixesConfig().editorial_enabled and MixesConfig().editorial_years
    assert MixesConfig().editorial_downloads == 20
    for invalid in (-1, 101):
        with pytest.raises(ValidationError):
            MixesConfig(editorial_downloads=invalid)
    assert len(editorial.EDITORIAL) == len(editorial.BY_KEY) == 38
    assert [sum(entry.group == group for entry in editorial.EDITORIAL) for group in (
        "decades", "eras", "years", "charts",
    )] == [6, 13, 18, 1]
