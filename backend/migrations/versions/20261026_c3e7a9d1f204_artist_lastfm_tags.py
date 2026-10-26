"""artist lastfm tags

Revision ID: c3e7a9d1f204
Revises: b731fa90c824
Create Date: 2026-10-26
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects.postgresql import JSONB

revision: str = "c3e7a9d1f204"
down_revision: str | Sequence[str] | None = "b731fa90c824"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("artists", sa.Column("lastfm_tags", JSONB()))
    op.add_column("artists", sa.Column("lastfm_checked_at", sa.DateTime(timezone=True)))


def downgrade() -> None:
    op.drop_column("artists", "lastfm_checked_at")
    op.drop_column("artists", "lastfm_tags")
