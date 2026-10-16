"""subsonic password

Revision ID: 5c8010a8b36f
Revises: 49b614aa97a2
Create Date: 2026-10-16

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "5c8010a8b36f"
down_revision: str | Sequence[str] | None = "49b614aa97a2"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("subsonic_password", sa.String(64), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "subsonic_password")
