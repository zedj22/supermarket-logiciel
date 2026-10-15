"""Loyalty reward redesign — owner-configured maximum reward discount %.

Migration 0033 (follows 0032 loyalty).  Adds the single new setting the
milestone-based reward model needs:

* ``loyalty_settings.max_reward_discount_percent`` — the maximum
  percentage a cashier may select when redeeming one loyalty reward
  (100 points) against a sale.  NUMERIC(18, 3), NOT NULL, column +
  Python default 20 (the approved example; a column default is required
  so pre-existing singleton rows receive the value), CHECK
  ``>= 0 AND <= 100`` so the owner can park the feature at 0 without
  breaking the column.

This migration is ADDITIVE ONLY: the deprecated points-as-money columns
(``point_value``, ``min_redemption_points``, ``max_redemption_percent``)
are RETAINED unchanged so existing rows and history stay intact; the
application simply no longer reads them.

Revision ID: b4d5e6f7a8c1
Revises: e8f2a4c6d1b9 (0032_loyalty)
Create Date: 2026-10-15
"""
from __future__ import annotations

from typing import Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b4d5e6f7a8c1"
down_revision: Union[str, None] = "e8f2a4c6d1b9"  # type: ignore[assignment]
branch_labels: Union[str, list[str], None] = None  # type: ignore[assignment]
depends_on: Union[str, list[str], None] = None  # type: ignore[assignment]


def upgrade() -> None:
    op.add_column(
        "loyalty_settings",
        sa.Column(
            "max_reward_discount_percent",
            sa.Numeric(18, 3),
            nullable=False,
            server_default="20",
        ),
    )
    op.create_check_constraint(
        "ck_loyalty_settings_max_reward_discount_percent",
        "loyalty_settings",
        "max_reward_discount_percent >= 0 "
        "AND max_reward_discount_percent <= 100",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_loyalty_settings_max_reward_discount_percent",
        "loyalty_settings",
        type_="check",
    )
    op.drop_column("loyalty_settings", "max_reward_discount_percent")
