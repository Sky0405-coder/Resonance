"""track fingerprints

Revision ID: a42d8b19e705
Revises: 07b1c4e2f953
Create Date: 2026-10-21
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a42d8b19e705"
down_revision: str | Sequence[str] | None = "07b1c4e2f953"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "track_fingerprints",
        sa.Column("track_id", sa.Uuid(), nullable=False),
        sa.Column("mtime", sa.Float(), nullable=False),
        sa.Column("fingerprint", sa.LargeBinary(), nullable=True),
        sa.Column("failed", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.ForeignKeyConstraint(["track_id"], ["tracks.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("track_id"),
    )


def downgrade() -> None:
    op.drop_table("track_fingerprints")
