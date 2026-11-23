import sys
from pathlib import Path

import pytest

from app import lyrics_script
from app.lyrics_script import LineScripts, lyric_scripts
from app.services import japanese


@pytest.fixture
def dictionary(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """The optional dictionary as the server installs it (cutlet with the stand-in for mojimoji)."""
    pytest.importorskip("fugashi")
    pytest.importorskip("unidic_lite")
    pytest.importorskip("jaconv")
    (tmp_path / "mojimoji.py").write_text(japanese._MOJIMOJI)
    monkeypatch.syspath_prepend(str(tmp_path))
    monkeypatch.delitem(sys.modules, "mojimoji", raising=False)
    pytest.importorskip("cutlet")
    monkeypatch.setattr(japanese, "_tools", None)
    monkeypatch.setitem(japanese._state, "state", "ready")


def test_japanese_with_dictionary(dictionary: None) -> None:
    lines = ["君の名は、今どこにいるの？", "東京タワーで待ってる！", "ありがとう", "明日", "Baby I love you", ""]
    assert lyric_scripts(lines) == [
        LineScripts(
            "きみのなは、いまどこにいるの？",
            "Kimi no na wa, ima doko ni iru no?",
            [("君", "きみ"), ("の", None), ("名", "な"), ("は、", None), ("今", "いま"), ("どこにいるの？", None)],
        ),
        # Katakana stays katakana in the kana reading; loanwords get their English spelling in romaji; okurigana
        # (the っ of 待っ) stays out of the furigana.
        LineScripts(
            "とうきょうタワーでまってる！",
            "Tokyo tower de matteru!",
            [("東京", "とうきょう"), ("タワーで", None), ("待", "ま"), ("ってる！", None)],
        ),
        LineScripts(None, "Arigatou"),
        # Kanji alone in a song with kana elsewhere is read as Japanese.
        LineScripts("あす", "Asu", [("明日", "あす")]),
        LineScripts(),
        LineScripts(),
    ]
    assert lyric_scripts(["夢を見ていた Baby I love you"])[0].latin == "Yume wo mite ita Baby I love you"


def test_japanese_without_dictionary() -> None:
    """pykakasi reads kanji one by one (君 as くん), but every line still gets kana, furigana and romaji."""
    assert japanese.tools() is None
    [line] = lyric_scripts(["東京タワーで待ってる！"])
    assert line.kana == "とうきょうタワーでまってる！"
    assert line.ruby[0] == ("東京", "とうきょう")
    assert line.latin.startswith("toukyou tawaa de")
    assert line.latin.endswith("!")


@pytest.mark.parametrize(
    ("line", "latin"),
    [
        # Chinese characters without kana anywhere in the song are Chinese: Pinyin, one syllable per character.
        ("我爱你，北京", "wo ai ni, bei jing"),
        ("Baby我爱你", "Baby wo ai ni"),
        ("안녕하세요 사랑해", "annyeonghaseyo salanghae"),
        ("Привет, как дела?", "Privet, kak dela?"),
    ],
)
def test_other_scripts_in_latin(line: str, latin: str) -> None:
    assert lyric_scripts([line]) == [LineScripts(latin=latin)]


def test_latin_with_accents_needs_nothing() -> None:
    assert lyric_scripts(["Café über Straße", "Ça va"]) == [LineScripts(), LineScripts()]


def test_furigana_keeps_shared_kana_out() -> None:
    assert lyrics_script._furigana([("見つめ", "みつめ"), ("て", None), ("いた", None)]) == [
        ("見", "み"),
        ("つめていた", None),
    ]
