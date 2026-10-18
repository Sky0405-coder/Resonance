import io
import zipfile
from pathlib import Path

import pytest
from PIL import Image

from app.models import Book
from app.services.books.epub import epub_cover, read_epub, write_epub
from app.services.books.importer import BookImportError, validate_file


def make_epub(
    path: Path,
    *,
    title: str = "File Title",
    language: str = "de-DE",
    isbn: str = "",
    epub3: bool = False,
    cover: bool = True,
    author: str = "File Author",
    extra: str = "",
) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    buffer = io.BytesIO()
    Image.new("RGB", (8, 16), "red").save(buffer, "PNG")
    series = (
        '<meta property="belongs-to-collection" id="series">File Series</meta><meta refines="#series" property="group-position">2.5</meta>'
        if epub3
        else '<meta name="calibre:series" content="File Series"/><meta name="calibre:series_index" content="2.5"/>'
    )
    opf = f"""<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
    <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>{title}</dc:title><dc:creator>{author}</dc:creator><dc:creator>Second Author</dc:creator>
    <dc:language>{language}</dc:language><dc:identifier id="bookid">{isbn or "fixture-id"}</dc:identifier>
    <dc:publisher>File Publisher</dc:publisher><dc:date>2004-01-02</dc:date>
    <dc:description>&lt;b&gt;Description&lt;/b&gt;</dc:description>{series}<meta name="cover" content="cover"/>{extra}</metadata>
    <manifest><item id="cover" href="cover.png" media-type="image/png" {'properties="cover-image"' if epub3 else ""}/></manifest></package>"""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_STORED) as archive:
        archive.writestr("mimetype", "application/epub+zip")
        archive.writestr(
            "META-INF/container.xml",
            '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/book.opf"/></rootfiles></container>',
        )
        archive.writestr("OEBPS/book.opf", opf)
        archive.writestr("OEBPS/chapter.xhtml", "<html>" + "x" * 1500 + "</html>")
        if cover:
            archive.writestr("OEBPS/cover.png", buffer.getvalue())
    return path


@pytest.mark.parametrize("epub3", [False, True])
def test_read_write_cover(tmp_path: Path, epub3: bool) -> None:
    path = make_epub(tmp_path / "book.epub", epub3=epub3, isbn="0-306-40615-2")
    meta = read_epub(path)
    assert meta.title == "File Title" and meta.authors == ["File Author", "Second Author"]
    assert meta.language == "de" and meta.isbn == "9780306406157"
    assert meta.series == "File Series" and meta.series_index == 2.5
    assert meta.publisher == "File Publisher" and meta.year == 2004 and meta.description == "Description"
    assert epub_cover(path).startswith(b"\x89PNG")
    book = Book(
        title="Catalog Title",
        authors=["Catalog Author"],
        language="en",
        isbn="9780306406157",
        publisher="Publisher",
        description="New Description",
        series="Catalog Series",
        series_index=0,
    )
    write_epub(path, book)
    updated = read_epub(path)
    assert updated.title == "Catalog Title" and updated.authors == ["Catalog Author"] and updated.language == "en"
    assert updated.series == "Catalog Series" and updated.series_index == 0
    with zipfile.ZipFile(path) as archive:
        assert archive.infolist()[0].filename == "mimetype"
        assert archive.infolist()[0].compress_type == zipfile.ZIP_STORED
        assert all(e.compress_type == zipfile.ZIP_DEFLATED for e in archive.infolist()[1:])
        assert b"fixture-id" not in archive.read("OEBPS/book.opf")
        assert b"0-306-40615-2" in archive.read("OEBPS/book.opf")
    assert epub_cover(path).startswith(b"\x89PNG")


def test_write_parse_error_untouched(tmp_path: Path) -> None:
    path = tmp_path / "bad.epub"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("META-INF/container.xml", '<!DOCTYPE x [<!ENTITY e SYSTEM "file:///etc/passwd">]><x>&e;</x>')
    original = path.read_bytes()
    write_epub(path, Book(title="Title", authors=[]))
    assert path.read_bytes() == original
    assert read_epub(path).title is None
    assert epub_cover(path) is None


@pytest.mark.parametrize("ext", ["pdf", "mobi", "azw3", "epub"])
def test_validation(tmp_path: Path, ext: str) -> None:
    path = tmp_path / f"book.{ext}"
    path.write_bytes(b"x" * 1024)
    with pytest.raises(BookImportError, match="Keine gültige Buchdatei"):
        validate_file(path)
    if ext == "epub":
        make_epub(path)
    elif ext == "pdf":
        path.write_bytes(b"%PDF-" + b"x" * 1024)
    else:
        path.write_bytes(b"\0" * 60 + b"BOOKMOBI" + b"x" * 1024)
    validate_file(path)
    path.write_bytes(b"small")
    with pytest.raises(BookImportError):
        validate_file(path)
