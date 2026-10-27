"""podcast ad removal

Revision ID: d4f8b2e6a915
Revises: c3e7a9d1f204
Create Date: 2026-10-27
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d4f8b2e6a915"
down_revision: str | Sequence[str] | None = "c3e7a9d1f204"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "podcast_subscriptions", sa.Column("remove_ads", sa.Boolean(), server_default=sa.false(), nullable=False)
    )
    op.add_column("podcast_episodes", sa.Column("ad_status", sa.Text()))
    op.add_column("podcast_episodes", sa.Column("ad_seconds", sa.Float()))
    op.add_column("podcast_episodes", sa.Column("ad_duration", sa.Float()))
    op.add_column("podcast_episodes", sa.Column("ad_processed_at", sa.DateTime(timezone=True)))
    op.create_table(
        "podcast_ads",
        sa.Column("id", sa.Uuid(), primary_key=True),
        sa.Column("podcast_id", sa.Uuid(), sa.ForeignKey("podcasts.id", ondelete="SET NULL")),
        sa.Column("hashes", sa.LargeBinary(), nullable=False),
        sa.Column("seconds", sa.Float(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index("ix_podcast_ads_created_at", "podcast_ads", ["created_at"])


def downgrade() -> None:
    op.drop_index("ix_podcast_ads_created_at", "podcast_ads")
    op.drop_table("podcast_ads")
    for column in ("ad_processed_at", "ad_duration", "ad_seconds", "ad_status"):
        op.drop_column("podcast_episodes", column)
    op.drop_column("podcast_subscriptions", "remove_ads")
