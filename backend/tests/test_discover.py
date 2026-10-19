import os
import time
from collections import Counter
from datetime import UTC, datetime, timedelta, tzinfo
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from fastapi import HTTPException
from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.api import mixes as mixes_api
from app.db import SessionLocal
from app.models import (
    DownloadItem,
    DownloadRequest,
    Playlist,
    PlaylistEntry,
    RadioPending,
    Track,
    User,
)
from app.services import mixes, radio
from app.services.deezer import DeezerError, deezer
from app.services.server_config import ServerConfig, update_config
from tests.test_mixes import entries, generated, library, like, plays
from tests.test_mixes import env as env  # noqa: PLC0414


@pytest.fixture
async def discover(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    env.tops = {}
    env.related_by_seed = {}
    env.downloads = []
    env.download_errors = {}

    async def related(artist_id: str, limit: int) -> list[dict]:
        env.calls.append(("related", artist_id, limit))
        if artist_id in env.failures:
            raise DeezerError("offline")
        return env.related_by_seed.get(artist_id, env.related)

    async def top(artist_id: str, limit: int) -> list[dict]:
        env.calls.append(("top", artist_id, limit))
        if artist_id in env.failures:
            raise DeezerError("offline")
        return env.tops.get(artist_id, [])

    async def request(
        db: AsyncSession, user: User, kind: str, catalog_id: str, *, temporary: bool, radio: bool
    ) -> None:
        env.downloads.append((catalog_id, temporary, radio))
        if catalog_id in env.download_errors:
            raise HTTPException(env.download_errors[catalog_id], "Nicht gefunden")
        # The real request helper commits each successful request.
        await db.commit()

    monkeypatch.setattr(deezer, "artist_related", related)
    monkeypatch.setattr(deezer, "artist_top", top)
    monkeypatch.setattr(mixes, "create_request", request)
    return env


def candidate(id: str, artist: str, title: str | None = None) -> dict:
    return {"id": id, "title": title or id, "artist": {"id": artist, "name": artist}, "duration": 180}


async def seed(db: AsyncSession, state: SimpleNamespace, name: str = "Seed", score: int = 20) -> None:
    tracks = await library(db, name, None, 1)
    plays(db, state.user_id, tracks[0], score)
    await db.commit()


def candidates(state: SimpleNamespace, count: int = 4) -> list[dict]:
    state.related = [{"id": f"artist-{i}", "name": f"New artist {i}"} for i in range(count)]
    tracks = [candidate(str(i), f"New artist {i}") for i in range(count)]
    state.tops = {f"artist-{i}": [track] for i, track in enumerate(tracks)}
    return tracks


async def pending_ids(db: AsyncSession, playlist: Playlist) -> list[str]:
    return list(await db.scalars(select(RadioPending.deezer_id).where(RadioPending.playlist_id == playlist.id)))


async def test_top_ten_seeds_share_recent_play_and_like_scoring(discover: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        for i in range(12):
            await seed(db, discover, f"Seed {i:02}", 12 - i)
        liked = await library(db, "Liked", None, 1)
        plays(db, discover.user_id, liked[0], 10)
        like(db, discover.user_id, liked[0], days=200)
        for name, days, seconds, user_id in (
            ("Old", 91, 30, discover.user_id),
            ("Short", 1, 29, discover.user_id),
            ("Foreign", 1, 30, discover.other_id),
        ):
            tracks = await library(db, name, None, 1)
            plays(db, user_id, tracks[0], 50, days=days, seconds=seconds)
        temporary = await library(db, "Temporary", None, 1, temporary=True)
        like(db, discover.user_id, temporary[0])
        await db.commit()
        assert await mixes.generate_discover(db, await db.get(User, discover.user_id)) is None
    assert [call[1] for call in discover.calls if call[0] == "search"] == ["Liked", *[f"Seed {i:02}" for i in range(9)]]
    assert all(limit == (5 if kind == "search" else 10) for kind, _, limit in discover.calls)


async def test_no_seeds_no_playlist_or_deezer_calls(discover: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await library(db, "Unheard", None, 1)
        await db.commit()
        assert await mixes.generate_discover(db, await db.get(User, discover.user_id)) is None
        assert await generated(db, discover.user_id) == {}
    assert discover.calls == discover.downloads == []


async def test_seed_related_artists_skipped_round_robin_and_deduplication(discover: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await seed(db, discover, "Seed A")
        await seed(db, discover, "Seed B", 10)
        discover.related_by_seed = {
            "Seed A": [{"id": "Seed B", "name": "Alias"}, {"id": "a", "name": "A"}],
            "Seed B": [{"id": "alias", "name": " SEED A "}, {"id": "b", "name": "B"}],
        }
        discover.tops = {
            "a": [
                candidate("1", "A", "First"),
                candidate("dup", " a ", " FIRST "),
                candidate("3", "A"),
                candidate("4", "A"),
            ],
            "b": [candidate("2", "B"), candidate("1", "Other"), candidate("5", "B"), candidate("6", "B")],
        }
        playlist = await mixes.generate_discover(db, await db.get(User, discover.user_id))
        assert [item[0] for item in discover.downloads] == ["1", "2", "3", "5"]
        assert set(await pending_ids(db, playlist)) == {"1", "2", "3", "5"}
    assert [call for call in discover.calls if call[0] == "top"] == [("top", "a", 5), ("top", "b", 5)]


async def test_any_play_or_like_excluded_unplayed_and_other_users_tracks_allowed(discover: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        tracks = []
        for i in range(5):
            tracks.extend(await library(db, f"Candidate {i}", None, 1))
        plays(db, discover.user_id, tracks[0], days=200, seconds=1)
        plays(db, discover.user_id, tracks[1], seconds=1)
        like(db, discover.user_id, tracks[2])
        plays(db, discover.other_id, tracks[4])
        discover.related = [{"id": "compilation", "name": "Related"}]
        discover.tops["compilation"] = [candidate(str(i), t.artist_credit, t.title) for i, t in enumerate(tracks)]
        await db.commit()
        playlist = await mixes.generate_discover(db, await db.get(User, discover.user_id))
        assert [entry.track_id for entry in await entries(db, playlist)] == [track.id for track in tracks[3:]]
        assert await pending_ids(db, playlist) == []
        assert discover.downloads == []
        assert playlist.kind == "mix" and playlist.mix_key == "discover-weekly"
        assert not playlist.is_public and playlist.generated_at is not None


@pytest.mark.parametrize("size,expected_count", [(30, 30), (None, 40)])
async def test_size_limit_and_two_per_artist(discover: SimpleNamespace, size: int | None, expected_count: int) -> None:
    async with SessionLocal() as db:
        if size is not None:
            await update_config(db, {"mixes": {"discover_size": size}})
        await seed(db, discover, "Seed A")
        await seed(db, discover, "Seed B", 10)
        expected = []
        for group, seed_name in enumerate(("Seed A", "Seed B")):
            artists = [{"id": f"{group}-{i}", "name": f"Artist {group}-{i}"} for i in range(10)]
            discover.related_by_seed[seed_name] = artists
            for artist in artists:
                tracks = await library(db, artist["name"], None, 5)
                discover.tops[artist["id"]] = [candidate(str(t.id), artist["name"], t.title) for t in tracks]
                expected.append(tracks[:2])
        await db.commit()
        playlist = await mixes.generate_discover(db, await db.get(User, discover.user_id))
        rows = await entries(db, playlist)
        # Default size 50: all 40 candidates (two per related artist) fit.
        assert len(rows) == len({row.track_id for row in rows}) == expected_count
        assert max(Counter([(await db.get(Track, row.track_id)).artist_id for row in rows]).values()) == 2
        assert rows[0].track_id == expected[0][0].id and rows[1].track_id == expected[10][0].id
        assert [row.position for row in rows] == list(range(1, expected_count + 1))


@pytest.mark.parametrize("limit,temporary", [(0, True), (2, True), (20, False)])
async def test_download_limit_pending_only_playlist_and_temporary_setting(
    discover: SimpleNamespace, limit: int, temporary: bool
) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover)
        await update_config(
            db, {"mixes": {"discover_downloads": limit}, "radio": {"temporary_tracks_enabled": temporary}}
        )
        playlist = await mixes.generate_discover(db, await db.get(User, discover.user_id))
        assert len(discover.downloads) == min(limit, 4)
        assert all(item[1:] == (temporary, True) for item in discover.downloads)
        if limit == 0:
            assert playlist is None
        else:
            assert await entries(db, playlist) == []
            assert len(await pending_ids(db, playlist)) == min(limit, 4)


@pytest.mark.parametrize("status,expected", [(404, ["0", "1", "2", "3"]), (429, ["0", "1"])])
async def test_http_failures_skip_or_stop_downloads_but_keep_library_entries(
    discover: SimpleNamespace, status: int, expected: list[str]
) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover)
        local = (await library(db, "New artist 3", None, 1))[0]
        discover.tops["artist-3"] = [candidate("local", local.artist_credit, local.title)]
        discover.download_errors["1"] = status
        await db.commit()
        playlist = await mixes.generate_discover(db, await db.get(User, discover.user_id))
        assert [item[0] for item in discover.downloads] == [id for id in expected if id != "3"]
        assert [row.track_id for row in await entries(db, playlist)] == [local.id]
        assert set(await pending_ids(db, playlist)) == ({"0", "2"} if status == 404 else {"0"})


@pytest.mark.parametrize("failure", ["search", "no_match", "Seed", "artist-0"])
async def test_single_deezer_failures_are_isolated(discover: SimpleNamespace, failure: str) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover)
        discover.failures.add(failure)
        playlist = await mixes.generate_discover(db, await db.get(User, discover.user_id))
        if failure == "artist-0":
            assert set(await pending_ids(db, playlist)) == {"1", "2", "3"}
        else:
            assert playlist is None and discover.downloads == []


async def test_upsert_replaces_entries_pending_and_daily_generation_preserves_it(discover: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover)
        local = (await library(db, "Local", None, 1))[0]
        discover.tops["artist-0"] = [candidate("local", local.artist_credit, local.title)]
        await db.commit()
        user = await db.get(User, discover.user_id)
        playlist = await mixes.generate_discover(db, user)
        first_id = playlist.id
        assert [row.track_id for row in await entries(db, playlist)] == [local.id]
        assert set(await pending_ids(db, playlist)) == {"1", "2", "3"}
        discover.related = [{"id": "replacement", "name": "Replacement"}]
        discover.tops["replacement"] = [candidate("new", "Replacement")]
        again = await mixes.generate_discover(db, user)
        assert again.id == first_id and await entries(db, again) == []
        assert await pending_ids(db, again) == ["new"]
        await mixes.generate_mixes(db, user)
        assert (await generated(db, discover.user_id))["discover-weekly"].id == first_id
        discover.related = []
        generated_at = again.generated_at
        assert await mixes.generate_discover(db, user) is None
        assert (await db.get(Playlist, first_id)).generated_at == generated_at
        assert await pending_ids(db, again) == ["new"]


async def test_pending_download_resolves_into_discover_playlist(discover: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover, 1)
        playlist = await mixes.generate_discover(db, await db.get(User, discover.user_id))
        track = (await library(db, "Downloaded", None, 1, temporary=True))[0]
        request = DownloadRequest(
            user_id=discover.user_id,
            kind="track",
            catalog_id="0",
            title=track.title,
            artist=track.artist_credit,
            status="done",
        )
        db.add(request)
        await db.flush()
        db.add(
            DownloadItem(
                request_id=request.id,
                position=0,
                title=track.title,
                artist=track.artist_credit,
                meta={"deezer_track_id": "0"},
                status="done",
                track_id=track.id,
            )
        )
        await db.commit()
        assert await radio.resolve_radio_pending(db) == 1
        assert [row.track_id for row in await entries(db, playlist)] == [track.id]
        assert await pending_ids(db, playlist) == []


async def test_cleanup_protects_discover_temporary_tracks(discover: SimpleNamespace) -> None:
    async with SessionLocal() as db:
        tracks = await library(db, "Temporary", None, 2, temporary=True)
        for track in tracks:
            track.created_at = datetime.now(UTC) - timedelta(days=30)
        playlist = Playlist(owner_id=discover.user_id, kind="mix", mix_key="discover-weekly", name="Mix der Woche")
        db.add(playlist)
        await db.flush()
        db.add(PlaylistEntry(playlist_id=playlist.id, track_id=tracks[0].id, position=1))
        await db.commit()
        assert await radio.cleanup(db) == (0, 1)
        assert await db.get(Track, tracks[0].id) is not None
        assert await db.scalar(select(Track.id).where(Track.id == tracks[1].id)) is None


async def test_disabled_skips_generator_api_and_scheduler(
    discover: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover)
        await update_config(db, {"mixes": {"discover_enabled": False}})
        assert await mixes.generate_discover(db, await db.get(User, discover.user_id)) is None
    generate = AsyncMock()
    monkeypatch.setattr(mixes, "generate_discover", generate)
    monkeypatch.setattr(mixes_api, "generate_discover", generate)
    response = await discover.client.get("/api/mixes", headers=discover.headers)
    assert response.status_code == 200 and response.json()["discover"] is None
    await mixes._generate_due()
    generate.assert_not_awaited()
    assert discover.downloads == []


def freeze(monkeypatch: pytest.MonkeyPatch, instant: datetime) -> None:
    class FrozenDatetime(datetime):
        @classmethod
        def now(cls, tz: tzinfo | None = None) -> datetime:
            return instant.astimezone(tz) if tz else instant.astimezone().replace(tzinfo=None)

    monkeypatch.setattr(mixes, "datetime", FrozenDatetime)


async def test_get_returns_separate_translated_discover_and_only_regenerates_after_monday(
    discover: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    sunday = datetime(2026, 10, 18, 12).astimezone()
    freeze(monkeypatch, sunday)
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover)
    generate = AsyncMock(wraps=mixes.generate_discover)
    monkeypatch.setattr(mixes_api, "generate_discover", generate)
    for lang, name in (("de", "Mix der Woche"), ("en", "Discover Weekly")):
        response = await discover.client.get("/api/mixes", headers={**discover.headers, "Accept-Language": lang})
        assert response.status_code == 200, response.text
        payload = response.json()
        assert payload["discover"]["name"] == name
        assert payload["discover"]["mix_key"] == "discover-weekly"
        assert all(item["mix_key"] != "discover-weekly" for item in payload["made_for_you"])
        if lang == "en":
            assert payload["discover"]["description"] == "New songs for you – fresh every Monday"
    generate.assert_awaited_once()
    freeze(monkeypatch, sunday.replace(day=19, hour=0, minute=0))
    assert (await discover.client.get("/api/mixes", headers=discover.headers)).status_code == 200
    assert generate.await_count == 2
    assert (await discover.client.get("/api/mixes", headers=discover.headers)).status_code == 200
    assert generate.await_count == 2


async def test_scheduler_weekly_check_runs_when_daily_mix_is_current(
    discover: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    async with SessionLocal() as db:
        await seed(db, discover)
        candidates(discover)
        db.add(
            Playlist(
                owner_id=discover.user_id, kind="mix", mix_key="daily:1", name="Daily", generated_at=datetime.now(UTC)
            )
        )
        await db.execute(update(User).where(User.id == discover.other_id).values(is_disabled=True))
        await db.commit()
    daily = AsyncMock()
    weekly = AsyncMock(wraps=mixes.generate_discover)
    monkeypatch.setattr(mixes, "generate_mixes", daily)
    monkeypatch.setattr(mixes, "generate_discover", weekly)
    await mixes._generate_due()
    weekly.assert_awaited_once()
    daily.assert_not_awaited()
    await mixes._generate_due()
    weekly.assert_awaited_once()
    async with SessionLocal() as db:
        await db.execute(
            update(Playlist)
            .where(Playlist.mix_key == "discover-weekly")
            .values(generated_at=datetime.now(UTC) - timedelta(days=8))
        )
        await db.commit()
    await mixes._generate_due()
    assert weekly.await_count == 2
    daily.assert_not_awaited()


def test_monday_boundary_uses_local_midnight_including_dst(monkeypatch: pytest.MonkeyPatch) -> None:
    old_tz = os.environ.get("TZ")
    monkeypatch.setenv("TZ", "Europe/Berlin")
    time.tzset()
    try:
        # Sunday after the DST change still belongs to the Monday in summer time.
        freeze(monkeypatch, datetime(2026, 10, 25, 20, tzinfo=UTC))
        assert not mixes.discover_due(datetime(2026, 10, 18, 22, tzinfo=UTC))
        assert mixes.discover_due(datetime(2026, 10, 18, 21, 59, 59, tzinfo=UTC))
        freeze(monkeypatch, datetime(2026, 10, 25, 23, tzinfo=UTC))
        assert mixes.discover_due(datetime(2026, 10, 18, 22, tzinfo=UTC))
        assert not mixes.discover_due(datetime(2026, 10, 25, 23, tzinfo=UTC))
    finally:
        if old_tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = old_tz
        time.tzset()


@pytest.mark.parametrize("limit", [-1, 101])
def test_config_download_bounds(limit: int) -> None:
    from pydantic import ValidationError

    assert ServerConfig().mixes.discover_enabled
    assert ServerConfig().mixes.discover_downloads == 20
    assert ServerConfig().mixes.discover_size == 50
    with pytest.raises(ValidationError):
        ServerConfig.model_validate({"mixes": {"discover_downloads": limit}})
    for size in (9, 101):
        with pytest.raises(ValidationError):
            ServerConfig.model_validate({"mixes": {"discover_size": size}})
