import asyncio
import os
import shutil
import uuid
from collections import Counter
from datetime import datetime
from email.message import Message
from pathlib import Path
from typing import Annotated, Literal
from urllib.parse import quote, unquote, urlparse

import httpx
from fastapi import (
    APIRouter,
    Depends,
    File,
    HTTPException,
    Query,
    Request,
    Response,
    UploadFile,
)
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field, HttpUrl
from sqlalchemy import String, cast, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import joinedload

from app.config import get_settings
from app.deps import DB, AdminUser, CurrentUser
from app.i18n import language, translate
from app.models import Book, BookRequest, User
from app.schemas import ORM, Page, UserRef
from app.services.books import catalog
from app.services.books.epub import write_epub
from app.services.books.importer import (
    BookImportError,
    file_hash,
    import_book,
    library_target,
    remove_empty_parents,
    validate_file,
)
from app.services.books.manager import book_manager, create_request
from app.services.books.text import BOOK_FORMATS, author_sort, safe_name, work_key
from app.services.server_config import load_config


async def enabled(request: Request, db: DB) -> None:
    if request.url.path != "/api/books/status" and not (await load_config(db)).books.enabled:
        raise HTTPException(409, "Bücher sind nicht aktiviert")


router = APIRouter(prefix="/api/books", tags=["books"], dependencies=[Depends(enabled)])
admin_router = APIRouter(prefix="/api/admin/books", tags=["books"], dependencies=[Depends(enabled)])

Author = Annotated[str, Field(min_length=1, max_length=256)]


class BookRequestIn(BaseModel):
    ref: str | None = Field(None, max_length=64)
    title: str = Field(min_length=1, max_length=512)
    subtitle: str | None = Field(None, max_length=512)
    authors: list[Author] = Field(default_factory=list, max_length=10)
    series: str | None = Field(None, max_length=512)
    series_index: float | None = None
    isbn: str | None = Field(None, max_length=13)
    publisher: str | None = Field(None, max_length=256)
    year: int | None = None
    description: str | None = Field(None, max_length=4000)
    cover_url: str | None = None
    language: Literal["de", "en", "any"] | None = None


class BookPatch(BaseModel):
    title: str = Field(None, min_length=1, max_length=512)
    subtitle: str | None = Field(None, max_length=512)
    authors: list[Author] = Field(None, max_length=10)
    series: str | None = Field(None, max_length=512)
    series_index: float | None = None
    language: str | None = Field(None, max_length=8)
    isbn: str | None = Field(None, max_length=13)
    publisher: str | None = Field(None, max_length=256)
    year: int | None = None
    description: str | None = Field(None, max_length=4000)


class BookOut(ORM):
    id: uuid.UUID
    title: str
    subtitle: str | None
    authors: list[str]
    author_sort: str
    series: str | None
    series_index: float | None
    language: str | None
    isbn: str | None
    publisher: str | None
    year: int | None
    description: str | None
    catalog_ref: str | None
    match_key: str
    format: str
    size: int
    source_sha256: str
    has_cover: bool
    source: str
    created_at: datetime
    updated_at: datetime
    cover_url: str | None
    file_url: str
    filename: str


class BookRequestOut(ORM):
    id: uuid.UUID
    user_id: uuid.UUID
    catalog_ref: str | None
    match_key: str
    title: str
    subtitle: str | None
    authors: list[str]
    series: str | None
    series_index: float | None
    isbn: str | None
    publisher: str | None
    year: int | None
    description: str | None
    language: str
    cover_url: str | None
    status: str
    torrent_name: str | None
    torrent_hash: str | None
    progress: float
    progress_at: datetime | None
    attempts: int
    error: str | None
    book_id: uuid.UUID | None
    created_at: datetime
    updated_at: datetime
    user: UserRef
    book: BookOut | None


class RejectIn(BaseModel):
    reason: str | None = None


class UrlIn(BaseModel):
    url: HttpUrl


class ImportResult(BaseModel):
    filename: str
    ok: bool
    book: BookOut | None = None
    error: str | None = None


def filename_for(book: Book) -> str:
    author = f"{safe_name(book.authors[0])} - " if book.authors else ""
    return f"{author}{safe_name(book.title)}.{book.format}"


def book_out(book: Book) -> BookOut:
    return BookOut.model_validate(
        {
            **{column.name: getattr(book, column.name) for column in Book.__table__.columns},
            "cover_url": f"/api/books/library/{book.id}/cover" if book.has_cover else None,
            "file_url": f"/api/books/library/{book.id}/file",
            "filename": filename_for(book),
        }
    )


def request_out(row: BookRequest, lang: str) -> BookRequestOut:
    values = {column.name: getattr(row, column.name) for column in BookRequest.__table__.columns}
    values.update(
        user=UserRef.model_validate(row.user),
        book=book_out(row.book) if row.book else None,
        error=translate(row.error, lang) if row.error else row.error,
    )
    return BookRequestOut.model_validate(values)


async def get_book(db: AsyncSession, id: uuid.UUID) -> Book:
    book = await db.get(Book, id)
    if book is None:
        raise HTTPException(404, "Buch nicht gefunden")
    return book


async def get_request(db: AsyncSession, user: User, id: uuid.UUID, lock: bool = False) -> BookRequest:
    query = (
        select(BookRequest)
        .options(joinedload(BookRequest.user), joinedload(BookRequest.book))
        .where(BookRequest.id == id)
    )
    if lock:
        query = query.with_for_update(of=BookRequest)
    row = await db.scalar(query.execution_options(populate_existing=True))
    if row is None or (row.user_id != user.id and not user.is_admin):
        raise HTTPException(404, "Anfrage nicht gefunden")
    return row


def file_response(book: Book, cover: bool = False) -> FileResponse:
    path = get_settings().books_dir / "library" / book.path
    if cover:
        path = path.with_name("cover.jpg")
        if not book.has_cover or not path.is_file():
            raise HTTPException(404, "Cover nicht gefunden")
        return FileResponse(path, media_type="image/jpeg")
    if not path.is_file():
        raise HTTPException(404, "Datei nicht gefunden")
    media_type = {
        "epub": "application/epub+zip",
        "mobi": "application/x-mobipocket-ebook",
        "azw3": "application/x-mobipocket-ebook",
        "pdf": "application/pdf",
    }[book.format]
    return FileResponse(
        path,
        media_type=media_type,
        headers={"Content-Disposition": f"attachment; filename*=UTF-8''{quote(filename_for(book), safe='')}"},
    )


@router.get("/status")
async def status(user: CurrentUser, db: DB) -> dict:
    cfg = await load_config(db)
    return {
        "enabled": cfg.books.enabled,
        "requests_enabled": cfg.books.enabled and cfg.downloads.torrent_enabled,
        "default_language": cfg.books.default_language,
        "can_import": cfg.books.enabled,
    }


@router.get("/catalog/search")
async def catalog_search(
    user: CurrentUser, db: DB, q: str = "", language: Literal["de", "en", "any"] | None = None
) -> list[dict]:
    cfg = await load_config(db)
    try:
        results = await catalog.search(cfg, q, language or cfg.books.default_language)
    except catalog.BooksError as e:
        raise HTTPException(e.status, e.message) from e
    keys = [work_key(book.title, book.authors) for book in results]
    library = dict((await db.execute(select(Book.match_key, Book.id).where(Book.match_key.in_(keys)))).all())
    requests = {
        r.match_key: r
        for r in await db.scalars(
            select(BookRequest).where(
                BookRequest.match_key.in_(keys),
                BookRequest.user_id == user.id,
                BookRequest.status.not_in(["done", "failed", "cancelled", "rejected"]),
            )
        )
    }
    return [
        {
            **book.model_dump(),
            "book_id": library.get(key),
            "request_id": requests[key].id if key in requests else None,
            "request_status": requests[key].status if key in requests else None,
        }
        for book, key in zip(results, keys)
    ]


@router.post("/requests", response_model=BookRequestOut, status_code=201)
async def create(
    body: BookRequestIn, response: Response, http_request: Request, user: CurrentUser, db: DB
) -> BookRequestOut:
    row, created = await create_request(db, user, body.model_dump())
    response.status_code = 201 if created else 200
    return request_out(await get_request(db, user, row.id), language(http_request))


@router.get("/requests", response_model=Page[BookRequestOut])
async def requests(
    user: CurrentUser,
    db: DB,
    http_request: Request,
    scope: Literal["mine", "all"] = "mine",
    status: str | None = None,
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
) -> Page[BookRequestOut]:
    if scope == "all" and not user.is_admin:
        raise HTTPException(403, "Nur für Admins")
    conditions = [] if scope == "all" else [BookRequest.user_id == user.id]
    if status:
        conditions.append(BookRequest.status == status)
    total = await db.scalar(select(func.count()).select_from(BookRequest).where(*conditions)) or 0
    rows = await db.scalars(
        select(BookRequest)
        .options(joinedload(BookRequest.user), joinedload(BookRequest.book))
        .where(*conditions)
        .order_by(BookRequest.created_at.desc())
        .offset(offset)
        .limit(limit)
    )
    return Page(
        items=[request_out(row, language(http_request)) for row in rows], total=total, offset=offset, limit=limit
    )


@router.get("/requests/{id}", response_model=BookRequestOut)
async def request_detail(id: uuid.UUID, user: CurrentUser, db: DB, http_request: Request) -> BookRequestOut:
    return request_out(await get_request(db, user, id), language(http_request))


@router.delete("/requests/{id}", status_code=204)
async def delete_request(id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    row = await get_request(db, user, id, lock=True)
    if row.status not in {"done", "failed", "cancelled", "rejected"}:
        await book_manager.cancel(db, row)
    else:
        await db.delete(row)
        await db.commit()


@router.post("/requests/{id}/retry", response_model=BookRequestOut)
async def retry(id: uuid.UUID, user: CurrentUser, db: DB, http_request: Request) -> BookRequestOut:
    row = await get_request(db, user, id, lock=True)
    if row.status not in {"failed", "cancelled"}:
        raise HTTPException(409, "Anfrage läuft noch")
    row.attempts, row.error, row.status = 0, None, "queued"
    await db.commit()
    book_manager.wake()
    return request_out(await get_request(db, user, id), language(http_request))


@router.post("/requests/{id}/approve", response_model=BookRequestOut)
async def approve(id: uuid.UUID, admin: AdminUser, db: DB, http_request: Request) -> BookRequestOut:
    row = await get_request(db, admin, id, lock=True)
    if row.status != "pending_approval":
        raise HTTPException(409, "Anfrage wartet nicht auf Freigabe")
    row.status = "queued"
    await db.commit()
    book_manager.wake()
    return request_out(await get_request(db, admin, id), language(http_request))


@router.post("/requests/{id}/reject", response_model=BookRequestOut)
async def reject(id: uuid.UUID, body: RejectIn, admin: AdminUser, db: DB, http_request: Request) -> BookRequestOut:
    row = await get_request(db, admin, id, lock=True)
    if row.status != "pending_approval":
        raise HTTPException(409, "Anfrage wartet nicht auf Freigabe")
    row.status, row.error = "rejected", body.reason
    await db.commit()
    return request_out(await get_request(db, admin, id), language(http_request))


def library_conditions(q: str = "", author: str | None = None, series: str | None = None) -> list:
    conditions = []
    if q:
        pattern = f"%{q}%"
        conditions.append(
            or_(
                Book.title.ilike(pattern),
                Book.subtitle.ilike(pattern),
                Book.series.ilike(pattern),
                cast(Book.authors, String).ilike(pattern),
            )
        )
    if author:
        conditions.append(Book.authors.contains([author]))
    if series:
        conditions.append(Book.series == series)
    return conditions


def library_order(sort: str) -> tuple:
    return {
        "added": (Book.created_at.desc(),),
        "title": (Book.title,),
        "author": (Book.author_sort, Book.series, Book.series_index, Book.title),
        "series": (Book.series, Book.series_index, Book.title),
    }[sort]


@router.get("/library", response_model=Page[BookOut])
async def library(
    user: CurrentUser,
    db: DB,
    q: str = "",
    author: str | None = None,
    series: str | None = None,
    sort: Literal["added", "title", "author", "series"] = "added",
    offset: int = Query(0, ge=0),
    limit: int = Query(50, ge=1, le=200),
) -> Page[BookOut]:
    conditions = library_conditions(q, author, series)
    total = await db.scalar(select(func.count()).select_from(Book).where(*conditions)) or 0
    rows = await db.scalars(select(Book).where(*conditions).order_by(*library_order(sort)).offset(offset).limit(limit))
    return Page(items=[book_out(row) for row in rows], total=total, offset=offset, limit=limit)


async def author_entries(db: AsyncSession) -> list[dict]:
    counts = Counter(name for authors in await db.scalars(select(Book.authors)) for name in authors)
    return [{"name": name, "count": count} for name, count in sorted(counts.items(), key=lambda e: e[0].casefold())]


async def series_entries(db: AsyncSession) -> list[dict]:
    counts: dict[str, Counter] = {}
    for name, authors in await db.execute(select(Book.series, Book.authors).where(Book.series.is_not(None))):
        counts.setdefault(name, Counter())[authors[0] if authors else ""] += 1
    return [
        {"name": name, "author": authors.most_common(1)[0][0], "count": sum(authors.values())}
        for name, authors in sorted(counts.items())
    ]


@router.get("/library/authors")
async def authors(user: CurrentUser, db: DB) -> list[dict]:
    return await author_entries(db)


@router.get("/library/series")
async def series(user: CurrentUser, db: DB) -> list[dict]:
    return await series_entries(db)


@router.get("/library/{id}", response_model=BookOut)
async def book_detail(id: uuid.UUID, user: CurrentUser, db: DB) -> BookOut:
    return book_out(await get_book(db, id))


@router.get("/library/{id}/file")
async def book_file(id: uuid.UUID, user: CurrentUser, db: DB) -> FileResponse:
    return file_response(await get_book(db, id))


@router.get("/library/{id}/cover")
async def book_cover(id: uuid.UUID, user: CurrentUser, db: DB) -> FileResponse:
    return file_response(await get_book(db, id), cover=True)


@router.patch("/library/{id}", response_model=BookOut)
async def patch_book(id: uuid.UUID, body: BookPatch, user: CurrentUser, db: DB) -> BookOut:
    book = await get_book(db, id)
    if not user.is_admin and book.added_by_id != user.id:
        raise HTTPException(403, "Keine Berechtigung")
    root = get_settings().books_dir / "library"
    old = root / book.path
    old_title, old_author = book.title, book.authors[:1]
    for name, value in body.model_dump(exclude_unset=True).items():
        setattr(book, name, value)
    book.match_key, book.author_sort = work_key(book.title, book.authors), author_sort(book.authors)
    target = old
    if old_title != book.title or old_author != book.authors[:1]:
        target = library_target(book.title, book.authors, book.format, current=old)
        if target != old:
            target.parent.mkdir(parents=True, exist_ok=True)
            await asyncio.to_thread(shutil.move, old, target)
            if old.with_name("cover.jpg").exists():
                await asyncio.to_thread(shutil.move, old.with_name("cover.jpg"), target.with_name("cover.jpg"))
            remove_empty_parents(old.parent, root)
            book.path = str(target.relative_to(root))
    if book.format == "epub":
        await asyncio.to_thread(write_epub, target, book)
        book.sha256, book.size = await asyncio.to_thread(file_hash, target), target.stat().st_size
    await db.commit()
    await db.refresh(book)
    return book_out(book)


@router.delete("/library/{id}", status_code=204)
async def delete_book(id: uuid.UUID, admin: AdminUser, db: DB) -> None:
    book = await get_book(db, id)
    root = get_settings().books_dir / "library"
    path = root / book.path
    path.unlink(missing_ok=True)
    path.with_name("cover.jpg").unlink(missing_ok=True)
    remove_empty_parents(path.parent, root)
    await db.delete(book)
    await db.commit()


async def import_result(
    db: AsyncSession, user: User, temp: Path, filename: str, origin: str, lang: str
) -> ImportResult:
    try:
        book = await import_book(db, temp, copy=False, origin=origin, user=user, request=None, filename=filename)
        return ImportResult(filename=filename, ok=True, book=book_out(book))
    except BookImportError as e:
        return ImportResult(filename=filename, ok=False, error=translate(str(e), lang))
    finally:
        temp.unlink(missing_ok=True)


@router.post("/import/upload", response_model=list[ImportResult])
async def upload(
    user: CurrentUser, db: DB, http_request: Request, files: Annotated[list[UploadFile], File(max_length=20)]
) -> list[ImportResult]:
    root = get_settings().books_dir / "import" / ".uploads"
    root.mkdir(parents=True, exist_ok=True)
    results = []
    lang = language(http_request)
    for file in files:
        filename = file.filename or ""
        ext = Path(filename).suffix.lower()[1:]
        temp = root / f"{uuid.uuid4()}.{ext}"
        try:
            if ext not in BOOK_FORMATS:
                results.append(
                    ImportResult(filename=filename, ok=False, error=translate("Format wird nicht unterstützt", lang))
                )
                continue
            size = 0
            with temp.open("wb") as output:
                while chunk := await file.read(1024**2):
                    size += len(chunk)
                    if size > 300 * 1024**2:
                        raise BookImportError("Datei ist zu groß")
                    output.write(chunk)
            results.append(await import_result(db, user, temp, filename, "upload", lang))
        except BookImportError as e:
            results.append(ImportResult(filename=filename, ok=False, error=translate(str(e), lang)))
        finally:
            temp.unlink(missing_ok=True)
            await file.close()
    return results


@router.post("/import/url", response_model=ImportResult)
async def url_import(body: UrlIn, user: CurrentUser, db: DB, http_request: Request) -> ImportResult:
    root = get_settings().books_dir / "import" / ".uploads"
    root.mkdir(parents=True, exist_ok=True)
    temp = root / f"{uuid.uuid4()}.download"
    filename = unquote(Path(urlparse(str(body.url)).path).name) or "Buch"
    try:
        try:
            async with httpx.AsyncClient(timeout=60, follow_redirects=True) as client:
                async with client.stream("GET", str(body.url)) as response:
                    response.raise_for_status()
                    message = Message()
                    message["Content-Disposition"] = response.headers.get("content-disposition", "")
                    filename = Path(message.get_filename() or filename).name
                    size = 0
                    with temp.open("wb") as output:
                        async for chunk in response.aiter_bytes():
                            size += len(chunk)
                            if size > 300 * 1024**2:
                                raise BookImportError("Datei ist zu groß")
                            output.write(chunk)
        except httpx.HTTPError as e:
            raise HTTPException(502, "Download fehlgeschlagen") from e
        ext = Path(filename).suffix.lower()[1:]
        if ext not in BOOK_FORMATS:
            for candidate in BOOK_FORMATS:
                renamed = temp.with_suffix(f".{candidate}")
                temp.rename(renamed)
                temp = renamed
                try:
                    await asyncio.to_thread(validate_file, temp)
                    ext = candidate
                    filename = str(Path(filename).with_suffix(f".{ext}"))
                    break
                except BookImportError:
                    continue
            else:
                raise BookImportError("Format wird nicht unterstützt")
        else:
            renamed = temp.with_suffix(f".{ext}")
            temp.rename(renamed)
            temp = renamed
        return await import_result(db, user, temp, filename, "url", language(http_request))
    except BookImportError as e:
        return ImportResult(filename=filename, ok=False, error=translate(str(e), language(http_request)))
    finally:
        temp.unlink(missing_ok=True)


@admin_router.get("/status")
async def admin_status(admin: AdminUser, db: DB, http_request: Request) -> dict:
    cfg = await load_config(db)
    lang = language(http_request)
    results = {}
    for name, function in (("google", catalog.google), ("audible", catalog.audible)):
        if name == "google" and not cfg.books.google_books_api_key:
            results[name] = {"ok": False, "message": translate("Kein Schlüssel eingetragen", lang)}
            continue
        try:
            await function(cfg, "Der Schwarm", cfg.books.default_language)
            results[name] = {"ok": True, "message": "OK"}
        except Exception:
            results[name] = {"ok": False, "message": translate("Buchkatalog nicht erreichbar", lang)}
    root = get_settings().books_dir / "library"
    count = await db.scalar(select(func.count()).select_from(Book)) or 0
    writable = root.is_dir() and os.access(root, os.W_OK)
    results["library"] = {
        "ok": writable,
        "message": translate(f"{count} Bücher" if writable else "Bibliothek nicht beschreibbar", lang),
    }
    return results
