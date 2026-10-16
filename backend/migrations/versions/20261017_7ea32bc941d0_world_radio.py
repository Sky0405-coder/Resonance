"""world radio

Revision ID: 7ea32bc941d0
Revises: 7e2a9b4c601d
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "7ea32bc941d0"
down_revision: str | Sequence[str] | None = "7e2a9b4c601d"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "radio_station_favorites",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("station_id", sa.String(64), nullable=False),
        sa.Column("data", postgresql.JSONB(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("user_id", "station_id"),
    )


def downgrade() -> None:
    op.drop_table("radio_station_favorites")
