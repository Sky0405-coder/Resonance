"""playlist_cover_key

Revision ID: e5f902c7d831
Revises: d4e8f1b9c620
Create Date: 2026-10-20
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e5f902c7d831"
down_revision: str | Sequence[str] | None = "d4e8f1b9c620"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("playlists", sa.Column("cover_key", sa.String(length=64), nullable=True))


def downgrade() -> None:
    op.drop_column("playlists", "cover_key")
