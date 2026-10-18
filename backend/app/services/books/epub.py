import logging
import os
import re
import tempfile
import zipfile
from dataclasses import dataclass, field
from html import unescape
from pathlib import Path
from xml.etree import ElementTree as ET

from defusedxml import ElementTree

from app.models import Book
from app.services.books.text import isbn13

log = logging.getLogger(__name__)


@dataclass
class FileMeta:
    title: str | None = None
    authors: list[str] = field(default_factory=list)
    language: str | None = None
    isbn: str | None = None
    series: str | None = None
    series_index: float | None = None
    publisher: str | None = None
    year: int | None = None
    description: str | None = None


def strip_html(value: str) -> str:
    return unescape(re.sub(r"<[^>]*>", "", value)).strip()


def _opf(archive: zipfile.ZipFile) -> tuple[str, ET.Element]:
    container = ElementTree.fromstring(archive.read("META-INF/container.xml"))
    rootfile = next(e for e in container.iter() if e.tag.rsplit("}", 1)[-1] == "rootfile")
    path = rootfile.attrib["full-path"]
    return path, ElementTree.fromstring(archive.read(path))


def read_epub(path: Path) -> FileMeta:
    try:
        with zipfile.ZipFile(path) as archive:
            _, root = _opf(archive)
        metadata = root.find("{*}metadata")
        if metadata is None:
            return FileMeta()

        def value(name: str) -> str | None:
            entry = metadata.find(f"{{http://purl.org/dc/elements/1.1/}}{name}")
            return "".join(entry.itertext()).strip() or None if entry is not None else None

        meta = FileMeta(
            title=value("title"),
            authors=[
                e.text.strip()
                for e in metadata.findall("{http://purl.org/dc/elements/1.1/}creator")
                if e.text and e.text.strip()
            ],
            language=(value("language") or "")[:2].lower() or None,
            isbn=next(
                (
                    isbn
                    for e in metadata.findall("{http://purl.org/dc/elements/1.1/}identifier")
                    if (isbn := isbn13(e.text or ""))
                ),
                None,
            ),
            publisher=value("publisher"),
            year=int(m[0]) if (m := re.search(r"\d{4}", value("date") or "")) else None,
            description=strip_html(value("description") or "") or None,
        )
        entries = metadata.findall("{*}meta")
        for entry in entries:
            name = entry.get("name")
            if name == "calibre:series":
                meta.series = entry.get("content")
            elif name == "calibre:series_index":
                try:
                    meta.series_index = float(entry.get("content", ""))
                except ValueError:
                    pass
        if not meta.series:
            collection = next((e for e in entries if e.get("property") == "belongs-to-collection"), None)
            if collection is not None:
                meta.series = collection.text
                position = next(
                    (
                        e
                        for e in entries
                        if e.get("property") == "group-position" and e.get("refines") == f"#{collection.get('id')}"
                    ),
                    None,
                )
                if position is not None:
                    try:
                        meta.series_index = float(position.text or "")
                    except ValueError:
                        pass
        return meta
    except Exception:
        log.warning("Cannot read EPUB metadata: %s", path, exc_info=True)
        return FileMeta()


def write_epub(path: Path, meta: Book) -> None:
    temp: Path | None = None
    try:
        with zipfile.ZipFile(path) as archive:
            opf_path, root = _opf(archive)
            metadata = root.find("{*}metadata")
            if metadata is None:
                raise ValueError("Missing EPUB metadata")
            dc = "{http://purl.org/dc/elements/1.1/}"
            opf = root.tag.rsplit("}", 1)[0] + "}"
            for name, values in (
                ("title", [meta.title]),
                ("creator", meta.authors),
                ("language", [meta.language]),
                ("publisher", [meta.publisher]),
                ("description", [meta.description]),
            ):
                for entry in metadata.findall(dc + name):
                    metadata.remove(entry)
                for value in values:
                    if value:
                        ET.SubElement(metadata, dc + name).text = value
            if meta.isbn:
                identifier = f"urn:isbn:{meta.isbn}"
                if not any(e.text == identifier for e in metadata.findall(dc + "identifier")):
                    ET.SubElement(metadata, dc + "identifier").text = identifier
            for entry in list(metadata):
                if entry.get("name") in {"calibre:series", "calibre:series_index"}:
                    metadata.remove(entry)
            if meta.series:
                ET.SubElement(metadata, opf + "meta", name="calibre:series", content=meta.series)
                if meta.series_index is not None:
                    ET.SubElement(metadata, opf + "meta", name="calibre:series_index", content=str(meta.series_index))
            opf_bytes = ET.tostring(root, encoding="utf-8", xml_declaration=True)
            fd, filename = tempfile.mkstemp(prefix=".epub-", dir=path.parent)
            os.close(fd)
            temp = Path(filename)
            with zipfile.ZipFile(temp, "w") as output:
                output.writestr("mimetype", archive.read("mimetype"), compress_type=zipfile.ZIP_STORED)
                for entry in archive.infolist():
                    if entry.filename != "mimetype":
                        output.writestr(
                            entry,
                            opf_bytes if entry.filename == opf_path else archive.read(entry),
                            compress_type=zipfile.ZIP_DEFLATED,
                        )
        os.replace(temp, path)
    except Exception:
        log.warning("Cannot write EPUB metadata: %s", path, exc_info=True)
    finally:
        if temp is not None:
            temp.unlink(missing_ok=True)


def epub_cover(path: Path) -> bytes | None:
    try:
        with zipfile.ZipFile(path) as archive:
            opf_path, root = _opf(archive)
            items = root.findall("{*}manifest/{*}item")
            cover = next((e for e in items if "cover-image" in e.get("properties", "").split()), None)
            if cover is None:
                entry = next((e for e in root.findall("{*}metadata/{*}meta") if e.get("name") == "cover"), None)
                cover = next((e for e in items if entry is not None and e.get("id") == entry.get("content")), None)
            if cover is not None and cover.get("media-type") in {"image/jpeg", "image/png"}:
                return archive.read(str(Path(opf_path).parent / cover.attrib["href"]))
    except Exception:
        log.warning("Cannot read EPUB cover: %s", path, exc_info=True)
    return None
