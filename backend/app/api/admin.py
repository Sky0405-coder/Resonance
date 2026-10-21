import uuid
from datetime import UTC, datetime, timedelta

from fastapi import APIRouter, BackgroundTasks, HTTPException, Request, status
from sqlalchemy import delete, func, select
from sqlalchemy.orm import aliased

from app.deps import DB, AdminUser
from app.i18n import language, translate
from app.models import (
    Album,
    Artist,
    AuthSession,
    Invite,
    Job,
    Role,
    Track,
    TrackLyrics,
    User,
)
from app.schemas import (
    DuplicateGroupOut,
    DuplicateMergeIn,
    DuplicateTrackOut,
    InviteCreated,
    InviteIn,
    InviteOut,
    JobOut,
    UserAdminPatch,
    UserOut,
)
from app.security import hash_password, hash_token, new_token
from app.services import genres, scanner, upgrades
from app.services.deletion import delete_empty_album, delete_tracks
from app.services.duplicates import find_groups, merge_group
from app.services.server_config import ServerConfig, load_config, update_config

router = APIRouter(prefix="/api/admin", tags=["admin"])


# --- server settings --------------------------------------------------------


@router.get("/config", response_model=ServerConfig)
async def get_config(admin: AdminUser, db: DB) -> ServerConfig:
    return await load_config(db)


@router.patch("/config", response_model=ServerConfig)
async def patch_config(patch: dict, admin: AdminUser, db: DB) -> ServerConfig:
    try:
        return await update_config(db, patch)
    except ValueError as e:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_CONTENT, str(e)) from e


@router.post("/upgrades/run", status_code=status.HTTP_202_ACCEPTED)
async def run_upgrades(admin: AdminUser, background_tasks: BackgroundTasks) -> dict[str, bool]:
    background_tasks.add_task(upgrades.run_once)
    return {"started": True}


@router.get("/lyrics/status")
async def lyrics_status(admin: AdminUser, db: DB) -> dict[str, int]:
    synced = func.coalesce(TrackLyrics.synced, "") != ""
    plain = func.coalesce(TrackLyrics.plain, "") != ""
    row = (await db.execute(
        select(
            func.count().label("total"),
            func.count().filter(synced).label("synced"),
            func.count().filter(plain, ~synced).label("plain_only"),
            func.count().filter(TrackLyrics.instrumental.is_(True)).label("instrumental"),
            func.count().filter(TrackLyrics.source == "none").label("none"),
            func.count().filter(TrackLyrics.track_id.is_(None)).label("missing"),
        )
        .select_from(Track)
        .outerjoin(TrackLyrics, TrackLyrics.track_id == Track.id)
        .where(Track.is_temporary.is_(False))
    )).one()
    return dict(row._mapping)


@router.post("/genres/fill", response_model=JobOut, status_code=status.HTTP_202_ACCEPTED)
async def fill_genres(admin: AdminUser, db: DB) -> JobOut:
    return JobOut.model_validate(await genres.start_fill(db))


@router.get("/genres/fill", response_model=JobOut | None)
async def genre_fill_status(admin: AdminUser, db: DB, request: Request) -> JobOut | None:
    job = await db.scalar(select(Job).where(Job.kind == "genres").order_by(Job.created_at.desc()).limit(1))
    if job is None:
        return None
    return JobOut.model_validate(job).model_copy(
        update={"message": translate(job.message, language(request)) if job.message else None}
    )


# --- invites ----------------------------------------------------------------


@router.get("/invites", response_model=list[InviteOut])
async def list_invites(admin: AdminUser, db: DB) -> list[InviteOut]:
    used_by = aliased(User)
    rows = await db.execute(
        select(Invite, used_by.username)
        .outerjoin(used_by, used_by.id == Invite.used_by_id)
        .order_by(Invite.created_at.desc())
    )
    out = []
    for invite, username in rows:
        item = InviteOut.model_validate(invite)
        item.used_by_username = username
        out.append(item)
    return out


@router.post("/invites", response_model=InviteCreated, status_code=status.HTTP_201_CREATED)
async def create_invite(body: InviteIn, admin: AdminUser, db: DB) -> InviteCreated:
    token = new_token()
    invite = Invite(
        token_hash=hash_token(token),
        note=body.note,
        role=body.role,
        created_by_id=admin.id,
        expires_at=datetime.now(UTC) + timedelta(hours=body.expires_in_hours) if body.expires_in_hours else None,
    )
    db.add(invite)
    await db.commit()
    await db.refresh(invite)
    # The plain token is only ever returned here; the client builds the share link from it.
    return InviteCreated(**InviteOut.model_validate(invite).model_dump(), token=token)


@router.delete("/invites/{invite_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_invite(invite_id: uuid.UUID, admin: AdminUser, db: DB) -> None:
    await db.execute(delete(Invite).where(Invite.id == invite_id))
    await db.commit()


# --- users ------------------------------------------------------------------


@router.get("/users", response_model=list[UserOut])
async def list_users(admin: AdminUser, db: DB) -> list[UserOut]:
    return [UserOut.model_validate(u) for u in await db.scalars(select(User).order_by(User.created_at))]


async def _admin_count(db: DB) -> int:
    return (
        await db.scalar(select(func.count()).select_from(User).where(User.role == Role.admin, ~User.is_disabled)) or 0
    )


@router.patch("/users/{user_id}", response_model=UserOut)
async def update_user(user_id: uuid.UUID, body: UserAdminPatch, admin: AdminUser, db: DB) -> UserOut:
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "User not found")
    demoting = user.is_admin and (body.role == Role.user or body.is_disabled)
    if demoting and await _admin_count(db) <= 1:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Es muss mindestens ein aktiver Admin bleiben")
    if body.role is not None:
        user.role = body.role
    if body.is_disabled is not None:
        user.is_disabled = body.is_disabled
        if body.is_disabled:
            await db.execute(delete(AuthSession).where(AuthSession.user_id == user.id))
    if body.new_password is not None:
        user.password_hash = hash_password(body.new_password)
        await db.execute(delete(AuthSession).where(AuthSession.user_id == user.id))
    await db.commit()
    await db.refresh(user)
    return UserOut.model_validate(user)


@router.delete("/users/{user_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_user(user_id: uuid.UUID, admin: AdminUser, db: DB) -> None:
    user = await db.get(User, user_id)
    if user is None:
        return
    if user.id == admin.id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Du kannst dich nicht selbst löschen")
    if user.is_admin and await _admin_count(db) <= 1:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "Es muss mindestens ein aktiver Admin bleiben")
    await db.delete(user)
    await db.commit()


# --- library ----------------------------------------------------------------


@router.get("/library/duplicates", response_model=list[DuplicateGroupOut])
async def library_duplicates(admin: AdminUser, db: DB) -> list[DuplicateGroupOut]:
    return [
        DuplicateGroupOut(
            kind=group.kind,
            verified=group.verified,
            pending=group.pending,
            album_id=group.tracks[0].album_id,
            album_title=group.tracks[0].album.title,
            artist_name=group.tracks[0].album.artist.name,
            tracks=[
                DuplicateTrackOut(
                    id=track.id,
                    title=track.title,
                    album=track.album.title,
                    path=track.path,
                    codec=track.codec,
                    bitrate=track.bitrate,
                    size=track.size,
                    duration=track.duration,
                    keep=index == 0,
                )
                for index, track in enumerate(group.tracks)
            ],
        )
        for group in await find_groups(db)
    ]


@router.post("/library/duplicates/merge")
async def merge_library_duplicates(body: DuplicateMergeIn, admin: AdminUser, db: DB) -> dict[str, int]:
    keep_ids = set(body.keep_ids)
    merged_groups = deleted_tracks = freed_bytes = 0
    groups = await find_groups(db)
    groups.sort(key=lambda group: group.kind == "cross_album")
    for candidate in groups:
        if body.kind is not None and candidate.kind != body.kind:
            continue
        if not candidate.verified or candidate.pending:
            continue
        group = candidate.tracks
        if group[0].id not in keep_ids:
            continue
        existing = set(await db.scalars(select(Track.id).where(Track.id.in_([track.id for track in group]))))
        if group[0].id not in existing:
            continue
        group = [track for track in group if track.id in existing]
        if len(group) < 2:
            continue
        await merge_group(db, group[0], group[1:])
        merged_groups += 1
        deleted_tracks += len(group) - 1
        freed_bytes += sum(track.size for track in group[1:])
    return {"merged_groups": merged_groups, "deleted_tracks": deleted_tracks, "freed_bytes": freed_bytes}


@router.get("/library/stats")
async def library_stats(admin: AdminUser, db: DB) -> dict:
    return {
        "artists": await db.scalar(select(func.count()).select_from(Artist)),
        "albums": await db.scalar(select(func.count()).select_from(Album)),
        "tracks": await db.scalar(select(func.count()).select_from(Track)),
        # SUM() returns NUMERIC/Decimal in Postgres, which would serialise as a string.
        "total_bytes": int(await db.scalar(select(func.coalesce(func.sum(Track.size), 0))) or 0),
        "total_seconds": float(await db.scalar(select(func.coalesce(func.sum(Track.duration), 0))) or 0),
    }


@router.delete("/library/tracks/{track_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_library_track(track_id: uuid.UUID, admin: AdminUser, db: DB) -> None:
    if await db.get(Track, track_id) is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nicht gefunden")
    await delete_tracks(db, [track_id])


@router.delete("/library/albums/{album_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_library_album(album_id: uuid.UUID, admin: AdminUser, db: DB) -> None:
    album = await db.get(Album, album_id)
    if album is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Nicht gefunden")
    track_ids = list(await db.scalars(select(Track.id).where(Track.album_id == album_id)))
    await delete_tracks(db, track_ids)
    if not track_ids:
        await delete_empty_album(db, album)


@router.post("/library/scan", response_model=JobOut, status_code=status.HTTP_202_ACCEPTED)
async def start_scan(admin: AdminUser, db: DB, request: Request, full: bool = False) -> JobOut:
    job = await scanner.start_scan(db, full=full)
    return JobOut.model_validate(job).model_copy(
        update={"message": translate(job.message, language(request)) if job.message is not None else None}
    )


@router.get("/jobs", response_model=list[JobOut])
async def list_jobs(admin: AdminUser, db: DB, request: Request, limit: int = 50) -> list[JobOut]:
    return [
        JobOut.model_validate(j).model_copy(
            update={"message": translate(j.message, language(request)) if j.message is not None else None}
        )
        for j in await db.scalars(select(Job).order_by(Job.created_at.desc()).limit(limit))
    ]
