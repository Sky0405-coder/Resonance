"""Per-user Connect sockets and playback snapshots, owned by this server process."""

import asyncio
import contextlib
import time
import uuid
from collections import deque
from dataclasses import dataclass, field

from fastapi import WebSocket


@dataclass
class Device:
    id: str
    name: str
    kind: str
    socket: WebSocket
    state: dict | None = None
    state_at: float = 0.0
    sent_at: deque[float] = field(default_factory=deque)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def send(self, message: dict) -> None:
        async with self.lock:
            await self.socket.send_json(message)


# How long the playing device stays listed (with its last playback) after its socket dropped: a phone with the screen
# off loses its connection while Android freezes the app, and the other devices should keep showing (and be able to
# take over) what it played.
AWAY_SECONDS = 6 * 3600


class DeviceRegistry:
    def __init__(self) -> None:
        self.users: dict[uuid.UUID, dict[str, Device]] = {}
        self.active: dict[uuid.UUID, str] = {}
        # The active device of a user after its socket dropped, until it returns or another device plays.
        self.away: dict[uuid.UUID, tuple[Device, float]] = {}

    def _away(self, user_id: uuid.UUID) -> Device | None:
        entry = self.away.get(user_id)
        if entry is None:
            return None
        device, since = entry
        if time.monotonic() - since > AWAY_SECONDS or self.active.get(user_id) != device.id:
            self.away.pop(user_id, None)
            if self.active.get(user_id) == device.id:
                self.active.pop(user_id, None)
            return None
        return device

    async def broadcast(self, user_id: uuid.UUID, message: dict, exclude: Device | None = None) -> None:
        for device in list(self.users.get(user_id, {}).values()):
            if device is not exclude:
                with contextlib.suppress(Exception):
                    await device.send(message)

    async def devices(self, user_id: uuid.UUID) -> None:
        active = self.active.get(user_id)
        listed = [
            {"id": d.id, "name": d.name, "kind": d.kind, "active": active == d.id}
            for d in self.users.get(user_id, {}).values()
        ]
        if (away := self._away(user_id)) is not None:
            listed.append({"id": away.id, "name": away.name, "kind": away.kind, "active": True, "online": False})
        await self.broadcast(user_id, {"type": "devices", "devices": listed})

    async def connect(self, user_id: uuid.UUID, device: Device) -> None:
        group = self.users.setdefault(user_id, {})
        previous = group.get(device.id)
        away = self._away(user_id)
        if away is not None and away.id == device.id:
            # The playing device is back (its last playback included).
            self.away.pop(user_id, None)
            previous = previous or away
        group[device.id] = device
        if previous is not None:
            device.state = previous.state
            device.state_at = previous.state_at
            if previous is not away:
                with contextlib.suppress(Exception):
                    await previous.socket.close(code=4000)
        await self.devices(user_id)
        # New controllers immediately see the current track and can take playback back here.
        away = self._away(user_id)
        for other in [*group.values(), *([away] if away else [])]:
            if other is not device and other.state is not None:
                await device.send({"type": "state", "device": other.id, "state": other.state})

    async def disconnect(self, user_id: uuid.UUID, device: Device) -> None:
        group = self.users.get(user_id, {})
        if group.get(device.id) is not device:
            return
        del group[device.id]
        if self.active.get(user_id) == device.id:
            if device.state is not None and device.state.get("track"):
                # Shown as it was when the connection dropped: paused where it had got to.
                state = dict(device.state)
                if state.get("playing"):
                    elapsed = int((time.monotonic() - device.state_at) * 1000)
                    state["position_ms"] = int(state.get("position_ms") or 0) + elapsed
                    state["playing"] = False
                device.state = state
                self.away[user_id] = (device, time.monotonic())
                await self.broadcast(user_id, {"type": "state", "device": device.id, "state": state})
            else:
                self.active.pop(user_id, None)
        if not group:
            self.users.pop(user_id, None)
        await self.devices(user_id)

    async def message(self, user_id: uuid.UUID, device: Device, message: dict) -> None:
        group = self.users.get(user_id, {})
        if group.get(device.id) is not device:
            return
        match message.get("type"):
            case "command":
                target = message.get("target")
                command = message.get("command")
                receiver = group.get(target) if isinstance(target, str) else None
                if receiver is None:
                    await device.send({"type": "error", "message": "Device unavailable"})
                elif isinstance(command, dict):
                    await receiver.send({"type": "command", "from": device.id, "command": command})
            case "activate":
                self.active[user_id] = device.id
                self.away.pop(user_id, None)
                await self.devices(user_id)
            case "state" if isinstance(message.get("state"), dict):
                now = time.monotonic()
                while device.sent_at and device.sent_at[0] <= now - 1:
                    device.sent_at.popleft()
                if len(device.sent_at) >= 4:
                    return
                device.sent_at.append(now)
                device.state = message["state"]
                device.state_at = now
                await self.broadcast(
                    user_id, {"type": "state", "device": device.id, "state": device.state}, exclude=device
                )


registry = DeviceRegistry()
