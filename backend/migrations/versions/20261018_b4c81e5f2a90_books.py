"""books

Revision ID: b4c81e5f2a90
Revises: 7ec4b2d8a1f6
Create Date: 2026-10-18 18:44:16.706623

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "b4c81e5f2a90"
down_revision: str | Sequence[str] | None = "7ec4b2d8a1f6"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        "book_progress",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("document", sa.String(length=64), nullable=False),
        sa.Column("progress", sa.Text(), nullable=False),
        sa.Column("percentage", sa.Float(), nullable=False),
        sa.Column("device", sa.String(length=128), nullable=False),
        sa.Column("device_id", sa.String(length=128), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_book_progress_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("user_id", "document", name=op.f("pk_book_progress")),
    )
    op.create_table(
        "books",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("title", sa.String(length=512), nullable=False),
        sa.Column("subtitle", sa.String(length=512), nullable=True),
        sa.Column("authors", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("author_sort", sa.String(length=256), nullable=False),
        sa.Column("series", sa.String(length=512), nullable=True),
        sa.Column("series_index", sa.Float(), nullable=True),
        sa.Column("language", sa.String(length=8), nullable=True),
        sa.Column("isbn", sa.String(length=13), nullable=True),
        sa.Column("publisher", sa.String(length=256), nullable=True),
        sa.Column("year", sa.Integer(), nullable=True),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("catalog_ref", sa.String(length=64), nullable=True),
        sa.Column("match_key", sa.String(length=256), nullable=False),
        sa.Column("path", sa.Text(), nullable=False),
        sa.Column("format", sa.String(length=8), nullable=False),
        sa.Column("size", sa.BigInteger(), nullable=False),
        sa.Column("sha256", sa.String(length=64), nullable=False),
        sa.Column("source_sha256", sa.String(length=64), nullable=False),
        sa.Column("has_cover", sa.Boolean(), nullable=False),
        sa.Column("source", sa.String(length=16), nullable=False),
        sa.Column("added_by_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["added_by_id"], ["users.id"], name=op.f("fk_books_added_by_id_users"), ondelete="SET NULL"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_books")),
        sa.UniqueConstraint("path", name=op.f("uq_books_path")),
        sa.UniqueConstraint("sha256", name=op.f("uq_books_sha256")),
    )
    op.create_index(op.f("ix_books_author_sort"), "books", ["author_sort"], unique=False)
    op.create_index(op.f("ix_books_isbn"), "books", ["isbn"], unique=False)
    op.create_index(op.f("ix_books_match_key"), "books", ["match_key"], unique=False)
    op.create_index(op.f("ix_books_series"), "books", ["series"], unique=False)
    op.create_index(op.f("ix_books_source_sha256"), "books", ["source_sha256"], unique=False)
    op.create_table(
        "book_requests",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("catalog_ref", sa.String(length=64), nullable=True),
        sa.Column("match_key", sa.String(length=256), nullable=False),
        sa.Column("title", sa.String(length=512), nullable=False),
        sa.Column("subtitle", sa.String(length=512), nullable=True),
        sa.Column("authors", postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column("series", sa.String(length=512), nullable=True),
        sa.Column("series_index", sa.Float(), nullable=True),
        sa.Column("isbn", sa.String(length=13), nullable=True),
        sa.Column("publisher", sa.String(length=256), nullable=True),
        sa.Column("year", sa.Integer(), nullable=True),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("language", sa.String(length=8), nullable=False),
        sa.Column("cover_url", sa.Text(), nullable=True),
        sa.Column("status", sa.String(length=24), nullable=False),
        sa.Column("torrent_name", sa.Text(), nullable=True),
        sa.Column("torrent_hash", sa.String(length=64), nullable=True),
        sa.Column("progress", sa.Float(), nullable=False),
        sa.Column("progress_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("attempts", sa.Integer(), nullable=False),
        sa.Column("exclude_guids", postgresql.JSONB(astext_type=sa.Text()), server_default="[]", nullable=False),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("book_id", sa.Uuid(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["book_id"], ["books.id"], name=op.f("fk_book_requests_book_id_books"), ondelete="SET NULL"
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_book_requests_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_book_requests")),
    )
    op.create_index(op.f("ix_book_requests_match_key"), "book_requests", ["match_key"], unique=False)
    op.create_index(op.f("ix_book_requests_status"), "book_requests", ["status"], unique=False)
    op.create_index(op.f("ix_book_requests_user_id"), "book_requests", ["user_id"], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f("ix_book_requests_user_id"), table_name="book_requests")
    op.drop_index(op.f("ix_book_requests_status"), table_name="book_requests")
    op.drop_index(op.f("ix_book_requests_match_key"), table_name="book_requests")
    op.drop_table("book_requests")
    op.drop_index(op.f("ix_books_source_sha256"), table_name="books")
    op.drop_index(op.f("ix_books_series"), table_name="books")
    op.drop_index(op.f("ix_books_match_key"), table_name="books")
    op.drop_index(op.f("ix_books_isbn"), table_name="books")
    op.drop_index(op.f("ix_books_author_sort"), table_name="books")
    op.drop_table("books")
    op.drop_table("book_progress")
