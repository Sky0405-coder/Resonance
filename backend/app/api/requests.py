import uuid
from typing import Literal

from fastapi import APIRouter, HTTPException, Query, Response
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload, selectinload

from app.deps import DB, AdminUser, CurrentUser
from app.models import DownloadItem, DownloadRequest, User
from app.schemas import (
    DownloadItemOut,
    DownloadRequestDetail,
    DownloadRequestOut,
    DownloadSummary,
    Page,
    RejectIn,
    RequestIn,
    UserRef,
)
from app.services.downloads import create_request, manager, recompute_request

router = APIRouter(prefix="/api/requests", tags=["requests"])


def _out(request: DownloadRequest) -> DownloadRequestDetail:
    items = request.items
    progress = sum(
        1 if i.status in {"done", "exists", "failed", "cancelled"} else i.progress if i.status == "downloading" else 0
        for i in items
    )
    return DownloadRequestDetail(
        id=request.id,
        kind=request.kind,
        mb_id=request.mb_id,
        catalog_id=request.catalog_id,
        title=request.title,
        artist=request.artist,
        cover_url=request.cover_url,
        status=request.status,
        is_temporary=request.is_temporary,
        note=request.note,
        torrent_status=request.torrent_status,
        torrent_name=request.torrent_name,
        torrent_progress=request.torrent_progress,
        torrent_error=request.torrent_error,
        created_at=request.created_at,
        updated_at=request.updated_at,
        user=UserRef.model_validate(request.user),
        progress=progress / len(items) if items else 0,
        item_count=len(items),
        done_count=sum(i.status in {"done", "exists"} for i in items),
        failed_count=sum(i.status == "failed" for i in items),
        items=[DownloadItemOut.model_validate(i) for i in items],
    )


async def _get(db: AsyncSession, user: User, id: uuid.UUID, lock: bool = False) -> DownloadRequest:
    query = select(DownloadRequest).options(selectinload(DownloadRequest.items), joinedload(DownloadRequest.user))
    query = query.where(DownloadRequest.id == id)
    if lock:
        query = query.with_for_update(of=DownloadRequest)
    request = await db.scalar(query)
    if request is None or (request.user_id != user.id and not user.is_admin):
        raise HTTPException(404, "Anfrage nicht gefunden")
    return request


@router.post("", response_model=DownloadRequestDetail, status_code=201)
async def create(body: RequestIn, response: Response, user: CurrentUser, db: DB) -> DownloadRequestDetail:
    existing = await db.scalar(
        select(DownloadRequest.id).where(
            DownloadRequest.user_id == user.id,
            DownloadRequest.kind == body.kind,
            DownloadRequest.catalog_id == body.id,
            DownloadRequest.status.in_(["pending_approval", "active"]),
        )
    )
    request = await create_request(db, user, body.kind, body.id, body.temporary)
    if existing == request.id:
        response.status_code = 200
    return _out(request)


@router.get("", response_model=Page[DownloadRequestOut])
async def list_requests(
    user: CurrentUser,
    db: DB,
    scope: Literal["mine", "all"] = "mine",
    state: Literal["open", "finished", "all"] = "all",
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
) -> Page[DownloadRequestOut]:
    if scope == "all" and not user.is_admin:
        raise HTTPException(403, "Nur für Admins")
    conditions = []
    if scope == "mine":
        conditions.append(DownloadRequest.user_id == user.id)
    if state != "all":
        open_state = DownloadRequest.status.in_(["pending_approval", "active"])
        conditions.append(open_state if state == "open" else ~open_state)
    total = await db.scalar(select(func.count()).select_from(DownloadRequest).where(*conditions)) or 0
    rows = await db.scalars(
        select(DownloadRequest)
        .options(selectinload(DownloadRequest.items), joinedload(DownloadRequest.user))
        .where(*conditions)
        .order_by(DownloadRequest.created_at.desc())
        .offset(offset)
        .limit(limit)
    )
    return Page(
        items=[DownloadRequestOut.model_validate(_out(r)) for r in rows], total=total, offset=offset, limit=limit
    )


@router.get("/summary", response_model=DownloadSummary)
async def summary(user: CurrentUser, db: DB) -> DownloadSummary:
    conditions = [] if user.is_admin else [DownloadRequest.user_id == user.id]
    rows = await db.execute(
        select(DownloadItem.status, func.count()).join(DownloadRequest).where(*conditions).group_by(DownloadItem.status)
    )
    counts = dict(rows.all())
    pending = (
        await db.scalar(
            select(func.count())
            .select_from(DownloadRequest)
            .where(*conditions, DownloadRequest.status == "pending_approval")
        )
        or 0
    )
    return DownloadSummary(
        active=sum(counts.get(s, 0) for s in ("searching", "downloading", "processing")),
        queued=counts.get("queued", 0),
        failed=counts.get("failed", 0),
        pending_approval=pending,
    )


@router.get("/{id}", response_model=DownloadRequestDetail)
async def detail(id: uuid.UUID, user: CurrentUser, db: DB) -> DownloadRequestDetail:
    return _out(await _get(db, user, id))


@router.post("/{id}/approve", response_model=DownloadRequestDetail)
async def approve(id: uuid.UUID, admin: AdminUser, db: DB) -> DownloadRequestDetail:
    request = await _get(db, admin, id, lock=True)
    if request.status != "pending_approval":
        raise HTTPException(409, "Anfrage wartet nicht auf Freigabe")
    request.status = "active"
    for item in request.items:
        if item.status == "waiting":
            item.status = "queued"
    await recompute_request(db, request)
    await db.commit()
    manager.wake()
    return _out(request)


@router.post("/{id}/reject", response_model=DownloadRequestDetail)
async def reject(id: uuid.UUID, body: RejectIn, admin: AdminUser, db: DB) -> DownloadRequestDetail:
    request = await _get(db, admin, id, lock=True)
    if request.status != "pending_approval":
        raise HTTPException(409, "Anfrage wartet nicht auf Freigabe")
    request.status = "rejected"
    request.note = body.note
    for item in request.items:
        item.status = "cancelled"
    await recompute_request(db, request)
    await db.commit()
    return _out(request)


@router.post("/{id}/cancel", response_model=DownloadRequestDetail)
async def cancel(id: uuid.UUID, user: CurrentUser, db: DB) -> DownloadRequestDetail:
    request = await _get(db, user, id, lock=True)
    await manager.cancel_request(db, request)
    return _out(request)


@router.post("/{id}/retry", response_model=DownloadRequestDetail)
async def retry(id: uuid.UUID, user: CurrentUser, db: DB) -> DownloadRequestDetail:
    request = await _get(db, user, id, lock=True)
    for item in request.items:
        if item.status == "failed":
            item.status = "queued"
            item.error = None
            item.progress = 0
    await recompute_request(db, request)
    await db.commit()
    manager.wake()
    return _out(request)


@router.delete("/{id}", status_code=204)
async def delete_request(id: uuid.UUID, admin: AdminUser, db: DB) -> None:
    request = await _get(db, admin, id, lock=True)
    if request.status == "active":
        raise HTTPException(409, "Aktive Anfrage kann nicht gelöscht werden")
    await db.delete(request)
    await db.commit()
