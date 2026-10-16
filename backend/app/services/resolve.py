from app.services.deezer import DeezerError, artist_string, deezer
from app.services.musicbrainz import MusicBrainzError, NotFound, TrackMeta, mb


def meta_from_deezer(track: dict, album: dict, disc_total: int, track_total: int | None) -> TrackMeta:
    date = album.get("release_date")
    genres = album.get("genres", {}).get("data", [])
    return TrackMeta(
        title=track["title"],
        artist=artist_string(track),
        artist_mbid=None,
        album=album["title"],
        album_artist=album.get("artist", {}).get("name", ""),
        album_artist_mbid=None,
        track_no=track.get("track_position"),
        track_total=track_total,
        disc_no=track.get("disk_number"),
        disc_total=disc_total,
        year=int(date[:4]) if date and date[:4].isdigit() else None,
        date=date,
        duration=track.get("duration"),
        isrc=track.get("isrc"),
        genre=genres[0]["name"] if genres else None,
        label=album.get("label"),
        mb_recording_id=None,
        mb_release_id=None,
        mb_release_group_id=None,
        deezer_track_id=str(track["id"]),
        deezer_album_id=str(album["id"]),
        cover_url=album.get("cover_xl"),
    )


async def resolve_track(deezer_id: str) -> TrackMeta:
    track = await deezer.track(deezer_id)
    album = await deezer.album(str(track["album"]["id"]))
    meta = None
    if track.get("isrc"):
        try:
            recordings = await mb.isrc_recordings(track["isrc"])
            if recordings:
                recording = min(
                    recordings,
                    key=lambda r: (
                        abs(r["length"] / 1000 - track["duration"]) if r.get("length") is not None else float("inf")
                    ),
                )
                meta = await mb.recording_meta(recording["id"], prefer_album=album["title"])
        except (NotFound, MusicBrainzError):
            pass
    if meta is None:
        meta = meta_from_deezer(track, album, 1, album.get("nb_tracks"))
    meta.deezer_track_id = str(track["id"])
    meta.deezer_album_id = str(album["id"])
    meta.cover_url = album.get("cover_xl")
    meta.isrc = meta.isrc or track.get("isrc")
    return meta


async def resolve_album(deezer_id: str) -> tuple[dict, list[TrackMeta]]:
    album = await deezer.album(deezer_id)
    tracks = await deezer.album_tracks(deezer_id)
    metas = []
    if album.get("upc"):
        upc = album["upc"]
        try:
            for barcode in dict.fromkeys([upc, upc.lstrip("0"), "0" + upc]):
                release_id = await mb.release_by_barcode(barcode, len(tracks))
                if release_id:
                    metas = await mb.track_meta_list(await mb.release_full(release_id))
                    break
        except (NotFound, MusicBrainzError):
            metas = []
    if len(metas) == len(tracks):
        for meta, track in zip(metas, tracks, strict=True):
            meta.deezer_track_id = str(track["id"])
            meta.deezer_album_id = str(album["id"])
            meta.cover_url = album.get("cover_xl")
    else:
        disc_total = max((t.get("disk_number") or 1 for t in tracks), default=1)
        metas = [
            meta_from_deezer(
                t,
                album,
                disc_total,
                sum((other.get("disk_number") or 1) == (t.get("disk_number") or 1) for other in tracks),
            )
            for t in tracks
        ]
    return album, metas


# Deezer `explicit_content_lyrics`: 3 = edited (censored) version of an explicit original.
EDITED = 3


def _same(a: str, b: str) -> bool:
    return " ".join(a.casefold().split()) == " ".join(b.casefold().split())


async def explicit_track_id(deezer_id: str) -> str:
    """Id of the explicit original when `deezer_id` is a censored version, else `deezer_id`."""
    track = await deezer.track(deezer_id)
    if track.get("explicit_content_lyrics") != EDITED:
        return deezer_id
    artist = track.get("artist", {}).get("name", "")
    try:
        results = await deezer.search_tracks(f'artist:"{artist}" track:"{track["title"]}"', 10)
    except DeezerError:
        return deezer_id
    for result in results:
        if (
            result.get("explicit_lyrics")
            and _same(result.get("artist", {}).get("name", ""), artist)
            and _same(result["title"], track["title"])
            and abs((result.get("duration") or 0) - (track.get("duration") or 0)) <= 10
        ):
            return str(result["id"])
    return deezer_id


async def explicit_album_id(deezer_id: str) -> str:
    """Id of the explicit edition when `deezer_id` is a censored album, else `deezer_id`."""
    album = await deezer.album(deezer_id)
    if album.get("explicit_content_lyrics") != EDITED:
        return deezer_id
    artist = album.get("artist", {}).get("name", "")
    try:
        results = await deezer.search_albums(f"{artist} {album['title']}", 10)
    except DeezerError:
        return deezer_id
    for result in results:
        if (
            result.get("explicit_lyrics")
            and _same(result.get("artist", {}).get("name", ""), artist)
            and _same(result["title"], album["title"])
            and abs((result.get("nb_tracks") or 0) - (album.get("nb_tracks") or 0)) <= 2
        ):
            return str(result["id"])
    return deezer_id
