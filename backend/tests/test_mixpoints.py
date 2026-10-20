import uuid
import wave
from datetime import UTC, datetime, timedelta
from pathlib import Path

import numpy as np
import pytest
from sqlalchemy import select

from app.db import Base, SessionLocal, engine
from app.models import Album, Artist, Track, TrackMixPoints
from app.services import mixpoints
from tests.conftest import MUSIC_DIR, auth, register

RATE = 22050


def beat_track(path: Path, *, bpm: float, seconds: float, lead: float = 0.0, tail: float = 0.0) -> Path:
    """Kick-like clicks on every beat plus a quiet hum, with optional leading/trailing silence."""
    t = np.arange(int(RATE * seconds)) / RATE
    audio = 0.05 * np.sin(2 * np.pi * 220 * t)
    period = 60 / bpm
    for start in np.arange(0, seconds, period):
        index = int(start * RATE)
        length = min(int(0.08 * RATE), len(audio) - index)
        envelope = np.exp(-np.arange(length) / (0.015 * RATE))
        audio[index : index + length] += 0.8 * envelope * np.sin(2 * np.pi * 60 * np.arange(length) / RATE)
    audio = np.concatenate([np.zeros(int(lead * RATE)), audio, np.zeros(int(tail * RATE))])
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    return path


@pytest.mark.parametrize("bpm", [96.0, 124.0, 170.0])
def test_analyze_finds_tempo_and_beat_aligned_points(tmp_path: Path, bpm: float) -> None:
    points = mixpoints.analyze(beat_track(tmp_path / "beat.wav", bpm=bpm, seconds=90, lead=2.0, tail=3.0))
    assert points.bpm == pytest.approx(bpm, rel=0.02)
    period = 60 / bpm
    # The first beat after the silence, and a fade-out point on a beat before the audible end.
    assert points.mix_in == pytest.approx(2.0, abs=0.06)
    assert points.end == pytest.approx(92.0, abs=0.2)
    assert 70 < points.mix_out < points.end - 4
    phase = ((points.mix_out - 2.0) / period) % 1
    assert min(phase, 1 - phase) < 0.08
    # On a 16-beat phrase boundary counted from the first beat.
    phrase = ((points.mix_out - points.mix_in) / (16 * period)) % 1
    assert min(phrase, 1 - phrase) < 0.02


def test_analyze_short_or_silent_file(tmp_path: Path) -> None:
    path = tmp_path / "short.wav"
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"\0\0" * 100)
    points = mixpoints.analyze(path)
    assert points.bpm is None and points.key is None and points.key_confidence is None


@pytest.mark.parametrize("notes, key", [([60, 64, 67], "8B"), ([57, 60, 64], "8A"), ([55, 59, 62], "9B")])
def test_analyze_finds_key(tmp_path: Path, notes: list[int], key: str) -> None:
    t = np.arange(RATE * 20) / RATE
    audio = sum(np.sin(2 * np.pi * 440 * 2 ** ((note - 69) / 12) * t) for note in notes + [n + 12 for n in notes])
    path = tmp_path / "triad.wav"
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes((audio / 6 * 32767).astype("<i2").tobytes())
    points = mixpoints.analyze(path)
    assert points.key == key
    assert points.key_confidence is not None and 0 < points.key_confidence <= 1
    assert points.key_confidence == round(points.key_confidence, 3)


def test_analyze_silence_has_no_key(tmp_path: Path) -> None:
    path = tmp_path / "silence.wav"
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes(b"\0\0" * RATE * 20)
    points = mixpoints.analyze(path)
    assert points.key is None and points.key_confidence is None


@pytest.fixture
async def env(client):
    async def reset() -> None:
        async with engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)
            await conn.run_sync(Base.metadata.create_all)

    await reset()
    user = await register(client, "mix-points")
    async with SessionLocal() as db:
        artist = Artist(name="Beats", name_key="beats")
        db.add(artist)
        await db.flush()
        album = Album(title="Beats", title_key="beats", artist_id=artist.id)
        db.add(album)
        await db.flush()
        path = beat_track(MUSIC_DIR / "Beats/beat.wav", bpm=120, seconds=40)
        track = Track(
            path="Beats/beat.wav",
            title="Beat",
            album_id=album.id,
            artist_id=artist.id,
            artist_credit="Beats",
            duration=40,
            mtime=path.stat().st_mtime,
        )
        missing = Track(
            path="Beats/missing.wav", title="Gone", album_id=album.id, artist_id=artist.id, artist_credit="Beats"
        )
        db.add_all([track, missing])
        await db.commit()
        ids = (track.id, missing.id)
    yield client, auth(user["token"]), *ids
    await reset()


async def test_api_analyzes_once_and_reanalyzes_changed_files(env, monkeypatch: pytest.MonkeyPatch) -> None:
    client, headers, track_id, missing_id = env
    calls = []
    original = mixpoints.analyze

    def counting(path):
        calls.append(path)
        return original(path)

    monkeypatch.setattr(mixpoints, "analyze", counting)
    unknown = uuid.uuid4()
    response = await client.get(
        "/api/mixpoints", params={"ids": f"{track_id},{missing_id},{unknown},{track_id}"}, headers=headers
    )
    assert response.status_code == 200, response.text
    body = response.json()
    assert body[str(track_id)]["bpm"] == pytest.approx(120, rel=0.02)
    assert body[str(missing_id)] is None and body[str(unknown)] is None
    assert len(calls) == 2
    again = await client.get("/api/mixpoints", params={"ids": str(track_id)}, headers=headers)
    assert again.json()[str(track_id)] == body[str(track_id)] and len(calls) == 2
    async with SessionLocal() as db:
        (await db.get(Track, track_id)).mtime += 1
        await db.commit()
    await client.get("/api/mixpoints", params={"ids": str(track_id)}, headers=headers)
    assert len(calls) == 3
    async with SessionLocal() as db:
        rows = list(await db.scalars(select(TrackMixPoints)))
        assert [row.track_id for row in rows] == [track_id] and rows[0].version == mixpoints.VERSION
    assert (await client.get("/api/mixpoints", params={"ids": "nope"}, headers=headers)).status_code == 422
    assert (await client.get("/api/mixpoints", params={"ids": str(track_id)})).status_code == 401


async def test_keys_api_reads_stored_keys_without_analysis(env, monkeypatch: pytest.MonkeyPatch) -> None:
    client, headers, track_id, missing_id = env

    async def no_analysis(path):
        pytest.fail("Keys lookup must not analyze audio")

    monkeypatch.setattr(mixpoints, "analyze_async", no_analysis)
    unknown = uuid.uuid4()
    async with SessionLocal() as db:
        db.add(TrackMixPoints(
            track_id=track_id, version=mixpoints.VERSION, mtime=0, bpm=120,
            mix_in=0, mix_out=30, end=40, key="8A", key_confidence=0.2,
        ))
        await db.commit()
    response = await client.get(
        "/api/mixpoints/keys", params={"ids": f"{track_id},{missing_id},{unknown}"}, headers=headers
    )
    assert response.status_code == 200, response.text
    assert response.json() == {str(track_id): {"key": "8A", "bpm": 120.0}, str(missing_id): None, str(unknown): None}
    full = ",".join(str(uuid.uuid4()) for _ in range(500))
    assert (await client.get("/api/mixpoints/keys", params={"ids": full}, headers=headers)).status_code == 200
    for ids in ("nope", f"{track_id},bad", "", full + f",{uuid.uuid4()}", ",".join([track_id.hex] * 501)):
        assert (await client.get("/api/mixpoints/keys", params={"ids": ids}, headers=headers)).status_code == 422
    assert (await client.get("/api/mixpoints/keys", params={"ids": str(track_id)})).status_code == 401


async def test_background_batch_selects_oldest_without_current_rows(env, monkeypatch: pytest.MonkeyPatch) -> None:
    _, _, track_id, missing_id = env
    created = datetime(2020, 1, 1, tzinfo=UTC)
    async with SessionLocal() as db:
        track = await db.get(Track, track_id)
        missing = await db.get(Track, missing_id)
        missing.created_at = created
        for id, version in ((track_id, mixpoints.VERSION), (missing_id, mixpoints.VERSION - 1)):
            db.add(TrackMixPoints(track_id=id, version=version, mtime=0, bpm=None, mix_in=0, mix_out=30, end=40))
        for i in range(121):
            db.add(Track(
                path=f"background/{i}.wav", title=str(i), album_id=track.album_id,
                artist_id=track.artist_id, artist_credit="Beats", created_at=created + timedelta(seconds=i + 1),
            ))
        db.add(Track(
            path="temporary.wav", title="Temporary", album_id=track.album_id, artist_id=track.artist_id,
            artist_credit="Beats", is_temporary=True, created_at=created - timedelta(days=1),
        ))
        await db.commit()
    paths = []
    sleeps = []

    async def analyze(path):
        paths.append(path)
        return mixpoints.MixPoints(120, 0, 30, 40, "8B", 0.1)

    async def sleep(seconds):
        sleeps.append(seconds)

    monkeypatch.setattr(mixpoints, "analyze_async", analyze)
    monkeypatch.setattr(mixpoints.asyncio, "sleep", sleep)
    await mixpoints.run_once()
    assert paths == [MUSIC_DIR / "Beats/missing.wav", *[MUSIC_DIR / f"background/{i}.wav" for i in range(119)]]
    assert sleeps == [30] * 120
    async with SessionLocal() as db:
        row = await db.get(TrackMixPoints, missing_id)
        assert row.version == mixpoints.VERSION and row.key == "8B" and row.key_confidence == 0.1
