import base64
import struct
from pathlib import Path

import httpx
import mutagen
from mutagen.apev2 import APEBinaryValue, APEv2
from mutagen.asf import ASF, ASFByteArrayAttribute
from mutagen.flac import FLAC, Picture
from mutagen.id3 import APIC, ID3, TALB, TCON, TDRC, TIT2, TPE1, TPE2, TPOS, TPUB, TRCK, TSRC, TXXX, UFID
from mutagen.mp4 import MP4, MP4Cover

from app.config import get_settings
from app.services.musicbrainz import TrackMeta

_ID_KEYS = {
    "isrc",
    "musicbrainz_trackid",
    "musicbrainz_albumid",
    "musicbrainz_releasegroupid",
    "musicbrainz_artistid",
    "musicbrainz_albumartistid",
}
_MB_NAMES = {
    "musicbrainz_trackid": "MusicBrainz Track Id",
    "musicbrainz_albumid": "MusicBrainz Album Id",
    "musicbrainz_releasegroupid": "MusicBrainz Release Group Id",
    "musicbrainz_artistid": "MusicBrainz Artist Id",
    "musicbrainz_albumartistid": "MusicBrainz Album Artist Id",
}


def write_tags(path: Path, meta: TrackMeta, cover: bytes | None, clear_missing: bool = False) -> None:
    values = {
        "title": meta.title,
        "artist": meta.artist,
        "album": meta.album,
        "albumartist": meta.album_artist,
        "tracknumber": str(meta.track_no) if meta.track_no is not None else None,
        "totaltracks": str(meta.track_total) if meta.track_total is not None else None,
        "discnumber": str(meta.disc_no) if meta.disc_no is not None else None,
        "totaldiscs": str(meta.disc_total) if meta.disc_total is not None else None,
        "date": meta.date or (str(meta.year) if meta.year else None),
        "genre": meta.genre,
        "isrc": meta.isrc,
        "label": meta.label,
        "musicbrainz_trackid": meta.mb_recording_id,
        "musicbrainz_albumid": meta.mb_release_id,
        "musicbrainz_releasegroupid": meta.mb_release_group_id,
        "musicbrainz_artistid": meta.artist_mbid,
        "musicbrainz_albumartistid": meta.album_artist_mbid,
    }
    audio = mutagen.File(path)
    if audio is None:
        raise ValueError("Audiodatei nicht lesbar")
    if audio.tags is None:
        audio.add_tags()

    def set_value(key: str, tag: str, value: object | None) -> None:
        if value is not None:
            audio[tag] = value
        elif clear_missing and key in _ID_KEYS:
            if tag in audio.tags:
                del audio.tags[tag]

    if isinstance(audio, MP4):
        atoms = {
            "title": "\xa9nam",
            "artist": "\xa9ART",
            "album": "\xa9alb",
            "albumartist": "aART",
            "date": "\xa9day",
            "genre": "\xa9gen",
        }
        for key, atom in atoms.items():
            set_value(key, atom, [values[key]] if values[key] is not None else None)
        for key, atom in {"isrc": "ISRC", "label": "LABEL", **_MB_NAMES}.items():
            set_value(
                key, f"----:com.apple.iTunes:{atom}", [values[key].encode("utf-8")] if values[key] is not None else None
            )
        for atom, number, total in (("trkn", meta.track_no, meta.track_total), ("disk", meta.disc_no, meta.disc_total)):
            if number is not None or total is not None:
                audio[atom] = [(number or 0, total or 0)]
        if cover:
            audio["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
    elif isinstance(audio.tags, ID3):
        frames = {
            "title": TIT2,
            "artist": TPE1,
            "album": TALB,
            "albumartist": TPE2,
            "date": TDRC,
            "genre": TCON,
            "isrc": TSRC,
            "label": TPUB,
        }
        for key, frame in frames.items():
            if values[key] is not None:
                audio.tags.add(frame(encoding=3, text=[values[key]]))
            elif clear_missing and key in _ID_KEYS:
                audio.tags.delall(frame.__name__)
        for frame, number, total in ((TRCK, meta.track_no, meta.track_total), (TPOS, meta.disc_no, meta.disc_total)):
            if number is not None or total is not None:
                audio.tags.add(frame(encoding=3, text=[f"{number or 0}/{total}" if total else str(number)]))
        if clear_missing:
            # EasyID3 and older taggers may use either UFID or TXXX for recording ids / ISRC.
            for key in _ID_KEYS:
                if values[key] is None:
                    names = {_MB_NAMES.get(key, "ISRC").casefold(), key.casefold()}
                    for frame in list(audio.tags.getall("TXXX")):
                        if frame.desc.casefold() in names:
                            del audio.tags[frame.HashKey]
            if meta.mb_recording_id is None:
                audio.tags.delall("UFID:http://musicbrainz.org")
        if meta.mb_recording_id is not None:
            audio.tags.add(UFID(owner="http://musicbrainz.org", data=meta.mb_recording_id.encode("ascii")))
        for key, name in _MB_NAMES.items():
            if key != "musicbrainz_trackid" and values[key] is not None:
                audio.tags.add(TXXX(encoding=3, desc=name, text=[values[key]]))
        if cover:
            audio.tags.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=cover))
        audio.save(v2_version=4)
        return
    elif isinstance(audio.tags, APEv2) or isinstance(audio, ASF):
        ape = isinstance(audio.tags, APEv2)
        keys = {
            "title": "Title",
            "artist": "Artist" if ape else "Author",
            "album": "Album" if ape else "WM/AlbumTitle",
            "albumartist": "Album Artist" if ape else "WM/AlbumArtist",
            "tracknumber": "Track" if ape else "WM/TrackNumber",
            "discnumber": "Disc" if ape else "WM/PartOfSet",
            "date": "Year" if ape else "WM/Year",
            "genre": "Genre" if ape else "WM/Genre",
            "isrc": "ISRC" if ape else "WM/ISRC",
            "label": "Label" if ape else "WM/Publisher",
            **{k: k.upper() if ape else v.replace("MusicBrainz ", "MusicBrainz/") for k, v in _MB_NAMES.items()},
        }
        for key, tag in keys.items():
            value = values[key]
            if key in {"tracknumber", "discnumber"}:
                number, total = (
                    (meta.track_no, meta.track_total) if key == "tracknumber" else (meta.disc_no, meta.disc_total)
                )
                value = f"{number or 0}/{total}" if total else value
            set_value(key, tag, value if ape else [value] if value is not None else None)
        if cover:
            if ape:
                audio["Cover Art (Front)"] = APEBinaryValue(b"cover.jpg\0" + cover)
            else:
                data = struct.pack("<BI", 3, len(cover)) + "image/jpeg\0".encode("utf-16-le") + b"\0\0" + cover
                audio["WM/Picture"] = [ASFByteArrayAttribute(data)]
    else:
        for key, value in values.items():
            set_value(key, key, [value] if value is not None else None)
        if cover:
            picture = Picture()
            picture.type = 3
            picture.mime = "image/jpeg"
            picture.data = cover
            if isinstance(audio, FLAC):
                audio.clear_pictures()
                audio.add_picture(picture)
            else:
                audio["METADATA_BLOCK_PICTURE"] = [base64.b64encode(picture.write()).decode("ascii")]
    audio.save()


async def fetch_cover(meta: TrackMeta) -> bytes | None:
    candidates = []
    if meta.mb_release_id:
        candidates.append(
            (
                f"{meta.mb_release_id}.jpg",
                [
                    f"https://coverartarchive.org/release/{meta.mb_release_id}/front-1200",
                    *(
                        [f"https://coverartarchive.org/release-group/{meta.mb_release_group_id}/front-1200"]
                        if meta.mb_release_group_id
                        else []
                    ),
                ],
            )
        )
    if meta.cover_url:
        candidates.append((f"dz-{meta.deezer_album_id}.jpg", [meta.cover_url]))
    for filename, urls in candidates:
        cache = get_settings().data_dir / "caa" / filename
        try:
            if cache.is_file():
                return cache.read_bytes()
            async with httpx.AsyncClient(follow_redirects=True, timeout=20) as client:
                response = await client.get(urls[0])
                if response.status_code == 404 and len(urls) > 1:
                    response = await client.get(urls[1])
                response.raise_for_status()
                if not response.content:
                    continue
                cache.parent.mkdir(parents=True, exist_ok=True)
                cache.write_bytes(response.content)
                return response.content
        except (httpx.HTTPError, OSError):
            pass
    return None
