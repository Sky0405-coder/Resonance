"""Readings of lyrics in other scripts: Japanese kanji as kana (whole lines, and as furigana over each word), and
every line in the Latin alphabet (Hepburn romaji for Japanese, Pinyin for Chinese, romanizations for Korean, Cyrillic,
Greek and the rest).

Japanese is read with the optional dictionary (app.services.japanese) when it is installed, else with pykakasi.
"""

import re
import unicodedata
from dataclasses import dataclass

from anyascii import anyascii

from app.services import japanese as dictionary

_kakasi = None
_KANA = re.compile(r"[\u3041-\u309f\u30a1-\u30ff\u31f0-\u31ff\uff66-\uff9f]")
_HAN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff\u3005\u3006]")
_HANGUL = re.compile(r"[\u1100-\u11ff\u3130-\u318f\uac00-\ud7af]")
# Runs of letters outside the Latin script, romanized one run at a time so Latin words keep their case.
_FOREIGN_RUN = re.compile(r"[^\x00-ɏḀ-ỿ\s\d\W]+|[^\x00-ɏḀ-ỿ\s\d]*[^\W\d_\x00-ɏ]+")


def _foreign(text: str) -> bool:
    for c in unicodedata.normalize("NFKD", text):
        if c.isalpha() and ord(c) > 0x24F and not 0x1E00 <= ord(c) <= 0x1EFF and not unicodedata.combining(c):
            return True
    return False


def _kakasi_parts(text: str) -> list[tuple[str, str, str]]:
    """(surface, hiragana, romaji) per word from pykakasi, the fallback without the dictionary."""
    global _kakasi
    if _kakasi is None:
        import pykakasi

        _kakasi = pykakasi.kakasi()
    return [(part["orig"], part["hira"], part["hepburn"]) for part in _kakasi.convert(text)]


def _hiragana(katakana: str) -> str:
    return "".join(chr(ord(c) - 0x60) if "\u30a1" <= c <= "\u30f6" else c for c in katakana)


def _words(text: str) -> list[tuple[str, str | None]]:
    """The line as (text, reading) pieces: the hiragana reading for words with kanji, None for the rest."""
    tools = dictionary.tools()
    pieces: list[tuple[str, str | None]] = []
    if tools is not None:
        for word in tools[0](text):
            reading = getattr(word.feature, "kana", None)
            if word.white_space:
                pieces.append((word.white_space, None))
            has_reading = _HAN.search(word.surface) and reading and reading != "*"
            pieces.append((word.surface, _hiragana(reading) if has_reading else None))
    else:
        for surface, hira, _ in _kakasi_parts(text):
            pieces.append((surface, hira if _HAN.search(surface) and hira else None))
    return pieces


def _furigana(pieces: list[tuple[str, str | None]]) -> list[tuple[str, str | None]]:
    """Moves kana the word and its reading share (okurigana such as the っ of 待っ) out from under the reading, and
    joins the pieces without one."""
    out: list[tuple[str, str | None]] = []

    def add(text: str, reading: str | None) -> None:
        if not text:
            return
        if reading is None and out and out[-1][1] is None:
            out[-1] = (out[-1][0] + text, None)
        else:
            out.append((text, reading))

    for text, reading in pieces:
        if reading is None:
            add(text, None)
            continue
        plain = _hiragana(text)
        head = 0
        while head < len(text) - 1 and head < len(reading) - 1 and plain[head] == reading[head] and not _HAN.match(text[head]):
            head += 1
        tail = 0
        while (
            tail < len(text) - head - 1
            and tail < len(reading) - head - 1
            and plain[-1 - tail] == reading[-1 - tail]
            and not _HAN.match(text[-1 - tail])
        ):
            tail += 1
        add(text[:head], None)
        add(text[head : len(text) - tail], reading[head : len(reading) - tail])
        add(text[len(text) - tail :], None)
    return out


def _romaji(text: str) -> str:
    tools = dictionary.tools()
    if tools is not None:
        return tools[1].romaji(text)
    latin = unicodedata.normalize("NFKC", " ".join(r.strip() for _, _, r in _kakasi_parts(text) if r.strip()))
    return re.sub(r"\s+([,.!?;:)\]])", r"\1", latin)


def _romanize(text: str, japanese: bool) -> str:
    def run(match: re.Match) -> str:
        part = match.group(0)
        if not japanese and _HAN.search(part):
            # anyascii writes Pinyin syllables run together and capitalized ("WoAiNi"); one word per character reads
            # like Pinyin lyrics usually do.
            return "".join(f" {anyascii(c).lower()} " if _HAN.match(c) else anyascii(c) for c in part)
        latin = anyascii(part)
        # Hangul syllables come back capitalized one by one ("AnNyeongHaSeYo").
        return latin.lower() if _HANGUL.search(part) else latin

    latin = _FOREIGN_RUN.sub(run, text)
    return re.sub(r"\s+([,.!?;:)\]])", r"\1", re.sub(r"\s+", " ", latin)).strip()


@dataclass
class LineScripts:
    # The line with kanji read as kana; None for lines without kanji.
    kana: str | None = None
    # The line in Latin letters; None for lines in the Latin script.
    latin: str | None = None
    # Furigana: the line as (text, reading) pieces, the reading over kanji; None for lines without kanji.
    ruby: list[tuple[str, str | None]] | None = None


def lyric_scripts(lines: list[str]) -> list[LineScripts]:
    """The readings of each line.

    A song counts as Japanese when any line has kana, so its lines in kanji alone are read as Japanese too, while
    lyrics in Chinese characters only get Pinyin.
    """
    japanese = any(_KANA.search(line) for line in lines)
    result: list[LineScripts] = []
    # The tagger and pykakasi are not thread safe.
    with dictionary.lock:
        for line in lines:
            if not _foreign(line):
                result.append(LineScripts())
                continue
            scripts = LineScripts()
            if japanese and (_KANA.search(line) or _HAN.search(line)):
                if _HAN.search(line):
                    pieces = _words(line)
                    scripts.kana = "".join(reading or text for text, reading in pieces)
                    scripts.ruby = _furigana(pieces)
                latin = _romaji(line)
            else:
                latin = _romanize(line, japanese)
            scripts.latin = latin if latin and latin != line else None
            result.append(scripts)
    return result
