"""Loyalty reward milestone — owner-configured ``min_reward_points``.

Migration 0035 (follows 0034 zakat; loyalty chain 0032 → 0033 → 0035).
Adds the second setting the milestone-based reward model needs:

* ``loyalty_settings.min_reward_points`` — points required to unlock ONE
  reward (the balance the customer must hold — alone or reached by the
  sale in progress —) AND the exact cost deducted when that reward is
  redeemed.  NUMERIC(18, 0), NOT NULL, column + server default 100 (the
  approved milestone, so pre-existing singleton rows keep today's
  behaviour), CHECK ``>= 1 AND <= 1000000`` so the milestone can never
  be parked at 0 (which would unlock a reward on every cart).

This migration is ADDITIVE ONLY: ``max_reward_discount_percent`` and the
deprecated points-as-money columns are RETAINED unchanged so existing
rows and history stay intact.

Revision ID: 9f4c1a7d2e63
Revises: dbdff6c3ec7f (0034_zakat_snapshots)
Create Date: 2026-10-17
"""
from __future__ import annotations

from typing import Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "9f4c1a7d2e63"
down_revision: Union[str, None] = "dbdff6c3ec7f"  # type: ignore[assignment]
branch_labels: Union[str, list[str], None] = None  # type: ignore[assignment]
depends_on: Union[str, list[str], None] = None  # type: ignore[assignment]


def upgrade() -> None:
    op.add_column(
        "loyalty_settings",
        sa.Column(
            "min_reward_points",
            sa.Numeric(18, 0),
            nullable=False,
            server_default="100",
        ),
    )
    op.create_check_constraint(
        "ck_loyalty_settings_min_reward_points",
        "loyalty_settings",
        "min_reward_points >= 1 AND min_reward_points <= 1000000",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_loyalty_settings_min_reward_points",
        "loyalty_settings",
        type_="check",
    )
    op.drop_column("loyalty_settings", "min_reward_points")
