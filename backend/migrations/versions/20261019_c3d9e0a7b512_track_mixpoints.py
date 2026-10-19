"""track_mixpoints

Revision ID: c3d9e0a7b512
Revises: b4c81e5f2a90
Create Date: 2026-10-19
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c3d9e0a7b512"
down_revision: str | Sequence[str] | None = "b4c81e5f2a90"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "track_mixpoints",
        sa.Column("track_id", sa.Uuid(), nullable=False),
        sa.Column("version", sa.Integer(), nullable=False),
        sa.Column("mtime", sa.Float(), nullable=False),
        sa.Column("bpm", sa.Float(), nullable=True),
        sa.Column("mix_in", sa.Float(), nullable=False),
        sa.Column("mix_out", sa.Float(), nullable=False),
        sa.Column("end", sa.Float(), nullable=False),
        sa.Column("analyzed_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(
            ["track_id"], ["tracks.id"], name=op.f("fk_track_mixpoints_track_id_tracks"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("track_id", name=op.f("pk_track_mixpoints")),
    )


def downgrade() -> None:
    op.drop_table("track_mixpoints")
