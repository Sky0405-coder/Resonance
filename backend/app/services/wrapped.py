"""The yearly review ("Wrapped"): what a user listened to in a year, from their play history."""

import uuid
from collections import Counter, defaultdict
from datetime import UTC, date, datetime

from sqlalchemy import extract, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models import Artist, PlayEvent, Playlist, PlaylistEntry, Track, User
from app.schemas import WrappedArtist, WrappedGenre, WrappedOut, WrappedTrack
from app.services.mixes import GENRE_NAMES, genre_keys
from app.services.views import track_options, tracks_out

# A play counts once a song ran this long (like the mixes' history).
COUNTED_SECONDS = 30


def playlist_key(year: int) -> str:
    return f"wrapped:{year}"


async def years(db: AsyncSession, user: User) -> list[int]:
    rows = await db.scalars(
        select(extract("year", PlayEvent.played_at).label("year"))
        .where(PlayEvent.user_id == user.id)
        .group_by("year")
        .order_by("year")
    )
    return [int(year) for year in rows]


async def top_track_ids(db: AsyncSession, user: User, year: int, limit: int) -> list[uuid.UUID]:
    start, end = _bounds(year)
    rows = await db.execute(
        select(PlayEvent.track_id, func.count().label("plays"), func.sum(PlayEvent.seconds_played).label("seconds"))
        .where(
            PlayEvent.user_id == user.id,
            PlayEvent.played_at >= start,
            PlayEvent.played_at < end,
            PlayEvent.seconds_played >= COUNTED_SECONDS,
        )
        .group_by(PlayEvent.track_id)
        .order_by(func.count().desc(), func.sum(PlayEvent.seconds_played).desc(), PlayEvent.track_id)
        .limit(limit)
    )
    return [track_id for track_id, _, _ in rows]


def _bounds(year: int) -> tuple[datetime, datetime]:
    """The year in the server's time zone (where the mixes' days are counted too)."""
    zone = datetime.now(UTC).astimezone().tzinfo
    return datetime(year, 1, 1, tzinfo=zone), datetime(year + 1, 1, 1, tzinfo=zone)


async def wrapped(db: AsyncSession, user: User, year: int) -> WrappedOut:
    start, end = _bounds(year)
    events = (
        await db.execute(
            select(PlayEvent.track_id, PlayEvent.played_at, PlayEvent.seconds_played)
            .where(PlayEvent.user_id == user.id, PlayEvent.played_at >= start, PlayEvent.played_at < end)
            .order_by(PlayEvent.played_at)
        )
    ).all()
    out = WrappedOut(year=year, years=await years(db, user))
    if not events:
        return out
    track_ids = {track_id for track_id, _, _ in events}
    tracks = {
        track.id: track
        for track in (await db.scalars(select(Track).where(Track.id.in_(track_ids)).options(*track_options()))).unique()
    }
    seconds = 0.0
    plays: Counter[uuid.UUID] = Counter()
    track_seconds: Counter[uuid.UUID] = Counter()
    artist_plays: Counter[uuid.UUID] = Counter()
    artist_seconds: Counter[uuid.UUID] = Counter()
    genre_seconds: Counter[str] = Counter()
    months = [0.0] * 12
    hours = [0.0] * 24
    days: Counter[date] = Counter()
    first: uuid.UUID | None = None
    for track_id, played_at, played in events:
        track = tracks.get(track_id)
        if track is None:
            continue
        local = played_at.astimezone(start.tzinfo)
        seconds += played
        track_seconds[track_id] += played
        artist_seconds[track.artist_id] += played
        months[local.month - 1] += played
        hours[local.hour] += played
        days[local.date()] += played
        for key in genre_keys(track.genre) or genre_keys(track.album.genre):
            genre_seconds[key] += played
        if played >= COUNTED_SECONDS:
            plays[track_id] += 1
            artist_plays[track.artist_id] += 1
            if first is None:
                first = track_id
    out.minutes = round(seconds / 60)
    out.plays = sum(plays.values())
    out.songs = len(plays)
    out.artists = len({tracks[track_id].artist_id for track_id in plays})
    out.months = [round(value / 60) for value in months]
    out.hours = [round(value / 60) for value in hours]
    if days:
        out.top_day, top_day_seconds = min(days.items(), key=lambda item: (-item[1], item[0]))
        out.top_day_minutes = round(top_day_seconds / 60)

    # Artists heard for the first time this year (no play before it).
    heard_before = set(
        await db.scalars(
            select(Track.artist_id)
            .join(PlayEvent, PlayEvent.track_id == Track.id)
            .where(PlayEvent.user_id == user.id, PlayEvent.played_at < start)
            .distinct()
        )
    )
    out.new_artists = len({tracks[track_id].artist_id for track_id in plays} - heard_before)

    top_tracks = sorted(plays, key=lambda track_id: (-plays[track_id], -track_seconds[track_id], str(track_id)))[:5]
    rendered = await tracks_out(db, user, [tracks[track_id] for track_id in top_tracks])
    out.top_tracks = [
        WrappedTrack(track=item, plays=plays[track_id], minutes=round(track_seconds[track_id] / 60))
        for track_id, item in zip(top_tracks, rendered, strict=True)
    ]
    top_artists = sorted(
        artist_plays, key=lambda artist_id: (-artist_plays[artist_id], -artist_seconds[artist_id], str(artist_id))
    )[:5]
    found = {artist.id: artist for artist in await db.scalars(select(Artist).where(Artist.id.in_(top_artists)))}
    artist_tracks: dict[uuid.UUID, int] = defaultdict(int)
    covers: dict[uuid.UUID, uuid.UUID] = {}
    for track_id in sorted(plays, key=lambda track_id: -plays[track_id]):
        track = tracks[track_id]
        artist_tracks[track.artist_id] += 1
        covers.setdefault(track.artist_id, track.album_id)
    out.top_artists = [
        WrappedArtist(
            id=artist_id,
            name=found[artist_id].name,
            plays=artist_plays[artist_id],
            minutes=round(artist_seconds[artist_id] / 60),
            songs=artist_tracks[artist_id],
            has_image=bool(found[artist_id].image_path),
            cover_album_id=covers.get(artist_id),
        )
        for artist_id in top_artists
    ]
    genre_total = sum(genre_seconds.values())
    out.top_genres = [
        WrappedGenre(name=GENRE_NAMES.get(key, key.title()), share=round(value / genre_total, 3))
        for key, value in sorted(genre_seconds.items(), key=lambda item: (-item[1], item[0]))[:5]
    ]
    if first is not None:
        out.first_track = (await tracks_out(db, user, [tracks[first]]))[0]
    out.playlist_id = await db.scalar(
        select(Playlist.id).where(Playlist.owner_id == user.id, Playlist.mix_key == playlist_key(year))
    )
    return out


async def save_playlist(db: AsyncSession, user: User, year: int, name: str, description: str) -> Playlist | None:
    """The year's 100 most played songs as the user's own playlist (made again with the current numbers)."""
    track_ids = await top_track_ids(db, user, year, 100)
    if not track_ids:
        return None
    playlist = await db.scalar(
        select(Playlist).where(Playlist.owner_id == user.id, Playlist.mix_key == playlist_key(year))
    )
    if playlist is None:
        playlist = Playlist(owner_id=user.id, kind="user", mix_key=playlist_key(year), is_public=False)
        db.add(playlist)
    playlist.name = name
    playlist.description = description
    await db.flush()
    await db.execute(PlaylistEntry.__table__.delete().where(PlaylistEntry.playlist_id == playlist.id))
    db.add_all(
        [
            PlaylistEntry(playlist_id=playlist.id, track_id=track_id, position=i, added_by_id=user.id)
            for i, track_id in enumerate(track_ids, 1)
        ]
    )
    playlist.updated_at = func.now()
    await db.commit()
    await db.refresh(playlist)
    return playlist
