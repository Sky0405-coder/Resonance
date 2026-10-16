"""playlist covers and reviewed tracks

Revision ID: 7e2a9b4c601d
Revises: 7ea232cad581
Create Date: 2026-10-17

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7e2a9b4c601d"
down_revision: str | Sequence[str] | None = "7ea232cad581"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("playlists", sa.Column("cover_file", sa.String(64), nullable=True))
    op.add_column("tracks", sa.Column("reviewed", sa.Boolean(), server_default=sa.false(), nullable=False))


def downgrade() -> None:
    op.drop_column("tracks", "reviewed")
    op.drop_column("playlists", "cover_file")
