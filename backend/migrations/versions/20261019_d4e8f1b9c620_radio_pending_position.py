"""radio_pending_position

Revision ID: d4e8f1b9c620
Revises: c3d9e0a7b512
Create Date: 2026-10-19
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "d4e8f1b9c620"
down_revision: str | Sequence[str] | None = "c3d9e0a7b512"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("radio_pending", sa.Column("position", sa.Float(), nullable=True))


def downgrade() -> None:
    op.drop_column("radio_pending", "position")
