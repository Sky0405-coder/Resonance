import asyncio
import hashlib
import io
import logging
import shutil
import zipfile
from pathlib import Path

import httpx
from PIL import Image
from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Book, BookRequest, User
from app.services.books.catalog import lookup_isbn
from app.services.books.epub import FileMeta, epub_cover, read_epub, write_epub
from app.services.books.text import BOOK_FORMATS, author_sort, relpath_for, work_key
from app.services.server_config import load_config

log = logging.getLogger(__name__)


class BookImportError(Exception):
    def __init__(self, message: str, book: Book | None = None) -> None:
        super().__init__(message)
        self.book = book


def validate_file(path: Path) -> None:
    try:
        ext = path.suffix.lower()[1:]
        if ext not in BOOK_FORMATS or path.stat().st_size < 1024:
            raise ValueError()
        if ext == "epub":
            with zipfile.ZipFile(path) as archive:
                archive.getinfo("META-INF/container.xml")
                if archive.testzip() is not None:
                    raise ValueError()
        else:
            with path.open("rb") as file:
                header = file.read(68)
            if (ext == "pdf" and not header.startswith(b"%PDF-")) or (
                ext in {"mobi", "azw3"} and header[60:68] != b"BOOKMOBI"
            ):
                raise ValueError()
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as e:
        raise BookImportError("Keine gültige Buchdatei") from e


def file_hash(path: Path) -> str:
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest()


def library_target(title: str, authors: list[str], ext: str, current: Path | None = None) -> Path:
    target = get_settings().books_dir / "library" / relpath_for(title, authors, ext)
    folder = target.parent
    number = 2
    while target != current and target.parent.exists():
        target = folder.with_name(f"{folder.name} ({number})") / target.name
        number += 1
    return target


def remove_empty_parents(folder: Path, root: Path) -> None:
    while folder != root and folder.is_relative_to(root):
        try:
            folder.rmdir()
        except OSError:
            break
        folder = folder.parent


async def download_cover(url: str | None) -> bytes | None:
    if not url:
        return None
    try:
        async with httpx.AsyncClient(
            timeout=15, follow_redirects=True, headers={"User-Agent": "Resonance/1.0"}
        ) as client:
            async with client.stream("GET", url) as response:
                response.raise_for_status()
                if not response.headers.get("content-type", "").startswith("image/"):
                    return None
                data = bytearray()
                async for chunk in response.aiter_bytes():
                    data.extend(chunk)
                    if len(data) > 5 * 1024**2:
                        return None
                return bytes(data)
    except httpx.HTTPError:
        log.warning("Book cover download failed: %s", url)
        return None


def save_cover(target: Path, data: bytes) -> bool:
    try:
        with Image.open(io.BytesIO(data)) as image:
            image = image.convert("RGB")
            if image.height > 1200:
                image.thumbnail((max(1, int(image.width * 1200 / image.height)), 1200))
            image.save(target.with_name("cover.jpg"), "JPEG")
        return True
    except (OSError, ValueError):
        log.warning("Invalid book cover")
        return False


async def import_book(
    db: AsyncSession,
    source: Path,
    *,
    copy: bool,
    origin: str,
    user: User | None,
    request: BookRequest | None,
    filename: str | None = None,
) -> Book:
    await asyncio.to_thread(validate_file, source)
    source_sha = await asyncio.to_thread(file_hash, source)
    existing = await db.scalar(select(Book).where(or_(Book.sha256 == source_sha, Book.source_sha256 == source_sha)))
    if existing is not None:
        raise BookImportError("Diese Datei ist schon in der Bibliothek", existing)
    ext = source.suffix.lower()[1:]
    file_meta = await asyncio.to_thread(read_epub, source) if ext == "epub" else FileMeta()
    lookup = await lookup_isbn(await load_config(db), file_meta.isbn) if file_meta.isbn else None
    stem = Path(filename or source.name).stem
    fallback = {"title": stem, "authors": []}
    if " - " in stem:
        author, title = stem.split(" - ", 1)
        fallback = {"title": title.strip(), "authors": [author.strip()] if author.strip() else []}
    fields = (
        "title",
        "subtitle",
        "authors",
        "series",
        "series_index",
        "language",
        "isbn",
        "publisher",
        "year",
        "description",
    )
    values = {}
    for field in fields:
        # The file knows its language better than the request ("de"/"en" wish, or "any").
        sources = (file_meta, lookup, request) if field == "language" else (request, file_meta, lookup)
        choices = [getattr(item, field, None) for item in sources] + [fallback.get(field)]
        values[field] = next((value for value in choices if value not in (None, "", [], "any")), None)
    values["authors"] = values["authors"] or []
    catalog_ref = (request.catalog_ref if request else None) or (lookup.ref if lookup else None)
    book = Book(
        **values,
        catalog_ref=catalog_ref,
        author_sort=author_sort(values["authors"]),
        match_key=work_key(values["title"], values["authors"]),
        format=ext,
        source=origin,
        source_sha256=source_sha,
        added_by_id=user.id if user else request.user_id if request else None,
        has_cover=False,
    )
    target = library_target(book.title, book.authors, ext)
    target.parent.mkdir(parents=True, exist_ok=True)
    temp = target.with_name(f".{target.name}.part")
    try:
        await asyncio.to_thread(shutil.copy2 if copy else shutil.move, source, temp)
        temp.replace(target)
        if ext == "epub":
            await asyncio.to_thread(write_epub, target, book)
        book.sha256 = await asyncio.to_thread(file_hash, target)
        book.size = target.stat().st_size
        book.path = str(target.relative_to(get_settings().books_dir / "library"))
        cover = await download_cover(request.cover_url if request else None)
        if cover:
            book.has_cover = await asyncio.to_thread(save_cover, target, cover)
        if not book.has_cover and ext == "epub":
            cover = await asyncio.to_thread(epub_cover, target)
            if cover:
                book.has_cover = await asyncio.to_thread(save_cover, target, cover)
        if not book.has_cover and lookup:
            cover = await download_cover(lookup.cover_url)
            if cover:
                book.has_cover = await asyncio.to_thread(save_cover, target, cover)
        db.add(book)
        await db.commit()
    except Exception:
        await db.rollback()
        if not copy and not source.exists():
            restore = target if target.exists() else temp
            if restore.exists():
                await asyncio.to_thread(shutil.move, restore, source)
        target.unlink(missing_ok=True)
        temp.unlink(missing_ok=True)
        target.with_name("cover.jpg").unlink(missing_ok=True)
        remove_empty_parents(target.parent, get_settings().books_dir / "library")
        raise
    return book
