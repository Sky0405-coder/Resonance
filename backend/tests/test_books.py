import hashlib
import io
import time
import uuid
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import parse_qs
from xml.etree import ElementTree as ET

import httpx
import pytest
from PIL import Image
from sqlalchemy import select

from app.api import books as books_api
from app.config import get_settings
from app.db import Base, SessionLocal, engine
from app.models import Book, BookRequest, User
from app.services.books import catalog
from app.services.books import manager as manager_module
from app.services.books.epub import read_epub
from app.services.books.importer import BookImportError, file_hash, import_book
from app.services.books.manager import BookManager
from app.services.server_config import BooksConfig, ServerConfig, update_config
from tests.conftest import auth, register
from tests.test_books_epub import make_epub


class Gateway:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.seen: list[httpx.Request] = []
        self.google: dict = {"items": []}
        self.audible: dict = {"products": []}
        self.google_code = self.audible_code = self.category_code = self.download_code = 200
        self.present = True
        self.progress = 0.0
        self.file_entries: list[dict] = []
        self.results = [self.result("first")]
        self.all_rows: list[dict] = []
        self.deleted: list[dict] = []
        self.source = "magnet"
        self.url_content = b"%PDF-" + b"x" * 2048
        self.url_headers: dict = {}
        self.dnb = '<collection xmlns="http://www.loc.gov/MARC21/slim"/>'

    def result(self, guid: str) -> dict:
        return {
            "title": "Frank Schaetzing Der Schwarm german epub",
            "protocol": "torrent",
            "size": 20000,
            "seeders": 5,
            "guid": guid,
            "magnetUrl": "magnet:?xt=urn:btih:book",
            "downloadUrl": "https://prowlarr.test/download",
        }

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.seen.append(request)
        host, path = request.url.host, request.url.path
        if host in {"www.googleapis.com", "api.audible.de", "services.dnb.de"}:
            assert request.headers["user-agent"] == "Resonance/1.0"
            if host == "www.googleapis.com":
                assert request.url.params["key"] == "key"
                return httpx.Response(self.google_code, json=self.google)
            if host == "api.audible.de":
                return httpx.Response(self.audible_code, json=self.audible)
            return httpx.Response(200, text=self.dnb)
        if host == "cover.test":
            buffer = io.BytesIO()
            Image.new("RGB", (8, 1600), "blue").save(buffer, "PNG")
            return httpx.Response(200, content=buffer.getvalue(), headers={"Content-Type": "image/png"})
        if host == "url.test":
            return httpx.Response(self.download_code, content=self.url_content, headers=self.url_headers)
        if path == "/api/v1/search":
            assert request.url.params.get_list("categories") == ["7000", "7020"]
            assert request.url.params["query"] in {"Schätzing Der Schwarm", "Der Schwarm"}
            return httpx.Response(200, json=self.results)
        if path == "/download":
            return httpx.Response(302, headers={"Location": "/redirect"})
        if path == "/redirect":
            if self.source == "redirect":
                return httpx.Response(302, headers={"Location": "magnet:?xt=urn:btih:redirect"})
            return httpx.Response(200, content=b"torrent-bytes")
        if path == "/api/v2/auth/login":
            return httpx.Response(200, text="Ok.")
        if path == "/api/v2/torrents/createCategory":
            assert parse_qs(request.content.decode()) == {
                "category": ["resonance-books"],
                "savePath": ["/data/downloads/books"],
            }
            return httpx.Response(self.category_code)
        if path == "/api/v2/torrents/add":
            assert b"resonance-books" in request.content and b"/data/downloads/books" in request.content
            return httpx.Response(200)
        if path == "/api/v2/torrents/info":
            assert request.url.params["category"] == "resonance-books"
            rows = [{"hash": "hash", "save_path": str(self.root), "progress": self.progress}] if self.present else []
            return httpx.Response(200, json=rows if "tag" in request.url.params else self.all_rows)
        if path == "/api/v2/torrents/files":
            return httpx.Response(200, json=self.file_entries)
        if path == "/api/v2/torrents/delete":
            self.deleted.append(parse_qs(request.content.decode()))
            return httpx.Response(200)
        raise AssertionError(str(request.url))


@pytest.fixture
async def env(
    client: httpx.AsyncClient, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> AsyncIterator[SimpleNamespace]:
    assert engine.url.database == "app_test_11a"
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    root = tmp_path / "books"
    (root / "library").mkdir(parents=True)
    (root / "import").mkdir()
    monkeypatch.setattr(get_settings(), "books_dir", root)
    admin = await register(client, "book-admin")
    await config(
        registration={"mode": "public"},
        books={"enabled": True},
        downloads={"torrent_enabled": True, "prowlarr_api_key": "key"},
    )
    user = await register(client, "book-user")
    other = await register(client, "book-other")
    gateway = Gateway(tmp_path / "torrent")
    factory = httpx.AsyncClient

    def mocked_client(**kwargs: object) -> httpx.AsyncClient:
        kwargs.setdefault("transport", httpx.MockTransport(gateway.handle))
        return factory(**kwargs)

    monkeypatch.setattr(httpx, "AsyncClient", mocked_client)
    monkeypatch.setattr(get_settings(), "prowlarr_url", "https://prowlarr.test")
    monkeypatch.setattr(get_settings(), "qbittorrent_url", "https://qbit.test")
    manager = BookManager()
    monkeypatch.setattr(books_api, "book_manager", manager)
    monkeypatch.setattr(manager_module, "book_manager", manager)
    yield SimpleNamespace(
        client=client, root=root, admin=admin, user=user, other=other, gateway=gateway, manager=manager, tmp=tmp_path
    )
    await manager.stop()


async def config(**values: dict) -> None:
    async with SessionLocal() as db:
        await update_config(db, values)


async def request_book(env: SimpleNamespace, account: dict | None = None, **values: object) -> httpx.Response:
    return await env.client.post(
        "/api/books/requests",
        headers=auth((account or env.admin)["token"]),
        json={"title": "Der Schwarm", "authors": ["Frank Schätzing"], **values},
    )


async def detail(env: SimpleNamespace, id: str | uuid.UUID) -> dict:
    response = await env.client.get(f"/api/books/requests/{id}", headers=auth(env.admin["token"]))
    assert response.status_code == 200, response.text
    return response.json()


async def upload(env: SimpleNamespace, path: Path, account: dict | None = None) -> dict:
    response = await env.client.post(
        "/api/books/import/upload",
        headers=auth((account or env.admin)["token"]),
        files=[("files", (path.name, path.read_bytes()))],
    )
    assert response.status_code == 200, response.text
    return response.json()[0]


def google_item(id: str = "g1", **values: object) -> dict:
    return {
        "id": id,
        "volumeInfo": {
            "title": "Der Schwarm",
            "authors": ["Frank Schätzing"],
            "language": "de",
            "industryIdentifiers": [{"type": "ISBN_10", "identifier": "0306406152"}],
            **values,
        },
    }


def audible_item(id: str = "a1", **values: object) -> dict:
    return {
        "asin": id,
        "title": "Der Schwarm (Ungekürzt)",
        "authors": [{"name": "Frank Schätzing"}, {"name": "Verlag GmbH"}],
        "language": "german",
        "publisher_name": "Audio Publisher",
        "series": [{"title": "Serie (Hörbuch)", "sequence": "1.5"}],
        "publisher_summary": "<p>Summary</p>",
        "product_images": {"500": "https://cover.test/book"},
        "release_date": "2004-03-10",
        **values,
    }


async def test_catalog_merge(env: SimpleNamespace) -> None:
    await config(books={"google_books_api_key": "key"})
    env.gateway.google = {
        "items": [
            google_item(),
            google_item("duplicate", description="Wrong"),
            google_item("g2", title="Schwarm Other", imageLinks={"thumbnail": "http://cover.test/x?x=1&edge=curl"}),
            google_item("g3", title="Unrelated"),
        ]
    }
    env.gateway.audible = {
        "products": [
            audible_item(),
            audible_item("a2", title="English Book", language="english"),
            audible_item("podcast", content_delivery_type="PodcastParent"),
            audible_item("a3", title="Third Schwarm", series=[]),
        ]
    }
    response = await env.client.get("/api/books/catalog/search?q=Schwarm", headers=auth(env.user["token"]))
    rows = response.json()
    # "Unrelated" does not match the query and is dropped (Audible's keyword search is loose).
    assert [r["ref"] for r in rows] == ["google:g1", "google:g2", "audible:a3"]
    assert rows[0]["series"] == "Serie" and rows[0]["series_index"] == 1.5
    assert rows[0]["description"] == "Summary" and rows[0]["isbn"] == "9780306406157" and rows[0]["publisher"] is None
    assert rows[1]["cover_url"] == "https://cover.test/x?x=1"
    created = (await request_book(env, env.user)).json()
    response = await env.client.get("/api/books/catalog/search?q=Schwarm", headers=auth(env.user["token"]))
    assert response.json()[0]["request_id"] == created["id"]
    await upload(env, make_epub(env.tmp / "catalog.epub", title="Der Schwarm", author="Frank Schätzing"))
    response = await env.client.get("/api/books/catalog/search?q=Schwarm", headers=auth(env.user["token"]))
    assert response.json()[0]["book_id"]


async def test_catalog_sources_and_failures(env: SimpleNamespace) -> None:
    env.gateway.audible = {"products": [audible_item()]}
    cfg = ServerConfig(books=BooksConfig(enabled=True))
    assert len(await catalog.search(cfg, "Schwarm", "de")) == 1
    assert not any(r.url.host == "www.googleapis.com" for r in env.gateway.seen)
    cfg.books.google_books_api_key = "key"
    env.gateway.google_code = 503
    assert len(await catalog.search(cfg, "Schwarm", "de")) == 1
    env.gateway.google_code, env.gateway.audible_code = 200, 503
    env.gateway.google = {"items": [google_item()]}
    assert len(await catalog.search(cfg, "Schwarm", "de")) == 1
    env.gateway.google_code = 503
    await config(books={"google_books_api_key": "key"})
    response = await env.client.get("/api/books/catalog/search?q=Schwarm", headers=auth(env.admin["token"]))
    assert response.status_code == 502
    assert await catalog.search(cfg, "   ", "de") == []
    env.gateway.audible_code = 200
    env.gateway.audible = {"products": [audible_item(language="english")]}
    assert len(await catalog.audible(cfg, "x", "any")) == 1
    assert await catalog.audible(cfg, "x", "de") == []


async def test_isbn_lookup(env: SimpleNamespace) -> None:
    cfg = ServerConfig(books=BooksConfig(google_books_api_key="key"))
    env.gateway.google = {"items": [google_item()]}
    assert (await catalog.lookup_isbn(cfg, "9780306406157")).ref == "google:g1"
    env.gateway.google = {"items": []}
    env.gateway.dnb = """<collection xmlns="http://www.loc.gov/MARC21/slim"><record><controlfield tag="001">123</controlfield>
    <datafield tag="245"><subfield code="a">&#x98;Der&#x9c; Schwarm</subfield><subfield code="b">Roman</subfield></datafield>
    <datafield tag="100"><subfield code="a">Schätzing, Frank</subfield></datafield>
    <datafield tag="700"><subfield code="a">Other, Author</subfield><subfield code="4">aut</subfield></datafield>
    <datafield tag="260"><subfield code="b">Publisher</subfield><subfield code="c">[2004]</subfield></datafield>
    <datafield tag="490"><subfield code="a">Series</subfield><subfield code="v">3.5</subfield></datafield>
    <datafield tag="041"><subfield code="a">ger</subfield></datafield><datafield tag="020"><subfield code="a">978-0-306-40615-7</subfield></datafield></record></collection>"""
    row = await catalog.lookup_isbn(cfg, "9780306406157")
    assert row.ref == "dnb:123" and row.title == "Der Schwarm" and row.subtitle == "Roman"
    assert row.authors == ["Frank Schätzing", "Author Other"]
    assert row.publisher == "Publisher" and row.year == 2004 and row.series_index == 3.5 and row.language == "de"
    assert row.isbn == "9780306406157"


async def test_requests_limits_approval(env: SimpleNamespace) -> None:
    await config(books={"daily_limit_per_user": 1}, downloads={"auto_approve_requests": False})
    response = await request_book(env, env.user)
    assert response.status_code == 201, response.text
    row = response.json()
    assert row["status"] == "pending_approval" and row["language"] == "de" and "exclude_guids" not in row
    duplicate = await request_book(env, env.user)
    assert duplicate.status_code == 200 and duplicate.json()["id"] == row["id"]
    assert (await request_book(env, env.user, title="Other")).status_code == 429
    path = f"/api/books/requests/{row['id']}"
    assert (await env.client.get(path, headers=auth(env.other["token"]))).status_code == 404
    assert (await env.client.get("/api/books/requests?scope=all", headers=auth(env.user["token"]))).status_code == 403
    assert (await env.client.post(path + "/approve", headers=auth(env.user["token"]))).status_code == 403
    assert (await env.client.post(path + "/approve", headers=auth(env.admin["token"]))).json()["status"] == "queued"
    assert (await env.client.post(path + "/approve", headers=auth(env.admin["token"]))).status_code == 409
    assert (await env.client.post(path + "/retry", headers=auth(env.user["token"]))).status_code == 409
    assert (await request_book(env, title="Admin One")).status_code == 201
    assert (await request_book(env, title="Admin Two")).status_code == 201
    listed = (
        await env.client.get("/api/books/requests?scope=all&status=queued&limit=1", headers=auth(env.admin["token"]))
    ).json()
    assert listed["total"] == 3 and len(listed["items"]) == 1
    assert (await env.client.delete(path, headers=auth(env.user["token"]))).status_code == 204
    assert (await detail(env, row["id"]))["status"] == "cancelled"
    rejected = (await request_book(env, env.user, title="Rejected")).json()
    reject_path = f"/api/books/requests/{rejected['id']}"
    result = await env.client.post(
        reject_path + "/reject", headers=auth(env.admin["token"]), json={"reason": "Not wanted"}
    )
    assert result.json()["status"] == "rejected" and result.json()["error"] == "Not wanted"
    assert (await request_book(env, env.user, title="Allowed again")).status_code == 201
    assert (await env.client.delete(reject_path, headers=auth(env.user["token"]))).status_code == 204
    await upload(env, make_epub(env.tmp / "existing.epub", title="Der Schwarm", author="Frank Schätzing"))
    assert (await request_book(env)).status_code == 409


@pytest.mark.parametrize("source", ["magnet", "bytes", "redirect"])
async def test_torrent_pipeline(env: SimpleNamespace, source: str) -> None:
    env.gateway.source, env.gateway.category_code = source, 409
    if source != "magnet":
        env.gateway.results[0]["magnetUrl"] = None
    response = await request_book(
        env,
        description="Catalog Description",
        series="Catalog Series",
        series_index=1,
        cover_url="https://cover.test/book",
    )
    id = uuid.UUID(response.json()["id"])
    original = make_epub(env.gateway.root / "book.epub")
    pdf = env.gateway.root / "book.pdf"
    pdf.write_bytes(b"%PDF-" + b"p" * 10000)
    original_bytes = original.read_bytes()
    env.gateway.file_entries = [{"name": p.name, "size": p.stat().st_size} for p in (original, pdf)]
    assert await env.manager.process_one()
    assert (await detail(env, id))["status"] == "downloading"
    category = next(i for i, r in enumerate(env.gateway.seen) if r.url.path.endswith("createCategory"))
    added = next(i for i, r in enumerate(env.gateway.seen) if r.url.path.endswith("/add"))
    assert category < added and str(id).encode() in env.gateway.seen[added].content
    env.gateway.progress = 0.5
    await env.manager._poll(id)
    progress = await detail(env, id)
    assert progress["progress"] == 0.5 and progress["torrent_hash"] == "hash"
    await env.manager._poll(id)
    assert (await detail(env, id))["progress_at"] == progress["progress_at"]
    env.gateway.progress = 1
    await env.manager._poll(id)
    finished = await detail(env, id)
    assert finished["status"] == "done" and finished["progress"] == 1
    assert finished["book"]["format"] == "epub" and finished["book"]["source"] == "torrent"
    async with SessionLocal() as db:
        book = await db.get(Book, uuid.UUID(finished["book_id"]))
        path = env.root / "library" / book.path
        assert read_epub(path).title == "Der Schwarm" and read_epub(path).authors == ["Frank Schätzing"]
        assert read_epub(path).description == "Catalog Description"
        assert file_hash(path) == book.sha256 and hashlib.sha256(original_bytes).hexdigest() == book.source_sha256
        with Image.open(path.with_name("cover.jpg")) as cover:
            assert cover.height <= 1200 and cover.format == "JPEG"
    assert original.read_bytes() == original_bytes and not env.gateway.deleted


async def test_wrong_language_three_attempts(env: SimpleNamespace) -> None:
    id = uuid.UUID((await request_book(env)).json()["id"])
    original = make_epub(env.gateway.root / "wrong.epub", language="en")
    env.gateway.file_entries = [{"name": original.name, "size": original.stat().st_size}]
    env.gateway.results = [env.gateway.result(str(i)) for i in range(3)]
    env.gateway.progress = 1
    for attempt in range(3):
        assert await env.manager.process_one()
        await env.manager._poll(id)
        row = await detail(env, id)
        assert row["status"] == ("failed" if attempt == 2 else "queued")
        assert row["error"] == "Falsche Sprache" and row["attempts"] == attempt + 1
    assert len(env.gateway.deleted) == 3
    async with SessionLocal() as db:
        assert (await db.get(BookRequest, id)).exclude_guids == ["0", "1", "2"]
    response = await env.client.post(f"/api/books/requests/{id}/retry", headers=auth(env.admin["token"]))
    assert response.json()["attempts"] == 0 and response.json()["error"] is None
    async with SessionLocal() as db:
        assert (await db.get(BookRequest, id)).exclude_guids == ["0", "1", "2"]
    assert await env.manager.process_one()
    assert (await detail(env, id))["error"] == "Kein passender Download gefunden"


@pytest.mark.parametrize("reason", ["missing", "stall", "no_file", "invalid"])
async def test_torrent_failures(env: SimpleNamespace, reason: str) -> None:
    id = uuid.UUID((await request_book(env)).json()["id"])
    assert await env.manager.process_one()
    if reason == "missing":
        env.gateway.present = False
    elif reason == "stall":
        async with SessionLocal() as db:
            row = await db.get(BookRequest, id)
            row.progress_at = datetime.now(UTC) - timedelta(minutes=61)
            await db.commit()
    else:
        env.gateway.progress = 1
        if reason == "invalid":
            path = env.gateway.root / "invalid.pdf"
            path.parent.mkdir(parents=True)
            path.write_bytes(b"invalid" * 1000)
            env.gateway.file_entries = [{"name": path.name, "size": path.stat().st_size}]
    await env.manager._poll(id)
    row = await detail(env, id)
    assert row["status"] == "queued" and row["error"]
    async with SessionLocal() as db:
        assert (await db.get(BookRequest, id)).exclude_guids == ["first"]


async def test_cancel_cleanup_recovery(env: SimpleNamespace) -> None:
    id = (await request_book(env)).json()["id"]
    assert await env.manager.process_one()
    assert (await env.client.delete(f"/api/books/requests/{id}", headers=auth(env.admin["token"]))).status_code == 204
    assert (await detail(env, id))["status"] == "cancelled" and env.gateway.deleted
    now = time.time()
    env.gateway.all_rows = [
        {"hash": "old", "progress": 1, "completion_on": now - 8 * 86400, "state": "uploading"},
        {"hash": "stopped", "progress": 1, "completion_on": now, "state": "stoppedUP"},
        {"hash": "fresh", "progress": 1, "completion_on": now, "state": "uploading"},
    ]
    assert await env.manager.torrent_cleanup() == 2
    ids = []
    for index, status in enumerate(("searching", "importing", "downloading")):
        id = uuid.UUID((await request_book(env, title=f"Title {index}")).json()["id"])
        ids.append(id)
        async with SessionLocal() as db:
            (await db.get(BookRequest, id)).status = status
            await db.commit()
    await env.manager.start()
    await env.manager.stop()
    assert [(await detail(env, id))["status"] for id in ids] == ["queued", "queued", "downloading"]


async def test_upload_invalid_duplicate(env: SimpleNamespace) -> None:
    original = make_epub(env.tmp / "upload.epub")
    first = await upload(env, original, env.user)
    assert first["ok"] and first["book"]["title"] == "File Title"
    assert not {"path", "sha256", "added_by_id"} & first["book"].keys()
    assert (await upload(env, original))["error"] == "Diese Datei ist schon in der Bibliothek"
    for name, expected in [("bad.epub", "Keine gültige Buchdatei"), ("bad.txt", "Format wird nicht unterstützt")]:
        path = env.tmp / name
        path.write_bytes(b"bad" * 1000)
        assert (await upload(env, path))["error"] == expected
    assert not list((env.root / "import" / ".uploads").iterdir())
    async with SessionLocal() as db:
        book = await db.get(Book, uuid.UUID(first["book"]["id"]))
        assert book.added_by_id == uuid.UUID(env.user["user"]["id"])
        with pytest.raises(BookImportError) as duplicate:
            await import_book(db, env.root / "library" / book.path, copy=True, origin="folder", user=None, request=None)
        assert duplicate.value.book.id == book.id


@pytest.mark.parametrize("named", [False, True])
async def test_url_import(env: SimpleNamespace, named: bool) -> None:
    env.gateway.url_content = make_epub(env.tmp / "url.epub").read_bytes()
    if named:
        env.gateway.url_headers = {"Content-Disposition": "attachment; filename*=UTF-8''Author%20-%20Title.epub"}
    response = await env.client.post(
        "/api/books/import/url", headers=auth(env.user["token"]), json={"url": "https://url.test/download"}
    )
    assert response.status_code == 200 and response.json()["ok"], response.text
    assert response.json()["book"]["format"] == "epub" and response.json()["book"]["source"] == "url"
    env.gateway.download_code = 503
    response = await env.client.post(
        "/api/books/import/url", headers=auth(env.user["token"]), json={"url": "https://url.test/book.pdf"}
    )
    assert response.status_code == 502


@pytest.mark.parametrize("copy", [False, True])
async def test_drop_folder(env: SimpleNamespace, copy: bool) -> None:
    await config(library={"import_mode": "copy" if copy else "move"})
    path = make_epub(env.root / "import" / "nested" / "drop.epub")
    failed = env.root / "import" / "invalid.pdf"
    failed.write_bytes(b"invalid" * 500)
    make_epub(env.root / "import" / ".hidden.epub")
    make_epub(env.root / "import" / ".uploads" / "temp.epub")
    await env.manager.scan_folder()
    assert path.exists()
    async with SessionLocal() as db:
        assert not list(await db.scalars(select(Book)))
    await env.manager.scan_folder()
    assert path.exists()
    for entry, (size, observed) in env.manager._observed.items():
        env.manager._observed[entry] = (size, observed - 61)
    await env.manager.scan_folder()
    async with SessionLocal() as db:
        books = list(await db.scalars(select(Book)))
        assert len(books) == 1 and books[0].source == "folder"
    assert path.exists() == copy and failed.exists() == copy
    if copy:
        assert env.manager._processed[path] and env.manager._processed[failed]
    else:
        assert not path.parent.exists() and (env.root / "import" / ".failed" / "invalid.pdf").exists()
    await env.manager.scan_folder()


async def test_library(env: SimpleNamespace) -> None:
    first = (await upload(env, make_epub(env.tmp / "one.epub", title="Alpha", author="Zed Author"), env.user))["book"]
    second = (await upload(env, make_epub(env.tmp / "two.epub", title="Beta", author="Able Author")))["book"]
    headers = auth(env.user["token"])
    for query, expected in [
        ("q=Alpha", [first["id"]]),
        ("author=Zed%20Author", [first["id"]]),
        ("series=File%20Series&sort=title", [first["id"], second["id"]]),
        ("sort=author", [second["id"], first["id"]]),
        ("sort=series", [first["id"], second["id"]]),
        ("q=Second%20Author&sort=title", [first["id"], second["id"]]),
    ]:
        rows = (await env.client.get("/api/books/library?" + query, headers=headers)).json()
        assert [r["id"] for r in rows["items"]] == expected
    assert (await env.client.get("/api/books/library/authors", headers=headers)).json() == [
        {"name": "Able Author", "count": 1},
        {"name": "Second Author", "count": 2},
        {"name": "Zed Author", "count": 1},
    ]
    assert (await env.client.get("/api/books/library/series", headers=headers)).json()[0]["count"] == 2
    file = await env.client.get(first["file_url"] + "?token=" + env.user["token"])
    assert file.headers["Content-Type"] == "application/epub+zip"
    assert file.headers["Content-Disposition"] == "attachment; filename*=UTF-8''Zed%20Author%20-%20Alpha.epub"
    assert (await env.client.get(first["cover_url"] + "?token=" + env.user["token"])).headers[
        "Content-Type"
    ] == "image/jpeg"
    url = f"/api/books/library/{first['id']}"
    assert (await env.client.patch(url, headers=auth(env.other["token"]), json={"title": "No"})).status_code == 403
    async with SessionLocal() as db:
        old = env.root / "library" / (await db.get(Book, uuid.UUID(first["id"]))).path
    response = await env.client.patch(
        url, headers=headers, json={"title": "Änderung", "authors": ["New Author"], "series": None}
    )
    assert response.status_code == 200, response.text
    assert response.json()["match_key"] == "author:aenderung"
    assert not old.exists() and not old.parent.exists()
    async with SessionLocal() as db:
        book = await db.get(Book, uuid.UUID(first["id"]))
        path = env.root / "library" / book.path
        assert "New Author/Änderung" in str(path) and path.with_name("cover.jpg").exists()
        assert file_hash(path) == book.sha256 and read_epub(path).title == "Änderung"
    assert (await env.client.delete(url, headers=headers)).status_code == 403
    assert (await env.client.delete(url, headers=auth(env.admin["token"]))).status_code == 204
    assert not path.exists() and not path.parent.exists()


async def test_disabled_and_status(env: SimpleNamespace) -> None:
    headers = auth(env.admin["token"])
    response = await env.client.get("/api/admin/books/status", headers=headers)
    assert response.json() == {
        "google": {"ok": False, "message": "Kein Schlüssel eingetragen"},
        "audible": {"ok": True, "message": "OK"},
        "library": {"ok": True, "message": "0 Bücher"},
    }
    await config(downloads={"torrent_enabled": False})
    assert (await request_book(env)).json()["detail"] == "Automatische Downloads sind deaktiviert"
    assert (await upload(env, make_epub(env.tmp / "off.epub")))["ok"]
    await config(books={"enabled": False})
    assert (await env.client.get("/api/books/status", headers=headers)).json() == {
        "enabled": False,
        "requests_enabled": False,
        "default_language": "de",
        "can_import": False,
    }
    for path in ("/api/books/library", "/api/books/catalog/search", "/api/admin/books/status"):
        assert (await env.client.get(path, headers=headers)).status_code == 409
    assert (await env.client.get("/opds")).status_code == 404
    assert (await env.client.get("/kosync/users/auth")).status_code == 404


async def app_password(env: SimpleNamespace) -> dict:
    async with SessionLocal() as db:
        user = await db.get(User, uuid.UUID(env.user["user"]["id"]))
        user.subsonic_password = "reader-password"
        await db.commit()
    return {"x-auth-user": "BOOK-USER", "x-auth-key": hashlib.md5(b"reader-password").hexdigest()}


async def test_kosync(env: SimpleNamespace) -> None:
    headers = await app_password(env)
    assert (await env.client.get("/kosync/users/auth", headers=headers)).json() == {"authorized": "OK"}
    response = await env.client.get("/kosync/users/auth", headers={**headers, "x-auth-key": "wrong"})
    assert response.status_code == 401 and response.json() == {"code": 2001, "message": "Unauthorized"}
    assert (await env.client.get("/kosync/syncs/progress/unknown", headers=headers)).json() == {}
    body = {
        "document": "a" * 32,
        "progress": "/body/DocFragment[2]",
        "percentage": 0.4,
        "device": "Kindle",
        "device_id": "reader",
        "metadata": {"ignored": True},
    }
    response = await env.client.put("/kosync/syncs/progress", headers=headers, json=body)
    assert response.status_code == 200, response.text
    row = (await env.client.get("/kosync/syncs/progress/" + body["document"], headers=headers)).json()
    assert row == {**{k: v for k, v in body.items() if k != "metadata"}, "timestamp": response.json()["timestamp"]}
    body["percentage"] = 0.8
    await env.client.put("/kosync/syncs/progress", headers=headers, json=body)
    assert (await env.client.get("/kosync/syncs/progress/" + body["document"], headers=headers)).json()[
        "percentage"
    ] == 0.8
    assert (
        await env.client.put("/kosync/syncs/progress", headers=headers, json={**body, "percentage": 2})
    ).status_code == 422
    response = await env.client.post("/kosync/users/create")
    assert response.status_code == 402 and response.json() == {
        "code": 2002,
        "message": "Registrierung nur in Resonance",
    }
    async with SessionLocal() as db:
        (await db.get(User, uuid.UUID(env.user["user"]["id"]))).is_disabled = True
        await db.commit()
    assert (await env.client.get("/kosync/users/auth", headers=headers)).status_code == 401


async def test_opds(env: SimpleNamespace) -> None:
    await app_password(env)
    basic = httpx.BasicAuth("BOOK-USER", "reader-password")
    response = await env.client.get("/opds")
    assert response.status_code == 401 and response.headers["WWW-Authenticate"] == 'Basic realm="Resonance"'
    book = (await upload(env, make_epub(env.tmp / "opds.epub")))["book"]
    response = await env.client.get("/opds", auth=basic)
    assert "kind=navigation" in response.headers["Content-Type"]
    ns = {"a": "http://www.w3.org/2005/Atom"}
    feed = ET.fromstring(response.content)
    assert len(feed.findall("a:entry", ns)) == 4
    assert feed.find("a:link[@rel='search']", ns).get("href") == "/opds/search.xml"
    for path in ("/opds/new", "/opds/search?q=File", "/opds/authors/File%20Author", "/opds/series/File%20Series"):
        response = await env.client.get(path, auth=basic)
        assert response.status_code == 200 and "kind=acquisition" in response.headers["Content-Type"]
        entry = ET.fromstring(response.content).find("a:entry", ns)
        assert entry.find("a:id", ns).text == "urn:uuid:" + book["id"]
        assert len(entry.findall("a:author", ns)) == 2 and len(entry.findall("a:link", ns)) == 3
    for path in ("/opds/authors", "/opds/series"):
        assert ET.fromstring((await env.client.get(path, auth=basic)).content).find("a:entry", ns) is not None
    assert (
        ET.fromstring((await env.client.get("/opds/search.xml", auth=basic)).content).find("{*}Url").get("template")
        == "/opds/search?q={searchTerms}"
    )
    assert (await env.client.get(f"/opds/books/{book['id']}/file", auth=basic)).content.startswith(b"PK")
    assert (await env.client.get(f"/opds/books/{book['id']}/cover", auth=basic)).headers["Content-Type"] == "image/jpeg"
    async with SessionLocal() as db:
        db.add(
            BookRequest(
                user_id=uuid.UUID(env.user["user"]["id"]),
                title="File Title",
                authors=[],
                language="de",
                match_key="x",
                status="done",
                book_id=uuid.UUID(book["id"]),
            )
        )
        await db.commit()
    assert ET.fromstring((await env.client.get("/opds/mine", auth=basic)).content).find("a:entry", ns) is not None


async def test_torrent_duplicate_links_existing_book(env: SimpleNamespace) -> None:
    id = uuid.UUID((await request_book(env)).json()["id"])
    path = make_epub(env.gateway.root / "book.epub")
    existing = (await upload(env, path))["book"]
    env.gateway.file_entries = [{"name": path.name, "size": path.stat().st_size}]
    env.gateway.progress = 1
    assert await env.manager.process_one()
    await env.manager._poll(id)
    row = await detail(env, id)
    assert row["status"] == "done" and row["book_id"] == existing["id"]
    assert not env.gateway.deleted


async def test_filename_fallback_and_library_collision(env: SimpleNamespace) -> None:
    first = env.tmp / "Writer - Title.pdf"
    first.write_bytes(b"%PDF-" + b"a" * 2048)
    second = env.tmp / "another" / first.name
    second.parent.mkdir()
    second.write_bytes(b"%PDF-" + b"b" * 2048)
    first_book, second_book = (await upload(env, first))["book"], (await upload(env, second))["book"]
    assert first_book["title"] == "Title" and first_book["authors"] == ["Writer"]
    async with SessionLocal() as db:
        books = list(await db.scalars(select(Book).order_by(Book.created_at)))
        assert books[0].path == "Writer/Title/Title.pdf"
        assert books[1].path == "Writer/Title (2)/Title.pdf"
    response = await env.client.patch(
        f"/api/books/library/{second_book['id']}",
        headers=auth(env.admin["token"]),
        json={"title": "Title", "publisher": "Changed"},
    )
    assert response.status_code == 200
    assert (await env.client.get(first_book["file_url"], headers=auth(env.user["token"]))).content == first.read_bytes()


async def test_drop_folder_size_change_restarts_wait(env: SimpleNamespace) -> None:
    path = env.root / "import" / "Growing.pdf"
    path.write_bytes(b"%PDF-" + b"a" * 1024)
    await env.manager.scan_folder()
    size, observed = env.manager._observed[path]
    env.manager._observed[path] = (size, observed - 61)
    with path.open("ab") as file:
        file.write(b"b" * 1024)
    await env.manager.scan_folder()
    assert path.exists() and env.manager._observed[path][0] == path.stat().st_size
    async with SessionLocal() as db:
        assert not list(await db.scalars(select(Book)))


async def test_opds_pagination_and_user_progress_isolation(env: SimpleNamespace) -> None:
    headers = await app_password(env)
    basic = httpx.BasicAuth("book-user", "reader-password")
    async with SessionLocal() as db:
        for index in range(51):
            db.add(
                Book(
                    title=f"Book {index:02}",
                    authors=[],
                    author_sort="",
                    match_key=f":book {index}",
                    path=f"{index}.pdf",
                    format="pdf",
                    size=1024,
                    sha256=f"{index:064x}",
                    source_sha256=f"{index:064x}",
                    source="upload",
                )
            )
        await db.commit()
    response = await env.client.get("/opds/search?q=Book", auth=basic)
    ns = {"a": "http://www.w3.org/2005/Atom"}
    root = ET.fromstring(response.content)
    assert len(root.findall("a:entry", ns)) == 50
    next_url = root.find("a:link[@rel='next']", ns).get("href")
    assert next_url == "/opds/search?q=Book&page=2"
    assert len(ET.fromstring((await env.client.get(next_url, auth=basic)).content).findall("a:entry", ns)) == 1
    assert (await env.client.get("/opds", auth=httpx.BasicAuth("book-user", "incorrect"))).status_code == 401
    async with SessionLocal() as db:
        other = await db.get(User, uuid.UUID(env.other["user"]["id"]))
        other.subsonic_password = "other"
        await db.commit()
    body = {"document": "shared", "progress": "123", "percentage": 0.4, "device": "Kindle", "device_id": "x"}
    await env.client.put("/kosync/syncs/progress", headers=headers, json=body)
    other_headers = {"x-auth-user": "book-other", "x-auth-key": hashlib.md5(b"other").hexdigest()}
    assert (await env.client.get("/kosync/syncs/progress/shared", headers=other_headers)).json() == {}


async def test_audible_duplicates_fill_empty_fields(env: SimpleNamespace) -> None:
    env.gateway.audible = {
        "products": [
            audible_item(series=[], publisher_summary="", product_images={}),
            audible_item("second", publisher_summary="Filled"),
        ]
    }
    rows = await catalog.search(ServerConfig(), "Schwarm", "de")
    assert len(rows) == 1 and rows[0].ref == "audible:a1"
    assert rows[0].series == "Serie" and rows[0].description == "Filled"
