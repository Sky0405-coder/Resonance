"""trigram indexes for searching artists, albums and songs

Revision ID: c4e8a1b7d350
Revises: a7c3e9f1d024
Create Date: 2026-11-09
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

revision: str = "c4e8a1b7d350"
down_revision: str | Sequence[str] | None = "a7c3e9f1d024"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_COLUMNS = (("artists", "name"), ("albums", "title"), ("tracks", "title"), ("tracks", "artist_credit"))


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS pg_trgm")
    for table, column in _COLUMNS:
        op.create_index(f"ix_{table}_{column}_trgm", table, [sa.text(f"{column} gin_trgm_ops")], postgresql_using="gin")
        op.create_index(
            f"ix_{table}_{column}_compact_trgm",
            table,
            [sa.text(rf"regexp_replace(lower({column}), '[^[\:alnum\:]]+', '', 'g') gin_trgm_ops")],
            postgresql_using="gin",
        )


def downgrade() -> None:
    for table, column in _COLUMNS:
        op.drop_index(f"ix_{table}_{column}_compact_trgm", table_name=table)
        op.drop_index(f"ix_{table}_{column}_trgm", table_name=table)
