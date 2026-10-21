from fastapi import APIRouter, WebSocket, WebSocketDisconnect

from app.db import SessionLocal
from app.deps import session_for_token
from app.services.devices import Device, registry

router = APIRouter(prefix="/api/devices", tags=["devices"])


@router.websocket("/ws")
async def socket(
    websocket: WebSocket, token: str = "", device_id: str = "", name: str = "", kind: str = "desktop"
) -> None:
    async with SessionLocal() as db:
        session = await session_for_token(db, token) if token else None
        user = session.user if session else None
    if user is None:
        await websocket.close(code=4401)
        return
    if not device_id or len(device_id) > 128 or len(name) > 100 or kind not in {"phone", "desktop", "web", "tv"}:
        await websocket.close(code=4400)
        return
    await websocket.accept()
    device = Device(device_id, name.strip() or kind, kind, websocket)
    try:
        await registry.connect(user.id, device)
        while True:
            try:
                message = await websocket.receive_json()
            except ValueError:
                continue
            if isinstance(message, dict):
                await registry.message(user.id, device, message)
    except WebSocketDisconnect:
        pass
    finally:
        await registry.disconnect(user.id, device)
