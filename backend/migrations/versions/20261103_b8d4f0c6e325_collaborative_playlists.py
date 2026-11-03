"""collaborative playlists: shared users may edit the songs; entries remember who added them

Revision ID: b8d4f0c6e325
Revises: a7c3e9b5d214
Create Date: 2026-11-03
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b8d4f0c6e325"
down_revision: str | Sequence[str] | None = "a7c3e9b5d214"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("playlists", sa.Column("collaborative", sa.Boolean(), nullable=False, server_default=sa.false()))
    op.add_column(
        "playlist_entries",
        sa.Column("added_by_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("playlist_entries", "added_by_id")
    op.drop_column("playlists", "collaborative")
