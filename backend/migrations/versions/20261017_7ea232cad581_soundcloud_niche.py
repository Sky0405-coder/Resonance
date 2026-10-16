"""SoundCloud and search requests

Revision ID: 7ea232cad581
Revises: 6d9121b9c470
Create Date: 2026-10-17

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7ea232cad581"
down_revision: str | Sequence[str] | None = "6d9121b9c470"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("download_requests", "catalog_id", existing_type=sa.String(32), type_=sa.String(64))
    op.add_column("spotify_pending", sa.Column("download_item_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_spotify_pending_download_item_id_download_items",
        "spotify_pending",
        "download_items",
        ["download_item_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint("fk_spotify_pending_download_item_id_download_items", "spotify_pending", type_="foreignkey")
    op.drop_column("spotify_pending", "download_item_id")
    op.alter_column("download_requests", "catalog_id", existing_type=sa.String(64), type_=sa.String(32))
