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
    sent_at: deque[float] = field(default_factory=deque)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def send(self, message: dict) -> None:
        async with self.lock:
            await self.socket.send_json(message)


class DeviceRegistry:
    def __init__(self) -> None:
        self.users: dict[uuid.UUID, dict[str, Device]] = {}
        self.active: dict[uuid.UUID, str] = {}

    async def broadcast(self, user_id: uuid.UUID, message: dict, exclude: Device | None = None) -> None:
        for device in list(self.users.get(user_id, {}).values()):
            if device is not exclude:
                with contextlib.suppress(Exception):
                    await device.send(message)

    async def devices(self, user_id: uuid.UUID) -> None:
        await self.broadcast(
            user_id,
            {
                "type": "devices",
                "devices": [
                    {"id": d.id, "name": d.name, "kind": d.kind, "active": self.active.get(user_id) == d.id}
                    for d in self.users.get(user_id, {}).values()
                ],
            },
        )

    async def connect(self, user_id: uuid.UUID, device: Device) -> None:
        group = self.users.setdefault(user_id, {})
        previous = group.get(device.id)
        group[device.id] = device
        if previous is not None:
            device.state = previous.state
            with contextlib.suppress(Exception):
                await previous.socket.close(code=4000)
        await self.devices(user_id)
        # New controllers immediately see the current track and can take playback back here.
        for other in list(group.values()):
            if other is not device and other.state is not None:
                await device.send({"type": "state", "device": other.id, "state": other.state})

    async def disconnect(self, user_id: uuid.UUID, device: Device) -> None:
        group = self.users.get(user_id, {})
        if group.get(device.id) is not device:
            return
        del group[device.id]
        if self.active.get(user_id) == device.id:
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
                await self.devices(user_id)
            case "state" if isinstance(message.get("state"), dict):
                now = time.monotonic()
                while device.sent_at and device.sent_at[0] <= now - 1:
                    device.sent_at.popleft()
                if len(device.sent_at) >= 4:
                    return
                device.sent_at.append(now)
                device.state = message["state"]
                await self.broadcast(
                    user_id, {"type": "state", "device": device.id, "state": device.state}, exclude=device
                )


registry = DeviceRegistry()
