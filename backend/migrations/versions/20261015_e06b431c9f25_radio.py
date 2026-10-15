"""radio

Revision ID: e06b431c9f25
Revises: d95a320b8e14
Create Date: 2026-10-15

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e06b431c9f25"
down_revision: str | Sequence[str] | None = "d95a320b8e14"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("playlists", sa.Column("kind", sa.String(16), server_default="user", nullable=False))
    op.add_column("playlists", sa.Column("radio_seed", sa.String(64), nullable=True))
    op.add_column("playlists", sa.Column("last_used_at", sa.DateTime(timezone=True), nullable=True))
    op.create_index("ix_playlists_owner_id_radio_seed", "playlists", ["owner_id", "radio_seed"], unique=False)
    op.create_table(
        "radio_pending",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("playlist_id", sa.Uuid(), nullable=False),
        sa.Column("deezer_id", sa.String(20), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["playlist_id"], ["playlists.id"], name=op.f("fk_radio_pending_playlist_id_playlists"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_radio_pending")),
    )
    op.create_index(op.f("ix_radio_pending_playlist_id"), "radio_pending", ["playlist_id"], unique=False)


def downgrade() -> None:
    op.drop_index(op.f("ix_radio_pending_playlist_id"), table_name="radio_pending")
    op.drop_table("radio_pending")
    op.drop_index("ix_playlists_owner_id_radio_seed", table_name="playlists")
    op.drop_column("playlists", "last_used_at")
    op.drop_column("playlists", "radio_seed")
    op.drop_column("playlists", "kind")
