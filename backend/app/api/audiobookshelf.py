from datetime import UTC, datetime, timedelta

import httpx
from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

from app.deps import DB, AdminUser, CurrentUser
from app.i18n import language, translate
from app.models import AudiobookshelfAccount
from app.services import audiobookshelf as abs_service
from app.services.server_config import AudiobookshelfConfig, load_config

router = APIRouter(prefix="/api/abs", tags=["audiobookshelf"])
admin_router = APIRouter(prefix="/api/admin/abs", tags=["admin"])


class _LoginIn(BaseModel):
    username: str = Field(min_length=1, max_length=256)
    password: str = Field(min_length=1, max_length=1024)


def _status(cfg: AudiobookshelfConfig, account: AudiobookshelfAccount | None) -> dict:
    return {
        "enabled": cfg.enabled,
        "url": cfg.url,
        "linked": account is not None,
        "username": account.abs_username if account else None,
    }


def _configured(cfg: AudiobookshelfConfig) -> None:
    if not cfg.enabled or not cfg.url:
        raise HTTPException(409, "Audiobookshelf ist nicht eingerichtet")


@router.get("/status")
async def abs_status(user: CurrentUser, db: DB) -> dict:
    cfg = (await load_config(db)).audiobookshelf
    return _status(cfg, await db.get(AudiobookshelfAccount, user.id))


@router.post("/login")
async def abs_login(body: _LoginIn, user: CurrentUser, db: DB) -> dict:
    cfg = (await load_config(db)).audiobookshelf
    _configured(cfg)
    try:
        abs_user = await abs_service.login(cfg, body.username, body.password)
    except abs_service.ABSError as e:
        raise HTTPException(e.status, e.message) from e
    account = await db.get(AudiobookshelfAccount, user.id)
    if account is None:
        account = AudiobookshelfAccount(user_id=user.id)
        db.add(account)
    account.abs_user_id = abs_user["id"]
    account.abs_username = abs_user["username"]
    account.refresh_token = abs_user["refreshToken"]
    account.access_token = abs_user["accessToken"]
    account.access_expires_at = datetime.now(UTC) + timedelta(minutes=50)
    await db.commit()
    return _status(cfg, account)


@router.delete("/login", status_code=204)
async def abs_logout(user: CurrentUser, db: DB) -> None:
    account = await db.get(AudiobookshelfAccount, user.id)
    if account is not None:
        cfg = (await load_config(db)).audiobookshelf
        try:
            await abs_service._get_client().post(
                f"{cfg.url}/logout", headers={"x-refresh-token": account.refresh_token}, timeout=20
            )
        except httpx.HTTPError:
            pass
        await db.delete(account)
        await db.commit()


@router.api_route("/api/{path:path}", methods=["GET", "POST", "PATCH", "DELETE"])
async def proxy(path: str, request: Request, user: CurrentUser, db: DB) -> StreamingResponse:
    if (
        ".." in path
        or path.startswith("/")
        or path.split("/", 1)[0]
        not in {
            "libraries",
            "items",
            "me",
            "session",
            "series",
            "authors",
            "collections",
            "playlists",
            "search",
        }
    ):
        raise HTTPException(404, "Nicht gefunden")
    cfg = (await load_config(db)).audiobookshelf
    _configured(cfg)
    account = await db.get(AudiobookshelfAccount, user.id)
    if account is None:
        raise HTTPException(409, "Kein Audiobookshelf-Konto verbunden")
    params = [(key, value) for key, value in request.query_params.multi_items() if key != "token"]
    headers = {key: request.headers[key] for key in ("range", "if-none-match") if key in request.headers}
    body = None
    if request.method in {"POST", "PATCH", "DELETE"}:
        body = await request.body()
        if "content-type" in request.headers:
            headers["content-type"] = request.headers["content-type"]
    try:
        response = await abs_service.request(
            db, account, request.method, path, params=params, json=body, headers=headers
        )
    except abs_service.ABSError as e:
        raise HTTPException(e.status, e.message) from e
    forwarded = {
        key: response.headers[key]
        for key in (
            "content-type",
            "content-length",
            "content-range",
            "accept-ranges",
            "etag",
            "cache-control",
            "last-modified",
        )
        if key in response.headers
    }
    return StreamingResponse(
        response.aiter_raw(),
        status_code=response.status_code,
        headers=forwarded,
        background=BackgroundTask(response.aclose),
    )


@admin_router.get("/status")
async def admin_status(admin: AdminUser, db: DB, request: Request) -> dict:
    cfg = (await load_config(db)).audiobookshelf
    if not cfg.url:
        return {"ok": False, "message": translate("Keine Adresse eingetragen", language(request))}
    try:
        response = await abs_service._get_client().get(f"{cfg.url}/status", timeout=20)
        response.raise_for_status()
        version = response.json()["serverVersion"]
        return {"ok": True, "message": f"Version {version}"}
    except (httpx.HTTPError, ValueError, KeyError):
        return {"ok": False, "message": translate("Audiobookshelf nicht erreichbar", language(request))}
