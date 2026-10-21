"""podcasts

Revision ID: b731fa90c824
Revises: a42d8b19e705
Create Date: 2026-10-21
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "b731fa90c824"
down_revision: str | Sequence[str] | None = "a42d8b19e705"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "podcasts",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("feed_url", sa.Text(), nullable=False, unique=True),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("author", sa.Text()),
        sa.Column("description", sa.Text()),
        sa.Column("image_url", sa.Text()),
        sa.Column("website", sa.Text()),
        sa.Column("last_fetched_at", sa.DateTime(timezone=True)),
        sa.Column("etag", sa.Text()),
        sa.Column("last_modified", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_table(
        "podcast_episodes",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("podcast_id", sa.Uuid(), sa.ForeignKey("podcasts.id", ondelete="CASCADE"), nullable=False),
        sa.Column("guid", sa.Text(), nullable=False),
        sa.Column("title", sa.Text(), nullable=False),
        sa.Column("description", sa.Text()),
        sa.Column("published_at", sa.DateTime(timezone=True)),
        sa.Column("duration_seconds", sa.Float()),
        sa.Column("audio_url", sa.Text(), nullable=False),
        sa.Column("audio_type", sa.Text()),
        sa.Column("image_url", sa.Text()),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.UniqueConstraint("podcast_id", "guid", name="uq_podcast_episodes_podcast_id"),
    )
    op.create_index("ix_podcast_episodes_podcast_id", "podcast_episodes", ["podcast_id"])
    op.create_index("ix_podcast_episodes_published_at", "podcast_episodes", ["published_at"])
    op.create_table(
        "podcast_subscriptions",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("podcast_id", sa.Uuid(), sa.ForeignKey("podcasts.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_table(
        "episode_progress",
        sa.Column("user_id", sa.Uuid(), sa.ForeignKey("users.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("episode_id", sa.Uuid(), sa.ForeignKey("podcast_episodes.id", ondelete="CASCADE"), primary_key=True),
        sa.Column("position_seconds", sa.Float(), nullable=False),
        sa.Column("completed", sa.Boolean(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table("episode_progress")
    op.drop_table("podcast_subscriptions")
    op.drop_table("podcast_episodes")
    op.drop_table("podcasts")
