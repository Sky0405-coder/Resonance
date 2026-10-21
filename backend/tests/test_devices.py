import uuid
from types import SimpleNamespace

import pytest
from fastapi import WebSocketDisconnect
from fastapi.testclient import TestClient

from app.api import devices as devices_api
from app.main import app
from app.services import devices as devices_service
from app.services.devices import DeviceRegistry


@pytest.fixture
def sockets(monkeypatch: pytest.MonkeyPatch):
    users = {token: SimpleNamespace(user=SimpleNamespace(id=uuid.uuid4())) for token in ("alice", "bob")}

    async def session(db, token):
        return users.get(token)

    registry = DeviceRegistry()
    monkeypatch.setattr(devices_api, "session_for_token", session)
    monkeypatch.setattr(devices_api, "registry", registry)
    # No lifespan: the registry has no background workers and tests must not start download services.
    yield SimpleNamespace(client=TestClient(app), registry=registry, users=users)


def url(device: str, token: str = "alice", kind: str = "desktop") -> str:
    return f"/api/devices/ws?token={token}&device_id={device}&name={device}&kind={kind}"


def test_registration_activate_disconnect(sockets) -> None:
    with sockets.client.websocket_connect(url("pc")) as pc:
        assert pc.receive_json() == {
            "type": "devices", "devices": [{"id": "pc", "name": "pc", "kind": "desktop", "active": False}]
        }
        with sockets.client.websocket_connect(url("phone", kind="phone")) as phone:
            devices = pc.receive_json()
            assert devices == phone.receive_json()
            assert [d["id"] for d in devices["devices"]] == ["pc", "phone"]
            phone.send_json({"type": "activate"})
            active = phone.receive_json()
            assert active == pc.receive_json()
            assert [d["active"] for d in active["devices"]] == [False, True]
            pc.send_json({"type": "activate"})
            assert [d["active"] for d in pc.receive_json()["devices"]] == [True, False]
            phone.receive_json()
            phone.send_json({"type": "activate"})
            phone.receive_json()
            pc.receive_json()
        remaining = pc.receive_json()["devices"]
        assert [d["id"] for d in remaining] == ["pc"]
        assert not remaining[0]["active"]
    assert not sockets.registry.users
    assert not sockets.registry.active


def test_commands_state_and_isolation(sockets) -> None:
    with sockets.client.websocket_connect(url("pc")) as pc:
        pc.receive_json()
        with sockets.client.websocket_connect(url("phone")) as phone:
            pc.receive_json()
            phone.receive_json()
            with sockets.client.websocket_connect(url("stranger", "bob")) as stranger:
                assert len(stranger.receive_json()["devices"]) == 1
                command = {"type": "seek", "position_ms": 1500}
                pc.send_json({"type": "command", "target": "phone", "command": command})
                assert phone.receive_json() == {"type": "command", "from": "pc", "command": command}
                phone.send_json({"type": "state", "state": {"playing": True, "position_ms": 42}})
                expected = {"type": "state", "device": "phone", "state": {"playing": True, "position_ms": 42}}
                assert pc.receive_json() == expected
                stranger.send_json({"type": "command", "target": "phone", "command": command})
                assert stranger.receive_json()["type"] == "error"
                pc.send_json({"type": "command", "target": "missing", "command": command})
                assert pc.receive_json()["type"] == "error"
                # A new controller gets both the device list and the stored playback snapshot.
                with sockets.client.websocket_connect(url("tablet")) as tablet:
                    tablet.receive_json()
                    assert tablet.receive_json() == expected
                    pc.receive_json()
                    phone.receive_json()
                stranger.send_json({"type": "command", "target": "stranger", "command": {"type": "play"}})
                assert stranger.receive_json() == {
                    "type": "command", "from": "stranger", "command": {"type": "play"}
                }


def test_replacement_does_not_remove_new_socket(sockets) -> None:
    with sockets.client.websocket_connect(url("pc")) as old:
        old.receive_json()
        old.send_json({"type": "activate"})
        old.receive_json()
        with sockets.client.websocket_connect(url("pc")) as replacement:
            assert replacement.receive_json()["devices"][0]["active"]
            with pytest.raises(WebSocketDisconnect) as closed:
                old.receive_json()
            assert closed.value.code == 4000
            assert len(sockets.registry.users[sockets.users["alice"].user.id]) == 1
            replacement.send_json({"type": "command", "target": "pc", "command": {"type": "pause"}})
            assert replacement.receive_json()["command"] == {"type": "pause"}


def test_state_rate_limit_and_malformed_messages(sockets, monkeypatch: pytest.MonkeyPatch) -> None:
    clock = [10.0]
    monkeypatch.setattr(devices_service.time, "monotonic", lambda: clock[0])
    with sockets.client.websocket_connect(url("pc")) as pc:
        pc.receive_json()
        with sockets.client.websocket_connect(url("phone")) as phone:
            pc.receive_json()
            phone.receive_json()
            phone.send_text("not json")
            phone.send_json([])
            phone.send_json({"type": "command", "target": []})
            assert phone.receive_json()["type"] == "error"
            for i in range(6):
                phone.send_json({"type": "state", "state": {"position_ms": i}})
            # The following command acts as a barrier after all state messages.
            phone.send_json({"type": "command", "target": "pc", "command": {"type": "pause"}})
            assert [pc.receive_json()["state"]["position_ms"] for _ in range(4)] == [0, 1, 2, 3]
            assert pc.receive_json()["type"] == "command"
            clock[0] += 1
            phone.send_json({"type": "state", "state": {"position_ms": 9}})
            assert pc.receive_json()["state"]["position_ms"] == 9
            device = sockets.registry.users[sockets.users["alice"].user.id]["phone"]
            assert device.state == {"position_ms": 9}


@pytest.mark.parametrize("path,code", [(url("pc", "invalid"), 4401), (url(""), 4400), (url("pc", kind="car"), 4400)])
def test_invalid_connections(sockets, path: str, code: int) -> None:
    with pytest.raises(WebSocketDisconnect) as closed, sockets.client.websocket_connect(path):
        pass
    assert closed.value.code == code
    assert not sockets.registry.users
