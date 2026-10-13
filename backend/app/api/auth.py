from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, HTTPException, Request, status
from sqlalchemy import delete, func, select

from app.config import get_settings
from app.deps import DB, CurrentUser
from app.models import AuthSession, Invite, Role, User
from app.schemas import AuthStatus, LoginIn, RegisterIn, TokenOut, UserOut
from app.security import hash_password, hash_token, new_token, verify_password
from app.services.server_config import load_config

router = APIRouter(prefix="/api/auth", tags=["auth"])


async def _user_count(db: DB) -> int:
    return await db.scalar(select(func.count()).select_from(User)) or 0


async def _issue_session(db: DB, user: User, device_name: str | None) -> TokenOut:
    token = new_token()
    db.add(
        AuthSession(
            user_id=user.id,
            token_hash=hash_token(token),
            device_name=device_name,
            expires_at=datetime.now(UTC) + timedelta(days=get_settings().session_ttl_days),
        )
    )
    user.last_seen_at = datetime.now(UTC)
    await db.commit()
    await db.refresh(user)
    return TokenOut(token=token, user=UserOut.model_validate(user))


@router.get("/status", response_model=AuthStatus)
async def auth_status(db: DB) -> AuthStatus:
    cfg = await load_config(db)
    return AuthStatus(
        server_name=cfg.server_name,
        setup_required=await _user_count(db) == 0,
        registration_mode=cfg.registration.mode,
    )


@router.get("/invites/{token}")
async def check_invite(token: str, db: DB) -> dict:
    invite = await _valid_invite(db, token)
    return {"valid": invite is not None}


async def _valid_invite(db: DB, token: str, *, lock: bool = False) -> Invite | None:
    query = select(Invite).where(Invite.token_hash == hash_token(token))
    # Lock during registration so a link cannot be redeemed twice concurrently.
    invite = await db.scalar(query.with_for_update() if lock else query)
    if invite is None or invite.used_at is not None:
        return None
    if invite.expires_at is not None and invite.expires_at < datetime.now(UTC):
        return None
    return invite


@router.post("/register", response_model=TokenOut, status_code=status.HTTP_201_CREATED)
async def register(body: RegisterIn, db: DB) -> TokenOut:
    first_user = await _user_count(db) == 0
    role = Role.admin if first_user else Role.user
    invite: Invite | None = None

    if not first_user:
        if body.invite:
            invite = await _valid_invite(db, body.invite, lock=True)
            if invite is None:
                raise HTTPException(status.HTTP_400_BAD_REQUEST, "Einladungslink ist ungültig oder abgelaufen")
            role = invite.role
        elif (await load_config(db)).registration.mode != "public":
            raise HTTPException(status.HTTP_403_FORBIDDEN, "Registrierung nur mit Einladungslink möglich")

    if await db.scalar(select(User).where(func.lower(User.username) == body.username.lower())):
        raise HTTPException(status.HTTP_409_CONFLICT, "Benutzername ist bereits vergeben")

    user = User(
        username=body.username,
        display_name=body.display_name or body.username,
        password_hash=hash_password(body.password),
        role=role,
    )
    db.add(user)
    await db.flush()
    if invite is not None:
        invite.used_at = datetime.now(UTC)
        invite.used_by_id = user.id
    return await _issue_session(db, user, body.device_name)


@router.post("/login", response_model=TokenOut)
async def login(body: LoginIn, db: DB) -> TokenOut:
    user = await db.scalar(select(User).where(func.lower(User.username) == body.username.lower()))
    if user is None or not verify_password(user.password_hash, body.password):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Benutzername oder Passwort falsch")
    if user.is_disabled:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Konto ist deaktiviert")
    return await _issue_session(db, user, body.device_name)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
async def logout(request: Request, user: CurrentUser, db: DB) -> None:
    await db.execute(delete(AuthSession).where(AuthSession.id == request.state.session_id))
    await db.commit()
