"""Per-user Audiobookshelf accounts.

Revision ID: b7318e9f4c02
Revises: a2c2f6d901ab
"""

import sqlalchemy as sa
from alembic import op

revision: str = "b7318e9f4c02"
down_revision: str = "a2c2f6d901ab"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "audiobookshelf_accounts",
        sa.Column("user_id", sa.Uuid(), nullable=False),
        sa.Column("abs_user_id", sa.String(64), nullable=False),
        sa.Column("abs_username", sa.String(256), nullable=False),
        sa.Column("refresh_token", sa.Text(), nullable=False),
        sa.Column("access_token", sa.Text(), nullable=True),
        sa.Column("access_expires_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.ForeignKeyConstraint(
            ["user_id"], ["users.id"], name=op.f("fk_audiobookshelf_accounts_user_id_users"), ondelete="CASCADE"
        ),
        sa.PrimaryKeyConstraint("user_id", name=op.f("pk_audiobookshelf_accounts")),
    )


def downgrade() -> None:
    op.drop_table("audiobookshelf_accounts")
