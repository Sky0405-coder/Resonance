import io
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest
from PIL import Image
from sqlalchemy import select

from app.db import SessionLocal
from app.models import Album, User
from app.services import covers, editorial, mix_covers, mixes
from tests.test_editorial import artwork, cached, song
from tests.test_mixes import env as env  # noqa: PLC0414
from tests.test_mixes import library


@pytest.mark.parametrize("count", [0, 1, 4])
@pytest.mark.parametrize("name", ["Daily Mix 1", "A long mix name that needs to wrap across two readable lines " * 3])
def test_render_jpeg_size_and_determinism(count: int, name: str) -> None:
    images = [artwork(color) for color in ("red", "green", "blue", "yellow")][:count]
    data = mix_covers.render(name, "Resonance", images, "daily:1")
    assert data == mix_covers.render(name, "Resonance", images, "daily:1")
    with Image.open(io.BytesIO(data)) as image:
        assert image.format == "JPEG" and image.size == (640, 640)
    assert data != mix_covers.render(name, "Resonance", images, "daily:2")


def test_duplicate_covers_and_font_fallback(monkeypatch: pytest.MonkeyPatch) -> None:
    cover = artwork()
    assert mix_covers.render("Mix", None, [cover] * 4, "mix") == mix_covers.render("Mix", None, [cover], "mix")
    monkeypatch.setattr(Path, "exists", lambda self: False)
    data = mix_covers.render("A" * 100, "Resonance", [], "mix")
    with Image.open(io.BytesIO(data)) as image:
        assert image.size == (640, 640)


async def test_generate_mixes_reuses_cover_until_album_art_changes(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch,
) -> None:
    render = Mock(wraps=mix_covers.render)
    monkeypatch.setattr(mix_covers, "render", render)
    async with SessionLocal() as db:
        await library(db, "Library", "Rock", 15)
        await db.commit()
        user = await db.get(User, env.user_id)
        await mixes.generate_mixes(db, user, chart_downloads=False)
        render.assert_called_once()
        await mixes.generate_mixes(db, user, chart_downloads=False)
        render.assert_called_once()
        album = await db.scalar(select(Album))
        album.cover_file = covers.store(artwork())
        await db.commit()
        await mixes.generate_mixes(db, user, chart_downloads=False)
        assert render.call_count == 2
        assert len(render.call_args.args[2]) == 1


async def test_generated_cover_reuse_changes_charts_and_editorial(
    env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch,
) -> None:
    render = Mock(wraps=mix_covers.render)
    monkeypatch.setattr(mix_covers, "render", render)
    async with SessionLocal() as db:
        tracks = []
        for index, color in enumerate(("red", "green", "blue", "yellow", "purple")):
            track = (await library(db, f"Artist {index}", None, 1))[0]
            album = await db.get(Album, track.album_id)
            album.cover_file = covers.store(artwork(color))
            tracks.append(track)
        await db.commit()
        user = await db.get(User, env.user_id)

        async def write(key: str, name: str, chosen: list) -> object:
            playlist = await mixes._write(db, user, key, name, "Description", chosen, datetime.now(UTC))
            await db.commit()
            return playlist

        ids = [track.id for track in tracks]
        playlist = await write("daily:1", "Daily Mix 1", ids[:4])
        assert playlist.cover_file and playlist.cover_key
        assert len(render.call_args.args[2]) == 4
        first = playlist.cover_file
        await write("daily:1", "Daily Mix 1", list(reversed(ids[:4])))
        assert render.call_count == 1 and playlist.cover_file == first
        await write("daily:1", "A new name", ids[:4])
        assert render.call_count == 2 and playlist.cover_file != first
        await write("daily:1", "A new name", ids[1:])
        assert render.call_count == 3
        await write("chart:de", "Top 100 Deutschland", ids[:4])
        assert render.call_args.args[2] == []
        discover = await write("discover-weekly", "Mix der Woche", ids[:4])
        assert discover.cover_file and discover.cover_key
        apple_cover = covers.store(artwork("orange"))
        cached("editorial:80s-hits", [song("Song", None)], apple_cover)
        editorial_playlist = await write("editorial:80s-hits", "80er Hits", ids[:4])
        assert editorial_playlist.cover_file == apple_cover and editorial_playlist.cover_key is None
        assert render.call_count == 5
        assert editorial._cache["editorial:80s-hits"][1].cover_file == apple_cover
    response = await env.client.get(f"/api/playlists/{discover.id}", headers=env.headers)
    assert response.json()["cover_key"] == discover.cover_file
    response = await env.client.get(f"/api/playlists/{discover.id}/cover", headers=env.headers)
    assert response.status_code == 200 and response.headers["content-type"] == "image/jpeg"
