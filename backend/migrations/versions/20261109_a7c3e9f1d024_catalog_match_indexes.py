"""indexes for matching catalogs against the library and finding downloads by Deezer id

Revision ID: a7c3e9f1d024
Revises: a7d2c5e1f804
Create Date: 2026-11-09
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "a7c3e9f1d024"
down_revision: str | Sequence[str] | None = "a7d2c5e1f804"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_index("ix_tracks_lower_title", "tracks", [sa.text("lower(title) text_pattern_ops")])
    op.create_index("ix_download_items_deezer_track_id", "download_items", [sa.text("(meta->>'deezer_track_id')")])


def downgrade() -> None:
    op.drop_index("ix_download_items_deezer_track_id", table_name="download_items")
    op.drop_index("ix_tracks_lower_title", table_name="tracks")
