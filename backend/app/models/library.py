import uuid
from datetime import datetime

from sqlalchemy import (
    BigInteger,
    DateTime,
    Float,
    ForeignKey,
    Index,
    String,
    Text,
    false,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base


class Artist(Base):
    __tablename__ = "artists"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    name: Mapped[str] = mapped_column(String(512))
    # Lower-cased name used for matching when no MusicBrainz ID is available.
    name_key: Mapped[str] = mapped_column(String(512), unique=True)
    sort_name: Mapped[str | None] = mapped_column(String(512))
    mb_artist_id: Mapped[str | None] = mapped_column(String(36), index=True)
    image_path: Mapped[str | None] = mapped_column(Text)
    bio_de: Mapped[str | None] = mapped_column(Text)
    bio_en: Mapped[str | None] = mapped_column(Text)
    info_checked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    albums: Mapped[list["Album"]] = relationship(back_populates="artist")


class Album(Base):
    __tablename__ = "albums"
    __table_args__ = (Index("ix_albums_artist_key", "artist_id", "title_key", unique=True),)

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    title: Mapped[str] = mapped_column(String(512))
    title_key: Mapped[str] = mapped_column(String(512))
    artist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("artists.id", ondelete="CASCADE"), index=True)
    year: Mapped[int | None]
    genre: Mapped[str | None] = mapped_column(String(256))
    mb_release_id: Mapped[str | None] = mapped_column(String(36), index=True)
    # Cached, normalised cover image (relative to the cover cache dir).
    cover_file: Mapped[str | None] = mapped_column(String(128))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    artist: Mapped[Artist] = relationship(back_populates="albums")
    tracks: Mapped[list["Track"]] = relationship(back_populates="album")


class Track(Base):
    __tablename__ = "tracks"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    path: Mapped[str] = mapped_column(Text, unique=True)
    title: Mapped[str] = mapped_column(String(512))
    album_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("albums.id", ondelete="CASCADE"), index=True)
    artist_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("artists.id", ondelete="CASCADE"), index=True)
    # Full credited artist string as tagged, e.g. "A feat. B".
    artist_credit: Mapped[str] = mapped_column(String(1024))
    track_no: Mapped[int | None]
    disc_no: Mapped[int | None]
    duration: Mapped[float] = mapped_column(Float, default=0)
    year: Mapped[int | None]
    genre: Mapped[str | None] = mapped_column(String(256))
    codec: Mapped[str | None] = mapped_column(String(32))
    bitrate: Mapped[int | None]
    sample_rate: Mapped[int | None]
    size: Mapped[int] = mapped_column(BigInteger, default=0)
    mtime: Mapped[float] = mapped_column(Float, default=0)
    mb_recording_id: Mapped[str | None] = mapped_column(String(36), index=True)
    isrc: Mapped[str | None] = mapped_column(String(16), index=True)
    replaygain_track_gain: Mapped[float | None]
    replaygain_album_gain: Mapped[float | None]
    # Radio auto-downloads are temporary until liked / added to a playlist (phase 5).
    is_temporary: Mapped[bool] = mapped_column(default=False)
    reviewed: Mapped[bool] = mapped_column(default=False, server_default=false())
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())

    album: Mapped[Album] = relationship(back_populates="tracks")
    artist: Mapped[Artist] = relationship()


class TrackLyrics(Base):
    __tablename__ = "track_lyrics"

    track_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True)
    synced: Mapped[str | None] = mapped_column(Text)
    plain: Mapped[str | None] = mapped_column(Text)
    instrumental: Mapped[bool] = mapped_column(default=False)
    source: Mapped[str] = mapped_column(String(16))
    fetched_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class TrackMixPoints(Base):
    """AutoMix analysis of a track's file (tempo and where to mix in and out)."""

    __tablename__ = "track_mixpoints"

    track_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True)
    version: Mapped[int]
    # The file's mtime when analyzed; a changed file is analyzed again.
    mtime: Mapped[float] = mapped_column(Float)
    bpm: Mapped[float | None] = mapped_column(Float)
    mix_in: Mapped[float] = mapped_column(Float)
    mix_out: Mapped[float] = mapped_column(Float)
    end: Mapped[float] = mapped_column(Float)
    analyzed_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
