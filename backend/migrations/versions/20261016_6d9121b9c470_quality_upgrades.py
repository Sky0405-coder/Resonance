"""quality upgrades

Revision ID: 6d9121b9c470
Revises: 5c8010a8b36f
Create Date: 2026-10-16

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "6d9121b9c470"
down_revision: str | Sequence[str] | None = "5c8010a8b36f"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "quality_upgrade_attempts",
        sa.Column("album_id", sa.Uuid(), nullable=False),
        sa.Column("tried_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("result", sa.String(24), nullable=False),
        sa.ForeignKeyConstraint(["album_id"], ["albums.id"], ondelete="CASCADE"),
        sa.PrimaryKeyConstraint("album_id"),
    )
    op.add_column("download_items", sa.Column("replace_track_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_download_items_replace_track_id_tracks",
        "download_items",
        "tracks",
        ["replace_track_id"],
        ["id"],
        ondelete="SET NULL",
    )


def downgrade() -> None:
    op.drop_constraint("fk_download_items_replace_track_id_tracks", "download_items", type_="foreignkey")
    op.drop_column("download_items", "replace_track_id")
    op.drop_table("quality_upgrade_attempts")
