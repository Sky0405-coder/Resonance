"""look for missing artist images again, now also on Deezer

Revision ID: a7c3e9b5d214
Revises: f6b2d8a4c913
Create Date: 2026-11-02
"""

from collections.abc import Sequence

from alembic import op

revision: str = "a7c3e9b5d214"
down_revision: str | Sequence[str] | None = "f6b2d8a4c913"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.execute("UPDATE artists SET info_checked_at = NULL WHERE image_path IS NULL")


def downgrade() -> None:
    pass
