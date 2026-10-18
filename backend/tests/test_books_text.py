from pathlib import Path

import pytest

from app.config import get_settings
from app.services.books.importer import library_target
from app.services.books.select import choose_book
from app.services.books.text import (
    author_sort,
    book_norm,
    clean_audible_title,
    isbn13,
    last_name,
    relpath_for,
    safe_name,
    work_key,
)


def test_normalization() -> None:
    assert book_norm("  ÄÖÜ ß Émile – \u0098Schätzing\u009c 123!") == "aeoeue ss emile schaetzing 123"
    assert book_norm("\u0098Der\u009c Schwarm") == "der schwarm"
    assert last_name("Schätzing, Frank") == last_name("Frank Schätzing") == "Schätzing"
    assert last_name("") == ""
    assert author_sort(["Frank Schätzing"]) == author_sort(["Schätzing, Frank"]) == "Schätzing, Frank"
    assert author_sort([]) == ""
    assert work_key("Der Schwarm", ["Frank Schätzing"]) == "schaetzing:der schwarm"
    assert work_key("A" * 1000, []) == ":" + "a" * 255


@pytest.mark.parametrize(
    "marker",
    [
        "Hörbuch",
        "Hörbücher",
        "Hörspiel",
        "ungekürzt",
        "gekürzt",
        "Lesung",
        "Besetzung",
        "audiobook",
        "unabridged",
        "abridged",
        "dramatized",
        "dramatised",
    ],
)
def test_clean_audible(marker: str) -> None:
    assert clean_audible_title(f"Der  Schwarm ({marker}) (Roman)") == "Der Schwarm (Roman)"


def test_paths(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    assert safe_name(' ../A\\B:*?"<>|\x00. ') == "_A_B________"
    assert safe_name(" . ") == "Unbekannt"
    assert safe_name("abcdef", 3) == "abc"
    assert relpath_for("Der Schwarm", ["Frank Schätzing"], "epub") == "Frank Schätzing/Der Schwarm/Der Schwarm.epub"
    assert relpath_for("Title", [], "pdf") == "Unbekannt/Title/Title.pdf"
    monkeypatch.setattr(get_settings(), "books_dir", tmp_path)
    first = library_target("Title", [], "epub")
    first.parent.mkdir(parents=True)
    first.write_bytes(b"first")
    second = library_target("Title", [], "epub")
    assert second.parent.name == "Title (2)"
    second.parent.mkdir()
    assert library_target("Title", [], "epub").parent.name == "Title (3)"
    assert library_target("Title", [], "epub", current=first) == first


@pytest.mark.parametrize(
    "source,expected",
    [
        ("0-306-40615-2", "9780306406157"),
        ("urn:isbn:978-3-462-03753-1", "9783462037531"),
        ("0306406153", None),
        ("9780306406158", None),
    ],
)
def test_isbn(source: str, expected: str | None) -> None:
    assert isbn13(source) == expected


def result(**updates: object) -> dict:
    return {
        "title": "Frank Schaetzing Der Schwarm epub german",
        "protocol": "torrent",
        "size": 10000,
        "seeders": 3,
        "guid": "a",
        **updates,
    }


def choose(
    rows: list[dict],
    language: str = "de",
    title: str = "Der Schwarm",
    authors: list[str] | None = None,
    exclude: list[str] | None = None,
) -> dict | None:
    return choose_book(rows, title, authors if authors is not None else ["Frank Schätzing"], language, 1, exclude or [])


@pytest.mark.parametrize(
    "marker,language,allowed",
    [
        ("german", "de", True),
        ("english", "de", False),
        ("french", "de", False),
        ("german english", "de", True),
        ("", "de", True),
        ("english", "en", True),
        ("german", "en", False),
        ("english german", "en", True),
        ("spanish", "any", True),
    ],
)
def test_selection_language(marker: str, language: str, allowed: bool) -> None:
    row = result(title=f"Schaetzing Der Schwarm epub {marker}")
    assert (choose([row], language) is row) == allowed


@pytest.mark.parametrize(
    "word",
    "mp3 m4b m4a aac flac audiobook hoerbuch horbuch hoerspiel collection sammlung bundle pack komplett complete anthology boxset magazine zeitschrift comic comics manga".split()
    + ["box set"],
)
def test_reject_words(word: str) -> None:
    row = result(title=f"Schaetzing Der Schwarm {word}")
    assert choose([row]) is None
    assert choose([row], title=f"Der Schwarm {word}") is row


@pytest.mark.parametrize(
    "updates",
    [
        {"size": 1023},
        {"size": 250 * 1024**2 + 1},
        {"seeders": 0},
        {"protocol": "usenet"},
        {"title": "Another Author Der Schwarm epub"},
        {"title": "Schaetzing Unrelated Title epub"},
    ],
)
def test_selection_reject(updates: dict) -> None:
    assert choose([result(**updates)]) is None


def test_selection_ranking_and_exclusion() -> None:
    rows = [
        result(title=f"Schaetzing Der Schwarm {ext}", seeders=seeders, guid=ext)
        for ext, seeders in [("pdf", 50), ("mobi", 50), ("azw3", 50), ("epub", 1)]
    ]
    assert choose(rows) is rows[-1]
    assert choose(rows, exclude=["epub"]) is rows[-2]
    preferred = result(title="Schaetzing Der Schwarm pdf german")
    assert choose([rows[-1], preferred]) is preferred
    assert choose([result(size=20000, seeders=100), result(size=10000, seeders=50)])["size"] == 10000
    assert choose([result()], exclude=["a"]) is None
    assert choose([result(title="Der Schwarm epub")], authors=[]) is not None


def test_clean_audible_title_spoken_by() -> None:
    assert clean_audible_title("Harry Potter und der Stein der Weisen - Gesprochen von Rufus Beck") == (
        "Harry Potter und der Stein der Weisen"
    )
    assert clean_audible_title("Der Hobbit: gelesen von Gert Heidenreich") == "Der Hobbit"
