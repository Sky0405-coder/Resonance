import asyncio
import json
import uuid
from types import SimpleNamespace

import httpx
import pytest
from fastapi import WebSocketDisconnect
from sqlalchemy import select

from app.api import jam as jam_api
from app.db import Base, SessionLocal, engine
from app.models import Album, Artist, Track
from app.services import jam as jam_service
from app.services.jam import IDLE_MS, Hub, JamError
from tests.conftest import auth, register


class Clock:
    def __init__(self) -> None:
        self.ms = 1_000_000

    def __call__(self) -> int:
        return self.ms


@pytest.fixture
async def env(client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch) -> SimpleNamespace:
    assert engine.url.database.startswith("app_test")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    clock = Clock()
    monkeypatch.setattr(jam_service, "now_ms", clock)
    monkeypatch.setattr(jam_api, "now_ms", clock)
    hub = Hub()
    monkeypatch.setattr(jam_api, "hub", hub)
    users = {}
    for name in ("host", "guest", "other"):
        data = await register(client, f"jam-{name}")
        users[name] = SimpleNamespace(
            token=data["token"], headers=auth(data["token"]), id=uuid.UUID(data["user"]["id"])
        )
        if name == "host":
            response = await client.patch(
                "/api/admin/config", json={"registration": {"mode": "public"}}, headers=users[name].headers
            )
            assert response.status_code == 200
    async with SessionLocal() as db:
        artist = Artist(name="Jam Artist", name_key="jam artist")
        db.add(artist)
        await db.flush()
        album = Album(title="Jam Album", title_key="jam album", artist_id=artist.id)
        db.add(album)
        await db.flush()
        tracks = [
            Track(
                title=f"Song {i}",
                artist_id=artist.id,
                album_id=album.id,
                artist_credit="Jam Artist",
                path=f"jam/{uuid.uuid4()}.flac",
                duration=100 + i,
            )
            for i in range(4)
        ]
        db.add_all(tracks)
        await db.commit()
        ids = [str(t.id) for t in tracks]
    yield SimpleNamespace(client=client, hub=hub, clock=clock, ids=ids, **users)
    await hub.stop()


async def start(env: SimpleNamespace, **body: object) -> dict:
    response = await env.client.post(
        "/api/jam", json={"track_ids": env.ids[:3], "index": 0, "playing": True, **body}, headers=env.host.headers
    )
    assert response.status_code == 200, response.text
    return response.json()


async def join(env: SimpleNamespace, code: str, who: str = "guest") -> httpx.Response:
    return await env.client.post(f"/api/jam/{code}/join", headers=getattr(env, who).headers)


async def test_create_join_leave(env: SimpleNamespace) -> None:
    state = await start(env)
    assert len(state["code"]) == 6 and state["index"] == 0 and state["playing"]
    assert [e["track"]["title"] for e in state["queue"]] == ["Song 0", "Song 1", "Song 2"]
    assert state["members"][0]["is_host"]
    joined = await join(env, state["code"].lower())
    assert joined.status_code == 200 and len(joined.json()["members"]) == 2
    assert (await env.client.get("/api/jam/current", headers=env.guest.headers)).json()["code"] == state["code"]
    assert (await join(env, "ZZZZZZ")).status_code == 404
    assert (await env.client.post("/api/jam/leave", headers=env.guest.headers)).status_code == 204
    assert (await env.client.get("/api/jam/current", headers=env.guest.headers)).status_code == 404
    await join(env, state["code"])
    # The host leaving ends the Jam for everyone.
    await env.client.post("/api/jam/leave", headers=env.host.headers)
    assert (await env.client.get("/api/jam/current", headers=env.guest.headers)).status_code == 404
    assert not env.hub.jams


async def test_codes_unique_and_member_limit(env: SimpleNamespace, monkeypatch: pytest.MonkeyPatch) -> None:
    codes = iter("AAAAAAAAAAAABBBBBB")
    monkeypatch.setattr(jam_service.secrets, "choice", lambda alphabet: next(codes))
    first = await env.hub.create(uuid.uuid4(), "a", [], 0, 0, False)
    second = await env.hub.create(uuid.uuid4(), "b", [], 0, 0, False)
    assert first.code == "AAAAAA" and second.code == "BBBBBB"
    monkeypatch.setattr(jam_service, "MAX_MEMBERS", 1)
    with pytest.raises(JamError) as e:
        await env.hub.join(uuid.uuid4(), "c", "aaaaaa")
    assert e.value.status == 409


async def test_position_and_auto_advance(env: SimpleNamespace) -> None:
    state = await start(env, position_ms=5000)
    jam = env.hub.get(state["code"])
    env.clock.ms += 10_000
    assert jam.position() == 15_000
    host = env.host.id
    await env.hub.command(jam, host, {"cmd": "pause"})
    env.clock.ms += 10_000
    assert jam.position() == 15_000
    await env.hub.command(jam, host, {"cmd": "play"})
    env.clock.ms += 100_000 - 15_000 + 2000
    assert await env.hub.tick(jam)
    assert jam.index == 1 and jam.position() == 2000
    await env.hub.command(jam, host, {"cmd": "jump", "entry_id": jam.queue[2].id})
    env.clock.ms += 200_000
    assert await env.hub.tick(jam)
    assert jam.index == 2 and not jam.playing and jam.position() == 0
    assert not await env.hub.tick(jam)


async def test_commands(env: SimpleNamespace) -> None:
    state = await start(env)
    jam = env.hub.get(state["code"])
    host = env.host.id
    await join(env, state["code"])
    guest = env.guest.id
    await env.hub.command(jam, host, {"cmd": "seek", "position_ms": 50_000})
    assert jam.position() == 50_000
    await env.hub.command(jam, host, {"cmd": "next"})
    assert jam.index == 1 and jam.position() == 0
    env.clock.ms += 5000
    await env.hub.command(jam, host, {"cmd": "previous"})
    assert jam.index == 1 and jam.position() == 0
    await env.hub.command(jam, host, {"cmd": "previous"})
    assert jam.index == 0
    durations = {uuid.UUID(env.ids[3]): 103_000}
    await env.hub.command(jam, guest, {"cmd": "add", "track_ids": [env.ids[3]], "next": True}, durations)
    assert [str(e.track_id) for e in jam.queue] == [env.ids[0], env.ids[3], env.ids[1], env.ids[2]]
    added = jam.queue[1]
    assert added.added_by == guest
    # Members may remove/move only their own entries.
    with pytest.raises(JamError):
        await env.hub.command(jam, guest, {"cmd": "remove", "entry_id": jam.queue[2].id})
    await env.hub.command(jam, guest, {"cmd": "move", "entry_id": added.id, "to_index": 3})
    assert jam.queue[3] is added and jam.index == 0
    await env.hub.command(jam, guest, {"cmd": "remove", "entry_id": added.id})
    assert len(jam.queue) == 3
    # Removing the current entry keeps the index on the following song.
    await env.hub.command(jam, host, {"cmd": "remove", "entry_id": jam.queue[0].id})
    assert jam.index == 0 and str(jam.queue[0].track_id) == env.ids[1]
    with pytest.raises(JamError):
        await env.hub.command(jam, guest, {"cmd": "set_control", "members_control": False})
    await env.hub.command(jam, host, {"cmd": "set_control", "members_control": False})
    with pytest.raises(JamError) as e:
        await env.hub.command(jam, guest, {"cmd": "pause"})
    assert e.value.message == "Steuerung ist für Mitglieder gesperrt"
    await env.hub.command(jam, guest, {"cmd": "add", "track_ids": [env.ids[3]]}, durations)
    with pytest.raises(JamError):
        await env.hub.command(jam, guest, {"cmd": "add", "track_ids": [env.ids[3]], "play": True}, durations)
    await env.hub.command(jam, host, {"cmd": "add", "track_ids": [env.ids[3]], "next": True, "play": True}, durations)
    assert jam.index == 1 and jam.playing and jam.position() == 0 and str(jam.queue[1].track_id) == env.ids[3]
    with pytest.raises(JamError):
        await env.hub.command(jam, guest, {"cmd": "explode"})
    with pytest.raises(JamError):
        await env.hub.command(jam, env.other.id, {"cmd": "play"})


async def test_kick(env: SimpleNamespace) -> None:
    state = await start(env)
    await join(env, state["code"])
    url = f"/api/jam/{state['code']}/kick/{env.guest.id}"
    assert (await env.client.post(url, headers=env.guest.headers)).status_code == 403
    assert (await env.client.post(url, headers=env.host.headers)).status_code == 204
    assert (await env.client.get("/api/jam/current", headers=env.guest.headers)).status_code == 404


async def test_expiry(env: SimpleNamespace) -> None:
    state = await start(env)
    env.clock.ms += IDLE_MS - 1
    assert await env.hub.expire() == 0
    env.clock.ms += 1
    assert await env.hub.expire() == 1
    assert state["code"] not in env.hub.jams


class FakeSocket:
    def __init__(self, language: str = "de") -> None:
        self.headers = {"accept-language": language}
        self.incoming: asyncio.Queue[str | None] = asyncio.Queue()
        self.sent: list[dict] = []
        self.closed: int | None = None
        self.changed = asyncio.Event()

    async def accept(self) -> None:
        pass

    async def send_text(self, text: str) -> None:
        self.sent.append(json.loads(text))
        self.changed.set()

    async def receive_text(self) -> str:
        text = await self.incoming.get()
        if text is None:
            raise WebSocketDisconnect()
        return text

    async def close(self, code: int = 1000) -> None:
        self.closed = code
        self.changed.set()

    async def wait(self, predicate) -> dict:
        async def loop() -> dict:
            while True:
                for message in self.sent:
                    if predicate(message):
                        return message
                self.changed.clear()
                await self.changed.wait()

        return await asyncio.wait_for(loop(), timeout=5)


async def test_websocket(env: SimpleNamespace) -> None:
    rejected = FakeSocket()
    await jam_api.socket(rejected, token="wrong")
    assert rejected.closed == 4401
    not_in_jam = FakeSocket()
    await jam_api.socket(not_in_jam, token=env.guest.token)
    assert not_in_jam.closed == 4404

    state = await start(env)
    await join(env, state["code"])
    host, guest = FakeSocket(), FakeSocket("en")
    tasks = [
        asyncio.create_task(jam_api.socket(host, token=env.host.token)),
        asyncio.create_task(jam_api.socket(guest, token=env.guest.token)),
    ]
    await guest.wait(lambda m: m["type"] == "state" and all(x["online"] for x in m["state"]["members"]))
    await guest.incoming.put(json.dumps({"type": "ping", "t": 5}))
    pong = await guest.wait(lambda m: m["type"] == "pong")
    assert pong == {"type": "pong", "t": 5, "server": env.clock.ms}
    await guest.incoming.put(json.dumps({"type": "cmd", "cmd": "add", "track_ids": [env.ids[3]]}))
    await host.wait(lambda m: m["type"] == "state" and len(m["state"]["queue"]) == 4)
    added = await guest.wait(lambda m: m["type"] == "state" and len(m["state"]["queue"]) == 4)
    assert added["state"]["queue"][3]["added_by"]["id"] == str(env.guest.id)
    await host.incoming.put(json.dumps({"type": "cmd", "cmd": "set_control", "members_control": False}))
    await guest.wait(lambda m: m["type"] == "state" and not m["state"]["members_control"])
    await guest.incoming.put(json.dumps({"type": "cmd", "cmd": "pause"}))
    error = await guest.wait(lambda m: m["type"] == "error")
    assert error["message"] == "Playback control is locked for members"
    await env.client.post("/api/jam/leave", headers=env.host.headers)
    await guest.wait(lambda m: m["type"] == "ended")
    await asyncio.wait_for(asyncio.gather(*tasks), timeout=5)
    assert guest.closed == 1000


async def test_deleted_track_hidden(env: SimpleNamespace) -> None:
    state = await start(env, index=2)
    async with SessionLocal() as db:
        track = await db.scalar(select(Track).where(Track.id == uuid.UUID(env.ids[0])))
        await db.delete(track)
        await db.commit()
    current = (await env.client.get("/api/jam/current", headers=env.host.headers)).json()
    assert current["code"] == state["code"]
    assert len(current["queue"]) == 2 and current["index"] == 1
