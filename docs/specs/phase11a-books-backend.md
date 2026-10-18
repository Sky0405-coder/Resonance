# Phase 11a – Ebooks: library, catalog, torrent requests, import, OPDS, KOReader sync (backend only)

Precise implementation spec. Implement exactly what is written; no extra features, endpoints, fields, settings or
files beyond what is listed. Where silent, choose the simplest option matching the existing code. List any
deviation with a reason in the final report.

General rules: like `docs/specs/phase2a-backend.md` §0 (no git commands that modify index/HEAD/working tree,
German user-facing texts **plus** an English entry in `app/i18n.py` `_EXACT`/`_PATTERNS` for every new message,
existing style, `ruff format --line-length 120` on new/rewritten files, tests without network – mock HTTP with
`httpx.MockTransport` the same way `tests/test_torrents.py` / `tests/test_audiobookshelf.py` do). Run backend tests
against the database given in the task prompt only; the whole suite must pass. **Only touch `backend/`** plus the
compose/Dockerfile lines in §1. The Flutter app and the KOReader plugin are done separately. Do not touch `docs/`.

## Context
Resonance gets an optional **books module**: a shared ebook library (like the music library), a metadata catalog
search with a German focus, automatic downloads via the existing Prowlarr + qBittorrent (VPN) setup, manual import
(upload, URL, drop folder), an OPDS catalog and a KOReader progress-sync server. Clients: the Flutter app ("Bücher"
tab) and a KOReader plugin on Kindle/Tolino that uses the normal REST API with a bearer token.
Everything lives in its own namespace: package `app/services/books/`, routers `app/api/books.py`, `app/api/opds.py`,
`app/api/kosync.py`, models in `app/models/books.py`, tests `tests/test_books*.py`. The module is off by default.
Book downloads are completely separate from music `DownloadRequest`s (own tables, own worker, own qBittorrent
category) – do not change the music download flow.

## 1. Settings, compose, dependencies
- `Settings.books_dir: Path = Path("/data/books")` (comment: "Ebook library (`library/`) and drop folder (`import/`)").
  Library root = `books_dir / "library"`, drop folder = `books_dir / "import"`; create both on startup of the
  book manager (`mkdir(parents=True, exist_ok=True)`, errors logged, not fatal).
- `docker-compose.yml`: header comment line `#   BOOKS_PATH  host path for ebooks (library + import drop folder),
  e.g. /mnt/hdd/books`; `resonance` service gets a long-syntax bind `${BOOKS_PATH}` → `/data/books`.
- `pyproject.toml` dependencies: add `"defusedxml>=0.7"` (all EPUB/OPF/DNB XML parsing goes through
  `defusedxml.ElementTree`).

## 2. Server config (`ServerConfig.books: BooksConfig`)
```python
class BooksConfig(BaseModel):
    # Show the "Bücher" tab, the OPDS catalog and the KOReader sync server.
    enabled: bool = False
    # Language for catalog search and torrent selection unless the request says otherwise.
    default_language: Literal["de", "en", "any"] = "de"
    # Optional key from https://console.cloud.google.com (Books API) – without it only Audible is searched.
    google_books_api_key: str = ""
    # Book requests per user and 24 hours (admins unlimited); 0 = no limit.
    daily_limit_per_user: int = Field(10, ge=0, le=1000)
```
Requests additionally require `downloads.torrent_enabled`; approval uses the existing
`downloads.auto_approve_requests`; minimum seeders `downloads.torrent_min_seeders`; stall timeout
`downloads.torrent_timeout_minutes`; seeding cleanup `downloads.torrent_seed_days`.

## 3. Models (`app/models/books.py`, exported from `app/models/__init__.py`) + one Alembic revision
Revision id `b4c81e5f2a90`, `down_revision` = current head.
```python
class Book(Base):
    __tablename__ = "books"
    id: uuid pk default uuid4
    title: String(512)
    subtitle: String(512) | None
    authors: JSONB list[str], not null, default []
    author_sort: String(256), index        # "Lastname, Firstname" of the first author, "" if none (§4.1)
    series: String(512) | None, index
    series_index: Float | None
    language: String(8) | None             # ISO 639-1 ("de", "en", …)
    isbn: String(13) | None, index
    publisher: String(256) | None
    year: Integer | None
    description: Text | None
    catalog_ref: String(64) | None         # "google:<id>" | "audible:<asin>" | "dnb:<id>"
    match_key: String(256), index          # §4.1 work_key(title, authors)
    path: Text, unique                     # relative to books_dir/library, e.g. "Frank Schätzing/Der Schwarm/Der Schwarm.epub"
    format: String(8)                      # epub | azw3 | mobi | pdf
    size: BigInteger
    sha256: String(64), unique             # of the library file (after metadata was written)
    source_sha256: String(64), index       # of the file as it was imported (duplicate detection)
    has_cover: bool default False          # cover.jpg next to the file
    source: String(16)                     # torrent | upload | url | folder
    added_by_id: FK users.id ON DELETE SET NULL | None
    created_at / updated_at (server_default now, onupdate now)

class BookRequest(Base):
    __tablename__ = "book_requests"
    id: uuid pk
    user_id: FK users.id ON DELETE CASCADE, index
    catalog_ref: String(64) | None
    match_key: String(256), index
    title, subtitle, authors, series, series_index, isbn, publisher, year, description: as in Book (all nullable
        except title/authors)
    language: String(8)                    # "de" | "en" | "any" – what the torrent selection looks for
    cover_url: Text | None
    status: String(24), index              # pending_approval | queued | searching | downloading | importing |
                                           # done | failed | cancelled | rejected
    torrent_name: Text | None
    torrent_hash: String(64) | None
    progress: Float default 0
    progress_at: DateTime(tz) | None       # last time progress increased
    attempts: Integer default 0
    exclude_guids: JSONB list[str], not null, server_default "[]"   # Prowlarr guids that already failed
    error: Text | None
    book_id: FK books.id ON DELETE SET NULL | None
    created_at / updated_at

class BookProgress(Base):                  # KOReader sync (§9)
    __tablename__ = "book_progress"
    user_id: FK users.id ON DELETE CASCADE, primary key part
    document: String(64), primary key part # KOReader document hash (md5 hex)
    progress: Text
    percentage: Float
    device: String(128)
    device_id: String(128)
    updated_at: DateTime(tz) server_default now, onupdate now
```

## 4. Helpers – `app/services/books/text.py` (pure functions)
### 4.1 Normalisation
- `book_norm(s)`: casefold; `ä→ae, ö→oe, ü→ue, ß→ss`; then NFKD and drop combining marks; drop the control
  characters U+0098/U+009C (DNB sort markers); every char that is not `[a-z0-9]` → space; collapse spaces; strip.
- `last_name(author)`: `"Schätzing, Frank"` → `"Schätzing"`; else last whitespace-separated word (`""` for empty).
- `author_sort(authors)`: first author as `"Lastname, Rest"` (unchanged if it already contains a comma), `""` if none.
- `work_key(title, authors)`: `f"{book_norm(last_name(authors[0]) if authors else '')}:{book_norm(title)}"[:256]`.
- `clean_audible_title(s)`: remove every parenthesised group whose casefolded content contains one of
  `hörbuch, hörbücher, hörspiel, ungekürzt, gekürzt, lesung, besetzung, audiobook, unabridged, abridged, dramatized,
  dramatised`; collapse spaces; strip.
- `safe_name(s, max_len=120)`: replace `/\:*?"<>|` and control chars with `_`, collapse spaces, strip dots/spaces at
  both ends, cut to `max_len`, `"Unbekannt"` if empty.
- `relpath_for(title, authors, ext)` → `f"{safe_name(authors[0] if authors else 'Unbekannt')}/{safe_name(title)}/{safe_name(title)}.{ext}"`.
  When the target already exists for a *different* book: append ` (2)`, ` (3)`, … to the title folder.

### 4.2 Formats
`BOOK_FORMATS = {"epub": 3, "azw3": 2, "mobi": 1, "pdf": 0}` (rank). A file is a book iff its lowercase suffix
without the dot is a key. Content check before import: epub/azw3/mobi/pdf must be ≥ 1 KiB; epub must be a valid zip
containing `META-INF/container.xml`; pdf must start with `%PDF-`; mobi/azw3 must contain `BOOKMOBI` at offset 60.
Failure → `BookImportError("Keine gültige Buchdatei")`.

## 5. EPUB metadata – `app/services/books/epub.py`
- `read_epub(path) -> FileMeta` (dataclass: `title, authors, language, isbn, series, series_index, publisher, year,
  description`, all optional/empty): OPF path from `META-INF/container.xml` (`rootfile/@full-path`), then from the
  OPF `metadata`: `dc:title` (first), `dc:creator` (all, in order), `dc:language` (first 2 letters, lowercased),
  `dc:identifier` values whose digits (ignore `-`, spaces, `urn:isbn:` prefix) form a valid ISBN-13 (or ISBN-10,
  converted to 13), `dc:publisher`, `dc:date` → year (first 4 digits), `dc:description` (HTML tags stripped),
  series from `<meta name="calibre:series" content>` / `calibre:series_index` or EPUB3
  `<meta property="belongs-to-collection">` + `group-position` refining it.
- `write_epub(path, meta: Book)`: rewrite the OPF of a **copy in the library** (never the torrent/import original):
  replace/insert `dc:title`, `dc:creator` (one per author, previous creators removed), `dc:language`,
  `dc:identifier` with `urn:isbn:{isbn}` (added, existing identifiers kept), `dc:publisher`, `dc:description`,
  calibre series metas (`calibre:series`, `calibre:series_index` – removed if no series). The zip is rewritten to a
  temp file in the same directory: `mimetype` first and `ZIP_STORED`, all other entries copied unchanged
  (`ZIP_DEFLATED`), then `os.replace`. Any parse error → leave the file untouched and log a warning (not fatal).
- `epub_cover(path) -> bytes | None`: OPF manifest item with `properties` containing `cover-image`, else the item
  referenced by `<meta name="cover" content=id>`; only `image/jpeg|png`.

## 6. Catalog – `app/services/books/catalog.py`
`CatalogBook` (pydantic): `ref, title, subtitle, authors, series, series_index, language, year, publisher, isbn,
description, cover_url`. `class BooksError(Exception)` with `status` and German `message` (like `ABSError`).

- **Google Books** (only if `google_books_api_key`): `GET https://www.googleapis.com/books/v1/volumes` params
  `q`, `printType=books`, `maxResults=20`, `key`, plus `langRestrict=<lang>` unless `any`. Map `volumeInfo`:
  `title, subtitle, authors, publisher, publishedDate[:4] → year, description` (tags stripped, max 4000 chars),
  `language`, ISBN-13 from `industryIdentifiers` (`ISBN_13`, else convert `ISBN_10`),
  `imageLinks.thumbnail` with `http://` → `https://` and `&edge=curl` removed, `seriesInfo` ignored. ref `google:{id}`.
- **Audible** (always): `GET https://api.audible.de/1.0/catalog/products` params `keywords`, `num_results=20`,
  `products_sort_by=Relevance`, `response_groups=product_desc,contributors,series,media,product_attrs`.
  Skip products with `content_delivery_type == "PodcastParent"`. Map: title/subtitle through
  `clean_audible_title`, `authors[].name` (skip names containing `GbR`, `GmbH`, `Verlag`), `series[0].title` (cleaned)
  and `float(series[0].sequence)` when parseable, `language` (`german→de`, `english→en`, `french→fr`,
  `spanish→es`, `italian→it`, else None), year from `release_date[:4]`, `publisher_name` is **not** used (audio
  publisher), description = `publisher_summary` or `merchandising_summary` (tags stripped, max 4000),
  cover `product_images["500"]`, isbn None. ref `audible:{asin}`. When the search language is not `any`, drop
  products whose mapped language is known and different.
- **DNB** (ISBN lookups only, §8.3): `GET https://services.dnb.de/sru/dnb` params `version=1.1`,
  `operation=searchRetrieve`, `query=num={isbn}`, `recordSchema=MARC21-xml`, `maximumRecords=1`. Map first record:
  `245$a` (+ `245$b` → subtitle), `100$a` (and `700$a` with `$4 aut`) converted `"Last, First"` → `"First Last"`,
  `264$b`/`264$c` (fallback `260$b`/`260$c`, year = first 4-digit number), `490$a`/`490$v` (index parsed as float when
  possible), `041$a` (`ger→de`, `eng→en`, else first 2 letters), `020$a` ISBN; strip U+0098/U+009C everywhere.
  ref `dnb:{001}`.
- `async def search(cfg, query, language) -> list[CatalogBook]`: Google and Audible in parallel
  (`asyncio.gather`, each with a 15 s timeout; a failing source is logged and skipped; all sources failed →
  `BooksError(502, "Buchkatalog nicht erreichbar")`). Merge by `work_key`: Google results first in their order
  (duplicates within Google: keep the first), then Audible results – a result with an existing key only fills the
  merged entry's empty fields (`series`, `series_index`, `description`, `cover_url`, `year`, `language`), otherwise
  it is appended. Max 30 results. Empty/whitespace query → `[]`.
- `async def lookup_isbn(cfg, isbn) -> CatalogBook | None`: Google `q=isbn:{isbn}` (if key) else/then DNB; first hit.
- One module-level `httpx.AsyncClient` per process is not required – use `async with httpx.AsyncClient(timeout=15)`
  per call, `User-Agent: Resonance/1.0`.

## 7. Requests and the book manager – `app/services/books/manager.py`
### 7.1 Creating (`POST /api/books/requests`, §10)
Body `BookRequestIn`: `ref: str | None (max 64), title (1..512), subtitle, authors: list[str] (0..10 items, each
1..256), series, series_index, isbn, publisher, year, description (max 4000), cover_url, language: "de"|"en"|"any"
| None` (None → `cfg.books.default_language`). The client sends back the catalog entry it shows; a free-text
request is the same body with `ref=None` (title + optional author typed by the user).
- Module disabled → 409 `"Bücher sind nicht aktiviert"`; `downloads.torrent_enabled` false → 409
  `"Automatische Downloads sind deaktiviert"`.
- `match_key = work_key(title, authors)`. Book with that key exists → 409 `"Das Buch ist schon in der Bibliothek"`.
  Active request (status not in `done|failed|cancelled|rejected`) of the same user with that key → return it (200).
- Daily limit (non-admins, `daily_limit_per_user > 0`): count of the user's book requests created in the last
  24 h with status not `rejected|cancelled` ≥ limit → 429 `"Tageslimit erreicht ({count} von {limit} Büchern in 24 Stunden)"`.
- Status `queued` if admin or `auto_approve_requests`, else `pending_approval`. Commit, `book_manager.wake()`, 201.

### 7.2 Worker (`class BookManager`, singleton `book_manager`, started/stopped in `main.lifespan` next to the music
manager and only when `download_workers > 0`)
One worker task + one monitor task (every 10 s). The worker loop picks the oldest `queued` request
(`with_for_update(skip_locked=True)`), sets `searching`, commits and runs `_start(request_id)`; it sleeps on an
`asyncio.Event` (`wake()`) with a 10 s timeout like the music worker.

`_start`:
1. Prowlarr search (extend `prowlarr.search` with an optional `categories: list[int] = [3000]` parameter, passed as
   repeated `categories` query params; books use `[7000, 7020]`). Queries in order until a result is chosen:
   `f"{last_name(authors[0])} {title}"` (only if authors), then `title`.
2. `choose_book` (§7.3) with `exclude_guids`. Nothing chosen → `failed`, error `"Kein passender Download gefunden"`.
3. Fetch and add the torrent exactly like the music `_torrent_start` does (magnet vs. `.torrent` bytes, manual
   redirect handling) – factor the "obtain magnet/bytes from a Prowlarr result" part into a shared helper in
   `app/services/torrents/` used by both, without changing music behaviour. Add with `category="resonance-books"`,
   `savepath="/data/downloads/books"`, `tag=str(request.id)` (extend `QBittorrent.add/info/all` with an optional
   `category` argument defaulting to `"resonance"`, and add `create_category(name, save_path)` →
   `POST /api/v2/torrents/createCategory`, HTTP 409 = already exists = fine; call it before every book add).
4. Status `downloading`, `torrent_name = result["title"]`, `progress=0`, `progress_at=now`, `attempts += 1`,
   remember the chosen guid in memory for step 7.4 (store it: append to `exclude_guids` only on failure).
   Prowlarr/qBittorrent errors (`TorrentError`) → `failed` with the error message.

Monitor (every 10 s) for each `downloading` request: `info(tag, category="resonance-books")`; missing → retry
logic (§7.4) with `"Torrent verschwunden"`; set `torrent_hash`, update `progress`/`progress_at` when it increased;
`progress >= 1` → `_import_torrent`; no progress for `torrent_timeout_minutes` → delete torrent with files, retry
logic with `"Torrent ohne Fortschritt"`. Once per hour: seeding cleanup like `torrent_cleanup` but for category
`resonance-books` and busy = book requests in `searching|downloading|importing`.

### 7.3 `choose_book(results, title, authors, language, min_seeders, exclude_guids) -> dict | None` (pure, `select.py` in the books package)
Keep results with `protocol == "torrent"`, `seeders >= min_seeders`, `guid not in exclude_guids`,
`1024 <= size <= 250 MiB`, and with `r = book_norm(result["title"])`, `t = book_norm(title)`:
- `fuzz.token_set_ratio(t, r) >= 85`;
- if authors: `fuzz.partial_ratio(book_norm(last_name(authors[0])), r) >= 90`;
- reject if `r` contains one of these words (as whole words) that `t` does not contain: `mp3 m4b m4a aac flac
  audiobook hoerbuch horbuch hoerspiel collection sammlung bundle pack komplett complete anthology boxset magazine
  zeitschrift comic comics manga`, or the phrase `box set`.
- Language markers (whole words in `r`): de = `german deutsch ger`; en = `english eng`; other = `french francais
  spanish espanol italian italiano dutch polish russian`. `language == "de"`: reject if an en/other marker is present
  without a de marker; `lang_rank = 1` if a de marker is present else 0. `"en"`: symmetric. `"any"`: rank 0, no filter.
- `format_rank`: highest `BOOK_FORMATS` rank of a format word in `r`; no format word → 1.
- Pick max by `(lang_rank, format_rank, min(seeders, 50), -size)`.

### 7.4 Import of a finished torrent and retry logic
`_import_torrent`: status `importing`. Files from `QBittorrent.files(hash)`, paths `Path(info["save_path"]) / name`.
Candidates = book files (§4.2); pick the best by `(format rank, size)`. If an epub's `read_epub().language` is known
and the request language is not `any` and differs → treat as failure `"Falsche Sprache"`. No candidate → failure
`"Keine Buchdatei im Download"`. Otherwise `import_book(source=..., copy=True, origin="torrent", request=request)`
(§8) → request `done`, `book_id`, `progress=1`. The torrent keeps seeding (cleanup as above).
**Retry logic** for any failure after a torrent was chosen: delete the torrent with files (errors ignored), append
the guid to `exclude_guids`; if `attempts < 3` → status `queued`, `error` = the reason (shown while retrying), wake;
else `failed` with the reason.
**Startup**: requests in `searching|importing` → `queued`; `downloading` stays (monitor resumes).
**Cancel** (`DELETE` on an active request): `downloading` → delete torrent with files; status `cancelled`.

## 8. Import – `app/services/books/importer.py`
`async def import_book(db, source: Path, *, copy: bool, origin: str, user: User | None, request: BookRequest | None,
filename: str | None = None) -> Book`:
1. Validate (§4.2); compute sha256 (in a thread). Same hash already in `books.sha256` or `books.source_sha256` → raise
   `BookImportError("Diese Datei ist schon in der Bibliothek")` (the existing `Book` is available on the exception as
   `.book` so callers can link a request to it: torrent import then sets `book_id` to it and finishes `done`).
2. Metadata, first non-empty wins per field: request fields (if `request`) → `read_epub` (epub only) →
   `lookup_isbn(isbn)` when the file has an ISBN → filename pattern `"Author - Title.ext"` (split on the first
   `" - "`; else title = stem) for `title`/`authors`. `catalog_ref` from the request or the ISBN lookup.
3. Target `books_dir/library/relpath_for(...)`; copy (`shutil.copy2`) or move (`shutil.move`) into a temp name
   `.{name}.part` in the target dir, then rename. For epub: `write_epub(target, book)`; `sha256`/`size` are then
   recomputed from the library file, while the hash from step 1 is stored as `source_sha256`.
4. Cover: request `cover_url` (download, max 5 MB, `image/*`), else `epub_cover`, else the ISBN lookup's cover; save
   as `cover.jpg` (convert with Pillow to JPEG, max 1200 px height) next to the file, `has_cover=True`.
5. Insert `Book` (`source=origin`, `added_by_id=user.id` or the request's user), commit, return.

Entry points:
- `POST /api/books/import/upload` (multipart, field `files`, max 20 files, each max 300 MB, streamed to
  `books_dir/import/.uploads/<uuid>.<ext>` then `import_book(copy=False, origin="upload", filename=<original>)`).
  Response: list of `{"filename", "ok", "book": BookOut | None, "error": str | None}`. Unknown extension →
  `ok=false`, `"Format wird nicht unterstützt"`.
- `POST /api/books/import/url` body `{"url": http(s) URL}`: stream download (60 s timeout, 300 MB max →
  `"Datei ist zu groß"`), filename from `Content-Disposition` or the URL path, extension check as above (if the URL
  has no known extension: detect by the §4.2 content checks), then `import_book(copy=False, origin="url")`.
  Network errors → 502 `"Download fehlgeschlagen"`. Response: one result object as above.
- Drop folder: the book manager scans `books_dir/import` (recursive, skip dot-files and `.uploads`) every 5 minutes;
  files whose size did not change for 60 s are imported with `copy = cfg.library.import_mode == "copy"`,
  `origin="folder"`, `user=None`; failures are logged and the file is moved to `books_dir/import/.failed/` (move
  mode) or remembered in memory by path+mtime so it is not retried (copy mode). Empty sub-directories are removed in
  move mode.
Who may import: every user when the module is enabled (like requests); the daily limit does not apply.

## 9. KOReader progress sync – `app/api/kosync.py`, prefix `/kosync`
Mirrors the koreader-sync-server API that KOReader's built-in "Progress sync" plugin talks to (custom server URL
`https://<host>/kosync`). Auth headers `x-auth-user` (username, case-insensitive) and `x-auth-key` = md5 hex of the
user's **app password** (`User.subsonic_password`, the same one OpenSubsonic uses); compare with
`hmac.compare_digest`. Disabled users / no app password / mismatch → 401 `{"code": 2001, "message": "Unauthorized"}`.
Module disabled → 404. Responses are JSON with content type `application/json`.
- `POST /kosync/users/create` → always 402 `{"code": 2002, "message": "Registrierung nur in Resonance"}`.
- `GET /kosync/users/auth` → 200 `{"authorized": "OK"}`.
- `PUT /kosync/syncs/progress` body `{document (1..64), progress (str), percentage (float 0..1), device, device_id}`
  (extra fields like `metadata` ignored) → upsert `BookProgress` → 200 `{"document", "timestamp": unix int}`.
- `GET /kosync/syncs/progress/{document}` → 200 `{"document","progress","percentage","device","device_id",
  "timestamp"}` or 200 `{}` when unknown.

## 10. REST API – `app/api/books.py`, prefix `/api/books`, all `CurrentUser`
Every endpoint except `/status` returns 409 `"Bücher sind nicht aktiviert"` while the module is disabled.
`BookOut`: all `Book` columns except `path`/`sha256`/`added_by_id`, plus `cover_url` (`/api/books/library/{id}/cover`
or None), `file_url` (`/api/books/library/{id}/file`), `filename` (`f"{safe_name(authors[0])} - {safe_name(title)}.{format}"`
or without author part). `BookRequestOut`: all request columns except `exclude_guids`, plus
`user: UserRef`, `book: BookOut | None`.
1. `GET /status` → `{"enabled", "requests_enabled" (enabled and torrents on), "default_language", "can_import": enabled}`.
2. `GET /catalog/search?q=&language=` (language default from config) → list of `CatalogBook` +
   `book_id` (library book with the same `match_key`, else None) + `request_id`/`request_status` (the caller's
   active request with that key). `BooksError` → its status/message.
3. `POST /requests` (§7.1). `GET /requests?scope=mine|all&status=` (`all` admin only, else 403
   `"Nur für Admins"`), `Page[BookRequestOut]`, newest first. `GET /requests/{id}` (own or admin, else 404
   `"Anfrage nicht gefunden"`). `DELETE /requests/{id}`: active → cancel (§7.4), finished → delete the row; 204.
   `POST /requests/{id}/retry` (failed/cancelled only, else 409 `"Anfrage läuft noch"`): `attempts=0`,
   `exclude_guids` kept, `error=None`, `queued`. `POST /requests/{id}/approve` and `/reject` (admin;
   only `pending_approval`, else 409 `"Anfrage wartet nicht auf Freigabe"`; reject body `{"reason": str | None}`
   stored in `error`).
4. `GET /library?q=&author=&series=&sort=added|title|author|series&offset&limit` → `Page[BookOut]`. `q`: ILIKE on
   title/subtitle/series and on `authors::text`. `author` exact match against an element of `authors`
   (`authors @> [author]`), `series` exact. Sort `added` = `created_at desc`; `title` = title; `author` =
   `author_sort, series, series_index, title`; `series` = `series, series_index, title`.
5. `GET /library/authors` → `[{"name", "count"}]` (each author of each book), sorted by name casefold.
   `GET /library/series` → `[{"name", "author", "count"}]` (author = most common first author), sorted by name.
6. `GET /library/{id}` → `BookOut`; `GET /library/{id}/file` → `FileResponse` with
   `Content-Disposition: attachment; filename*=UTF-8''<filename>` and media type by format (`application/epub+zip`,
   `application/x-mobipocket-ebook` for mobi/azw3, `application/pdf`); `GET /library/{id}/cover` → JPEG or 404.
   Both accept the `?token=` query auth like the music stream endpoint.
7. `PATCH /library/{id}` (admin or `added_by_id == user.id`, else 403 `"Keine Berechtigung"`): any of
   `title, subtitle, authors, series, series_index, language, isbn, publisher, year, description`; recompute
   `match_key`/`author_sort`; move the file + cover to the new `relpath_for` when title/first author changed (remove
   empty old folders); epub → `write_epub` again and refresh sha256/size.
8. `DELETE /library/{id}` (admin) → delete file, cover and empty parent folders, then the row; 204.
9. Import endpoints from §8.
Admin: `GET /api/admin/books/status` (second router in the same file) → `{"google": {"ok","message"},
"audible": {...}, "library": {"ok","message"}}`: Google = one search for `"Der Schwarm"` (`"Kein Schlüssel
eingetragen"` with ok=false when empty), Audible likewise, library = `books_dir/library` writable →
`"{n} Bücher"`.

## 11. OPDS 1.2 catalog – `app/api/opds.py`, prefix `/opds`
For KOReader's built-in OPDS browser and other readers. HTTP **Basic** auth: username + app password
(`subsonic_password`); missing/wrong → 401 with `WWW-Authenticate: Basic realm="Resonance"`. Module disabled → 404.
Atom XML built with `xml.etree.ElementTree` (namespaces `http://www.w3.org/2005/Atom`,
`http://purl.org/dc/terms/`, `http://opds-spec.org/2010/catalog`), content types
`application/atom+xml;profile=opds-catalog;kind=navigation|acquisition`.
- `GET /opds` navigation feed: entries "Neu hinzugefügt" (`/opds/new`), "Autoren" (`/opds/authors`),
  "Serien" (`/opds/series`), "Meine Anfragen" (`/opds/mine` = books of the user's `done` requests, newest first),
  plus `<link rel="search" type="application/opensearchdescription+xml" href="/opds/search.xml">`.
- `/opds/authors` and `/opds/series`: navigation feeds linking to `/opds/authors/{name}` / `/opds/series/{name}`
  (URL-encoded) which are acquisition feeds (sort as §10.4 `author` / `series`).
- `/opds/search.xml`: OpenSearch description with template `/opds/search?q={searchTerms}`; `/opds/search` acquisition feed.
- Acquisition feeds are paged 50 per page (`?page=`, `rel="next"` link). Entry: `id urn:uuid:{id}`, `title`,
  `author/name` per author, `updated`, `dc:language`, `dc:issued` (year), `summary` (description, max 1000 chars),
  `link rel="http://opds-spec.org/acquisition"` → `/opds/books/{id}/file` with the format's media type,
  `rel="http://opds-spec.org/image"` and `.../image/thumbnail` → `/opds/books/{id}/cover` when `has_cover`.
- `/opds/books/{id}/file` and `/cover`: same responses as §10.6 but with Basic auth.
All hrefs are absolute paths (starting with `/opds/`).

## 12. Tests (no network; temp `books_dir` via settings override)
`test_books_text.py`: `book_norm` (umlauts, DNB markers), `work_key`, `clean_audible_title`, `safe_name`,
`relpath_for` collision suffix, `choose_book` (language rules, format rank, seeders, size, reject words unless in
title, author check, exclude_guids).
`test_books_epub.py`: build small EPUB2/EPUB3 fixtures in the test; `read_epub` (creators, ISBN-10→13, calibre and
EPUB3 series), `write_epub` round trip (mimetype first + stored), `epub_cover`.
`test_books.py`: catalog merge with mocked Google + Audible (incl. Google key empty → Audible only, one source
failing, both failing → 502, language drop); request create/duplicate/in-library 409/daily limit/approval;
end-to-end with mocked Prowlarr + qBittorrent: request → category created → torrent added → monitor progress →
import of the best file (epub over pdf) → `done` with a `Book` and library file + metadata written, original
unchanged; wrong-language epub → retry with excluded guid → third failure `failed`; stall timeout; cancel; startup
recovery; upload (valid epub, invalid file, duplicate), URL import (mocked), drop-folder scan (stable-size rule,
move vs. copy); library list filters/sorts, authors/series, file download headers with `?token=`, PATCH moves the
file, DELETE; module disabled → 409/404; kosync auth (md5 of app password), put/get progress, create → 402;
OPDS root/search/acquisition feed XML (parse it), Basic auth 401, file download. All existing tests stay green.

## 13. Report
Files, pytest tail, migration check (`alembic upgrade head` on a fresh DB + `alembic check`), deviations (or "none").
