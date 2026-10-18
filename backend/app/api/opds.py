import hmac
import uuid
from datetime import UTC, datetime
from typing import Annotated
from urllib.parse import quote, urlencode
from xml.etree import ElementTree as ET

from fastapi import APIRouter, Depends, HTTPException, Query, Request, Response
from fastapi.responses import FileResponse
from fastapi.security import HTTPBasic, HTTPBasicCredentials
from sqlalchemy import Select, func, select

from app.api.books import (
    author_entries,
    file_response,
    get_book,
    library_conditions,
    library_order,
    series_entries,
)
from app.deps import DB
from app.i18n import language, translate
from app.models import Book, BookRequest, User
from app.services.server_config import load_config


async def enabled(db: DB) -> None:
    if not (await load_config(db)).books.enabled:
        raise HTTPException(404)


# Plain <feed>/<dc:…>/<opds:…> names instead of ns0:/ns1: prefixes – simple OPDS parsers (KOReader) need them.
ET.register_namespace("", "http://www.w3.org/2005/Atom")
ET.register_namespace("dc", "http://purl.org/dc/terms/")
ET.register_namespace("opds", "http://opds-spec.org/2010/catalog")

router = APIRouter(prefix="/opds", tags=["opds"], dependencies=[Depends(enabled)])


async def authenticate(
    db: DB, credentials: Annotated[HTTPBasicCredentials | None, Depends(HTTPBasic(auto_error=False))]
) -> User:
    user = (
        await db.scalar(select(User).where(func.lower(User.username) == credentials.username.lower()))
        if credentials
        else None
    )
    if (
        user is None
        or user.is_disabled
        or not user.subsonic_password
        or not hmac.compare_digest(user.subsonic_password.encode(), credentials.password.encode())
    ):
        raise HTTPException(
            401, "Benutzername oder Passwort falsch", headers={"WWW-Authenticate": 'Basic realm="Resonance"'}
        )
    return user


Reader = Annotated[User, Depends(authenticate)]


def _tag(name: str) -> str:
    return f"{{http://www.w3.org/2005/Atom}}{name}"


def _text(parent: ET.Element, name: str, value: str) -> None:
    ET.SubElement(parent, _tag(name)).text = value


def _feed(title: str, path: str) -> ET.Element:
    feed = ET.Element(_tag("feed"))
    _text(feed, "id", path)
    _text(feed, "title", title)
    _text(feed, "updated", datetime.now(UTC).isoformat())
    return feed


def _response(feed: ET.Element, kind: str) -> Response:
    return Response(
        ET.tostring(feed, encoding="utf-8", xml_declaration=True),
        media_type=f"application/atom+xml;profile=opds-catalog;kind={kind}",
    )


def _navigation(title: str, path: str, entries: list[tuple[str, str]], acquisition: bool = False) -> Response:
    feed = _feed(title, path)
    for name, href in entries:
        entry = ET.SubElement(feed, _tag("entry"))
        _text(entry, "id", href)
        _text(entry, "title", name)
        _text(entry, "updated", datetime.now(UTC).isoformat())
        ET.SubElement(
            entry,
            _tag("link"),
            href=href,
            type=f"application/atom+xml;profile=opds-catalog;kind={'acquisition' if acquisition or href in {'/opds/new', '/opds/mine'} else 'navigation'}",
        )
    if path == "/opds":
        ET.SubElement(
            feed, _tag("link"), rel="search", type="application/opensearchdescription+xml", href="/opds/search.xml"
        )
    return _response(feed, "navigation")


@router.get("")
async def root(user: Reader, request: Request) -> Response:
    lang = language(request)
    return _navigation(
        translate("Bücher", lang),
        "/opds",
        [
            (translate("Neu hinzugefügt", lang), "/opds/new"),
            (translate("Autoren", lang), "/opds/authors"),
            (translate("Serien", lang), "/opds/series"),
            (translate("Meine Anfragen", lang), "/opds/mine"),
        ],
    )


@router.get("/authors")
async def authors(user: Reader, db: DB, request: Request) -> Response:
    return _navigation(
        translate("Autoren", language(request)),
        "/opds/authors",
        [(entry["name"], f"/opds/authors/{quote(entry['name'], safe='')}") for entry in await author_entries(db)],
        acquisition=True,
    )


@router.get("/series")
async def series(user: Reader, db: DB, request: Request) -> Response:
    return _navigation(
        translate("Serien", language(request)),
        "/opds/series",
        [(entry["name"], f"/opds/series/{quote(entry['name'], safe='')}") for entry in await series_entries(db)],
        acquisition=True,
    )


@router.get("/search.xml")
async def search_description(user: Reader) -> Response:
    # Literal document: ElementTree would prefix the OpenSearch namespace (Atom owns the default one).
    return Response(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<OpenSearchDescription xmlns="http://a9.com/-/spec/opensearch/1.1/">'
        "<ShortName>Resonance</ShortName><Description>Resonance</Description>"
        '<Url type="application/atom+xml;profile=opds-catalog;kind=acquisition" template="/opds/search?q={searchTerms}"/>'
        "</OpenSearchDescription>",
        media_type="application/opensearchdescription+xml",
    )


async def _acquisition(db: DB, request: Request, query: Select[tuple[Book]], page: int) -> Response:
    rows = list(await db.scalars(query.offset((page - 1) * 50).limit(51)))
    feed = _feed(translate("Bücher", language(request)), request.url.path)
    if len(rows) > 50:
        params = dict(request.query_params)
        params["page"] = str(page + 1)
        ET.SubElement(feed, _tag("link"), rel="next", href=f"{quote(request.url.path, safe='/')}?{urlencode(params)}")
    for book in rows[:50]:
        entry = ET.SubElement(feed, _tag("entry"))
        _text(entry, "id", f"urn:uuid:{book.id}")
        _text(entry, "title", book.title)
        for name in book.authors:
            _text(ET.SubElement(entry, _tag("author")), "name", name)
        _text(entry, "updated", book.updated_at.isoformat())
        if book.language:
            ET.SubElement(entry, "{http://purl.org/dc/terms/}language").text = book.language
        if book.year:
            ET.SubElement(entry, "{http://purl.org/dc/terms/}issued").text = str(book.year)
        _text(entry, "summary", (book.description or "")[:1000])
        media_type = {"epub": "application/epub+zip", "pdf": "application/pdf"}.get(
            book.format, "application/x-mobipocket-ebook"
        )
        ET.SubElement(
            entry,
            _tag("link"),
            rel="http://opds-spec.org/acquisition",
            href=f"/opds/books/{book.id}/file",
            type=media_type,
        )
        if book.has_cover:
            for rel in ("http://opds-spec.org/image", "http://opds-spec.org/image/thumbnail"):
                ET.SubElement(entry, _tag("link"), rel=rel, href=f"/opds/books/{book.id}/cover", type="image/jpeg")
    return _response(feed, "acquisition")


@router.get("/new")
async def new(user: Reader, db: DB, request: Request, page: int = Query(1, ge=1)) -> Response:
    return await _acquisition(db, request, select(Book).order_by(*library_order("added")), page)


@router.get("/mine")
async def mine(user: Reader, db: DB, request: Request, page: int = Query(1, ge=1)) -> Response:
    query = (
        select(Book)
        .join(BookRequest, BookRequest.book_id == Book.id)
        .where(BookRequest.user_id == user.id, BookRequest.status == "done")
        .order_by(BookRequest.created_at.desc())
    )
    return await _acquisition(db, request, query, page)


@router.get("/search")
async def search(user: Reader, db: DB, request: Request, q: str = "", page: int = Query(1, ge=1)) -> Response:
    return await _acquisition(
        db, request, select(Book).where(*library_conditions(q)).order_by(*library_order("title")), page
    )


@router.get("/authors/{name}")
async def author(name: str, user: Reader, db: DB, request: Request, page: int = Query(1, ge=1)) -> Response:
    return await _acquisition(
        db, request, select(Book).where(*library_conditions(author=name)).order_by(*library_order("author")), page
    )


@router.get("/series/{name}")
async def series_books(name: str, user: Reader, db: DB, request: Request, page: int = Query(1, ge=1)) -> Response:
    return await _acquisition(
        db, request, select(Book).where(*library_conditions(series=name)).order_by(*library_order("series")), page
    )


@router.get("/books/{id}/file")
async def file(id: uuid.UUID, user: Reader, db: DB) -> FileResponse:
    return file_response(await get_book(db, id))


@router.get("/books/{id}/cover")
async def cover(id: uuid.UUID, user: Reader, db: DB) -> FileResponse:
    return file_response(await get_book(db, id), cover=True)
