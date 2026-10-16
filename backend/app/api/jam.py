import asyncio
import contextlib
import json
import uuid

from fastapi import APIRouter, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import Response
from pydantic import BaseModel, Field
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.deps import DB, CurrentUser, session_for_token
from app.i18n import translate
from app.models import Track, User
from app.services.jam import Jam, JamError, hub, now_ms
from app.services.views import track_options, tracks_out

router = APIRouter(prefix="/api/jam", tags=["jam"])


class JamStartIn(BaseModel):
    track_ids: list[uuid.UUID] = Field(default=[], max_length=500)
    index: int = 0
    position_ms: int = Field(0, ge=0)
    playing: bool = False


async def _durations(db: AsyncSession, ids: list[uuid.UUID]) -> dict[uuid.UUID, int]:
    if not ids:
        return {}
    rows = await db.execute(select(Track.id, Track.duration).where(Track.id.in_(ids)))
    return {track_id: int(round((duration or 0) * 1000)) for track_id, duration in rows}


async def jam_state(db: AsyncSession, jam: Jam, viewer: User) -> dict:
    ids = list(dict.fromkeys(entry.track_id for entry in jam.queue))
    tracks = list(await db.scalars(select(Track).options(*track_options()).where(Track.id.in_(ids)))) if ids else []
    outs = {out.id: out for out in await tracks_out(db, viewer, tracks)}
    names = {member.id: member.name for member in jam.members.values()}
    queue = []
    index = jam.index
    for i, entry in enumerate(jam.queue):
        track = outs.get(entry.track_id)
        if track is None:
            # Deleted from the library meanwhile: hide it and keep the index pointing at the same entry.
            if i < jam.index:
                index -= 1
            continue
        queue.append(
            {
                "entry_id": entry.id,
                "added_by": {"id": str(entry.added_by), "name": names.get(entry.added_by, "")},
                "track": track.model_dump(mode="json"),
            }
        )
    host = jam.members.get(jam.host_id)
    return {
        "code": jam.code,
        "host": {"id": str(jam.host_id), "name": host.name if host else ""},
        "members": [
            {"id": str(m.id), "name": m.name, "is_host": m.id == jam.host_id, "online": jam.online(m.id)}
            for m in sorted(jam.members.values(), key=lambda m: (m.id != jam.host_id, m.joined_at_ms))
        ],
        "members_control": jam.members_control,
        "playing": jam.playing,
        "position_ms": jam.position_ms,
        "server_time_ms": jam.updated_at_ms,
        "version": jam.version,
        "index": index if 0 <= index < len(queue) else -1,
        "queue": queue,
    }


def _raise(e: JamError) -> HTTPException:
    return HTTPException(e.status, e.message)


@router.post("")
async def start(body: JamStartIn, user: CurrentUser, db: DB) -> dict:
    durations = await _durations(db, body.track_ids)
    entries = [(track_id, durations[track_id]) for track_id in body.track_ids if track_id in durations]
    jam = await hub.create(user.id, user.display_name, entries, body.index, body.position_ms, body.playing)
    return await jam_state(db, jam, user)


@router.get("/current")
async def current(user: CurrentUser, db: DB) -> dict:
    jam = hub.of_user(user.id)
    if jam is None:
        raise HTTPException(404, "Kein Jam aktiv")
    return await jam_state(db, jam, user)


@router.post("/leave", status_code=204)
async def leave(user: CurrentUser) -> Response:
    await hub.leave(user.id)
    return Response(status_code=204)


@router.post("/{code}/join")
async def join(code: str, user: CurrentUser, db: DB) -> dict:
    try:
        jam = await hub.join(user.id, user.display_name, code)
    except JamError as e:
        raise _raise(e) from e
    return await jam_state(db, jam, user)


@router.post("/{code}/kick/{user_id}", status_code=204)
async def kick(code: str, user_id: uuid.UUID, user: CurrentUser) -> Response:
    try:
        await hub.kick(user.id, code, user_id)
    except JamError as e:
        raise _raise(e) from e
    return Response(status_code=204)


@router.websocket("/ws")
async def socket(websocket: WebSocket, token: str = "") -> None:
    async with SessionLocal() as db:
        session = await session_for_token(db, token) if token else None
        user = session.user if session else None
    if user is None:
        await websocket.close(code=4401)
        return
    jam = hub.of_user(user.id)
    if jam is None:
        await websocket.close(code=4404)
        return
    header = websocket.headers.get("accept-language")
    lang = "de" if header is None or header.split(",", 1)[0].strip().lower().startswith("de") else "en"
    await websocket.accept()
    send_lock = asyncio.Lock()
    closed = asyncio.Event()

    async def send(message: dict) -> None:
        async with send_lock:
            await websocket.send_text(json.dumps(message))

    async def listener(changed: Jam, ended: bool) -> None:
        if ended:
            kicked = hub.jams.get(changed.code) is changed
            with contextlib.suppress(Exception):
                await send({"type": "kicked" if kicked else "ended"})
                await websocket.close(code=1000)
            closed.set()
            return
        async with SessionLocal() as db:
            viewer = await db.get(User, user.id)
            state = await jam_state(db, changed, viewer)
        await send({"type": "state", "state": state})

    hub.connect(jam, user.id, listener)
    try:
        await hub.broadcast(jam)
        while not closed.is_set():
            receive = asyncio.create_task(websocket.receive_text())
            stop = asyncio.create_task(closed.wait())
            done, _ = await asyncio.wait({receive, stop}, return_when=asyncio.FIRST_COMPLETED)
            if receive not in done:
                receive.cancel()
                break
            stop.cancel()
            try:
                message = json.loads(receive.result())
            except ValueError:
                continue
            if not isinstance(message, dict):
                continue
            if message.get("type") == "ping":
                await send({"type": "pong", "t": message.get("t"), "server": now_ms()})
            elif message.get("type") == "cmd":
                try:
                    tracks = None
                    if message.get("cmd") == "add":
                        ids = [uuid.UUID(str(i)) for i in message.get("track_ids", [])][:500]
                        async with SessionLocal() as db:
                            tracks = await _durations(db, ids)
                    await hub.command(jam, user.id, message, tracks)
                except JamError as e:
                    await send({"type": "error", "message": translate(e.message, lang)})
                except (ValueError, TypeError):
                    await send({"type": "error", "message": translate("Unbekannter Befehl", lang)})
    except WebSocketDisconnect:
        pass
    finally:
        await hub.disconnect(jam, user.id, listener)
