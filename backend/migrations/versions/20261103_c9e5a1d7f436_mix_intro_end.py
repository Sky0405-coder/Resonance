"""AutoMix: where each song's intro ends (analysis version 4 analyzes every song again)

Revision ID: c9e5a1d7f436
Revises: b8d4f0c6e325
Create Date: 2026-11-03
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c9e5a1d7f436"
down_revision: str | Sequence[str] | None = "b8d4f0c6e325"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("track_mixpoints", sa.Column("intro_end", sa.Float(), nullable=True))


def downgrade() -> None:
    op.drop_column("track_mixpoints", "intro_end")
