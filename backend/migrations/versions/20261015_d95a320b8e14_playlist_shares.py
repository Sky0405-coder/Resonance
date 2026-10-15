"""playlist_shares

Revision ID: d95a320b8e14
Revises: c84f219a7d03
Create Date: 2026-10-15

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d95a320b8e14"
down_revision: str | Sequence[str] | None = "c84f219a7d03"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "playlist_shares",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("playlist_id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["playlist_id"], ["playlists.id"], name=op.f("fk_playlist_shares_playlist_id_playlists"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_playlist_shares_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_playlist_shares")),
        sa.UniqueConstraint("playlist_id", "user_id", name=op.f("uq_playlist_shares_playlist_id")),
    )
    op.create_index(op.f("ix_playlist_shares_playlist_id"), "playlist_shares", ["playlist_id"], unique=False)
    op.create_index(op.f("ix_playlist_shares_user_id"), "playlist_shares", ["user_id"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_playlist_shares_user_id"), table_name="playlist_shares")
    op.drop_index(op.f("ix_playlist_shares_playlist_id"), table_name="playlist_shares")
    op.drop_table("playlist_shares")
