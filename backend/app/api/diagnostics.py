"""Playback diagnostics for devices without usable logs (the Samsung TV): clients post player events, the stream
endpoint notes the requests it gets, admins read both. Kept in memory only, the newest entries."""

from collections import deque
from datetime import UTC, datetime
from typing import Any

from fastapi import APIRouter
from pydantic import BaseModel, Field

from app.deps import AdminUser, CurrentUser

router = APIRouter(tags=["diagnostics"])

_entries: deque[dict[str, Any]] = deque(maxlen=1000)


def note(user: str, kind: str, **data: Any) -> None:
    _entries.append({"at": datetime.now(UTC).isoformat(), "user": user, "kind": kind, **data})


class ClientEvents(BaseModel):
    events: list[dict[str, Any]] = Field(max_length=200)


@router.post("/api/diagnostics/events", status_code=204)
async def post_events(body: ClientEvents, user: CurrentUser) -> None:
    for event in body.events:
        note(user.username, "client", **{k: v for k, v in list(event.items())[:20]})


@router.get("/api/admin/diagnostics")
async def get_diagnostics(admin: AdminUser) -> list[dict[str, Any]]:
    return list(_entries)
