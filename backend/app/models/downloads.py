import uuid
from datetime import datetime

from sqlalchemy import DateTime, Float, ForeignKey, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.user import User


class DownloadRequest(Base):
    __tablename__ = "download_requests"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    kind: Mapped[str] = mapped_column(String(16))
    mb_id: Mapped[str | None] = mapped_column(String(36))
    catalog_id: Mapped[str | None] = mapped_column(String(64), index=True)
    replace_track_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("tracks.id", ondelete="SET NULL"))
    mb_release_id: Mapped[str | None] = mapped_column(String(36))
    title: Mapped[str] = mapped_column(String(512))
    artist: Mapped[str] = mapped_column(String(1024))
    cover_url: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(24), index=True)
    is_temporary: Mapped[bool] = mapped_column(default=False)
    note: Mapped[str | None] = mapped_column(Text)
    torrent_status: Mapped[str | None] = mapped_column(String(16))
    torrent_name: Mapped[str | None] = mapped_column(Text)
    torrent_progress: Mapped[float] = mapped_column(Float, default=0)
    torrent_progress_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    torrent_error: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    items: Mapped[list["DownloadItem"]] = relationship(
        back_populates="request", cascade="all, delete-orphan", order_by="DownloadItem.position"
    )
    user: Mapped[User] = relationship()


class DownloadItem(Base):
    __tablename__ = "download_items"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    request_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("download_requests.id", ondelete="CASCADE"), index=True)
    position: Mapped[int]
    title: Mapped[str] = mapped_column(String(512))
    artist: Mapped[str] = mapped_column(String(1024))
    duration: Mapped[float | None] = mapped_column(Float)
    meta: Mapped[dict] = mapped_column(JSONB)
    status: Mapped[str] = mapped_column(String(16), index=True)
    progress: Mapped[float] = mapped_column(Float, default=0)
    source: Mapped[str | None] = mapped_column(String(32))
    source_ref: Mapped[str | None] = mapped_column(Text)
    exclude_refs: Mapped[list[str]] = mapped_column(JSONB, nullable=False, server_default="[]", default=list)
    error: Mapped[str | None] = mapped_column(Text)
    attempts: Mapped[int] = mapped_column(default=0)
    track_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("tracks.id", ondelete="SET NULL"))
    replace_track_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("tracks.id", ondelete="SET NULL"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    request: Mapped[DownloadRequest] = relationship(back_populates="items")


class QualityUpgradeAttempt(Base):
    __tablename__ = "quality_upgrade_attempts"

    album_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("albums.id", ondelete="CASCADE"), primary_key=True)
    tried_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    result: Mapped[str] = mapped_column(String(24))
