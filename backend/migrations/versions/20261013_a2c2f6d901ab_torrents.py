"""Torrent download request state.

Revision ID: a2c2f6d901ab
Revises: 0f30cb02da03
"""

import sqlalchemy as sa
from alembic import op

revision: str = "a2c2f6d901ab"
down_revision: str = "0f30cb02da03"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column("download_requests", sa.Column("torrent_status", sa.String(16), nullable=True))
    op.add_column("download_requests", sa.Column("torrent_name", sa.Text(), nullable=True))
    op.add_column("download_requests", sa.Column("torrent_progress", sa.Float(), nullable=False, server_default="0"))
    op.alter_column("download_requests", "torrent_progress", server_default=None)
    op.add_column("download_requests", sa.Column("torrent_progress_at", sa.DateTime(timezone=True), nullable=True))
    op.add_column("download_requests", sa.Column("torrent_error", sa.Text(), nullable=True))


def downgrade() -> None:
    for name in ("torrent_error", "torrent_progress_at", "torrent_progress", "torrent_name", "torrent_status"):
        op.drop_column("download_requests", name)
