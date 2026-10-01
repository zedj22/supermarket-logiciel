"""0020_phase14_report_indexes

Revision ID: 4a1e5c7b9d2f
Revises: 2f6b9c4d8a31
Create Date: 2026-09-30

Phase 14 (Reports + Dashboard) - additive ONLY (decision record §14):

Four btree indexes backing the report date-window scans. No tables, no
columns, no backfill, no constraint - the report surface is a read-only
projection over Phase 8/9/11/13 data.

1. ix_sales_sale_date
      sales.sale_date BETWEEN ? AND ? is the WHERE clause of every §5.1-§5.4
      aggregate (financial, sales detail, daily, hourly, peak, dashboard).
2. ix_sales_status_sale_date
      every aggregate additionally filters ``status = 'completed'``; the
      two-column index serves the filtered form directly so voided invoices
      do not widen the scan.
3. ix_debt_ledger_entries_entry_date
      §5.5 ``debt_collected`` = SUM(amount) WHERE entry_type = 'payment'
      AND entry_date IN WINDOW.
4. ix_supplier_ledger_entries_entry_date
      §5.7 supplier movement block = SUM over entry_type in window; the
      existing (supplier_id, entry_date) index cannot serve a window that
      spans every supplier.

Two PostgreSQL-only extended statistics objects (no-op on SQLite, where
statistics do not exist) back the §15 planner estimates:

5. st_0020_sales_utc_day
      GROUP BY CAST(sale_date AT TIME ZONE 'UTC' AS DATE) (A1 buckets) has
      no column statistics by default - PostgreSQL estimates ~one group per
      input row, declares partial aggregation useless and runs the daily /
      products / categories statements serially (measured 2.2x over the
      parallel plan). The statistics give the true ~400-row estimate.
6. st_0020_sale_lines_item
      same story for the §5.8 item aggregation GROUP BY
      COALESCE(product_id, pack_id), <kind case>: estimated 81600 groups,
      actual ~510; with statistics the join and aggregate stay parallel.

DOWNGRADE drops only these four indexes and two statistics objects;
nothing else is touched and no data is rewritten in either direction.
"""

from alembic import op

# revision identifiers, used by Alembic.
revision: str = '4a1e5c7b9d2f'
down_revision = '2f6b9c4d8a31'
branch_labels = None
depends_on = None

_INDEXES = (
    ("ix_sales_sale_date", "sales", ["sale_date"]),
    ("ix_sales_status_sale_date", "sales", ["status", "sale_date"]),
    (
        "ix_debt_ledger_entries_entry_date",
        "debt_ledger_entries",
        ["entry_date"],
    ),
    (
        "ix_supplier_ledger_entries_entry_date",
        "supplier_ledger_entries",
        ["entry_date"],
    ),
)

# (name, table, expression list) - PostgreSQL only; expressions must match
# the report SQL byte-for-byte after parsing to receive the statistics.
_STATISTICS = (
    (
        "st_0020_sales_utc_day",
        "sales",
        "((sale_date AT TIME ZONE 'UTC')::date)",
    ),
    (
        "st_0020_sale_lines_item",
        "sale_lines",
        "(COALESCE(product_id, pack_id)), "
        "((CASE WHEN (product_id IS NULL) THEN 'pack'::text "
        "WHEN ((product_id IS NOT NULL) AND (pack_id IS NOT NULL)) "
        "THEN 'component'::text ELSE 'product'::text END))",
    ),
)


def upgrade() -> None:
    for name, table, columns in _INDEXES:
        op.create_index(name, table, columns)
    if op.get_bind().dialect.name == "postgresql":
        for name, table, exprs in _STATISTICS:
            op.execute(f'CREATE STATISTICS "{name}" ON {exprs} FROM "{table}"')
            op.execute(f'ANALYZE "{table}"')


def downgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        for name, _table, _exprs in reversed(_STATISTICS):
            op.execute(f'DROP STATISTICS IF EXISTS "{name}"')
    for name, table, _columns in reversed(_INDEXES):
        op.drop_index(name, table_name=table)
