"""mix analysis: downbeat, section starts and energy (phrase-aware transitions, DJ set order)

Revision ID: a7d2c5e1f804
Revises: f3b8d4a0c769
Create Date: 2026-11-06
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "a7d2c5e1f804"
down_revision: str | Sequence[str] | None = "f3b8d4a0c769"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("track_mixpoints", sa.Column("downbeat", sa.Float(), nullable=True))
    op.add_column("track_mixpoints", sa.Column("phrases", postgresql.JSONB(), nullable=True))
    op.add_column("track_mixpoints", sa.Column("energy", sa.Float(), nullable=True))


def downgrade() -> None:
    op.drop_column("track_mixpoints", "energy")
    op.drop_column("track_mixpoints", "phrases")
    op.drop_column("track_mixpoints", "downbeat")
