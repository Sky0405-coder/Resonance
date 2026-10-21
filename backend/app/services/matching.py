import re
import unicodedata
from collections import defaultdict

from sqlalchemy import func, or_, select, tuple_
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import aliased

from app.models import Album, Artist, Track
from app.schemas import CatalogAlbum, CatalogArtist, CatalogTrack
from app.services.tags import primary_artist

_LOOSE_PUNCTUATION = str.maketrans({**dict.fromkeys("’‘`´'\"“”", ""), **dict.fromkeys("‐‑‒–—−-&+/", " ")})
_FEATURED = re.compile(
    r"\(\s*(?:feat\.?|ft\.?|featuring)\s+[^)]*\)|\[\s*(?:feat\.?|ft\.?|featuring)\s+[^\]]*\]"
    r"|\s+(?:feat\.?|ft\.?|featuring)\s+.*?(?=\s*[\[(]|\s+-\s+|$)",
    re.IGNORECASE,
)
_BRACKETED_SUFFIX = re.compile(r"\s*(?:\(([^()]*)\)|\[([^\[\]]*)\])$")
_VERSION = re.compile(
    r"\b(?:radio (?:edit|version|mix)|single (?:version|edit)|(?:album|original) version|"
    r"remaster(?:ed)?|mono|stereo|explicit|clean|edit)\b"
)
_DISTINCT_VERSION = re.compile(r"\b(?:remix|live|acoustic|extended|club|instrumental)\b|(?<!radio )\bmix\b")
_BARE_VERSION_SUFFIX = re.compile(
    r"\s+(?:radio[\s‐‑‒–—−-]+(?:edit|version|mix)|single[\s‐‑‒–—−-]+(?:version|edit)|"
    r"(?:album|original)[\s‐‑‒–—−-]+version)$",
    re.IGNORECASE,
)


def name_key(value: str) -> str:
    return " ".join(value.casefold().split())


def loose_key(value: str) -> str:
    # The spacing acute accent decomposes into a space and a combining mark in NFKD.
    value = unicodedata.normalize("NFKD", value.replace("´", "'"))
    value = "".join(char for char in value if not unicodedata.category(char).startswith("M"))
    value = value.casefold().translate(_LOOSE_PUNCTUATION)
    value = re.sub(r"\b(?:and|und|n)\b", " ", value)
    return " ".join("".join(char for char in value if char.isalnum() or char.isspace()).split())


def base_title(title: str) -> str:
    title = " ".join(_FEATURED.sub(" ", title).split())
    while True:
        bracketed = _BRACKETED_SUFFIX.search(title)
        if bracketed:
            decoration = bracketed.group(1) or bracketed.group(2) or ""
            start = bracketed.start()
        else:
            head, separator, decoration = title.rpartition(" - ")
            start = len(head) if separator else len(title)
        key = loose_key(decoration)
        if start < len(title):
            if _VERSION.search(key) and not _DISTINCT_VERSION.search(key):
                title = title[:start].rstrip()
                continue
            return title
        # Some providers put "Radio Edit" after a bracketed featured artist without a separator.
        bare = _BARE_VERSION_SUFFIX.search(title)
        if bare:
            title = title[:bare.start()].rstrip()
            continue
        return title


async def match_artists(db: AsyncSession, artists: list[CatalogArtist]) -> None:
    if not artists:
        return
    rows = await db.scalars(select(Artist).where(Artist.name_key.in_([name_key(a.name) for a in artists])))
    by_name = {a.name_key: a.id for a in rows}
    for artist in artists:
        artist.library_id = by_name.get(name_key(artist.name))


async def match_albums(db: AsyncSession, albums: list[CatalogAlbum]) -> None:
    if not albums:
        return
    rows = await db.execute(
        select(Album.id, Artist.name_key, Album.title_key)
        .join(Artist)
        .where(tuple_(Artist.name_key, Album.title_key).in_([(name_key(a.artist), name_key(a.title)) for a in albums]))
    )
    matches = {(artist, title): id for id, artist, title in rows}
    for album in albums:
        album.library_id = matches.get((name_key(album.artist), name_key(album.title)))


async def match_tracks(db: AsyncSession, tracks: list[CatalogTrack]) -> None:
    if not tracks:
        return
    album_artist = aliased(Artist)
    pairs = [(name_key(primary_artist(t.artist)), t.title.casefold()) for t in tracks]
    rows = await db.execute(
        select(Track.id, Track.isrc, func.lower(Track.title), Artist.name_key, album_artist.name_key)
        .join(Artist, Artist.id == Track.artist_id)
        .join(Album, Album.id == Track.album_id)
        .join(album_artist, album_artist.id == Album.artist_id)
        .where(
            or_(
                Track.isrc.in_([t.isrc for t in tracks if t.isrc]),
                tuple_(Artist.name_key, func.lower(Track.title)).in_(pairs),
                tuple_(album_artist.name_key, func.lower(Track.title)).in_(pairs),
            )
        )
        .order_by(Track.id)
    )
    by_isrc = {}
    by_name = {}
    for id, isrc, title, artist, album_credit in rows:
        if isrc:
            by_isrc.setdefault(isrc, id)
        by_name.setdefault((artist, title), id)
        by_name.setdefault((album_credit, title), id)
    for track in tracks:
        track.library_id = by_isrc.get(track.isrc) or by_name.get(
            (name_key(primary_artist(track.artist)), track.title.casefold())
        )

    unmatched = [track for track in tracks if track.library_id is None]
    prefixes = {words[0].lower() for track in unmatched if (words := base_title(track.title).split())}
    if not prefixes:
        return
    patterns = [
        prefix.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") + "%" for prefix in sorted(prefixes)
    ]
    rows = await db.execute(
        select(Track, Artist.name, album_artist.name)
        .join(Artist, Artist.id == Track.artist_id)
        .join(Album, Album.id == Track.album_id)
        .join(album_artist, album_artist.id == Album.artist_id)
        .where(or_(*(func.lower(Track.title).like(pattern, escape="\\") for pattern in patterns)))
        .order_by(Track.id)
        .limit(5000)
    )
    # duplicates imports name_key, so defer this import until matching is called.
    from app.services.duplicates import track_quality

    candidates: dict[tuple[str, str], list[Track]] = defaultdict(list)
    for library_track, artist, album_credit in sorted(rows, key=lambda row: (-track_quality(row[0]), row[0].id)):
        title_key = loose_key(base_title(library_track.title))
        for artist_key in {loose_key(artist), loose_key(album_credit)}:
            candidates[(artist_key, title_key)].append(library_track)
    for track in unmatched:
        key = (loose_key(primary_artist(track.artist)), loose_key(base_title(track.title)))
        for candidate in candidates.get(key, []):
            if (
                track.duration is not None
                and candidate.duration is not None
                and abs(track.duration - candidate.duration) > 8
            ):
                continue
            track.library_id = candidate.id
            break
