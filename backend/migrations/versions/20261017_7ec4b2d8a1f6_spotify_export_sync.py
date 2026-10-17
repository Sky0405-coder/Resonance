"""spotify_export_sync

Revision ID: 7ec4b2d8a1f6
Revises: 7eb1d4a2c9f3
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "7ec4b2d8a1f6"
down_revision: str | Sequence[str] | None = "7eb1d4a2c9f3"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("spotify_accounts", sa.Column("scope", sa.Text(), nullable=True))
    op.create_table(
        "spotify_syncs",
        sa.Column("id", sa.Uuid(), nullable=False),
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("playlist_id", sa.Uuid(), nullable=False),
        sa.Column("spotify_playlist_id", sa.String(64), nullable=False),
        sa.Column("spotify_url", sa.Text(), nullable=True),
        sa.Column("two_way", sa.Boolean(), nullable=False),
        sa.Column("status", sa.String(16), nullable=False),
        sa.Column("error", sa.Text(), nullable=True),
        sa.Column("last_synced_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("prev_spotify", postgresql.JSONB(), server_default="[]", nullable=False),
        sa.Column("prev_tracks", postgresql.JSONB(), server_default="[]", nullable=False),
        sa.Column("unmatched", postgresql.JSONB(), server_default="[]", nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_spotify_syncs_user_id_users"), ondelete="CASCADE"
        ),
        sa.ForeignKeyConstraint(
            ["playlist_id"], ["playlists.id"], name=op.f("fk_spotify_syncs_playlist_id_playlists"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("id", name=op.f("pk_spotify_syncs")),
        sa.UniqueConstraint("playlist_id", name=op.f("uq_spotify_syncs_playlist_id")),
    )
    op.create_index(op.f("ix_spotify_syncs_user_id"), "spotify_syncs", ["user_id"])
    op.create_table(
        "spotify_track_map",
        sa.Column("track_id", sa.Uuid(), nullable=False),
        sa.Column("spotify_uri", sa.String(64), nullable=True),
        sa.Column("checked_at", sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(
            ["track_id"], ["tracks.id"], name=op.f("fk_spotify_track_map_track_id_tracks"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("track_id", name=op.f("pk_spotify_track_map")),
    )


def downgrade() -> None:
    op.drop_table("spotify_track_map")
    op.drop_index(op.f("ix_spotify_syncs_user_id"), table_name="spotify_syncs")
    op.drop_table("spotify_syncs")
    op.drop_column("spotify_accounts", "scope")
