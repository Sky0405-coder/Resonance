import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Float, ForeignKey, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db import Base
from app.models.user import User


class Book(Base):
    __tablename__ = "books"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    title: Mapped[str] = mapped_column(String(512))
    subtitle: Mapped[str | None] = mapped_column(String(512))
    authors: Mapped[list[str]] = mapped_column(JSONB, default=list)
    author_sort: Mapped[str] = mapped_column(String(256), index=True)
    series: Mapped[str | None] = mapped_column(String(512), index=True)
    series_index: Mapped[float | None] = mapped_column(Float)
    language: Mapped[str | None] = mapped_column(String(8))
    isbn: Mapped[str | None] = mapped_column(String(13), index=True)
    publisher: Mapped[str | None] = mapped_column(String(256))
    year: Mapped[int | None]
    description: Mapped[str | None] = mapped_column(Text)
    catalog_ref: Mapped[str | None] = mapped_column(String(64))
    match_key: Mapped[str] = mapped_column(String(256), index=True)
    path: Mapped[str] = mapped_column(Text, unique=True)
    format: Mapped[str] = mapped_column(String(8))
    size: Mapped[int] = mapped_column(BigInteger)
    sha256: Mapped[str] = mapped_column(String(64), unique=True)
    source_sha256: Mapped[str] = mapped_column(String(64), index=True)
    has_cover: Mapped[bool] = mapped_column(default=False)
    source: Mapped[str] = mapped_column(String(16))
    added_by_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id", ondelete="SET NULL"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )


class BookRequest(Base):
    __tablename__ = "book_requests"

    id: Mapped[uuid.UUID] = mapped_column(primary_key=True, default=uuid.uuid4)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    catalog_ref: Mapped[str | None] = mapped_column(String(64))
    match_key: Mapped[str] = mapped_column(String(256), index=True)
    title: Mapped[str] = mapped_column(String(512))
    subtitle: Mapped[str | None] = mapped_column(String(512))
    authors: Mapped[list[str]] = mapped_column(JSONB, default=list)
    series: Mapped[str | None] = mapped_column(String(512))
    series_index: Mapped[float | None] = mapped_column(Float)
    isbn: Mapped[str | None] = mapped_column(String(13))
    publisher: Mapped[str | None] = mapped_column(String(256))
    year: Mapped[int | None]
    description: Mapped[str | None] = mapped_column(Text)
    language: Mapped[str] = mapped_column(String(8))
    cover_url: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(24), index=True)
    torrent_name: Mapped[str | None] = mapped_column(Text)
    torrent_hash: Mapped[str | None] = mapped_column(String(64))
    progress: Mapped[float] = mapped_column(Float, default=0)
    progress_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    attempts: Mapped[int] = mapped_column(default=0)
    exclude_guids: Mapped[list[str]] = mapped_column(JSONB, default=list, server_default="[]")
    error: Mapped[str | None] = mapped_column(Text)
    book_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("books.id", ondelete="SET NULL"))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )

    user: Mapped[User] = relationship()
    book: Mapped[Book | None] = relationship()


class BookProgress(Base):
    __tablename__ = "book_progress"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    document: Mapped[str] = mapped_column(String(64), primary_key=True)
    progress: Mapped[str] = mapped_column(Text)
    percentage: Mapped[float] = mapped_column(Float)
    device: Mapped[str] = mapped_column(String(128))
    device_id: Mapped[str] = mapped_column(String(128))
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), server_default=func.now(), onupdate=func.now()
    )
