"""track lyrics

Revision ID: 028d653eb147
Revises: f17c542da036
Create Date: 2026-10-16

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "028d653eb147"
down_revision: str | Sequence[str] | None = "f17c542da036"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "track_lyrics",
        sa.Column("track_id", sa.Uuid(), nullable=False),
        sa.Column("synced", sa.Text(), nullable=True),
        sa.Column("plain", sa.Text(), nullable=True),
        sa.Column("instrumental", sa.Boolean(), nullable=False),
        sa.Column("source", sa.String(16), nullable=False),
        sa.Column("fetched_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(["track_id"], ["tracks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("track_id"),
    )


def downgrade() -> None:
    op.drop_table("track_lyrics")
