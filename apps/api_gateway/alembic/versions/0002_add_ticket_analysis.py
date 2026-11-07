"""add ticket analysis and the escalated status

Revision ID: 0002
Revises: 0001
Create Date: 2026-11-01 18:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = '0002'
down_revision: str | Sequence[str] | None = '0001'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    """Add ``tickets.analysis`` and the ``escalated`` value of ``ticket_status``."""
    # ALTER TYPE ... ADD VALUE cannot run inside a transaction block, so it gets its own
    # autocommit block. IF NOT EXISTS keeps the migration re-runnable.
    with op.get_context().autocommit_block():
        op.execute("ALTER TYPE ticket_status ADD VALUE IF NOT EXISTS 'escalated'")
    op.add_column('tickets', sa.Column('analysis', sa.Text(), nullable=True))


def downgrade() -> None:
    """Drop ``tickets.analysis``.

    PostgreSQL cannot remove a value from an enum type, so ``escalated`` stays in
    ``ticket_status``. Rows that use it must be moved to another status before running
    an older version of the application.
    """
    op.drop_column('tickets', 'analysis')
