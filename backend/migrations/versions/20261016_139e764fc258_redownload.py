"""redownload

Revision ID: 139e764fc258
Revises: 028d653eb147
Create Date: 2026-10-16

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "139e764fc258"
down_revision: str | Sequence[str] | None = "028d653eb147"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("download_requests", sa.Column("replace_track_id", sa.Uuid(), nullable=True))
    op.create_foreign_key(
        "fk_download_requests_replace_track_id_tracks",
        "download_requests",
        "tracks",
        ["replace_track_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.add_column(
        "download_items",
        sa.Column("exclude_refs", postgresql.JSONB(), server_default=sa.text("'[]'"), nullable=False),
    )


def downgrade() -> None:
    op.drop_column("download_items", "exclude_refs")
    op.drop_constraint("fk_download_requests_replace_track_id_tracks", "download_requests", type_="foreignkey")
    op.drop_column("download_requests", "replace_track_id")
