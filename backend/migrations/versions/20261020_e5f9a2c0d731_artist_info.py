"""artist information

Revision ID: e5f9a2c0d731
Revises: e5f902c7d831
Create Date: 2026-10-20
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "e5f9a2c0d731"
down_revision: str | Sequence[str] | None = "e5f902c7d831"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("artists", sa.Column("bio_de", sa.Text(), nullable=True))
    op.add_column("artists", sa.Column("bio_en", sa.Text(), nullable=True))
    op.add_column("artists", sa.Column("info_checked_at", sa.DateTime(timezone=True), nullable=True))


def downgrade() -> None:
    op.drop_column("artists", "info_checked_at")
    op.drop_column("artists", "bio_en")
    op.drop_column("artists", "bio_de")
