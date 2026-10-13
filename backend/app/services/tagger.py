import base64
from pathlib import Path

import httpx
import mutagen
from mutagen.flac import FLAC, Picture
from mutagen.id3 import APIC, TALB, TCON, TDRC, TIT2, TPE1, TPE2, TPOS, TPUB, TRCK, TSRC, TXXX, UFID
from mutagen.mp4 import MP4, MP4Cover

from app.config import get_settings
from app.services.musicbrainz import TrackMeta


def write_tags(path: Path, meta: TrackMeta, cover: bytes | None) -> None:
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
    if isinstance(audio, MP4):
        atoms = {
            "title": "\xa9nam",
            "artist": "\xa9ART",
            "album": "\xa9alb",
            "albumartist": "aART",
            "date": "\xa9day",
            "genre": "\xa9gen",
        }
        freeforms = {
            "isrc": "ISRC",
            "label": "LABEL",
            "musicbrainz_trackid": "MusicBrainz Track Id",
            "musicbrainz_albumid": "MusicBrainz Album Id",
            "musicbrainz_releasegroupid": "MusicBrainz Release Group Id",
            "musicbrainz_artistid": "MusicBrainz Artist Id",
            "musicbrainz_albumartistid": "MusicBrainz Album Artist Id",
        }
        for key, atom in atoms.items():
            if values[key] is not None:
                audio[atom] = [values[key]]
        for key, atom in freeforms.items():
            if values[key] is not None:
                audio[f"----:com.apple.iTunes:{atom}"] = [values[key].encode("utf-8")]
        for atom, number, total in (("trkn", meta.track_no, meta.track_total), ("disk", meta.disc_no, meta.disc_total)):
            if number is not None or total is not None:
                audio[atom] = [(number or 0, total or 0)]
        if cover:
            audio["covr"] = [MP4Cover(cover, imageformat=MP4Cover.FORMAT_JPEG)]
    elif path.suffix.lower() == ".mp3":
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
        for frame, number, total in ((TRCK, meta.track_no, meta.track_total), (TPOS, meta.disc_no, meta.disc_total)):
            if number is not None or total is not None:
                audio.tags.add(frame(encoding=3, text=[f"{number or 0}/{total}" if total else str(number)]))
        if meta.mb_recording_id is not None:
            audio.tags.add(UFID(owner="http://musicbrainz.org", data=meta.mb_recording_id.encode("ascii")))
        names = {
            "musicbrainz_albumid": "MusicBrainz Album Id",
            "musicbrainz_releasegroupid": "MusicBrainz Release Group Id",
            "musicbrainz_artistid": "MusicBrainz Artist Id",
            "musicbrainz_albumartistid": "MusicBrainz Album Artist Id",
        }
        for key, name in names.items():
            if values[key] is not None:
                audio.tags.add(TXXX(encoding=3, desc=name, text=[values[key]]))
        if cover:
            audio.tags.add(APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=cover))
        audio.save(v2_version=4)
        return
    else:
        for key, value in values.items():
            if value is not None:
                audio[key] = [value]
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
