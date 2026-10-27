import shutil
import wave
from pathlib import Path

import numpy as np
import pytest

from app.db import Base, SessionLocal, engine
from app.models import Album, Artist, Track
from app.services import ringtone
from tests.conftest import MUSIC_DIR, auth, register

RATE = 22050


def song(path: Path, loudness: list[float]) -> Path:
    """One second of 440 Hz per entry, at that amplitude."""
    t = np.arange(RATE) / RATE
    audio = np.concatenate([level * np.sin(2 * np.pi * 440 * t) for level in loudness])
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes((audio * 32767).astype("<i2").tobytes())
    return path


def test_highlight_finds_the_first_loud_stretch_and_skips_the_outro() -> None:
    energy = np.array([0.1] * 20 + [0.8] * 10 + [0.2] * 20 + [0.8] * 10 + [0.2] * 10 + [0.9] * 10)
    assert ringtone.highlight(energy, 10) == 20


def test_levels_are_scaled_to_the_loudest_second() -> None:
    assert ringtone.levels(np.array([0.2, 0.4, 0.1])) == [0.5, 1.0, 0.25]
    assert ringtone.levels(np.zeros(2)) == [0.0, 0.0]


def test_highlight_of_short_or_silent_songs_starts_at_zero() -> None:
    assert ringtone.highlight(np.ones(8), 30) == 0
    assert ringtone.highlight(np.zeros(100), 30) == 0


@pytest.fixture
async def env(client):
    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)

    await reset()
    user = await register(client, "ringtone")
    async with SessionLocal() as db:
        artist = Artist(name="Tones", name_key="tones")
        db.add(artist)
        await db.flush()
        album = Album(title="Tones", title_key="tones", artist_id=artist.id)
        db.add(album)
        await db.flush()
        path = song(MUSIC_DIR / "Ringtones/a.wav", [0.05] * 12 + [0.8] * 8 + [0.1] * 20)
        track = Track(
            path="Ringtones/a.wav", title="A", album_id=album.id, artist_id=artist.id, artist_credit="Tones",
            duration=40, mtime=path.stat().st_mtime,
        )
        db.add(track)
        await db.commit()
        track_id = track.id
    yield client, auth(user["token"]), track_id
    await reset()
    shutil.rmtree(MUSIC_DIR / "Ringtones", ignore_errors=True)


async def test_suggestion_starts_at_the_loud_part(env) -> None:
    client, headers, track_id = env
    response = await client.get(f"/api/tracks/{track_id}/ringtone/suggestion?length=8", headers=headers)
    assert response.status_code == 200
    body = response.json()
    assert (body["start"], body["duration"]) == (12.0, 40.0)
    assert len(body["levels"]) == 40
    assert body["levels"][15] == 1.0
    assert body["levels"][0] < 0.1


async def test_cut_is_a_faded_mp3_of_the_asked_length(env, tmp_path: Path) -> None:
    client, headers, track_id = env
    response = await client.get(f"/api/tracks/{track_id}/ringtone?start=12&length=8", headers=headers)
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mpeg"
    out = tmp_path / "cut.mp3"
    out.write_bytes(response.content)
    energy = ringtone._energy(out)
    assert 7 <= len(energy) <= 9
    # Loud throughout (the chorus), but faded at both ends.
    assert energy[0] < energy[3] and energy[-1] < energy[3]
    assert energy[3] > 0.4


async def test_cut_rejects_a_start_past_the_end(env) -> None:
    client, headers, track_id = env
    response = await client.get(f"/api/tracks/{track_id}/ringtone?start=40&length=8", headers=headers)
    assert response.status_code == 422
