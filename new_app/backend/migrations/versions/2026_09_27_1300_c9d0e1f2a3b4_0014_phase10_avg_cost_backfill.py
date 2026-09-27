"""0014_phase10_avg_cost_backfill

Revision ID: c9d0e1f2a3b4
Revises: b7c8d9e0f1a2
Create Date: 2026-09-27

Phase 10 BUGFIX — the pack profitability preview reported a 100% margin.

Root cause: migration 0008 added ``products.avg_cost`` (the Phase 7 PMP)
with ``NOT NULL DEFAULT 0`` and never backfilled it, so every product row
created before 2026-09-23 kept ``avg_cost = 0`` while ``products.cost``
held a real value. The pack estimate

    estimated_cost          = SUM(pack_items.quantity * products.avg_cost)
    estimated_profit        = price - estimated_cost
    estimated_margin_percent = profit / price * 100

then computed a zero cost, a profit equal to the price and therefore a
margin of exactly 100%.

Fix (data only): seed the PMP from the nominal cost — the very rule
``ProductService.create`` already applies — but ONLY where no receipt has
ever priced the product. A positive adjustment / package receive carrying
an explicit ``unit_cost`` owns the average and is never rewritten; sales,
package breaks and cost-less adjustments only read the PMP.

Idempotent: once seeded, ``avg_cost = cost > 0`` so the WHERE clause no
longer matches. Downgrade is a no-op on purpose — the seeded PMP is
correct data, not schema.
"""

from alembic import op


# revision identifiers
revision = "c9d0e1f2a3b4"
down_revision = "b7c8d9e0f1a2"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.execute(
        """
        UPDATE products
        SET avg_cost = cost
        WHERE avg_cost = 0
          AND cost > 0
          AND NOT EXISTS (
              SELECT 1
              FROM inventory_movements m
              WHERE m.product_id = products.id
                AND m.movement_type IN ('adjustment', 'package_receive')
                AND m.quantity_change > 0
                AND m.unit_cost IS NOT NULL
          )
        """
    )


def downgrade() -> None:
    # Data seed: intentionally not reversed. The seeded PMP is correct and
    # re-running upgrade() on an already seeded row is a no-op.
    pass
