"""Reading audio metadata with mutagen into a format-independent structure."""

import base64
import re
import struct
from dataclasses import dataclass, field
from pathlib import Path

import mutagen
from mutagen.apev2 import APEv2
from mutagen.asf import ASF
from mutagen.flac import Picture
from mutagen.id3 import ID3
from mutagen.mp3 import MP3
from mutagen.mp4 import MP4

AUDIO_EXTENSIONS = {
    ".mp3",
    ".flac",
    ".m4a",
    ".mp4",
    ".aac",
    ".ogg",
    ".oga",
    ".opus",
    ".wav",
    ".aif",
    ".aiff",
    ".wv",
    ".ape",
    ".wma",
    ".mpc",
}
COVER_NAMES = ("cover", "folder", "front", "album", "albumart")
COVER_EXTENSIONS = (".jpg", ".jpeg", ".png", ".webp")

_FEAT = re.compile(r"\s+(?:feat\.?|ft\.?|featuring)\s+", re.IGNORECASE)
_RG = re.compile(r"(-?\d+(?:\.\d+)?)")


@dataclass
class TrackTags:
    title: str
    artist: str
    artist_credit: str
    album: str
    album_artist: str
    has_album_tag: bool = False
    has_album_artist_tag: bool = False
    track_total: int | None = None
    disc_total: int | None = None
    label: str | None = None
    mb_release_group_id: str | None = None
    track_no: int | None = None
    disc_no: int | None = None
    year: int | None = None
    genre: str | None = None
    duration: float = 0
    codec: str | None = None
    bitrate: int | None = None
    sample_rate: int | None = None
    mb_recording_id: str | None = None
    mb_album_id: str | None = None
    mb_artist_id: str | None = None
    mb_album_artist_id: str | None = None
    isrc: str | None = None
    artist_sort: str | None = None
    album_artist_sort: str | None = None
    replaygain_track_gain: float | None = None
    replaygain_album_gain: float | None = None
    extra: dict = field(default_factory=dict)

    def __post_init__(self) -> None:
        # Real-world tags contain NUL bytes, junk IDs and absurdly long values; Postgres rejects all of them.
        for name, limit in _LIMITS.items():
            value = getattr(self, name)
            if isinstance(value, str):
                value = _CONTROL.sub("", value).strip()[:limit]
                if name in _EXACT and len(value) != _EXACT[name]:
                    value = ""
                setattr(self, name, value or (None if name not in _REQUIRED else "Unknown"))


_CONTROL = re.compile(r"[\x00-\x1f\x7f]")
_LIMITS = {
    "title": 512, "artist": 512, "artist_credit": 1024, "album": 512, "album_artist": 512, "genre": 256,
    "codec": 32, "mb_recording_id": 36, "mb_album_id": 36, "mb_artist_id": 36, "mb_album_artist_id": 36,
    "mb_release_group_id": 36, "label": 512, "isrc": 16, "artist_sort": 512, "album_artist_sort": 512,
}  # fmt: skip
_EXACT = {
    "mb_release_group_id": 36,
    "mb_recording_id": 36,
    "mb_album_id": 36,
    "mb_artist_id": 36,
    "mb_album_artist_id": 36,
}
_REQUIRED = {"title", "artist", "artist_credit", "album", "album_artist"}


def _first(tags, *keys: str) -> str | None:
    if tags is None:
        return None
    for key in keys:
        try:
            value = tags.get(key)
        except (KeyError, ValueError):
            continue
        if value:
            v = value[0] if isinstance(value, list) else value
            v = str(v).strip()
            if v:
                return v
    return None


def _all(tags, key: str) -> list[str]:
    try:
        value = tags.get(key) if tags is not None else None
    except (KeyError, ValueError):
        return []
    if not value:
        return []
    return [str(v).strip() for v in (value if isinstance(value, list) else [value]) if str(v).strip()]


def _int_prefix(value: str | None) -> int | None:
    """'3/12' -> 3, '2004-05-01' -> 2004."""
    if not value:
        return None
    m = re.match(r"\s*(\d+)", value)
    return int(m.group(1)) if m else None


def _gain(value: str | None) -> float | None:
    if not value:
        return None
    m = _RG.search(value)
    return float(m.group(1)) if m else None


def primary_artist(credit: str) -> str:
    return _FEAT.split(credit, maxsplit=1)[0].strip() or credit


def _normal_tags(audio: mutagen.FileType) -> dict:
    tags = audio.tags
    if tags is None:
        return {}
    if isinstance(tags, ID3):
        keys = {
            "title": "TIT2",
            "artist": "TPE1",
            "album": "TALB",
            "albumartist": "TPE2",
            "tracknumber": "TRCK",
            "discnumber": "TPOS",
            "date": "TDRC",
            "originaldate": "TDOR",
            "genre": "TCON",
            "isrc": "TSRC",
            "label": "TPUB",
            "artistsort": "TSOP",
            "albumartistsort": "TSO2",
        }
        out = {k: tags[v].text for k, v in keys.items() if v in tags}
        for frame in tags.getall("TXXX"):
            key = frame.desc.lower().replace("musicbrainz ", "musicbrainz_").replace(" ", "")
            out[key] = frame.text
        ufid = tags.get("UFID:http://musicbrainz.org")
        if ufid:
            out["musicbrainz_trackid"] = [ufid.data.decode("ascii", errors="replace")]
        return out
    if isinstance(audio, MP4):
        keys = {
            "title": "\xa9nam",
            "artist": "\xa9ART",
            "album": "\xa9alb",
            "albumartist": "aART",
            "date": "\xa9day",
            "genre": "\xa9gen",
            "artistsort": "soar",
            "albumartistsort": "soaa",
        }
        out = {k: tags[v] for k, v in keys.items() if v in tags}
        for key, value in tags.items():
            if key.startswith("----:com.apple.iTunes:"):
                name = key.rsplit(":", 1)[1].lower().replace("musicbrainz ", "musicbrainz_").replace(" ", "")
                out[name] = [bytes(v).decode("utf-8", errors="replace") for v in value]
        for atom, key in (("trkn", "tracknumber"), ("disk", "discnumber")):
            if tags.get(atom):
                number, total = tags[atom][0]
                out[key] = [f"{number}/{total}"]
        return out
    out = {k.lower(): v for k, v in tags.items()}
    if isinstance(tags, APEv2):
        out = {k: list(v) if hasattr(v, "__iter__") else [str(v)] for k, v in out.items() if k != "cover art (front)"}
        aliases = {"album artist": "albumartist", "track": "tracknumber", "disc": "discnumber"}
    elif isinstance(audio, ASF):
        aliases = {
            "author": "artist",
            "wm/albumtitle": "album",
            "wm/albumartist": "albumartist",
            "wm/tracknumber": "tracknumber",
            "wm/partofset": "discnumber",
            "wm/year": "year",
            "wm/genre": "genre",
            "wm/isrc": "isrc",
            "wm/publisher": "label",
        }
        for key in list(out):
            if key.startswith("musicbrainz/"):
                aliases[key] = key.replace("musicbrainz/", "musicbrainz_").replace(" ", "")
    else:
        aliases = {}
    for original, normal in aliases.items():
        if original in out:
            out[normal] = out[original]
    return out


def _total(value: str | None) -> int | None:
    return _int_prefix(value.split("/", 1)[1]) if value and "/" in value else None


def read_tags(path: Path) -> TrackTags | None:
    try:
        audio = mutagen.File(path)
        if audio is None:
            return None
        tags = _normal_tags(audio)
        if isinstance(audio, (MP3, MP4)):
            # Keep EasyID3/EasyMP4's existing genre and ReplayGain decoding alongside the extra raw fields.
            easy = mutagen.File(path, easy=True)
            if easy is not None and easy.tags is not None:
                tags.update(dict(easy.tags.items()))
    except Exception:
        return None
    info = audio.info
    artists = _all(tags, "artist")
    credit = " / ".join(artists) if len(artists) > 1 else (artists[0] if artists else "")
    album_dir = path.parent
    artist = primary_artist(artists[0]) if artists else album_dir.parent.name or "Unknown Artist"
    raw_album_artist = _first(tags, "albumartist", "album artist", "album_artist")
    raw_album = _first(tags, "album")
    raw_title = _first(tags, "title")
    track = _first(tags, "tracknumber")
    disc = _first(tags, "discnumber")
    return TrackTags(
        title=raw_title or path.stem,
        artist=artist,
        artist_credit=credit or artist,
        album=raw_album or album_dir.name or "Unknown Album",
        album_artist=raw_album_artist or artist,
        has_album_tag=bool(raw_album),
        has_album_artist_tag=bool(raw_album_artist),
        track_no=_int_prefix(track),
        track_total=_int_prefix(_first(tags, "totaltracks", "tracktotal")) or _total(track),
        disc_no=_int_prefix(disc),
        disc_total=_int_prefix(_first(tags, "totaldiscs", "disctotal")) or _total(disc),
        year=_int_prefix(_first(tags, "originaldate", "date", "year")),
        genre=_first(tags, "genre"),
        label=_first(tags, "label"),
        duration=float(getattr(info, "length", 0) or 0),
        codec=_codec(audio, path),
        bitrate=(getattr(info, "bitrate", 0) or 0) // 1000 or None,
        sample_rate=getattr(info, "sample_rate", None),
        mb_recording_id=_first(tags, "musicbrainz_trackid", "musicbrainz track id"),
        mb_album_id=_first(tags, "musicbrainz_albumid", "musicbrainz album id"),
        mb_release_group_id=_first(tags, "musicbrainz_releasegroupid"),
        mb_artist_id=_first(tags, "musicbrainz_artistid", "musicbrainz artist id"),
        mb_album_artist_id=_first(tags, "musicbrainz_albumartistid", "musicbrainz album artist id"),
        isrc=_first(tags, "isrc"),
        artist_sort=_first(tags, "artistsort"),
        album_artist_sort=_first(tags, "albumartistsort"),
        replaygain_track_gain=_gain(_first(tags, "replaygain_track_gain")),
        replaygain_album_gain=_gain(_first(tags, "replaygain_album_gain")),
        extra={"has_title_tag": bool(raw_title), "has_artist_tag": bool(artists)},
    )


def _codec(audio, path: Path) -> str:
    name = type(audio).__name__.lower().removeprefix("easy")
    if name == "mp4" and str(getattr(audio.info, "codec", "")).startswith("alac"):
        return "alac"
    return {"mp4": "aac", "oggvorbis": "vorbis", "oggopus": "opus", "monkeysaudio": "ape", "wavpack": "wavpack"}.get(
        name, name or path.suffix.lstrip(".").lower()
    )


def embedded_cover(path: Path) -> bytes | None:
    try:
        audio = mutagen.File(path)
    except Exception:
        return None
    if audio is None:
        return None
    pictures = getattr(audio, "pictures", None)  # FLAC
    if pictures:
        front = next((p for p in pictures if p.type == 3), pictures[0])
        return front.data
    tags = audio.tags
    if tags is None:
        return None
    if hasattr(tags, "getall"):  # ID3
        apic = tags.getall("APIC")
        if apic:
            front = next((p for p in apic if p.type == 3), apic[0])
            return front.data
    covr = tags.get("covr") if hasattr(tags, "get") else None  # MP4
    if covr:
        return bytes(covr[0])
    if isinstance(tags, APEv2) and tags.get("Cover Art (Front)"):
        return bytes(tags["Cover Art (Front)"]).split(b"\0", 1)[-1]
    if isinstance(audio, ASF) and tags.get("WM/Picture"):
        try:
            raw = bytes(tags["WM/Picture"][0].value)
            size = struct.unpack_from("<I", raw, 1)[0]
            offset = 5
            for _ in range(2):
                while raw[offset : offset + 2] != b"\0\0":
                    if offset + 2 > len(raw):
                        raise ValueError("Ungültiges ASF-Cover")
                    offset += 2
                offset += 2
            return raw[offset : offset + size]
        except (ValueError, IndexError, struct.error):
            return None
    block = tags.get("metadata_block_picture") if hasattr(tags, "get") else None  # Ogg/Opus
    if block:
        try:
            return Picture(base64.b64decode(block[0])).data
        except Exception:
            return None
    return None


def folder_cover(directory: Path) -> Path | None:
    try:
        candidates = [p for p in directory.iterdir() if p.is_file() and p.suffix.lower() in COVER_EXTENSIONS]
    except OSError:
        return None
    for name in COVER_NAMES:
        for p in candidates:
            if p.stem.lower() == name:
                return p
    return candidates[0] if len(candidates) == 1 else None
