from app.services.deezer import artist_string, deezer
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
