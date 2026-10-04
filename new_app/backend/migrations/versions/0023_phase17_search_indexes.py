"""0023_phase17_search_indexes

Revision ID: 5c8d2e1f4a73
Revises: e7d4a9c1f3b6
Create Date: 2026-10-04

Phase 17 - 17.8 performance audit - additive ONLY.

POS lookup is a statement pair in ``app/repositories/catalog.py::search``::

    count : SELECT count(*) FROM products
            WHERE (name ILIKE '%term%' OR barcode ILIKE '%term%')
              AND archived_at IS NULL
    items : SELECT ... FROM products WHERE <same predicate>
            ORDER BY name, id LIMIT n

Measured on the 17.8 benchmark fixture (``supermarket_bench_phase17``,
100 000 products, ``EXPLAIN (ANALYZE, BUFFERS)``) BOTH statements were
sequential scans: 46 ms of COUNT plus 53 ms of items before SQLAlchemy even
hydrates a row - p95 185 ms against the Phase 0 target
"POS lookup p95 < 100 ms" (docs/PHASE_0_PERFORMANCE_AUDIT.md).

The remedy is the one Phase 0 already prescribes - "indexed server search":

1. ``ix_products_name`` (btree)
      ``ORDER BY name, id LIMIT n`` walks the index in order and stops at the
      first n matches instead of sorting every surviving row.
2. ``ix_products_name_trgm`` / ``ix_products_barcode_trgm`` (GIN, pg_trgm)
      substring ``ILIKE '%term%'`` becomes a bitmap scan for the selective
      typing-ahead terms a till actually sends ("sha", "009999", a digit run).

``pg_trgm`` is a trusted extension on PostgreSQL 13+, but this migration does
not assume the installer ran as superuser: extension creation happens inside a
SAVEPOINT, and when it is refused the btree index is still installed and a
warning is printed (only the non-selective, matches-everything term keeps its
sequential scan).  No tables, no columns, no constraint, no data rewrite.

Downgrade drops only what this revision added.
"""

from alembic import op
import sqlalchemy as sa

# revision identifiers, used by Alembic.
revision: str = '5c8d2e1f4a73'
down_revision = 'e7d4a9c1f3b6'
branch_labels = None
depends_on = None

_TRGM_INDEXES = (
    ("ix_products_name_trgm", "products", "name"),
    ("ix_products_barcode_trgm", "products", "barcode"),
)


def upgrade() -> None:
    op.create_index("ix_products_name", "products", ["name"], unique=False)

    bind = op.get_bind()
    if bind.dialect.name != "postgresql":
        return

    try:
        with bind.begin_nested():
            bind.execute(sa.text("CREATE EXTENSION IF NOT EXISTS pg_trgm"))
    except Exception as exc:  # pragma: no cover - refused only for non-superuser
        print(
            "WARNING: pg_trgm could not be created "
            f"({exc}); substring product search stays a sequential scan"
        )
        return

    for name, table, column in _TRGM_INDEXES:
        bind.execute(
            sa.text(
                f"CREATE INDEX IF NOT EXISTS {name} ON {table} "
                f"USING gin ({column} gin_trgm_ops)"
            )
        )
    bind.execute(sa.text("ANALYZE products"))


def downgrade() -> None:
    bind = op.get_bind()
    if bind.dialect.name == "postgresql":
        for name, _table, _column in reversed(_TRGM_INDEXES):
            bind.execute(sa.text(f"DROP INDEX IF EXISTS {name}"))
    op.drop_index("ix_products_name", table_name="products")
