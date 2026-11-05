"""the transition editor's lanes (volume, EQ, filter, effect, loop, beatmatching) per saved transition

Revision ID: e2a7c3f9b658
Revises: d1f6b2e8a547
Create Date: 2026-11-05
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "e2a7c3f9b658"
down_revision: str | Sequence[str] | None = "d1f6b2e8a547"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("playlist_transitions", sa.Column("lanes", postgresql.JSONB(), nullable=True))


def downgrade() -> None:
    op.drop_column("playlist_transitions", "lanes")
