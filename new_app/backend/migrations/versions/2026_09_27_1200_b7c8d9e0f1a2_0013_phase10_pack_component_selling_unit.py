"""0013_phase10_pack_component_selling_unit

Revision ID: b7c8d9e0f1a2
Revises: d1e2f3a4b5c6
Create Date: 2026-09-27

Phase 10 UX/domain fix round — pack components may now name one of the
product's EXISTING SELLING UNITS (Phase 6 model, no variants):

- pack_items.selling_unit_id          NULLable FK -> product_selling_units
                                       (ON DELETE SET NULL; NULL = product
                                       base unit, i.e. every legacy row).
- pack_items.selling_unit_name        snapshot of the unit name at pack
                                       definition time.
- pack_items.selling_unit_multiplier  snapshot of the multiplier at pack
                                       definition time (NULL = base x1).

pack_items.quantity keeps its ORIGINAL meaning — base units consumed by one
pack (GATE 2). Nothing is rewritten: a component entered as "2 Box" is
stored as quantity = 2 x 24 = 48 base pieces, computed once at write time,
so later catalog edits (rename / multiplier change) can never silently
change an existing pack's stock meaning.

Additive and reversible: upgrade adds three nullable columns + one index,
downgrade drops them again. No rows are read or rewritten.
"""

from alembic import op
import sqlalchemy as sa


# revision identifiers
revision = "b7c8d9e0f1a2"
down_revision = "d1e2f3a4b5c6"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "pack_items",
        sa.Column(
            "selling_unit_id",
            sa.Uuid(),
            nullable=True,
        ),
    )
    op.add_column(
        "pack_items",
        sa.Column(
            "selling_unit_name",
            sa.String(length=50),
            nullable=True,
        ),
    )
    op.add_column(
        "pack_items",
        sa.Column(
            "selling_unit_multiplier",
            sa.Numeric(18, 3),
            nullable=True,
        ),
    )
    op.create_foreign_key(
        "pack_items_selling_unit_id_fkey",
        "pack_items",
        "product_selling_units",
        ["selling_unit_id"],
        ["id"],
        ondelete="SET NULL",
    )
    op.create_index(
        "ix_pack_items_selling_unit_id",
        "pack_items",
        ["selling_unit_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index("ix_pack_items_selling_unit_id", table_name="pack_items")
    op.drop_constraint(
        "pack_items_selling_unit_id_fkey",
        "pack_items",
        type_="foreignkey",
    )
    op.drop_column("pack_items", "selling_unit_multiplier")
    op.drop_column("pack_items", "selling_unit_name")
    op.drop_column("pack_items", "selling_unit_id")
