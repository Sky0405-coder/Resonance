from rapidfuzz import fuzz

from app.services.books.text import BOOK_FORMATS, book_norm, last_name


def choose_book(
    results: list[dict], title: str, authors: list[str], language: str, min_seeders: int, exclude_guids: list[str]
) -> dict | None:
    candidates = []
    t = book_norm(title)
    title_words = set(t.split())
    reject = set(
        "mp3 m4b m4a aac flac audiobook hoerbuch horbuch hoerspiel collection sammlung bundle pack komplett complete anthology boxset magazine zeitschrift comic comics manga".split()
    )
    de = {"german", "deutsch", "ger"}
    en = {"english", "eng"}
    other = set("french francais spanish espanol italian italiano dutch polish russian".split())
    for result in results:
        seeders, size = result.get("seeders") or 0, result.get("size") or 0
        if result.get("protocol") != "torrent" or seeders < min_seeders or result.get("guid") in exclude_guids:
            continue
        if not 1024 <= size <= 250 * 1024**2:
            continue
        r = book_norm(result.get("title", ""))
        words = set(r.split())
        if fuzz.token_set_ratio(t, r) < 85:
            continue
        if authors and fuzz.partial_ratio(book_norm(last_name(authors[0])), r) < 90:
            continue
        if (words & reject) - title_words or (" box set " in f" {r} " and " box set " not in f" {t} "):
            continue
        preferred, foreign = (de, en | other) if language == "de" else (en, de | other)
        if language != "any" and words & foreign and not words & preferred:
            continue
        lang_rank = int(bool(words & preferred)) if language != "any" else 0
        format_rank = max((rank for ext, rank in BOOK_FORMATS.items() if ext in words), default=1)
        candidates.append(((lang_rank, format_rank, min(seeders, 50), -size), result))
    return max(candidates, key=lambda c: c[0])[1] if candidates else None
