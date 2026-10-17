"""download items: source picked by the user

Revision ID: 7eb1d4a2c9f3
Revises: 7ea32bc941d0
Create Date: 2026-10-17
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "7eb1d4a2c9f3"
down_revision: str | Sequence[str] | None = "7ea32bc941d0"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "download_items", sa.Column("source_pinned", sa.Boolean(), server_default=sa.false(), nullable=False)
    )


def downgrade() -> None:
    op.drop_column("download_items", "source_pinned")
