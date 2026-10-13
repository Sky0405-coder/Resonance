"""downloads

Revision ID: 8ca22a79b0da
Revises: 65bcbff6c6d1
Create Date: 2026-10-13 19:38:07.695448

"""
from typing import Sequence

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

# revision identifiers, used by Alembic.
revision: str = '8ca22a79b0da'
down_revision: str | Sequence[str] | None = '65bcbff6c6d1'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Upgrade schema."""
    op.create_table(
        'download_requests',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('user_id', sa.Uuid(), nullable=False),
        sa.Column('kind', sa.String(length=16), nullable=False),
        sa.Column('mb_id', sa.String(length=36), nullable=False),
        sa.Column('mb_release_id', sa.String(length=36), nullable=True),
        sa.Column('title', sa.String(length=512), nullable=False),
        sa.Column('artist', sa.String(length=1024), nullable=False),
        sa.Column('cover_url', sa.Text(), nullable=True),
        sa.Column('status', sa.String(length=24), nullable=False),
        sa.Column('is_temporary', sa.Boolean(), nullable=False),
        sa.Column('note', sa.Text(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['user_id'], ['users.id'],
            name=op.f('fk_download_requests_user_id_users'), ondelete='CASCADE'
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_download_requests'))
    )
    op.create_index(op.f('ix_download_requests_status'), 'download_requests', ['status'], unique=False)
    op.create_index(op.f('ix_download_requests_user_id'), 'download_requests', ['user_id'], unique=False)
    op.create_table(
        'download_items',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('request_id', sa.Uuid(), nullable=False),
        sa.Column('position', sa.Integer(), nullable=False),
        sa.Column('title', sa.String(length=512), nullable=False),
        sa.Column('artist', sa.String(length=1024), nullable=False),
        sa.Column('duration', sa.Float(), nullable=True),
        sa.Column('meta', postgresql.JSONB(astext_type=sa.Text()), nullable=False),
        sa.Column('status', sa.String(length=16), nullable=False),
        sa.Column('progress', sa.Float(), nullable=False),
        sa.Column('source', sa.String(length=32), nullable=True),
        sa.Column('source_ref', sa.Text(), nullable=True),
        sa.Column('error', sa.Text(), nullable=True),
        sa.Column('attempts', sa.Integer(), nullable=False),
        sa.Column('track_id', sa.Uuid(), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['request_id'], ['download_requests.id'],
            name=op.f('fk_download_items_request_id_download_requests'), ondelete='CASCADE'
        ),
        sa.ForeignKeyConstraint(['track_id'], ['tracks.id'],
            name=op.f('fk_download_items_track_id_tracks'), ondelete='SET NULL'
        ),
        sa.PrimaryKeyConstraint('id', name=op.f('pk_download_items'))
    )
    op.create_index(op.f('ix_download_items_request_id'), 'download_items', ['request_id'], unique=False)
    op.create_index(op.f('ix_download_items_status'), 'download_items', ['status'], unique=False)


def downgrade() -> None:
    """Downgrade schema."""
    op.drop_index(op.f('ix_download_items_status'), table_name='download_items')
    op.drop_index(op.f('ix_download_items_request_id'), table_name='download_items')
    op.drop_table('download_items')
    op.drop_index(op.f('ix_download_requests_user_id'), table_name='download_requests')
    op.drop_index(op.f('ix_download_requests_status'), table_name='download_requests')
    op.drop_table('download_requests')
