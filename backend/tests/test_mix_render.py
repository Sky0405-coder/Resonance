import asyncio
import uuid
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest
from sqlalchemy import select

from app.db import SessionLocal
from app.models import Album, Artist, Track
from app.services import mix_render
from app.services.mixpoints import MixPoints
from tests.conftest import auth
from tests.test_deletion import create_playlist, env  # noqa: F401 (env is a fixture)
from tests.test_mixpoints import beat_track


def points(bpm=120.0, mix_in=0.5, mix_out=160.5, end=200.0, intro_end=None, phrases=None) -> MixPoints:
    return MixPoints(bpm, mix_in, mix_out, end, intro_end=intro_end, phrases=phrases)


def test_plan_matches_tempo_and_swaps_on_the_phrase() -> None:
    plan = mix_render.plan(points(phrases=[160.5]), points(bpm=126))
    beat = 0.5
    assert plan.speed == pytest.approx(120 / 126)
    # 8 beats under the current song, the swap a phrase (16 beats) after the outro starts.
    assert plan.start + plan.swap == pytest.approx(160.5 + 16 * beat)
    assert plan.swap == pytest.approx(8 * beat)
    assert plan.incoming_start == 0.5
    older = mix_render.plan(points(), points(bpm=126))
    assert older.start + older.swap == pytest.approx(160.5 + 8 * beat)
    intro = mix_render.plan(points(phrases=[]), points(bpm=120, mix_in=1.0, intro_end=9.0))
    assert intro.swap == pytest.approx(8.0) and intro.incoming_start == pytest.approx(1.0)
    # Too far apart in tempo: a short crossfade at the end, no tempo change.
    apart = mix_render.plan(points(bpm=90), points(bpm=140))
    assert apart.speed == 1 and apart.duration <= 6
    unknown = mix_render.plan(None, points())
    assert unknown.duration == 6


def test_bass_split_adds_up_and_blend_hands_over() -> None:
    t = np.arange(mix_render.RATE * 2) / mix_render.RATE
    tone = np.stack([np.sin(2 * np.pi * 60 * t) + np.sin(2 * np.pi * 2000 * t)] * 2, axis=1).astype(np.float32)
    low, high = mix_render.split_bass(tone)
    assert np.allclose(low + high, tone, atol=1e-4)
    assert np.std(low) == pytest.approx(np.sqrt(0.5), rel=0.05)
    mixed = mix_render.blend(tone, np.zeros_like(tone), swap=len(tone) // 2)
    assert np.abs(mixed[: len(tone) // 4]).max() > 1.5, "the current song plays fully before the swap"
    assert np.abs(mixed[-100:]).max() < 0.05, "and is gone at the end"


def test_stretch_plays_faster_and_reports_the_position() -> None:
    audio = np.stack([np.arange(1000, dtype=np.float32)] * 2, axis=1)
    out, end = mix_render.stretch(audio, 10, np.full(100, 2.0))
    assert out[:3, 0].tolist() == [10, 12, 14]
    assert end == pytest.approx(210)


def test_chapters_name_each_song_with_its_span() -> None:
    tracks = [SimpleNamespace(artist_credit="A=B", title="One"), SimpleNamespace(artist_credit="C", title="Two")]
    text = mix_render.chapters("My; Mix", tracks, [0.0, 61.5], 120.0)
    assert r"title=My\; Mix" in text
    assert "START=61500\nEND=120000\ntitle=C - Two" in text
    assert r"title=A\=B - One" in text


async def test_render_endpoint_makes_one_mp3_and_rerenders_after_changes(env: SimpleNamespace) -> None:  # noqa: F811
    music = env.settings.music_dir
    async with SessionLocal() as db:
        artist = Artist(name="Beats", name_key="beats")
        db.add(artist)
        await db.flush()
        album = Album(title="Beats", title_key="beats", artist_id=artist.id)
        db.add(album)
        await db.flush()
        tracks = []
        for name, bpm in (("one", 120.0), ("two", 124.0)):
            path = beat_track(music / f"Beats/{name}.wav", bpm=bpm, seconds=50)
            tracks.append(Track(
                path=f"Beats/{name}.wav", title=name, album_id=album.id, artist_id=artist.id,
                artist_credit="Beats", duration=50, mtime=path.stat().st_mtime,
            ))
        db.add_all(tracks)
        await db.commit()
        ids = [str(t.id) for t in tracks]
    playlist_id = await create_playlist(env)
    url = f"/api/playlists/{playlist_id}"
    await env.client.post(f"{url}/tracks", json={"track_ids": ids}, headers=env.headers)
    assert (await env.client.get(f"{url}/render", headers=env.headers)).json()["state"] == "idle"
    response = await env.client.post(f"{url}/render", headers=env.headers)
    assert response.status_code == 200, response.text
    state = mix_render.status(uuid.UUID(playlist_id))
    await asyncio.wait_for(state.task, 120)
    status = (await env.client.get(f"{url}/render", headers=env.headers)).json()
    assert status == {"state": "done", "progress": 1.0, "error": None}
    response = await env.client.get(f"{url}/render/file", headers=env.headers)
    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/mpeg"
    assert len(response.content) > 50_000
    assert "Mix" in response.headers["content-disposition"]
    # Another user without access sees nothing.
    assert (await env.client.get(f"{url}/render", headers=auth(env.b["token"]))).status_code in (403, 404)
    # Reordering makes it stale: idle again, the file is gone until it is rendered anew.
    detail = (await env.client.get(url, headers=env.headers)).json()
    order = [e["entry_id"] for e in reversed(detail["entries"])]
    await env.client.put(f"{url}/order", json={"entry_ids": order}, headers=env.headers)
    assert (await env.client.get(f"{url}/render", headers=env.headers)).json()["state"] == "idle"
    assert (await env.client.get(f"{url}/render/file", headers=env.headers)).status_code == 404
    async with SessionLocal() as db:
        assert len(list(await db.scalars(select(Track)))) == 2


def test_render_songs_writes_every_song_once(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    audio = np.ones((mix_render.RATE * 20, 2), dtype=np.float32) * 0.1
    monkeypatch.setattr(mix_render, "decode", lambda path: audio)
    monkeypatch.setattr(mix_render, "resolve_path", lambda path: path)
    song = SimpleNamespace(path="x", replaygain_track_gain=None, replaygain_album_gain=None)
    songs = [(song, None), (song, None)]
    plans = [mix_render.Plan(start=14.0, incoming_start=0.0, duration=6.0, swap=3.0)]
    blocks = []
    starts, total = mix_render.render_songs(songs, plans, blocks.append)
    written = sum(len(b) for b in blocks) / mix_render.RATE
    assert written == pytest.approx(total)
    # Two 20 s songs overlapping by 6 s.
    assert total == pytest.approx(34.0, abs=0.01)
    assert starts == [0.0, pytest.approx(17.0)]


def _tone(freq: float, seconds: float, level: float = 0.3) -> np.ndarray:
    t = np.arange(int(mix_render.RATE * seconds)) / mix_render.RATE
    wave = (level * np.sin(2 * np.pi * freq * t)).astype(np.float32)
    return np.stack([wave, wave], axis=1)


def _rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(audio**2))) if len(audio) else 0.0


def _lanes_plan(lanes: dict, bars: int = 2) -> mix_render.Plan:
    # 120 bpm: two bars last 4 s.
    return mix_render.Plan(0.0, 0.0, bars * 2.0, bars, lanes=lanes, bars=bars, beat=0.5)


def test_editor_lanes_shape_the_rendered_transition() -> None:
    rate = mix_render.RATE
    current, incoming = _tone(440, 10), _tone(60, 4)
    p = _lanes_plan({"volume": "center_cut"})
    mixed = mix_render.blend_lanes(current, rate, incoming, p)
    assert mixed.shape == incoming.shape
    # A center cut: only the current song in the first half, only the next one in the second.
    first, second = mixed[: int(rate * 1.9)], mixed[int(rate * 2.1) :]
    spectrum = np.abs(np.fft.rfft(second[:, 0]))
    freqs = np.fft.rfftfreq(len(second), 1 / rate)
    assert freqs[spectrum.argmax()] == pytest.approx(60, abs=2)
    assert _rms(first) == pytest.approx(_rms(current), rel=0.1)

    # A drawn curve: the next song's high-pass closed all along removes its 60 Hz tone.
    drawn = {"volume": "overlap", "curves": {"filter_in": [[0, 1], [1, 1]], "volume_out": [[0, 0], [1, 0]]}}
    filtered = mix_render.blend_lanes(current, rate, incoming, _lanes_plan(drawn))
    assert _rms(filtered[rate:]) < 0.1 * _rms(incoming)


def test_every_lane_and_effect_renders(monkeypatch: pytest.MonkeyPatch) -> None:
    rate = mix_render.RATE
    current, incoming = _tone(220, 8), _tone(330, 4)
    for lanes in [
        {"eq": "three_band", "filter": "noise_end", "effect": "echo_3q_tail"},
        {"filter": "lowpass_in_highpass_out", "effect": "reverb_middle"},
        {"effect": "flanger"}, {"effect": "phaser"}, {"effect": "gate"}, {"effect": "beat_roll"},
        {"effect": "brake"}, {"loop": 4, "beatmatch": False},
    ]:
        mixed = mix_render.blend_lanes(current, rate, incoming, _lanes_plan(lanes))
        assert mixed.shape == incoming.shape, lanes
        assert np.isfinite(mixed).all(), lanes
        assert _rms(mixed) > 0.01, lanes


def test_gate_chops_eighth_notes_and_echo_rings_after_the_cut() -> None:
    rate = mix_render.RATE
    current, silent = _tone(440, 10), np.zeros((rate * 4, 2), dtype=np.float32)
    gated = mix_render.blend_lanes(current, 0, silent, _lanes_plan({"volume": "overlap", "effect": "gate"}))
    # Second half, eighth notes of 0.25 s: on for the first 0.125 s, nearly off after.
    on = gated[int(rate * 2.5) : int(rate * 2.6)]
    off = gated[int(rate * 2.64) : int(rate * 2.74)]
    assert _rms(off) < 0.2 * _rms(on)
    # "Echo every beat rings out" over four bars: fed from the middle, the song stops a bar early (6 s), its echo
    # goes on.
    silent = np.zeros((rate * 8, 2), dtype=np.float32)
    echoed = mix_render.blend_lanes(
        current, 0, silent, _lanes_plan({"volume": "overlap", "effect": "echo_beat_tail"}, bars=4)
    )
    assert _rms(echoed[int(rate * 6.2) : int(rate * 6.8)]) > 0.02
    plain = mix_render.blend_lanes(current, 0, silent, _lanes_plan({"volume": "overlap"}, bars=4))
    assert _rms(plain[int(rate * 6.2) : int(rate * 6.8)]) > _rms(echoed[int(rate * 6.2) : int(rate * 6.8)])
