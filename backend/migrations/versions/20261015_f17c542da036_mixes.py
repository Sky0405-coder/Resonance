"""mixes

Revision ID: f17c542da036
Revises: e06b431c9f25
Create Date: 2026-10-15

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "f17c542da036"
down_revision: str | Sequence[str] | None = "e06b431c9f25"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("playlists", sa.Column("mix_key", sa.String(128), nullable=True))
    op.add_column("playlists", sa.Column("generated_at", sa.DateTime(timezone=True), nullable=True))
    op.create_index(
        "ix_playlists_owner_id_mix_key",
        "playlists",
        ["owner_id", "mix_key"],
        unique=True,
        postgresql_where=sa.text("mix_key IS NOT NULL"),
    )


def downgrade() -> None:
    op.drop_index("ix_playlists_owner_id_mix_key", table_name="playlists")
    op.drop_column("playlists", "generated_at")
    op.drop_column("playlists", "mix_key")
