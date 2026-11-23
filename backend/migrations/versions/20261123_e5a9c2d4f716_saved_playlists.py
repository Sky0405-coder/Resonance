"""saved playlists: other users' public playlists and mixes kept in the library

Until now every public playlist of every user showed in everyone's library. Those the users see there now are saved
for them, so nothing disappears; from here on others' public playlists are found by searching and saved with the heart.

Revision ID: e5a9c2d4f716
Revises: d3f7b9e1a248
Create Date: 2026-11-23
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e5a9c2d4f716"
down_revision: str | Sequence[str] | None = "d3f7b9e1a248"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "saved_playlists",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("playlist_id", sa.Uuid(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["playlist_id"], ["playlists.id"], name=op.f("fk_saved_playlists_playlist_id_playlists"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_saved_playlists_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_saved_playlists")),
        sa.UniqueConstraint("user_id", "playlist_id", name=op.f("uq_saved_playlists_user_id")),
    )
    op.create_index(op.f("ix_saved_playlists_user_id"), "saved_playlists", ["user_id"])
    op.create_index(op.f("ix_saved_playlists_playlist_id"), "saved_playlists", ["playlist_id"])
    op.execute(
        "INSERT INTO saved_playlists (id, user_id, playlist_id, created_at) "
        "SELECT gen_random_uuid(), users.id, playlists.id, now() FROM users JOIN playlists "
        "ON playlists.is_public AND playlists.kind = 'user' AND playlists.owner_id <> users.id"
    )


def downgrade() -> None:
    op.drop_index("ix_saved_playlists_playlist_id", table_name="saved_playlists")
    op.drop_index("ix_saved_playlists_user_id", table_name="saved_playlists")
    op.drop_table("saved_playlists")
