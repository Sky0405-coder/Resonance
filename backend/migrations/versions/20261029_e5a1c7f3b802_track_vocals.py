"""track vocals from the optional song analysis

Revision ID: e5a1c7f3b802
Revises: d4f8b2e6a915
Create Date: 2026-10-29
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e5a1c7f3b802"
down_revision: str | Sequence[str] | None = "d4f8b2e6a915"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "track_vocals",
        sa.Column("track_id", sa.Uuid(), sa.ForeignKey("tracks.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("mtime", sa.Float(), nullable=False),
        sa.Column("failed", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("vocals_in", sa.Float()),
        sa.Column("vocals_out", sa.Float()),
        sa.Column("analyzed_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("track_vocals")
