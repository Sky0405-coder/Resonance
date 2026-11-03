"""transitions made in the transition editor, per playlist and pair of songs

Revision ID: d1f6b2e8a547
Revises: c9e5a1d7f436
Create Date: 2026-11-03
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d1f6b2e8a547"
down_revision: str | Sequence[str] | None = "c9e5a1d7f436"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "playlist_transitions",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("playlist_id", sa.Uuid(), sa.ForeignKey("playlists.id", ondelete="CASCADE"), nullable=False),
        sa.Column("from_track_id", sa.Uuid(), sa.ForeignKey("tracks.id", ondelete="CASCADE"), nullable=False),
        sa.Column("to_track_id", sa.Uuid(), sa.ForeignKey("tracks.id", ondelete="CASCADE"), nullable=False),
        sa.Column("style", sa.String(16), nullable=False),
        sa.Column("bars", sa.Integer(), nullable=False),
        sa.Column("start", sa.Float(), nullable=False),
        sa.Column("incoming_start", sa.Float(), nullable=False),
        sa.Column("updated_by_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="SET NULL"), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("playlist_id", "from_track_id", "to_track_id"),
    )
    op.create_index("ix_playlist_transitions_playlist_id", "playlist_transitions", ["playlist_id"])


def downgrade() -> None:
    op.drop_index("ix_playlist_transitions_playlist_id", table_name="playlist_transitions")
    op.drop_table("playlist_transitions")
