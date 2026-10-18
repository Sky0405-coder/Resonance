import re
import unicodedata

BOOK_FORMATS = {"epub": 3, "azw3": 2, "mobi": 1, "pdf": 0}


def book_norm(s: str) -> str:
    s = s.casefold().translate(str.maketrans({"ä": "ae", "ö": "oe", "ü": "ue", "ß": "ss", "\u0098": "", "\u009c": ""}))
    s = "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))
    return " ".join(re.sub(r"[^a-z0-9]", " ", s).split())


def last_name(author: str) -> str:
    return author.split(",", 1)[0].strip() if "," in author else author.split()[-1] if author.split() else ""


def author_sort(authors: list[str]) -> str:
    if not authors:
        return ""
    author = authors[0].strip()
    if "," in author:
        return author
    words = author.split()
    return f"{words[-1]}, {' '.join(words[:-1])}" if len(words) > 1 else author


def work_key(title: str, authors: list[str]) -> str:
    return f"{book_norm(last_name(authors[0]) if authors else '')}:{book_norm(title)}"[:256]


_SPOKEN_BY = re.compile(r"\s*[-–:]\s*(?:gesprochen|gelesen|erzählt|read|narrated) (?:von|by)\b.*$", re.IGNORECASE)


def clean_audible_title(s: str) -> str:
    s = _SPOKEN_BY.sub("", s)
    words = (
        "hörbuch",
        "hörbücher",
        "hörspiel",
        "ungekürzt",
        "gekürzt",
        "lesung",
        "besetzung",
        "audiobook",
        "unabridged",
        "abridged",
        "dramatized",
        "dramatised",
    )
    output = []
    start = 0
    depth = 0
    for index, char in enumerate(s):
        if char == "(":
            if depth == 0:
                output.append(s[start:index])
                start = index
            depth += 1
        elif char == ")" and depth:
            depth -= 1
            if depth == 0:
                group = s[start : index + 1]
                if not any(word in group.casefold() for word in words):
                    output.append(group)
                start = index + 1
    output.append(s[start:])
    return " ".join("".join(output).split())


def safe_name(s: str, max_len: int = 120) -> str:
    s = "".join("_" if c in '/\\:*?"<>|' or unicodedata.category(c) == "Cc" else c for c in s)
    return " ".join(s.split()).strip(". ")[:max_len] or "Unbekannt"


def relpath_for(title: str, authors: list[str], ext: str) -> str:
    name = safe_name(title)
    return f"{safe_name(authors[0] if authors else 'Unbekannt')}/{name}/{name}.{ext}"


def isbn13(value: str) -> str | None:
    value = re.sub(r"^urn:isbn:", "", value.strip(), flags=re.IGNORECASE)
    value = re.sub(r"[-\s]", "", value).upper()
    if len(value) == 10 and re.fullmatch(r"\d{9}[\dX]", value):
        if sum((10 - i) * (10 if c == "X" else int(c)) for i, c in enumerate(value)) % 11:
            return None
        value = "978" + value[:9]
        value += str(-sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(value)) % 10)
    if len(value) == 13 and value.isascii() and value.isdigit():
        if sum(int(c) * (1 if i % 2 == 0 else 3) for i, c in enumerate(value)) % 10 == 0:
            return value
    return None
