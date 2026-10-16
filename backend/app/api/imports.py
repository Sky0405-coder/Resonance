import uuid

from fastapi import APIRouter, HTTPException, Query, Request
from sqlalchemy import func, select

from app.config import get_settings
from app.deps import DB, AdminUser
from app.i18n import language, translate
from app.models import ImportBatch, ImportFile
from app.schemas import ImportBatchIn, ImportBatchOut, ImportFileOut, Page
from app.services import importer
from app.services.scanner import _walk
from app.services.server_config import load_config

router = APIRouter(prefix="/api/admin/imports", tags=["admin"])


def _out(batch: ImportBatch, lang: str) -> ImportBatchOut:
    return ImportBatchOut.model_validate(batch).model_copy(
        update={
            "message": translate(batch.message, lang) if batch.message is not None else None,
            "progress": batch.processed / batch.total if batch.total else 0,
        }
    )


async def _get(db: DB, id: uuid.UUID) -> ImportBatch:
    batch = await db.get(ImportBatch, id)
    if batch is None:
        raise HTTPException(404, "Import nicht gefunden")
    return batch


@router.get("/info")
async def info(admin: AdminUser, db: DB) -> dict:
    cfg = (await load_config(db)).library
    root = get_settings().import_dir
    return {
        "import_dir": str(root),
        "pending_files": len(_walk(root)),
        "acoustid_configured": bool(cfg.acoustid_api_key),
        "import_mode": cfg.import_mode,
    }


@router.post("", response_model=ImportBatchOut, status_code=201)
async def create(body: ImportBatchIn, admin: AdminUser, db: DB, request: Request) -> ImportBatchOut:
    return _out(await importer.start_batch(db, body.kind, admin), language(request))


@router.get("", response_model=list[ImportBatchOut])
async def list_batches(admin: AdminUser, db: DB, request: Request) -> list[ImportBatchOut]:
    rows = await db.scalars(select(ImportBatch).order_by(ImportBatch.created_at.desc()).limit(20))
    return [_out(row, language(request)) for row in rows]


@router.get("/{id}", response_model=ImportBatchOut)
async def detail(id: uuid.UUID, admin: AdminUser, db: DB, request: Request) -> ImportBatchOut:
    return _out(await _get(db, id), language(request))


@router.get("/{id}/files", response_model=Page[ImportFileOut])
async def files(
    id: uuid.UUID,
    admin: AdminUser,
    db: DB,
    request: Request,
    status: str | None = None,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
) -> Page[ImportFileOut]:
    await _get(db, id)
    conditions = [ImportFile.batch_id == id]
    if status:
        conditions.append(ImportFile.status == status)
    total = await db.scalar(select(func.count()).select_from(ImportFile).where(*conditions)) or 0
    rows = await db.scalars(select(ImportFile).where(*conditions).order_by(ImportFile.path).offset(offset).limit(limit))
    return Page(
        items=[
            ImportFileOut.model_validate(row).model_copy(
                update={
                    **{key: (row.meta or {}).get(key) for key in ("title", "artist", "album")},
                    "error": translate(row.error, language(request)) if row.error is not None else None,
                }
            )
            for row in rows
        ],
        total=total,
        offset=offset,
        limit=limit,
    )


@router.post("/{id}/cancel", response_model=ImportBatchOut)
async def cancel(id: uuid.UUID, admin: AdminUser, db: DB, request: Request) -> ImportBatchOut:
    batch = await _get(db, id)
    importer.cancel_batch(batch)
    return _out(batch, language(request))
