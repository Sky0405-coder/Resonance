"""spotify links

Revision ID: 49b614aa97a2
Revises: 139e764fc258
Create Date: 2026-10-16

"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "49b614aa97a2"
down_revision: str | Sequence[str] | None = "139e764fc258"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "spotify_imports", sa.Column("links", postgresql.JSONB(), server_default=sa.text("'[]'"), nullable=False)
    )


def downgrade() -> None:
    op.drop_column("spotify_imports", "links")
