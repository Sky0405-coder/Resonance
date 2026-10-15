import uuid
from datetime import datetime

from sqlalchemy import DateTime, Float, ForeignKey, String, Text, UniqueConstraint, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.library import Track


class Playlist(Base):
    __tablename__ = "playlists"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    owner_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    name: Mapped[str] = mapped_column(String(256))
    description: Mapped[str | None] = mapped_column(Text)
    is_public: Mapped[bool] = mapped_column(default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    entries: Mapped[list["PlaylistEntry"]] = relationship(
        back_populates="playlist", cascade="all, delete-orphan", order_by="PlaylistEntry.position"
    )


class PlaylistEntry(Base):
    __tablename__ = "playlist_entries"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    playlist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("playlists.id", ondelete="CASCADE"), index=True)
    track_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"))
    # Fractional positions allow inserts/moves without renumbering the whole list.
    position: Mapped[float] = mapped_column(Float)
    added_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    playlist: Mapped[Playlist] = relationship(back_populates="entries")
    track: Mapped[Track] = relationship()


class PlaylistShare(Base):
    __tablename__ = "playlist_shares"
    __table_args__ = (UniqueConstraint("playlist_id", "user_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    playlist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("playlists.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class TrackLike(Base):
    __tablename__ = "track_likes"
    __table_args__ = (UniqueConstraint("user_id", "track_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    track_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class SavedAlbum(Base):
    __tablename__ = "saved_albums"
    __table_args__ = (UniqueConstraint("user_id", "album_id"),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    album_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("albums.id", ondelete="CASCADE"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class PlayEvent(Base):
    """Listening history; basis for 'recently played', mixes and scrobbling."""

    __tablename__ = "play_events"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    track_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"), index=True)
    played_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now(), index=True)
    seconds_played: Mapped[float] = mapped_column(Float, default=0)
    # Where playback was started from, e.g. "album:<id>", "playlist:<id>", "radio:<id>".
    context: Mapped[str | None] = mapped_column(String(128))
