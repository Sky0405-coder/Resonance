"""mixpoint failures

Revision ID: 07b1c4e2f953
Revises: f6a0b3d1e842
Create Date: 2026-10-21
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "07b1c4e2f953"
down_revision: str | Sequence[str] | None = "f6a0b3d1e842"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("track_mixpoints", sa.Column("failed", sa.Boolean(), server_default=sa.false(), nullable=False))
    for column in ("mix_in", "mix_out", "end"):
        op.alter_column("track_mixpoints", column, existing_type=sa.Float(), nullable=True)


def downgrade() -> None:
    # Failed rows have no mix points and cannot be represented by the previous schema.
    op.execute(sa.text("DELETE FROM track_mixpoints WHERE failed"))
    for column in ("mix_in", "mix_out", "end"):
        op.alter_column("track_mixpoints", column, existing_type=sa.Float(), nullable=False)
    op.drop_column("track_mixpoints", "failed")
