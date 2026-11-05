"""Song credits (who sang, wrote, produced and mixed it): from the file's tags, completed from MusicBrainz."""

import asyncio
import logging
import re
from datetime import UTC, datetime, timedelta
from pathlib import Path

import mutagen
from mutagen.id3 import ID3
from mutagen.mp4 import MP4
from sqlalchemy.dialects.postgresql import insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.models import Album, Track, TrackCredits
from app.schemas import CreditOut, CreditsOut
from app.services.musicbrainz import MusicBrainzError, mb
from app.services.tags import _FEAT

log = logging.getLogger(__name__)
VERSION = 1
# Roles by section; anything else a musician played (instruments, vocals) counts as performing.
WRITING = ("composer", "lyricist", "writer", "arranger", "librettist")
PRODUCING = ("producer", "co-producer", "executive producer")
ENGINEERING = ("mix", "mastering", "recording", "engineer", "programming", "sound", "audio")
# Free-form tag names and the role they stand for.
_TAG_ROLES = {
    "composer": "composer",
    "lyricist": "lyricist",
    "writer": "writer",
    "songwriter": "writer",
    "arranger": "arranger",
    "producer": "producer",
    "engineer": "engineer",
    "mixer": "mix",
    "mixing engineer": "mix",
    "mastering engineer": "mastering",
    "djmixer": "mix",
}
_SPLIT = re.compile(r"\s*(?:;|\s/\s|\x00)\s*")


def _names(values) -> list[str]:
    if isinstance(values, str):
        values = [values]
    out: list[str] = []
    for value in values or []:
        for name in _SPLIT.split(str(value)):
            name = name.strip()
            if name and name not in out:
                out.append(name)
    return out


def file_credits(path: Path) -> dict:
    """{"people": [[name, role], ...], "label": ..., "copyright": ...} from the file's tags."""
    people: list[tuple[str, str]] = []
    label = copyright_ = None
    try:
        audio = mutagen.File(path)
    except (mutagen.MutagenError, OSError, ValueError):
        return {"people": [], "label": None, "copyright": None}
    tags = audio.tags if audio is not None else None
    if tags is None:
        return {"people": [], "label": None, "copyright": None}

    def add(role: str, values) -> None:
        for name in _names(values):
            people.append((name, role))

    if isinstance(tags, ID3):
        for frame, role in (("TCOM", "composer"), ("TEXT", "lyricist")):
            if frame in tags:
                add(role, tags[frame].text)
        for frame in ("TIPL", "IPLS", "TMCL"):
            for item in tags.getall(frame):
                for role, names in item.people:
                    role = role.strip().lower()
                    add(_TAG_ROLES.get(role, role) if frame != "TMCL" else role, names)
        for frame in tags.getall("TXXX"):
            role = frame.desc.strip().lower()
            if role in _TAG_ROLES:
                add(_TAG_ROLES[role], frame.text)
            elif role in ("label", "publisher"):
                label = label or next(iter(_names(frame.text)), None)
        if "TPUB" in tags:
            label = next(iter(_names(tags["TPUB"].text)), None)
        if "TCOP" in tags:
            copyright_ = next(iter(tags["TCOP"].text), None)
    elif isinstance(audio, MP4):
        if "\xa9wrt" in tags:
            add("composer", tags["\xa9wrt"])
        if "cprt" in tags:
            copyright_ = next(iter(tags["cprt"]), None)
        for key, values in tags.items():
            if not key.startswith("----:com.apple.iTunes:"):
                continue
            role = key.rsplit(":", 1)[1].strip().lower()
            texts = [bytes(v).decode("utf-8", errors="replace") for v in values]
            if role in _TAG_ROLES:
                add(_TAG_ROLES[role], texts)
            elif role in ("label", "publisher"):
                label = label or next(iter(_names(texts)), None)
    else:
        normal = {key.lower(): value for key, value in tags.items()}
        for key, role in _TAG_ROLES.items():
            if key in normal:
                add(role, normal[key])
        for value in _names(normal.get("performer")):
            # Vorbis comments: "Name (instrument)".
            match = re.fullmatch(r"(.+?)\s*\((.+)\)", value)
            people.append((match[1], match[2].lower()) if match else (value, "performer"))
        label = next(iter(_names(normal.get("label") or normal.get("organization") or normal.get("publisher"))), None)
        copyright_ = next(iter(_names(normal.get("copyright"))), None)
    return {"people": [list(person) for person in people], "label": label, "copyright": copyright_}


def _relation_people(relations: list[dict]) -> list[tuple[str, str]]:
    people = []
    for relation in relations:
        artist = relation.get("artist")
        if relation.get("target-type") != "artist" or not artist:
            continue
        name = relation.get("target-credit") or artist.get("name")
        kind = relation.get("type", "")
        attributes = [attribute for attribute in relation.get("attributes", []) if attribute not in ("additional",)]
        if kind in ("instrument", "vocal") and attributes:
            people.extend((name, attribute.lower()) for attribute in attributes)
        elif kind == "vocal":
            people.append((name, "vocals"))
        elif kind == "performer":
            people.append((name, "performer"))
        elif kind == "producer" and "co" in attributes:
            people.append((name, "co-producer"))
        elif kind == "producer" and "executive" in attributes:
            people.append((name, "executive producer"))
        elif kind in ("engineer", "audio", "sound") and attributes:
            people.extend((name, attribute.lower()) for attribute in attributes)
        elif kind:
            people.append((name, kind.replace("mix-dj", "mix")))
    return people


async def musicbrainz_credits(track: Track, album: Album | None) -> dict | None:
    """{"people": [...], "label": ...} from MusicBrainz, None when the song is not there (or it is unreachable)."""
    recording_id = track.mb_recording_id
    try:
        if recording_id is None and track.isrc:
            found = await mb._get(f"isrc/{track.isrc}")
            recording_id = next((item["id"] for item in found.get("recordings", [])), None)
        if recording_id is None:
            return None
        recording = await mb._get(f"recording/{recording_id}", inc="artist-rels+work-rels+work-level-rels")
        people = _relation_people(recording.get("relations", []))
        for relation in recording.get("relations", []):
            work = relation.get("work")
            if relation.get("target-type") == "work" and work:
                people.extend(_relation_people(work.get("relations", [])))
        label = None
        if album is not None and album.mb_release_id:
            release = await mb.release_full(album.mb_release_id)
            label = next((item["label"]["name"] for item in release.get("label-info", []) if item.get("label")), None)
        return {"people": [list(person) for person in people], "label": label}
    except MusicBrainzError:
        log.debug("MusicBrainz credits failed", exc_info=True)
        return None


def _section(people: list[tuple[str, str]], roles) -> list[CreditOut]:
    out: dict[str, list[str]] = {}
    keys: dict[str, str] = {}
    for name, role in people:
        if not roles(role):
            continue
        key = name.casefold()
        keys.setdefault(key, name)
        if role not in out.setdefault(key, []):
            out[key].append(role)
    return [CreditOut(name=keys[key], roles=found) for key, found in out.items()]


def assemble(track: Track, cached: dict) -> CreditsOut:
    """The credits shown: the song's artists from its credit first, then what tags and MusicBrainz name."""
    main, *featured = _FEAT.split(track.artist_credit, maxsplit=1)
    # The main credit stays whole ("Simon & Garfunkel"); several tagged artists are joined with " / ".
    people: list[tuple[str, str]] = [(name, "artist") for name in _names(main)]
    for part in featured:
        people.extend((name, "featured") for name in _names(re.split(r"\s*(?:,|&)\s*", part)))
    for source in ("tags", "musicbrainz"):
        people.extend((name, role) for name, role in (cached.get(source) or {}).get("people", []))

    def writing(role: str) -> bool:
        return role in WRITING

    def producing(role: str) -> bool:
        return role in PRODUCING

    def engineering(role: str) -> bool:
        return role in ENGINEERING or role.endswith("engineer")

    def performing(role: str) -> bool:
        return not (writing(role) or producing(role) or engineering(role))

    tags = cached.get("tags") or {}
    brainz = cached.get("musicbrainz") or {}
    return CreditsOut(
        performers=_section(people, performing),
        writers=_section(people, writing),
        producers=_section(people, producing),
        engineers=_section(people, engineering),
        label=tags.get("label") or brainz.get("label"),
        copyright=tags.get("copyright"),
        sources=[source for source in ("tags", "musicbrainz") if (cached.get(source) or {}).get("people")],
    )


async def credits(db: AsyncSession, track: Track) -> CreditsOut:
    row = await db.get(TrackCredits, track.id)
    stale = row is None or row.data.get("v") != VERSION or row.data.get("mtime") != track.mtime
    # Songs MusicBrainz did not know (or was unreachable for) are asked again after a month.
    if not stale and row.data.get("musicbrainz") is None:
        stale = row.fetched_at < datetime.now(UTC) - timedelta(days=30)
    if not stale:
        return assemble(track, row.data)
    path = get_settings().music_dir / track.path
    tags = await asyncio.to_thread(file_credits, path)
    album = await db.get(Album, track.album_id)
    brainz = await musicbrainz_credits(track, album)
    data = {"v": VERSION, "mtime": track.mtime, "tags": tags, "musicbrainz": brainz}
    await db.execute(
        insert(TrackCredits)
        .values(track_id=track.id, data=data, fetched_at=datetime.now(UTC))
        .on_conflict_do_update(
            index_elements=[TrackCredits.track_id], set_={"data": data, "fetched_at": datetime.now(UTC)}
        )
    )
    await db.commit()
    return assemble(track, data)
