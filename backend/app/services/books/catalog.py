import asyncio
import logging
import re
from xml.etree.ElementTree import Element

import httpx
from defusedxml import ElementTree
from pydantic import BaseModel
from rapidfuzz import fuzz

from app.services.books.epub import strip_html
from app.services.books.text import book_norm, clean_audible_title, isbn13, work_key
from app.services.server_config import ServerConfig

log = logging.getLogger(__name__)


class CatalogBook(BaseModel):
    ref: str
    title: str
    subtitle: str | None = None
    authors: list[str] = []
    series: str | None = None
    series_index: float | None = None
    language: str | None = None
    year: int | None = None
    publisher: str | None = None
    isbn: str | None = None
    description: str | None = None
    cover_url: str | None = None


class BooksError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.message = message


async def google(cfg: ServerConfig, query: str, language: str) -> list[CatalogBook]:
    params = {"q": query, "printType": "books", "maxResults": 20, "key": cfg.books.google_books_api_key}
    if language != "any":
        params["langRestrict"] = language
    async with httpx.AsyncClient(timeout=15, headers={"User-Agent": "Resonance/1.0"}) as client:
        response = await client.get("https://www.googleapis.com/books/v1/volumes", params=params)
        response.raise_for_status()
    results = []
    for item in response.json().get("items", []):
        info = item.get("volumeInfo", {})
        identifiers = info.get("industryIdentifiers", [])
        isbn = next(
            (
                value
                for kind in ("ISBN_13", "ISBN_10")
                for e in identifiers
                if e.get("type") == kind and (value := isbn13(e.get("identifier", "")))
            ),
            None,
        )
        cover = info.get("imageLinks", {}).get("thumbnail")
        results.append(
            CatalogBook(
                ref=f"google:{item['id']}",
                title=info.get("title", ""),
                subtitle=info.get("subtitle"),
                authors=info.get("authors") or [],
                publisher=info.get("publisher"),
                year=int(year) if (year := info.get("publishedDate", "")[:4]).isdigit() else None,
                description=strip_html(info.get("description") or "")[:4000] or None,
                language=info.get("language"),
                isbn=isbn,
                cover_url=cover.replace("http://", "https://", 1).replace("&edge=curl", "") if cover else None,
            )
        )
    return results


async def audible(cfg: ServerConfig, query: str, language: str) -> list[CatalogBook]:
    async with httpx.AsyncClient(timeout=15, headers={"User-Agent": "Resonance/1.0"}) as client:
        response = await client.get(
            "https://api.audible.de/1.0/catalog/products",
            params={
                "keywords": query,
                "num_results": 20,
                "products_sort_by": "Relevance",
                "response_groups": "product_desc,contributors,series,media,product_attrs",
            },
        )
        response.raise_for_status()
    results = []
    for item in response.json().get("products", []):
        if item.get("content_delivery_type") == "PodcastParent":
            continue
        lang = {"german": "de", "english": "en", "french": "fr", "spanish": "es", "italian": "it"}.get(
            (item.get("language") or "").lower()
        )
        if language != "any" and lang and lang != language:
            continue
        series = (item.get("series") or [{}])[0]
        try:
            index = float(series.get("sequence", ""))
        except (ValueError, TypeError):
            index = None
        results.append(
            CatalogBook(
                ref=f"audible:{item['asin']}",
                title=clean_audible_title(item.get("title", "")),
                subtitle=clean_audible_title(item.get("subtitle") or "") or None,
                authors=[
                    a["name"]
                    for a in item.get("authors", [])
                    if not any(
                        w in a["name"].casefold()
                        for w in ("gbr", "gmbh", "verlag", "übersetzer", "translator", "sprecher", "narrator")
                    )
                ],
                series=clean_audible_title(series.get("title") or "") or None,
                series_index=index,
                language=lang,
                year=int(year) if (year := (item.get("release_date") or "")[:4]).isdigit() else None,
                description=strip_html(item.get("publisher_summary") or item.get("merchandising_summary") or "")[:4000]
                or None,
                cover_url=item.get("product_images", {}).get("500"),
            )
        )
    return results


async def dnb(isbn: str) -> CatalogBook | None:
    async with httpx.AsyncClient(timeout=15, headers={"User-Agent": "Resonance/1.0"}) as client:
        response = await client.get(
            "https://services.dnb.de/sru/dnb",
            params={
                "version": "1.1",
                "operation": "searchRetrieve",
                "query": f"num={isbn}",
                "recordSchema": "MARC21-xml",
                "maximumRecords": 1,
            },
        )
        response.raise_for_status()
    root = ElementTree.fromstring(response.content)
    record = next(
        (e for e in root.iter() if e.tag.rsplit("}", 1)[-1] == "record" and e.find("{*}controlfield") is not None), None
    )
    if record is None:
        return None

    def clean(value: str) -> str:
        return value.replace("\u0098", "").replace("\u009c", "").strip()

    def fields(tag: str) -> list[Element]:
        return [e for e in record.findall("{*}datafield") if e.get("tag") == tag]

    def sub(entry: Element, code: str) -> str:
        return next((clean(e.text or "") for e in entry if e.get("code") == code), "")

    def value(tag: str, code: str) -> str:
        return next((text for e in fields(tag) if (text := sub(e, code))), "")

    authors = []
    for tag in ("100", "700"):
        for entry in fields(tag):
            if tag == "700" and sub(entry, "4") != "aut":
                continue
            name = sub(entry, "a")
            if name:
                authors.append(" ".join(reversed([s.strip() for s in name.split(",", 1)])) if "," in name else name)
    try:
        index = float(value("490", "v"))
    except ValueError:
        index = None
    lang = value("041", "a")
    year = value("264", "c") or value("260", "c")
    identifier = next((clean(e.text or "") for e in record.findall("{*}controlfield") if e.get("tag") == "001"), "")
    raw_isbn = value("020", "a")
    return CatalogBook(
        ref=f"dnb:{identifier}",
        title=value("245", "a"),
        subtitle=value("245", "b") or None,
        authors=authors,
        publisher=value("264", "b") or value("260", "b") or None,
        year=int(m[0]) if (m := re.search(r"\d{4}", year)) else None,
        series=value("490", "a") or None,
        series_index=index,
        language={"ger": "de", "eng": "en"}.get(lang, lang[:2] or None),
        isbn=isbn13(raw_isbn) or isbn13(raw_isbn.split(" ", 1)[0]),
    )


async def search(cfg: ServerConfig, query: str, language: str) -> list[CatalogBook]:
    if not query.strip():
        return []
    calls = [audible(cfg, query, language)]
    if cfg.books.google_books_api_key:
        calls.insert(0, google(cfg, query, language))
    responses = await asyncio.gather(*(asyncio.wait_for(call, 15) for call in calls), return_exceptions=True)
    merged: dict[str, CatalogBook] = {}
    successes = 0
    for source_index, rows in enumerate(responses):
        if isinstance(rows, BaseException):
            log.warning("Book catalog source failed: %s", rows)
            continue
        successes += 1
        seen = set()
        for book in rows:
            key = work_key(book.title, book.authors)
            if key in seen and cfg.books.google_books_api_key and source_index == 0:
                continue
            seen.add(key)
            if key not in merged:
                merged[key] = book
            else:
                existing = merged[key]
                for field in ("series", "series_index", "description", "cover_url", "year", "language"):
                    if getattr(existing, field) in (None, ""):
                        setattr(existing, field, getattr(book, field))
    if not successes:
        raise BooksError(502, "Buchkatalog nicht erreichbar")
    # Audible's keyword search is loose ("Der Schwarm" also finds Harry Potter): keep what matches the query.
    wanted = book_norm(query)

    def relevance(book: CatalogBook) -> float:
        return fuzz.token_set_ratio(wanted, book_norm(" ".join([book.title, book.subtitle or "", *book.authors])))

    books = sorted((b for b in merged.values() if relevance(b) >= 70), key=relevance, reverse=True)
    return books[:30]


async def lookup_isbn(cfg: ServerConfig, isbn: str) -> CatalogBook | None:
    if cfg.books.google_books_api_key:
        try:
            rows = await google(cfg, f"isbn:{isbn}", "any")
            if rows:
                return rows[0]
        except Exception:
            log.warning("Google ISBN lookup failed", exc_info=True)
    try:
        return await dnb(isbn)
    except Exception:
        log.warning("DNB ISBN lookup failed", exc_info=True)
        return None
