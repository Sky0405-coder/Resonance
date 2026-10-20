import asyncio
import secrets
import uuid

from fastapi import APIRouter, HTTPException, Query, Request, status
from fastapi.responses import FileResponse
from sqlalchemy import delete, select

from app.deps import DB, CurrentUser
from app.models import AuthSession, PlayEvent, SavedAlbum, Track, TrackLike
from app.schemas import PlayEventIn, ProfilePatch, SessionOut, TrackOut, UserOut
from app.security import hash_password, verify_password
from app.services import covers, mix_covers
from app.services.views import track_options, tracks_out

router = APIRouter(prefix="/api/me", tags=["me"])


@router.get("", response_model=UserOut)
async def me(user: CurrentUser) -> UserOut:
    return UserOut.model_validate(user)


@router.post("/subsonic-password")
async def generate_subsonic_password(user: CurrentUser, db: DB) -> dict[str, str]:
    user.subsonic_password = secrets.token_urlsafe(18)
    await db.commit()
    return {"password": user.subsonic_password}


@router.delete("/subsonic-password", status_code=status.HTTP_204_NO_CONTENT)
async def remove_subsonic_password(user: CurrentUser, db: DB) -> None:
    user.subsonic_password = None
    await db.commit()


@router.patch("", response_model=UserOut)
async def update_me(body: ProfilePatch, user: CurrentUser, db: DB) -> UserOut:
    if body.display_name is not None:
        user.display_name = body.display_name
    if body.accent_color is not None:
        user.accent_color = body.accent_color
    if body.new_password is not None:
        if not body.current_password or not verify_password(user.password_hash, body.current_password):
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "Aktuelles Passwort ist falsch")
        user.password_hash = hash_password(body.new_password)
    await db.commit()
    return UserOut.model_validate(user)


@router.get("/sessions", response_model=list[SessionOut])
async def sessions(request: Request, user: CurrentUser, db: DB) -> list[SessionOut]:
    rows = await db.scalars(
        select(AuthSession).where(AuthSession.user_id == user.id).order_by(AuthSession.last_used_at.desc())
    )
    out = []
    for s in rows:
        item = SessionOut.model_validate(s)
        item.current = s.id == request.state.session_id
        out.append(item)
    return out


@router.delete("/sessions/{session_id}", status_code=status.HTTP_204_NO_CONTENT)
async def revoke_session(session_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    await db.execute(delete(AuthSession).where(AuthSession.id == session_id, AuthSession.user_id == user.id))
    await db.commit()


# --- likes ------------------------------------------------------------------


_liked_cover: str | None = None


@router.get("/likes/cover")
async def liked_cover(user: CurrentUser, size: int | None = Query(None, ge=32, le=2000)) -> FileResponse:
    """The Liked Songs cover (a heart), for clients that show one picture per collection, such as Android Auto."""
    global _liked_cover
    if _liked_cover is None:
        _liked_cover = await asyncio.to_thread(lambda: covers.store(mix_covers.liked()))
    path = covers.resized(_liked_cover, size) if _liked_cover else None
    if path is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No cover")
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=604800"})


@router.get("/likes/tracks", response_model=list[TrackOut])
async def liked_tracks(user: CurrentUser, db: DB) -> list[TrackOut]:
    rows = await db.scalars(
        select(Track)
        .join(TrackLike, TrackLike.track_id == Track.id)
        .where(TrackLike.user_id == user.id)
        .options(*track_options())
        .order_by(TrackLike.created_at.desc())
    )
    return await tracks_out(db, user, list(rows))


@router.put("/likes/tracks/{track_id}", status_code=status.HTTP_204_NO_CONTENT)
async def like_track(track_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    track = await db.get(Track, track_id)
    if track is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Track not found")
    exists = await db.scalar(select(TrackLike).where(TrackLike.user_id == user.id, TrackLike.track_id == track_id))
    if not exists:
        db.add(TrackLike(user_id=user.id, track_id=track_id))
        # Liking keeps a temporary radio download permanently.
        track.is_temporary = False
        await db.commit()


@router.delete("/likes/tracks/{track_id}", status_code=status.HTTP_204_NO_CONTENT)
async def unlike_track(track_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    await db.execute(delete(TrackLike).where(TrackLike.user_id == user.id, TrackLike.track_id == track_id))
    await db.commit()


@router.put("/albums/{album_id}", status_code=status.HTTP_204_NO_CONTENT)
async def save_album(album_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    exists = await db.scalar(select(SavedAlbum).where(SavedAlbum.user_id == user.id, SavedAlbum.album_id == album_id))
    if not exists:
        db.add(SavedAlbum(user_id=user.id, album_id=album_id))
        await db.commit()


@router.delete("/albums/{album_id}", status_code=status.HTTP_204_NO_CONTENT)
async def unsave_album(album_id: uuid.UUID, user: CurrentUser, db: DB) -> None:
    await db.execute(delete(SavedAlbum).where(SavedAlbum.user_id == user.id, SavedAlbum.album_id == album_id))
    await db.commit()


# --- history ----------------------------------------------------------------


@router.post("/plays", status_code=status.HTTP_204_NO_CONTENT)
async def report_play(body: PlayEventIn, user: CurrentUser, db: DB) -> None:
    if await db.get(Track, body.track_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Track not found")
    db.add(PlayEvent(user_id=user.id, track_id=body.track_id, seconds_played=body.seconds_played, context=body.context))
    await db.commit()
