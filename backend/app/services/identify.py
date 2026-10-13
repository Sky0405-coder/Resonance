import math
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from pathlib import PurePosixPath

from rapidfuzz import fuzz

from app.services.deezer import DeezerError, artist_string, deezer
from app.services.matching import name_key
from app.services.musicbrainz import MusicBrainzError, TrackMeta, mb
from app.services.resolve import resolve_track
from app.services.sources.youtube import norm
from app.services.tags import TrackTags, primary_artist


@dataclass
class Candidate:
    score: float
    recording_id: str
    release_id: str | None
    release_group_id: str | None
    album: str | None
    disc_no: int | None
    track_no: int | None
    release_tracks: int | None
    year: int | None
    title: str | None = None  # recording title as known to AcoustID


@dataclass(eq=False)
class FileInfo:
    candidates: list[Candidate]
    tags: TrackTags


@dataclass
class AlbumCtx:
    album: str
    album_artist: str
    year: int | None
    disc_total: int | None
    size: int = field(default=1, compare=False)  # files sharing this album context


def group_key(rel_path: str) -> str:
    parent = PurePosixPath(rel_path).parent
    if re.fullmatch(r"(cd|disc|disk)\s*\d+", parent.name, flags=re.IGNORECASE):
        parent = parent.parent
    return "" if str(parent) == "." else str(parent)


def candidates(results: list[dict]) -> list[Candidate]:
    out = []
    for result in results:
        score = result.get("score", 0) or 0
        if score < 0.8:
            continue
        for recording in result.get("recordings", []) or []:
            if not recording.get("id"):
                continue
            groups = recording.get("releasegroups", []) or []
            if not groups:
                out.append(
                    Candidate(score, recording["id"], None, None, None, None, None, None, None, recording.get("title"))
                )
            for group in groups:
                for release in group.get("releases", []) or []:
                    for medium in release.get("mediums", []) or []:
                        for track in medium.get("tracks", []) or []:
                            out.append(
                                Candidate(
                                    score,
                                    recording["id"],
                                    release.get("id"),
                                    group.get("id"),
                                    group.get("title"),
                                    medium.get("position"),
                                    track.get("position"),
                                    release.get("track_count"),
                                    (release.get("date") or {}).get("year"),
                                    recording.get("title"),
                                )
                            )
    return out


def _fit(candidate: Candidate, tags: TrackTags) -> tuple[bool, bool, float]:
    """How well a candidate fits a file: title agrees, position agrees, fingerprint score.

    AcoustID sometimes links one fingerprint to several recordings of the same album, so the existing
    tags decide between them.
    """
    title_ok = bool(candidate.title) and fuzz.token_set_ratio(norm(candidate.title), norm(tags.title)) >= 85
    position_ok = (
        tags.track_no is not None
        and candidate.track_no == tags.track_no
        and (tags.disc_no is None or candidate.disc_no == tags.disc_no)
    )
    return title_ok, position_ok, candidate.score


def assign_releases(files: list[FileInfo]) -> dict[FileInfo, Candidate]:
    """Assign files of one folder to MusicBrainz releases.

    Greedy: take the release covering most remaining files (ties: track numbers that agree with the tags,
    track count closest to the folder size, earliest year), give every file at most one position and
    every position at most one file, repeat for the rest – folders may hold several albums.
    """
    assigned: dict[FileInfo, Candidate] = {}
    remaining = [f for f in files if f.candidates]
    while remaining:
        releases: dict[str, list[FileInfo]] = defaultdict(list)
        details: dict[str, Candidate] = {}
        for file in remaining:
            for rid in dict.fromkeys(c.release_id for c in file.candidates if c.release_id):
                releases[rid].append(file)
                details.setdefault(rid, next(c for c in file.candidates if c.release_id == rid))
        if not releases:
            break

        def agreement(rid: str) -> int:
            return sum(any(c.release_id == rid and _fit(c, f.tags)[1] for c in f.candidates) for f in releases[rid])

        best = min(
            releases,
            key=lambda rid: (
                -len(releases[rid]),
                -agreement(rid),
                abs((details[rid].release_tracks or 0) - len(remaining)),
                details[rid].year or 9999,
                rid,
            ),
        )
        count = len(releases[best])
        tracks = details[best].release_tracks or 0
        ok = count >= 2 and (
            count >= math.ceil(0.6 * len(remaining)) or (tracks > 0 and count >= math.ceil(0.6 * tracks))
        )
        single = (
            len(files) == 1
            and files[0].tags.has_album_tag
            and any(
                c.release_id == best and c.album is not None and name_key(files[0].tags.album) == name_key(c.album)
                for c in files[0].candidates
            )
        )
        if not ok and not single:
            break
        pairs = sorted(
            ((f, c) for f in releases[best] for c in f.candidates if c.release_id == best),
            key=lambda fc: _fit(fc[1], fc[0].tags),
            reverse=True,
        )
        taken: set[tuple[int | None, int | None]] = set()
        for file, candidate in pairs:
            if file in assigned or (candidate.disc_no, candidate.track_no) in taken:
                continue
            assigned[file] = candidate
            taken.add((candidate.disc_no, candidate.track_no))
        remaining = [f for f in remaining if f not in assigned and f not in releases[best]]
    return assigned


# Album-artist spellings for compilations found in real libraries.
_VARIOUS = {
    "various artists", "various", "va", "v.a.", "v/a", "diverse", "diverse interpreten", "div. interpreten",
    "verschiedene interpreten", "verschiedene", "sampler", "compilation", "multi-interprètes", "artistes divers",
}  # fmt: skip


def _common[T](values: list[T]) -> T | None:
    return Counter(values).most_common(1)[0][0] if values else None


def album_context(files: list[FileInfo]) -> dict[FileInfo, AlbumCtx]:
    out = {}
    groups: dict[str, list[FileInfo]] = defaultdict(list)
    for file in files:
        tags = file.tags
        if not tags.has_album_tag:
            out[file] = AlbumCtx(tags.title, tags.artist, tags.year, tags.disc_no, 1)
        else:
            groups[name_key(tags.album)].append(file)
    for group in groups.values():
        artists = [f.tags.album_artist for f in group if f.tags.has_album_artist_tag]
        if len(artists) >= len(group) / 2:
            artist = _common(artists)
        elif len({name_key(primary_artist(f.tags.artist)) for f in group}) >= 2:
            artist = "Various Artists"
        else:
            artist = group[0].tags.artist
        if name_key(artist) in _VARIOUS:
            artist = "Various Artists"
        context = AlbumCtx(
            _common([f.tags.album for f in group]),
            artist,
            _common([f.tags.year for f in group if f.tags.year is not None]),
            max((f.tags.disc_no for f in group if f.tags.disc_no is not None), default=None),
            len(group),
        )
        for file in group:
            out[file] = context
    return out


def _tag_meta(tags: TrackTags, context: AlbumCtx) -> TrackMeta:
    return TrackMeta(
        title=tags.title,
        artist=tags.artist_credit,
        artist_mbid=tags.mb_artist_id,
        album=context.album,
        album_artist=context.album_artist,
        album_artist_mbid=tags.mb_album_artist_id,
        track_no=tags.track_no,
        track_total=tags.track_total,
        disc_no=tags.disc_no,
        disc_total=context.disc_total,
        year=context.year,
        date=str(context.year) if context.year else None,
        duration=tags.duration,
        isrc=tags.isrc,
        genre=tags.genre,
        label=tags.label,
        mb_recording_id=tags.mb_recording_id,
        mb_release_id=tags.mb_album_id,
        mb_release_group_id=tags.mb_release_group_id,
    )


def _track_meta(tags: TrackTags, context: AlbumCtx, basic: dict, recording_id: str | None) -> TrackMeta:
    return _tag_meta(tags, context).model_copy(
        update={
            "title": basic.get("title") or tags.title,
            "artist": basic.get("artist") or tags.artist_credit,
            "artist_mbid": basic.get("artist_mbid"),
            "isrc": basic.get("isrc"),
            "genre": basic.get("genre"),
            "duration": basic.get("duration", basic.get("length")),
            "mb_recording_id": recording_id,
            "album_artist_mbid": None,
            "track_total": None,
            "date": str(context.year) if context.year else None,
            "label": None,
            "mb_release_id": None,
            "mb_release_group_id": None,
        }
    )


async def identify_file(
    file: FileInfo,
    context: AlbumCtx,
    assigned: Candidate | None,
    import_unidentified: bool,
) -> tuple[TrackMeta | None, str | None]:
    if assigned is not None and assigned.release_id:
        try:
            metas = await mb.track_meta_list(await mb.release_full(assigned.release_id))
            for meta in metas:
                if (meta.disc_no, meta.track_no) == (assigned.disc_no, assigned.track_no):
                    return meta, "release"
        except (MusicBrainzError, ValueError, KeyError):
            pass
    if file.candidates:
        best = max(file.candidates, key=lambda c: (_fit(c, file.tags)[0], c.score))
        try:
            if context.size == 1:
                # A lone song (e.g. picked from a compilation) goes to its original release, like on Spotify.
                return await mb.recording_meta(best.recording_id), "recording"
            basic = await mb.recording_basic(best.recording_id)
            return _track_meta(file.tags, context, basic, best.recording_id), "recording"
        except (MusicBrainzError, ValueError, KeyError):
            pass
    if file.tags.extra.get("has_artist_tag") and file.tags.extra.get("has_title_tag"):
        tags = file.tags
        try:
            results = await deezer.search_tracks(f'artist:"{tags.artist_credit}" track:"{tags.title}"', 5)
            for result in results:
                if (
                    fuzz.token_set_ratio(norm(tags.title), norm(result.get("title", ""))) >= 90
                    and fuzz.token_set_ratio(norm(tags.artist_credit), norm(artist_string(result))) >= 85
                    and result.get("duration") is not None
                    and abs(tags.duration - result["duration"]) <= 3
                ):
                    meta = await resolve_track(str(result["id"]))
                    if context.size == 1:
                        return meta, "deezer"
                    return _track_meta(tags, context, meta.model_dump(), meta.mb_recording_id), "deezer"
        except (DeezerError, MusicBrainzError, ValueError, KeyError):
            pass
    return (_tag_meta(file.tags, context), "tags") if import_unidentified else (None, None)
