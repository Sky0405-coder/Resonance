"""Android in-app updates: admins upload the latest APK, the app compares its build number and installs it."""

import json
import os
from datetime import UTC, datetime
from pathlib import Path

from fastapi import APIRouter, Form, HTTPException, UploadFile
from fastapi.responses import FileResponse
from pydantic import BaseModel

from app.config import get_settings
from app.deps import AdminUser, CurrentUser

router = APIRouter(tags=["app"])

MAX_APK_BYTES = 300 * 1024 * 1024


class AndroidRelease(BaseModel):
    version_name: str
    version_code: int
    size: int
    uploaded_at: datetime


def _dir() -> Path:
    path = get_settings().data_dir / "app-releases"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _current() -> AndroidRelease | None:
    meta = _dir() / "android.json"
    if not meta.is_file() or not (_dir() / "android.apk").is_file():
        return None
    return AndroidRelease.model_validate(json.loads(meta.read_text()))


@router.get("/api/app/android", response_model=AndroidRelease)
async def android_release(user: CurrentUser) -> AndroidRelease:
    release = _current()
    if release is None:
        raise HTTPException(404, "Keine App-Version hochgeladen")
    return release


@router.get("/api/app/android/apk")
async def android_apk(user: CurrentUser) -> FileResponse:
    if _current() is None:
        raise HTTPException(404, "Keine App-Version hochgeladen")
    return FileResponse(
        _dir() / "android.apk", media_type="application/vnd.android.package-archive", filename="Resonance.apk"
    )


@router.put("/api/admin/app/android", response_model=AndroidRelease)
async def upload_android(
    admin: AdminUser,
    file: UploadFile,
    version_name: str = Form(min_length=1, max_length=64),
    version_code: int = Form(ge=1),
) -> AndroidRelease:
    temp = _dir() / ".android.apk.part"
    size = 0
    with temp.open("wb") as out:
        while chunk := await file.read(1024 * 1024):
            size += len(chunk)
            if size > MAX_APK_BYTES:
                out.close()
                temp.unlink()
                raise HTTPException(413, "Datei zu groß")
            out.write(chunk)
    with temp.open("rb") as f:
        if f.read(2) != b"PK":  # APKs are zip files
            temp.unlink()
            raise HTTPException(422, "Keine gültige APK-Datei")
    release = AndroidRelease(
        version_name=version_name, version_code=version_code, size=size, uploaded_at=datetime.now(UTC)
    )
    os.replace(temp, _dir() / "android.apk")
    (_dir() / "android.json").write_text(release.model_dump_json())
    return release
