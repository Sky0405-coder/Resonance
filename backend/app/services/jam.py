"""Jam: users of this server listen together with a shared queue.

State lives in memory only: the server runs a single uvicorn process, so one hub sees every connection. A restart
ends all Jams (clients notice the closed socket and clear their Jam state).
"""

import asyncio
import contextlib
import logging
import secrets
import time
import uuid
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field

log = logging.getLogger(__name__)

CODE_ALPHABET = "0123456789"
MAX_MEMBERS = 20
MAX_QUEUE = 500
IDLE_MS = 10 * 60 * 1000
# A "previous" press later than this restarts the current song instead.
RESTART_MS = 3000

HOST_ONLY = "Nur der Host darf das"
CONTROL_LOCKED = "Steuerung ist für Mitglieder gesperrt"


def now_ms() -> int:
    return int(time.time() * 1000)


class JamError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


@dataclass
class Member:
    id: uuid.UUID
    name: str
    joined_at_ms: int


@dataclass
class Entry:
    id: str
    track_id: uuid.UUID
    duration_ms: int
    added_by: uuid.UUID


# Called with the Jam after every change; `ended` is True when the Jam is gone (or the user was removed).
Listener = Callable[["Jam", bool], Awaitable[None]]


@dataclass
class Jam:
    code: str
    host_id: uuid.UUID
    members: dict[uuid.UUID, Member] = field(default_factory=dict)
    queue: list[Entry] = field(default_factory=list)
    index: int = -1
    playing: bool = False
    position_ms: int = 0
    updated_at_ms: int = 0
    members_control: bool = True
    version: int = 0
    # user id -> listeners (one per open WebSocket)
    connections: dict[uuid.UUID, set[Listener]] = field(default_factory=dict)
    idle_since_ms: int = 0
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)
    advance_task: asyncio.Task | None = None

    def position(self, now: int | None = None) -> int:
        if not self.playing:
            return self.position_ms
        return self.position_ms + max(0, (now if now is not None else now_ms()) - self.updated_at_ms)

    def freeze(self, now: int) -> None:
        self.position_ms = self.position(now)
        self.updated_at_ms = now

    def online(self, user_id: uuid.UUID) -> bool:
        return bool(self.connections.get(user_id))

    def current(self) -> Entry | None:
        return self.queue[self.index] if 0 <= self.index < len(self.queue) else None


class Hub:
    def __init__(self) -> None:
        self.jams: dict[str, Jam] = {}
        self.by_user: dict[uuid.UUID, str] = {}
        self._sweeper: asyncio.Task | None = None

    # --- lookup -------------------------------------------------------------------------------------------------

    def of_user(self, user_id: uuid.UUID) -> Jam | None:
        code = self.by_user.get(user_id)
        return self.jams.get(code) if code else None

    def get(self, code: str) -> Jam:
        jam = self.jams.get(code.strip().upper())
        if jam is None:
            raise JamError(404, "Jam nicht gefunden")
        return jam

    def _new_code(self) -> str:
        while True:
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(6))
            if code not in self.jams:
                return code

    # --- membership ---------------------------------------------------------------------------------------------

    async def create(
        self,
        user_id: uuid.UUID,
        name: str,
        entries: list[tuple[uuid.UUID, int]],
        index: int,
        position_ms: int,
        playing: bool,
    ) -> Jam:
        await self.leave(user_id)
        now = now_ms()
        jam = Jam(code=self._new_code(), host_id=user_id, updated_at_ms=now, idle_since_ms=now)
        jam.members[user_id] = Member(user_id, name, now)
        jam.queue = [Entry(uuid.uuid4().hex, track_id, duration, user_id) for track_id, duration in entries[:MAX_QUEUE]]
        if jam.queue:
            jam.index = min(max(index, 0), len(jam.queue) - 1)
            jam.position_ms = max(0, position_ms)
            jam.playing = playing
        self.jams[jam.code] = jam
        self.by_user[user_id] = jam.code
        self._schedule_advance(jam)
        return jam

    async def join(self, user_id: uuid.UUID, name: str, code: str) -> Jam:
        jam = self.get(code)
        if user_id in jam.members:
            return jam
        if len(jam.members) >= MAX_MEMBERS:
            raise JamError(409, "Jam ist voll")
        await self.leave(user_id)
        async with jam.lock:
            jam.members[user_id] = Member(user_id, name, now_ms())
            self.by_user[user_id] = jam.code
            jam.version += 1
        await self.broadcast(jam)
        return jam

    async def leave(self, user_id: uuid.UUID) -> None:
        jam = self.of_user(user_id)
        if jam is None:
            return
        if jam.host_id == user_id:
            await self.end(jam)
            return
        await self._remove(jam, user_id)

    async def kick(self, host_id: uuid.UUID, code: str, user_id: uuid.UUID) -> None:
        jam = self.get(code)
        if jam.host_id != host_id:
            raise JamError(403, HOST_ONLY)
        if user_id == host_id or user_id not in jam.members:
            raise JamError(404, "Mitglied nicht gefunden")
        await self._remove(jam, user_id)

    async def _remove(self, jam: Jam, user_id: uuid.UUID) -> None:
        async with jam.lock:
            jam.members.pop(user_id, None)
            if self.by_user.get(user_id) == jam.code:
                del self.by_user[user_id]
            listeners = jam.connections.pop(user_id, set())
            jam.version += 1
        for listener in listeners:
            await _call(listener, jam, True)
        await self.broadcast(jam)

    async def end(self, jam: Jam) -> None:
        if self.jams.get(jam.code) is not jam:
            return
        del self.jams[jam.code]
        for user_id in list(jam.members):
            if self.by_user.get(user_id) == jam.code:
                del self.by_user[user_id]
        if jam.advance_task is not None:
            jam.advance_task.cancel()
        listeners = [listener for group in jam.connections.values() for listener in group]
        jam.connections.clear()
        for listener in listeners:
            await _call(listener, jam, True)

    # --- connections --------------------------------------------------------------------------------------------

    def connect(self, jam: Jam, user_id: uuid.UUID, listener: Listener) -> None:
        jam.connections.setdefault(user_id, set()).add(listener)

    async def disconnect(self, jam: Jam, user_id: uuid.UUID, listener: Listener) -> None:
        group = jam.connections.get(user_id)
        if group is None or listener not in group:
            return
        group.discard(listener)
        if not group:
            del jam.connections[user_id]
            jam.version += 1
            if not jam.connections:
                jam.idle_since_ms = now_ms()
            await self.broadcast(jam)

    async def broadcast(self, jam: Jam) -> None:
        for listener in [listener for group in list(jam.connections.values()) for listener in list(group)]:
            await _call(listener, jam, False)

    # --- commands -----------------------------------------------------------------------------------------------

    async def command(
        self, jam: Jam, user_id: uuid.UUID, cmd: dict, tracks: dict[uuid.UUID, int] | None = None
    ) -> None:
        """Apply one command. `tracks` maps the track ids of an `add` command to their duration in ms."""
        name = cmd.get("cmd")
        is_host = user_id == jam.host_id
        async with jam.lock:
            if user_id not in jam.members:
                raise JamError(403, "Nicht in diesem Jam")
            now = now_ms()
            jam.freeze(now)
            if (
                (name in {"play", "pause", "seek", "next", "previous", "jump"} or (name == "add" and cmd.get("play")))
                and not is_host
                and not jam.members_control
            ):
                raise JamError(403, CONTROL_LOCKED)
            if name == "play":
                if jam.current() is None and jam.queue:
                    jam.index, jam.position_ms = 0, 0
                jam.playing = jam.current() is not None
            elif name == "pause":
                jam.playing = False
            elif name == "seek":
                entry = jam.current()
                if entry is not None:
                    jam.position_ms = min(max(0, int(cmd.get("position_ms", 0))), entry.duration_ms)
            elif name == "next":
                self._go(jam, jam.index + 1)
            elif name == "previous":
                if jam.position_ms > RESTART_MS or jam.index <= 0:
                    jam.position_ms = 0
                else:
                    self._go(jam, jam.index - 1)
            elif name == "jump":
                position = self._find(jam, cmd.get("entry_id"))
                jam.index, jam.position_ms = position, 0
                jam.playing = True
            elif name == "add":
                ids = [uuid.UUID(str(i)) for i in cmd.get("track_ids", [])]
                new = [
                    Entry(uuid.uuid4().hex, track_id, tracks[track_id], user_id)
                    for track_id in ids
                    if tracks is not None and track_id in tracks
                ][: MAX_QUEUE - len(jam.queue)]
                at = jam.index + 1 if cmd.get("next") and jam.index >= 0 else len(jam.queue)
                jam.queue[at:at] = new
                if new and cmd.get("play"):
                    # "Play this now": like tapping a song while in the Jam.
                    jam.index, jam.position_ms, jam.playing = at, 0, True
                elif jam.index < 0 and new:
                    jam.index, jam.position_ms = 0, 0
            elif name == "remove":
                position = self._find(jam, cmd.get("entry_id"))
                if not is_host and jam.queue[position].added_by != user_id:
                    raise JamError(403, HOST_ONLY)
                del jam.queue[position]
                if position < jam.index:
                    jam.index -= 1
                elif position == jam.index:
                    jam.position_ms = 0
                    if jam.index >= len(jam.queue):
                        jam.index = len(jam.queue) - 1
                        jam.playing = False
                if not jam.queue:
                    jam.index, jam.playing = -1, False
            elif name == "move":
                position = self._find(jam, cmd.get("entry_id"))
                if not is_host and jam.queue[position].added_by != user_id:
                    raise JamError(403, HOST_ONLY)
                current = jam.current()
                entry = jam.queue.pop(position)
                to = min(max(0, int(cmd.get("to_index", 0))), len(jam.queue))
                jam.queue.insert(to, entry)
                if current is not None:
                    jam.index = jam.queue.index(current)
            elif name == "set_control":
                if not is_host:
                    raise JamError(403, HOST_ONLY)
                jam.members_control = bool(cmd.get("members_control"))
            else:
                raise JamError(422, "Unbekannter Befehl")
            jam.version += 1
            self._schedule_advance(jam)
        await self.broadcast(jam)

    @staticmethod
    def _find(jam: Jam, entry_id: object) -> int:
        for i, entry in enumerate(jam.queue):
            if entry.id == entry_id:
                return i
        raise JamError(404, "Song nicht in der Warteschlange")

    @staticmethod
    def _go(jam: Jam, index: int) -> None:
        if index >= len(jam.queue):
            # End of the queue: stop at the start of the last song.
            jam.index = len(jam.queue) - 1
            jam.position_ms = 0
            jam.playing = False
            return
        jam.index, jam.position_ms = max(index, 0), 0

    # --- automatic advance + expiry -----------------------------------------------------------------------------

    async def tick(self, jam: Jam) -> bool:
        """Move to the next song when the current one has ended. Returns True when something changed."""
        async with jam.lock:
            entry = jam.current()
            now = now_ms()
            if entry is None or not jam.playing or jam.position(now) < entry.duration_ms:
                return False
            overshoot = jam.position(now) - entry.duration_ms
            jam.updated_at_ms = now
            self._go(jam, jam.index + 1)
            if jam.playing:
                jam.position_ms = min(overshoot, jam.queue[jam.index].duration_ms)
            jam.version += 1
            self._schedule_advance(jam)
        await self.broadcast(jam)
        return True

    def _schedule_advance(self, jam: Jam) -> None:
        if jam.advance_task is not None and jam.advance_task is not asyncio.current_task():
            jam.advance_task.cancel()
        jam.advance_task = None
        entry = jam.current()
        if entry is None or not jam.playing:
            return
        try:
            loop = asyncio.get_running_loop()
        except RuntimeError:
            return
        delay = max(0, entry.duration_ms - jam.position()) / 1000

        async def run() -> None:
            await asyncio.sleep(delay)
            try:
                await self.tick(jam)
            except Exception:
                log.exception("Jam advance failed")

        jam.advance_task = loop.create_task(run())

    async def expire(self) -> int:
        now = now_ms()
        stale = [jam for jam in self.jams.values() if not jam.connections and now - jam.idle_since_ms >= IDLE_MS]
        for jam in stale:
            await self.end(jam)
        return len(stale)

    async def _sweep(self) -> None:
        while True:
            await asyncio.sleep(60)
            try:
                await self.expire()
            except Exception:
                log.exception("Jam expiry failed")

    async def start(self) -> None:
        if self._sweeper is None or self._sweeper.done():
            self._sweeper = asyncio.create_task(self._sweep())

    async def stop(self) -> None:
        tasks = [t for t in [self._sweeper, *(j.advance_task for j in self.jams.values())] if t is not None]
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        self._sweeper = None


async def _call(listener: Listener, jam: Jam, ended: bool) -> None:
    with contextlib.suppress(Exception):
        await listener(jam, ended)


hub = Hub()
