import pytest

from app.api import catalog
from app.services import resolve
from app.services.deezer import deezer
from app.services.musicbrainz import TrackMeta
from app.services.sources import youtube


def _meta(title: str) -> TrackMeta:
    return TrackMeta(
        title=title,
        artist="Eminem",
        artist_mbid=None,
        album="The Eminem Show",
        album_artist="Eminem",
        album_artist_mbid=None,
        track_no=None,
        track_total=None,
        disc_no=None,
        disc_total=None,
        year=None,
        date=None,
        duration=290,
        isrc=None,
        genre=None,
        label=None,
        mb_recording_id=None,
        mb_release_id=None,
        mb_release_group_id=None,
    )


async def test_edited_track_is_swapped_for_explicit_original(monkeypatch: pytest.MonkeyPatch) -> None:
    async def track(id: str) -> dict:
        return {
            "id": int(id),
            "title": "Without Me",
            "artist": {"name": "Eminem"},
            "duration": 290,
            "explicit_content_lyrics": 3 if id == "1" else 1,
        }

    async def search(q: str, limit: int) -> list[dict]:
        return [
            {"id": 1, "title": "Without Me", "artist": {"name": "Eminem"}, "duration": 290, "explicit_lyrics": False},
            {"id": 7, "title": "Without Me", "artist": {"name": "Other"}, "duration": 290, "explicit_lyrics": True},
            {"id": 2, "title": "Without Me", "artist": {"name": "Eminem"}, "duration": 291, "explicit_lyrics": True},
        ]

    monkeypatch.setattr(deezer, "track", track)
    monkeypatch.setattr(deezer, "search_tracks", search)
    assert await resolve.explicit_track_id("1") == "2"
    assert await resolve.explicit_track_id("5") == "5"


async def test_edited_album_is_swapped_for_explicit_edition(monkeypatch: pytest.MonkeyPatch) -> None:
    async def album(id: str) -> dict:
        return {
            "id": int(id),
            "title": "The Eminem Show",
            "artist": {"name": "Eminem"},
            "nb_tracks": 20,
            "explicit_content_lyrics": 3,
        }

    async def search(q: str, limit: int) -> list[dict]:
        return [
            {
                "id": 3,
                "title": "The Eminem Show (Expanded)",
                "artist": {"name": "Eminem"},
                "nb_tracks": 36,
                "explicit_lyrics": True,
            },
            {
                "id": 4,
                "title": "The Eminem Show",
                "artist": {"name": "Eminem"},
                "nb_tracks": 20,
                "explicit_lyrics": True,
            },
        ]

    monkeypatch.setattr(deezer, "album", album)
    monkeypatch.setattr(deezer, "search_albums", search)
    assert await resolve.explicit_album_id("1") == "4"


def test_catalog_drops_clean_duplicates_only() -> None:
    items = [
        {"title": "Without Me", "artist": {"name": "Eminem"}, "explicit_lyrics": False},
        {"title": "Without Me", "artist": {"name": "Eminem"}, "explicit_lyrics": True},
        {"title": "Rasputin", "artist": {"name": "Boney M."}, "explicit_lyrics": False},
    ]
    kept = catalog._drop_censored(items, lambda t: (t["title"], t["artist"]["name"]))
    assert kept == items[1:]


def test_youtube_rejects_clean_and_tribute_versions() -> None:
    meta = _meta("Without Me")
    assert youtube.score_candidate(meta, "Without Me (Clean)", ["Eminem"], 290, False) is None
    assert youtube.score_candidate(meta, "Without Me (Radio Edit)", ["Eminem"], 290, False) is None
    assert youtube.score_candidate(meta, "Without Me (Originally Performed By Eminem)", ["Eminem"], 290, False) is None
    assert youtube.score_candidate(meta, "Without Me", ["Eminem"], 290, False) is not None


async def test_youtube_prefers_explicit_result(monkeypatch: pytest.MonkeyPatch) -> None:
    class Music:
        def search(self, query: str, filter: str, limit: int) -> list[dict]:
            if filter != "songs":
                return []
            return [
                {
                    "videoId": "clean",
                    "title": "Without Me",
                    "artists": [{"name": "Eminem"}],
                    "duration_seconds": 290,
                    "isExplicit": False,
                },
                {
                    "videoId": "explicit",
                    "title": "Without Me",
                    "artists": [{"name": "Eminem"}],
                    "duration_seconds": 293,
                    "isExplicit": True,
                },
            ]

    source = youtube.YouTubeMusicSource.__new__(youtube.YouTubeMusicSource)
    source._music = Music()
    candidate = await source.find(_meta("Without Me"))
    assert candidate is not None and candidate.ref == "explicit"
