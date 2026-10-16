import uuid
from datetime import date

from fastapi import APIRouter, HTTPException, Request, status
from sqlalchemy import delete, func, or_, select, update
from sqlalchemy.orm import joinedload

from app.deps import DB, CurrentUser
from app.i18n import language
from app.models import Playlist, PlaylistEntry, PlaylistShare, RadioPending, Track, User
from app.schemas import (
    AddTracksIn,
    MoveEntryIn,
    PlaylistDetail,
    PlaylistEntryOut,
    PlaylistIn,
    PlaylistOut,
    PlaylistPatch,
    PlaylistSharesIn,
)
from app.services.views import playlists_out, tracks_out

router = APIRouter(prefix="/api/playlists", tags=["playlists"])


async def _get_visible(db: DB, user: User, playlist_id: uuid.UUID) -> Playlist:
    playlist = await db.scalar(
        select(Playlist).where(
            Playlist.id == playlist_id,
            or_(Playlist.owner_id == user.id, Playlist.kind == "user"),
            or_(
                Playlist.owner_id == user.id,
                Playlist.is_public,
                select(PlaylistShare.id)
                .where(PlaylistShare.playlist_id == Playlist.id, PlaylistShare.user_id == user.id)
                .exists(),
            ),
        )
    )
    if playlist is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Playlist nicht gefunden")
    return playlist


async def _get_owned(db: DB, user: User, playlist_id: uuid.UUID) -> Playlist:
    playlist = await _get_visible(db, user, playlist_id)
    if playlist.owner_id != user.id:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Nicht deine Playlist")
    return playlist


async def _position_before(
    db: DB, playlist_id: uuid.UUID, before_entry_id: uuid.UUID | None, count: int
) -> list[float]:
    """Compute `count` fractional positions placed before `before_entry_id` (or at the end)."""
    if before_entry_id is None:
        last = await db.scalar(select(func.max(PlaylistEntry.position)).where(PlaylistEntry.playlist_id == playlist_id))
        start = (last or 0) + 1
        return [start + i for i in range(count)]
    before = await db.get(PlaylistEntry, before_entry_id)
    if before is None or before.playlist_id != playlist_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Unknown entry")
    prev = await db.scalar(
        select(func.max(PlaylistEntry.position)).where(
            PlaylistEntry.playlist_id == playlist_id, PlaylistEntry.position < before.position
        )
    )
    low = prev if prev is not None else before.position - 1
    step = (before.position - low) / (count + 1)
    return [low + step * (i + 1) for i in range(count)]


@router.get("", response_model=list[PlaylistOut])
async def list_playlists(user: CurrentUser, db: DB, request: Request) -> list[PlaylistOut]:
    rows = await db.scalars(
        select(Playlist)
        .where(
            or_(Playlist.owner_id == user.id, Playlist.kind == "user"),
            or_(
                Playlist.owner_id == user.id,
                Playlist.is_public,
                select(PlaylistShare.id)
                .where(PlaylistShare.playlist_id == Playlist.id, PlaylistShare.user_id == user.id)
                .exists(),
            ),
        )
        .order_by(Playlist.updated_at.desc())
    )
    return await playlists_out(db, list(rows), user.id, language(request))


@router.post("", response_model=PlaylistOut, status_code=status.HTTP_201_CREATED)
async def create_playlist(body: PlaylistIn, user: CurrentUser, db: DB) -> PlaylistOut:
    playlist = Playlist(owner_id=user.id, **body.model_dump())
    db.add(playlist)
    await db.commit()
    await db.refresh(playlist)
    return (await playlists_out(db, [playlist], user.id))[0]


@router.get("/{playlist_id}", response_model=PlaylistDetail)
async def get_playlist(playlist_id: uuid.UUID, user: CurrentUser, db: DB, request: Request) -> PlaylistDetail:
    playlist = await _get_visible(db, user, playlist_id)
    entries = list(
        await db.scalars(
            select(PlaylistEntry)
            .options(
                joinedload(PlaylistEntry.track).joinedload(Track.artist),
                joinedload(PlaylistEntry.track).joinedload(Track.album),
            )
            .where(PlaylistEntry.playlist_id == playlist_id)
            .order_by(PlaylistEntry.position)
        )
    )
    tracks = await tracks_out(db, user, [e.track for e in entries])
    detail = PlaylistDetail.model_validate(
        (await playlists_out(db, [playlist], user.id, language(request)))[0].model_dump()
    )
    detail.entries = [
        PlaylistEntryOut(entry_id=e.id, added_at=e.added_at, track=t) for e, t in zip(entries, tracks, strict=True)
    ]
    detail.editable = playlist.owner_id == user.id and playlist.kind != "mix"
    return detail


@router.patch("/{playlist_id}", response_model=PlaylistOut)
async def update_playlist(playlist_id: uuid.UUID, body: PlaylistPatch, user: CurrentUser, db: DB) -> PlaylistOut:
    playlist = await _get_owned(db, user, playlist_id)
    if playlist.kind != "user" and body.is_public is True:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Radios und Mixe können nicht geteilt werden")
    for key, value in body.model_dump(exclude_unset=True).items():
        setattr(playlist, key, value)
    await db.commit()
    await db.refresh(playlist)
    return (await playlists_out(db, [playlist], user.id))[0]


@router.put("/{playlist_id}/shares", response_model=PlaylistOut)
async def replace_shares(playlist_id: uuid.UUID, body: PlaylistSharesIn, user: CurrentUser, db: DB) -> PlaylistOut:
    playlist = await _get_owned(db, user, playlist_id)
    if playlist.kind != "user":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Radios und Mixe können nicht geteilt werden")
    user_ids = set(body.user_ids)
    known_ids = set(
        await db.scalars(select(User.id).where(User.id.in_(user_ids), ~User.is_disabled, User.id != user.id))
    )
    if user_ids != known_ids:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Unbekannter Nutzer")
    await db.execute(delete(PlaylistShare).where(PlaylistShare.playlist_id == playlist_id))
    db.add_all([PlaylistShare(playlist_id=playlist_id, user_id=shared_user_id) for shared_user_id in user_ids])
    playlist.updated_at = func.now()
    await db.commit()
    await db.refresh(playlist)
    return (await playlists_out(db, [playlist], user.id))[0]


@router.delete("/{playlist_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_playlist(playlist_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    playlist = await _get_owned(db, user, playlist_id)
    await db.delete(playlist)
    await db.commit()


@router.post("/{playlist_id}/keep", response_model=PlaylistOut)
async def keep_radio(playlist_id: uuid.UUID, user: CurrentUser, db: DB) -> PlaylistOut:
    playlist = await _get_owned(db, user, playlist_id)
    if playlist.kind == "mix":
        track_ids = await db.scalars(
            select(PlaylistEntry.track_id)
            .where(PlaylistEntry.playlist_id == playlist_id)
            .order_by(PlaylistEntry.position)
        )
        copy = Playlist(
            owner_id=user.id,
            kind="user",
            name=f"{playlist.name} ({date.today():%d.%m.%Y})",
            description=playlist.description,
            is_public=False,
            entries=[PlaylistEntry(track_id=track_id, position=i) for i, track_id in enumerate(track_ids, 1)],
        )
        db.add(copy)
        await db.commit()
        await db.refresh(copy)
        return (await playlists_out(db, [copy], user.id))[0]
    if playlist.kind != "radio":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Keine Radio-Playlist")
    playlist.kind = "user"
    playlist.radio_seed = None
    await db.execute(
        update(Track)
        .where(
            Track.is_temporary,
            Track.id.in_(select(PlaylistEntry.track_id).where(PlaylistEntry.playlist_id == playlist_id)),
        )
        .values(is_temporary=False)
    )
    await db.execute(delete(RadioPending).where(RadioPending.playlist_id == playlist_id))
    await db.commit()
    await db.refresh(playlist)
    return (await playlists_out(db, [playlist], user.id))[0]


@router.post("/{playlist_id}/tracks", status_code=status.HTTP_204_NO_CONTENT)
async def add_tracks(playlist_id: uuid.UUID, body: AddTracksIn, user: CurrentUser, db: DB) -> None:
    playlist = await _get_owned(db, user, playlist_id)
    if playlist.kind == "mix":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Mixe werden automatisch erstellt")
    tracks = {t.id: t for t in await db.scalars(select(Track).where(Track.id.in_(body.track_ids)))}
    if len(tracks) != len(set(body.track_ids)):
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Unknown track id")
    positions = await _position_before(db, playlist_id, body.before_entry_id, len(body.track_ids))
    for track_id, pos in zip(body.track_ids, positions, strict=True):
        db.add(PlaylistEntry(playlist_id=playlist_id, track_id=track_id, position=pos))
        if playlist.kind == "user":
            tracks[track_id].is_temporary = False
    playlist.updated_at = func.now()
    await db.commit()


@router.post("/{playlist_id}/move", status_code=status.HTTP_204_NO_CONTENT)
async def move_entry(playlist_id: uuid.UUID, body: MoveEntryIn, user: CurrentUser, db: DB) -> None:
    playlist = await _get_owned(db, user, playlist_id)
    if playlist.kind == "mix":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Mixe werden automatisch erstellt")
    entry = await db.get(PlaylistEntry, body.entry_id)
    if entry is None or entry.playlist_id != playlist_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Entry not found")
    if body.before_entry_id == entry.id:
        return
    entry.position = (await _position_before(db, playlist_id, body.before_entry_id, 1))[0]
    playlist.updated_at = func.now()
    await db.commit()


@router.delete("/{playlist_id}/entries/{entry_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_entry(playlist_id: uuid.UUID, entry_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    playlist = await _get_owned(db, user, playlist_id)
    if playlist.kind == "mix":
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Mixe werden automatisch erstellt")
    entry = await db.get(PlaylistEntry, entry_id)
    if entry is None or entry.playlist_id != playlist_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Entry not found")
    await db.delete(entry)
    playlist.updated_at = func.now()
    await db.commit()
