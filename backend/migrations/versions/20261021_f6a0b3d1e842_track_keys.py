"""track keys

Revision ID: f6a0b3d1e842
Revises: e5f9a2c0d731
Create Date: 2026-10-21
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f6a0b3d1e842"
down_revision: str | Sequence[str] | None = "e5f9a2c0d731"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("track_mixpoints", sa.Column("key", sa.String(3), nullable=True))
    op.add_column("track_mixpoints", sa.Column("key_confidence", sa.Float(), nullable=True))


def downgrade() -> None:
    op.drop_column("track_mixpoints", "key_confidence")
    op.drop_column("track_mixpoints", "key")
