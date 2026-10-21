import uuid
from collections.abc import AsyncIterator

import pytest
from sqlalchemy.ext.asyncio import AsyncSession

from app.db import SessionLocal
from app.models import Album, Artist, Track
from app.schemas import CatalogTrack
from app.services.matching import base_title, loose_key, match_tracks, name_key


@pytest.mark.parametrize(
    "value, expected",
    [
        ("Salt-N-Pepa", "salt pepa"),
        ("Salt ’n’ Pepa", "salt pepa"),
        ("Salt‐n‐Pepa", "salt pepa"),
        ("Salt and Pepa", "salt pepa"),
        ("Salt und Pepa", "salt pepa"),
        ("Mélle Mél", "melle mel"),
        ("Straße", "strasse"),
        ("  A & B+C/D  ", "a b c d"),
        ("Candy Underground Nine", "candy underground nine"),
        ("Song_One:Two!", "songonetwo"),
        ("White Lines (Don't Do It)", "white lines dont do it"),
        ("White Lines (Don’t Do It)", "white lines dont do it"),
    ],
)
def test_loose_key(value: str, expected: str) -> None:
    assert loose_key(value) == expected


@pytest.mark.parametrize("quote", list("’‘`´'\"“”"))
def test_loose_key_drops_quotes(quote: str) -> None:
    assert loose_key(f"Don{quote}t") == "dont"


@pytest.mark.parametrize("separator", list("‐‑‒–—−-&+/"))
def test_loose_key_separates_words(separator: str) -> None:
    assert loose_key(f"Salt{separator}n{separator}Pepa") == "salt pepa"


@pytest.mark.parametrize(
    "title, expected",
    [
        ("Push It (Radio Version)", "Push It"),
        ("Push It (single version)", "Push It"),
        ("Abschied nehmen (Radio-Edit)", "Abschied nehmen"),
        ("Engel (feat. Gim) Radio Edit", "Engel"),
        ("Song - Remastered 2011", "Song"),
        ("Song (2011 Remaster)", "Song"),
        ("Song (Radio Mix)", "Song"),
        ("Song [Single Edit]", "Song"),
        ("Song (Album Version)", "Song"),
        ("Song - Original Version", "Song"),
        ("Song (Mono)", "Song"),
        ("Song [Stereo]", "Song"),
        ("Song (Explicit)", "Song"),
        ("Song [Clean]", "Song"),
        ("Song (Edit)", "Song"),
        ("Song (Radio Version) [Remastered 2011] - Stereo", "Song"),
        ("Song (feat. Guest)", "Song"),
        ("Song [feat. Guest] (Single Version)", "Song"),
        ("Song feat. Guest", "Song"),
        ("Song ft. Guest", "Song"),
        ("Song featuring Guest", "Song"),
        ("Song (feat. Guest) Continued", "Song Continued"),
        ("Song feat. Guest (Live)", "Song (Live)"),
        ("Song featuring Guest - Extended Mix", "Song - Extended Mix"),
        ("Song - Live - Remastered 2011", "Song - Live"),
        ("White Lines (Don't Do It)", "White Lines (Don't Do It)"),
    ],
)
def test_base_title(title: str, expected: str) -> None:
    assert base_title(title) == expected


@pytest.mark.parametrize(
    "decoration",
    [
        "Live", "Extended Mix", "Acoustic", "Club Mix", "Instrumental", "Remix", "Dance Mix", "Version",
        "Single Mix", "Live Album Version", "Extended Radio Edit", "Acoustic Remastered 2011",
    ],
)
@pytest.mark.parametrize("template", ["Song ({})", "Song [{}]", "Song - {}"])
def test_base_title_preserves_distinct_versions(decoration: str, template: str) -> None:
    title = template.format(decoration)
    assert base_title(title) == title
    assert loose_key(base_title(title)) != loose_key(base_title("Song"))


@pytest.fixture
async def db() -> AsyncIterator[AsyncSession]:
    async with SessionLocal() as session:
        yield session


@pytest.fixture
async def library(db: AsyncSession) -> Track:
    artist = Artist(name="Salt ’n’ Pepa", name_key=name_key("Salt ’n’ Pepa"))
    db.add(artist)
    await db.flush()
    album = Album(title="Album", title_key="album", artist_id=artist.id)
    db.add(album)
    await db.flush()
    track = Track(
        id=uuid.UUID(int=1),
        title="Push It",
        artist_id=artist.id,
        album_id=album.id,
        artist_credit=artist.name,
        path="matching/push-it.mp3",
        duration=180,
        codec="mp3",
        bitrate=192,
    )
    db.add(track)
    await db.flush()
    return track


def catalog(title: str = "Push It (Radio Version)", artist: str = "Salt-N-Pepa", **values: object) -> CatalogTrack:
    return CatalogTrack(
        **{
            "id": "catalog-track",
            "title": title,
            "artist": artist,
            "artist_id": None,
            "album": None,
            "album_id": None,
            "cover_url": None,
            "duration": 180,
            "preview_url": None,
            **values,
        }
    )


@pytest.mark.parametrize("temporary", [False, True])
async def test_loose_matching_includes_temporary_tracks(db: AsyncSession, library: Track, temporary: bool) -> None:
    library.is_temporary = temporary
    tracks = [
        catalog(),
        catalog(artist="Salt‐n‐Pepa feat. Guest"),
        catalog("Push It (Extended Mix)"),
        catalog(artist="Other Artist"),
    ]
    await match_tracks(db, tracks)
    assert [track.library_id for track in tracks] == [library.id, library.id, None, None]


async def test_loose_matching_preserves_library_extended_mix(db: AsyncSession, library: Track) -> None:
    library.title = "Push It (Extended Mix)"
    track = catalog()
    await match_tracks(db, [track])
    assert track.library_id is None


async def test_loose_matching_uses_album_artist(db: AsyncSession, library: Track) -> None:
    guest = Artist(name="Guest", name_key="guest")
    db.add(guest)
    await db.flush()
    library.artist_id = guest.id
    track = catalog()
    await match_tracks(db, [track])
    assert track.library_id == library.id


async def test_loose_matching_typographic_apostrophe(db: AsyncSession, library: Track) -> None:
    artist = await db.get(Artist, library.artist_id)
    artist.name = "Melle Mel"
    artist.name_key = name_key(artist.name)
    library.title = "White Lines (Don’t Do It)"
    track = catalog("White Lines (Don't Do It)", "Melle Mel")
    await match_tracks(db, [track])
    assert track.library_id == library.id


@pytest.mark.parametrize("duration, matches", [(172, True), (188, True), (171.9, False), (188.1, False), (None, True)])
async def test_loose_matching_duration(
    db: AsyncSession, library: Track, duration: float | None, matches: bool,
) -> None:
    track = catalog(duration=duration)
    await match_tracks(db, [track])
    assert track.library_id == (library.id if matches else None)


@pytest.mark.parametrize("exact", [False, True])
async def test_loose_matching_quality_and_exact_priority(db: AsyncSession, library: Track, exact: bool) -> None:
    lossless = Track(
        id=uuid.UUID(int=2),
        title="Push It (Single Version)",
        artist_id=library.artist_id,
        album_id=library.album_id,
        artist_credit=library.artist_credit,
        path="matching/push-it.flac",
        duration=180,
        codec="flac",
    )
    db.add(lossless)
    track = catalog("Push It", "Salt ’n’ Pepa") if exact else catalog()
    await match_tracks(db, [track])
    assert track.library_id == (library.id if exact else lossless.id)


async def test_exact_isrc_match_keeps_existing_behavior(db: AsyncSession, library: Track) -> None:
    library.isrc = "MATCH"
    track = catalog("Different Title", "Other Artist", duration=300, isrc="MATCH")
    await match_tracks(db, [track])
    assert track.library_id == library.id


@pytest.mark.parametrize("prefix", ["100%", "Under_score", "Back\\slash"])
async def test_loose_matching_escaped_prefix(db: AsyncSession, library: Track, prefix: str) -> None:
    library.title = f"{prefix} Song"
    track = catalog(f"{prefix} Song (Radio Version)")
    await match_tracks(db, [track])
    assert track.library_id == library.id
