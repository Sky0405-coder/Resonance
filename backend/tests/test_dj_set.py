import wave
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

from app.db import SessionLocal
from app.models import TrackMixPoints
from app.services import dj_set, mixpoints
from tests.conftest import auth
from tests.test_deletion import create_playlist, env, library  # noqa: F401 (env is a fixture)

RATE = 22050


def write(path: Path, audio: np.ndarray) -> Path:
    with wave.open(str(path), "wb") as out:
        out.setnchannels(1)
        out.setsampwidth(2)
        out.setframerate(RATE)
        out.writeframes((np.clip(audio, -1, 1) * 32767).astype("<i2").tobytes())
    return path


def bars_track(bpm: float, bars: int, *, pickup: int = 0, gain=lambda bar: 1.0) -> np.ndarray:
    """A kick on every bar's beat 1, hats on the other beats, [pickup] hat beats before the first bar."""
    beat = 60 / bpm
    total = (bars * 4 + pickup) * beat + 1
    t = np.arange(int(RATE * total)) / RATE
    audio = np.zeros_like(t)
    for index in range(bars * 4 + pickup):
        start = int(index * beat * RATE)
        bar_beat = index - pickup
        level = gain(bar_beat // 4) if bar_beat >= 0 else 0.6
        length = int(0.12 * RATE)
        n = np.arange(min(length, len(audio) - start))
        if bar_beat >= 0 and bar_beat % 4 == 0:
            audio[start : start + len(n)] += level * 0.9 * np.exp(-n / (0.03 * RATE)) * np.sin(2 * np.pi * 55 * n / RATE)
        else:
            rng = np.random.default_rng(index)
            audio[start : start + len(n)] += level * 0.3 * np.exp(-n / (0.01 * RATE)) * rng.uniform(-1, 1, len(n))
    # A pad so the level follows the bars between hits.
    bar_of = np.floor((t / beat - pickup) / 4).astype(int)
    pad = np.array([gain(b) if b >= 0 else 0.6 for b in range(bar_of.max() + 1)])
    audio += 0.15 * pad[np.clip(bar_of, 0, None)] * np.sin(2 * np.pi * 220 * t)
    return audio


def test_downbeat_skips_a_pickup_and_sections_follow_the_8_bar_grid(tmp_path: Path) -> None:
    bpm = 120.0
    beat = 60 / bpm
    # Quiet first 16 bars, the full song from bar 16, an outro 8 dB down for the last 16 bars.
    audio = bars_track(bpm, 64, pickup=1, gain=lambda bar: 0.3 if bar < 16 else (0.4 if bar >= 48 else 1.0))
    points = mixpoints.analyze(write(tmp_path / "song.wav", audio))
    assert points.bpm == pytest.approx(bpm, rel=0.02)
    assert points.downbeat == pytest.approx(beat, abs=0.06), "beat 1 comes after the pickup"
    assert points.mix_in == pytest.approx(points.downbeat)
    assert any(abs(p - (beat + 16 * 4 * beat)) < 0.1 for p in points.phrases)
    outro = beat + 48 * 4 * beat
    assert any(abs(p - outro) < 0.1 for p in points.phrases)
    assert points.mix_out == pytest.approx(outro, abs=0.1), "the next song comes in where the outro starts"


def test_energy_is_higher_for_fast_busy_songs(tmp_path: Path) -> None:
    calm = mixpoints.analyze(write(tmp_path / "calm.wav", bars_track(80, 32, gain=lambda bar: 0.3 + 0.7 * (bar % 2))))
    busy = mixpoints.analyze(write(tmp_path / "busy.wav", bars_track(140, 48)))
    assert 0 <= calm.energy < busy.energy <= 1


def test_set_order_follows_the_arc_with_harmonic_neighbours() -> None:
    tracks = [
        dj_set.SetTrack(i, bpm, key, energy)
        for i, (bpm, key, energy) in enumerate([
            (124, "8A", 0.9), (120, "8A", 0.3), (122, "9A", 0.5), (126, "3B", 0.7), (123, "8B", 0.6), (125, "7A", 0.8),
        ])
    ]
    rise = dj_set.order(tracks, "rise")
    assert rise[0].energy == 0.3
    assert sum(t.energy for t in rise[:3]) < sum(t.energy for t in rise[3:])
    # The song in a clashing key is not squeezed between compatible neighbours.
    assert rise[-1].key == "3B"
    down = dj_set.order(tracks, "down")
    assert down[0].energy >= 0.8 and down[-1].energy <= 0.5 or down[-1].key == "3B"
    assert sorted(t.id for t in dj_set.order(tracks, "peak")) == list(range(6))
    assert dj_set.camelot_compatible("12A", "1A") and dj_set.camelot_compatible("8A", "8B")
    assert not dj_set.camelot_compatible("8A", "9B")
    assert dj_set.order(tracks[:2], "peak") == tracks[:2]


async def test_order_endpoints_reorder_the_whole_playlist(env: SimpleNamespace) -> None:  # noqa: F811
    rows = await library(env, paths=tuple(f"Artist/Album/{i:02}.flac" for i in range(4)))
    playlist_id = await create_playlist(env)
    url = f"/api/playlists/{playlist_id}"
    await env.client.post(f"{url}/tracks", json={"track_ids": [str(t) for t in rows.tracks]}, headers=env.headers)
    entries = [e["entry_id"] for e in (await env.client.get(url, headers=env.headers)).json()["entries"]]
    reversed_ids = list(reversed(entries))
    response = await env.client.put(f"{url}/order", json={"entry_ids": reversed_ids}, headers=env.headers)
    assert response.status_code == 204, response.text
    detail = (await env.client.get(url, headers=env.headers)).json()
    assert [e["entry_id"] for e in detail["entries"]] == reversed_ids
    # Not every entry (the playlist changed meanwhile): refused.
    response = await env.client.put(f"{url}/order", json={"entry_ids": reversed_ids[:3]}, headers=env.headers)
    assert response.status_code == 409
    response = await env.client.put(f"{url}/order", json={"entry_ids": entries}, headers=auth(env.b["token"]))
    assert response.status_code in (403, 404)
    async with SessionLocal() as db:
        for track_id, energy in zip(rows.tracks, (0.9, 0.2, 0.6, 0.4), strict=True):
            db.add(TrackMixPoints(
                track_id=track_id, version=mixpoints.VERSION, mtime=0, bpm=120, mix_in=0, mix_out=30, end=40,
                key="8A", key_confidence=0.5, energy=energy,
            ))
        await db.commit()
    response = await env.client.post(f"{url}/set-order", json={"arc": "rise"}, headers=env.headers)
    assert response.status_code == 204, response.text
    detail = (await env.client.get(url, headers=env.headers)).json()
    order = [e["track"]["id"] for e in detail["entries"]]
    assert order == [str(rows.tracks[i]) for i in (1, 3, 2, 0)]
    response = await env.client.post(f"{url}/set-order", json={"arc": "zigzag"}, headers=env.headers)
    assert response.status_code == 422
