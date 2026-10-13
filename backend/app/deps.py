from datetime import UTC, datetime, timedelta
from typing import Annotated

from fastapi import Depends, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.db import get_db
from app.models import AuthSession, User
from app.security import hash_token

DB = Annotated[AsyncSession, Depends(get_db)]

# Avoid a DB write on every request just to bump last_used_at.
_TOUCH_INTERVAL = timedelta(minutes=5)


def _extract_token(request: Request, token: str | None) -> str | None:
    auth = request.headers.get("authorization", "")
    if auth.lower().startswith("bearer "):
        return auth[7:].strip()
    # Query-string token: needed for <audio>/image URLs where headers cannot be set (web player).
    return token


async def current_user(
    request: Request,
    db: DB,
    token: Annotated[str | None, Query(include_in_schema=False)] = None,
) -> User:
    raw = _extract_token(request, token)
    if not raw:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Not authenticated")
    session = await db.scalar(
        select(AuthSession).options(joinedload(AuthSession.user)).where(AuthSession.token_hash == hash_token(raw))
    )
    now = datetime.now(UTC)
    if session is None or session.expires_at < now or session.user.is_disabled:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Invalid or expired session")
    if now - session.last_used_at > _TOUCH_INTERVAL:
        session.last_used_at = now
        session.user.last_seen_at = now
        await db.commit()
    request.state.session_id = session.id
    return session.user


async def require_admin(user: Annotated[User, Depends(current_user)]) -> User:
    if not user.is_admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Admin only")
    return user


CurrentUser = Annotated[User, Depends(current_user)]
AdminUser = Annotated[User, Depends(require_admin)]
