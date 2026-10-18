import hashlib
import hmac
from datetime import UTC, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.dialects.postgresql import insert

from app.deps import DB
from app.i18n import language, translate
from app.models import BookProgress, User
from app.services.server_config import load_config

router = APIRouter(prefix="/kosync", tags=["kosync"])


class KosyncError(Exception):
    pass


async def error_response(request: Request, exc: KosyncError) -> JSONResponse:
    return JSONResponse({"code": 2001, "message": "Unauthorized"}, status_code=401)


async def enabled(db: DB) -> None:
    if not (await load_config(db)).books.enabled:
        raise HTTPException(404)


async def authenticate(request: Request, db: DB, _: Annotated[None, Depends(enabled)]) -> User:
    username = request.headers.get("x-auth-user", "")
    key = request.headers.get("x-auth-key", "")
    user = await db.scalar(select(User).where(func.lower(User.username) == username.lower()))
    if user is None or user.is_disabled or not user.subsonic_password:
        raise KosyncError()
    expected = hashlib.md5(user.subsonic_password.encode()).hexdigest()
    if not hmac.compare_digest(expected.encode(), key.encode()):
        raise KosyncError()
    return user


SyncUser = Annotated[User, Depends(authenticate)]


class ProgressIn(BaseModel):
    document: str = Field(min_length=1, max_length=64)
    progress: str
    percentage: float = Field(ge=0, le=1)
    device: str = Field(max_length=128)
    device_id: str = Field(max_length=128)


@router.post("/users/create", dependencies=[Depends(enabled)])
async def create(request: Request) -> JSONResponse:
    return JSONResponse(
        {"code": 2002, "message": translate("Registrierung nur in Resonance", language(request))}, status_code=402
    )


@router.get("/users/auth")
async def auth(user: SyncUser) -> dict:
    return {"authorized": "OK"}


@router.put("/syncs/progress")
async def put_progress(body: ProgressIn, user: SyncUser, db: DB) -> dict:
    now = datetime.now(UTC)
    values = body.model_dump()
    await db.execute(
        insert(BookProgress)
        .values(user_id=user.id, **values, updated_at=now)
        .on_conflict_do_update(
            index_elements=[BookProgress.user_id, BookProgress.document], set_={**values, "updated_at": now}
        )
    )
    await db.commit()
    return {"document": body.document, "timestamp": int(now.timestamp())}


@router.get("/syncs/progress/{document}")
async def get_progress(document: str, user: SyncUser, db: DB) -> dict:
    row = await db.get(BookProgress, (user.id, document))
    if row is None:
        return {}
    return {
        "document": row.document,
        "progress": row.progress,
        "percentage": row.percentage,
        "device": row.device,
        "device_id": row.device_id,
        "timestamp": int(row.updated_at.timestamp()),
    }
