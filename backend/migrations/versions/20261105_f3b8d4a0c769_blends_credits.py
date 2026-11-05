"""blends (two users' shared daily mix) and cached song credits

Revision ID: f3b8d4a0c769
Revises: e2a7c3f9b658
Create Date: 2026-11-05
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "f3b8d4a0c769"
down_revision: str | Sequence[str] | None = "e2a7c3f9b658"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "blends",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_a_id", sa.Uuid(), nullable=False),
        sa.Column("user_b_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["user_a_id"], ["users.id"], ondelete="CASCADE"),
        sa.ForeignKeyConstraint(["user_b_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("id"),
        sa.UniqueConstraint("user_a_id", "user_b_id"),
    )
    op.create_index(op.f("ix_blends_user_a_id"), "blends", ["user_a_id"])
    op.create_index(op.f("ix_blends_user_b_id"), "blends", ["user_b_id"])
    op.create_table(
        "track_credits",
        sa.Column("track_id", sa.Uuid(), nullable=False),
        sa.Column("data", postgresql.JSONB(), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["track_id"], ["tracks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("track_id"),
    )


def downgrade() -> None:
    op.drop_table("track_credits")
    op.drop_index(op.f("ix_blends_user_b_id"), table_name="blends")
    op.drop_index(op.f("ix_blends_user_a_id"), table_name="blends")
    op.drop_table("blends")
