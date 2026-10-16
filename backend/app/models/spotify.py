import uuid
from datetime import datetime

from sqlalchemy import DateTime, Float, ForeignKey, String, Text, UniqueConstraint, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class SpotifyAccount(Base):
    __tablename__ = "spotify_accounts"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    spotify_user_id: Mapped[str] = mapped_column(String(128))
    display_name: Mapped[str | None] = mapped_column(String(256))
    access_token: Mapped[str] = mapped_column(Text)
    refresh_token: Mapped[str] = mapped_column(Text)
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class SpotifyPlaylistLink(Base):
    __tablename__ = "spotify_playlist_links"
    __table_args__ = (UniqueConstraint("user_id", "spotify_playlist_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    spotify_playlist_id: Mapped[str] = mapped_column(String(64))
    playlist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("playlists.id", ondelete="CASCADE"))


class SpotifyImport(Base):
    __tablename__ = "spotify_imports"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    status: Mapped[str] = mapped_column(String(16))
    liked: Mapped[bool]
    playlist_ids: Mapped[list[str]] = mapped_column(JSONB)
    links: Mapped[list[str]] = mapped_column(JSONB, nullable=False, server_default="[]", default=list)
    download_missing: Mapped[bool]
    total: Mapped[int] = mapped_column(default=0)
    matched: Mapped[int] = mapped_column(default=0)
    missing: Mapped[int] = mapped_column(default=0)
    requested: Mapped[int] = mapped_column(default=0)
    message: Mapped[str | None] = mapped_column(Text)
    missing_tracks: Mapped[list[dict]] = mapped_column(JSONB, default=list)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    finished_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))


class SpotifyPending(Base):
    __tablename__ = "spotify_pending"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    isrc: Mapped[str | None] = mapped_column(String(16), index=True)
    deezer_id: Mapped[str | None] = mapped_column(String(32))
    title: Mapped[str] = mapped_column(String(512))
    artist: Mapped[str] = mapped_column(String(1024))
    duration: Mapped[float | None] = mapped_column(Float)
    like: Mapped[bool]
    like_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    playlist_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("playlists.id", ondelete="CASCADE"))
    position: Mapped[float | None] = mapped_column(Float)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
