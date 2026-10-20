import struct
import wave
from pathlib import Path

import numpy as np
import pytest

from app.db import Base, SessionLocal, engine
from app.models import Album, Artist, Track
from app.services import spectrum
from tests.conftest import MUSIC_DIR, auth, register

RATE = 22050


def tone(path: Path, freq: float, seconds: float) -> Path:
    t = np.arange(int(RATE * seconds)) / RATE
    audio = 0.5 * np.sin(2 * np.pi * freq * t)
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes((audio * 32767).astype("<i2").tobytes())
    return path


def parse(data: bytes) -> np.ndarray:
    magic, bands, fps, frames = struct.unpack_from("<4sBfI", data)
    assert magic == spectrum.MAGIC and bands == spectrum.BANDS and fps == spectrum.FPS
    body = np.frombuffer(data, dtype=np.uint8, offset=struct.calcsize("<4sBfI"))
    return body.reshape(frames, bands)


@pytest.mark.parametrize(("freq", "band"), [(100.0, 5), (1000.0, 13), (5000.0, 21)])
def test_tone_lands_in_its_band(tmp_path: Path, freq: float, band: int) -> None:
    frames = parse(spectrum.analyze(tone(tmp_path / "tone.wav", freq, 4)))
    assert abs(len(frames) - 4 * spectrum.FPS) <= 2
    loudest = np.bincount(frames.argmax(axis=1)).argmax()
    assert abs(int(loudest) - band) <= 1
    assert frames[:, loudest].mean() > 200


def test_band_edges_are_increasing() -> None:
    edges = spectrum._band_edges()
    assert len(edges) == spectrum.BANDS + 1 and (np.diff(edges) >= 1).all()


@pytest.fixture
async def env(client, tmp_path, monkeypatch):
    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)

    await reset()
    monkeypatch.setattr(spectrum, "_cache_dir", lambda: tmp_path)
    user = await register(client, "spectrum")
    async with SessionLocal() as db:
        artist = Artist(name="Tones", name_key="tones")
        db.add(artist)
        await db.flush()
        album = Album(title="Tones", title_key="tones", artist_id=artist.id)
        db.add(album)
        await db.flush()
        path = tone(MUSIC_DIR / "Tones/a.wav", 440, 3)
        track = Track(
            path="Tones/a.wav", title="A", album_id=album.id, artist_id=artist.id, artist_credit="Tones",
            duration=3, mtime=path.stat().st_mtime,
        )
        db.add(track)
        await db.commit()
        track_id = track.id
    yield client, auth(user["token"]), track_id, tmp_path
    await reset()


async def test_api_serves_and_caches(env, monkeypatch: pytest.MonkeyPatch) -> None:
    client, headers, track_id, cache = env
    calls = []
    original = spectrum.analyze
    monkeypatch.setattr(spectrum, "analyze", lambda path: calls.append(path) or original(path))
    response = await client.get(f"/api/tracks/{track_id}/spectrum", headers=headers)
    assert response.status_code == 200, response.text
    assert len(parse(response.content)) >= 55
    again = await client.get(f"/api/tracks/{track_id}/spectrum", headers=headers)
    assert again.content == response.content and len(calls) == 1
    assert len(list(cache.glob("*.bin"))) == 1
    assert (await client.get(f"/api/tracks/{track_id}/spectrum")).status_code == 401
    missing = "00000000-0000-0000-0000-000000000000"
    assert (await client.get(f"/api/tracks/{missing}/spectrum", headers=headers)).status_code == 404
