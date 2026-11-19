"""0038_receipt_print_mode

Revision ID: b6c8f1a3d527
Revises: e5b7d2c9a41f (0037_zakat_basis_wholesale)
Create Date: 2026-11-19

Adds the independent post-checkout receipt printing control:

* ``app_settings.receipt_print_mode`` — VARCHAR(30), NOT NULL,
  ``'disabled' | 'auto_print' | 'ask_above_threshold'`` (CHECK). The
  column default is ``'disabled'`` so every pre-existing installation
  keeps the current behaviour (the legacy ``ask_before_print`` /
  ``auto_print_invoice`` pair still decides what happens).
* ``app_settings.receipt_min_amount`` — NUMERIC(18, 3), NOT NULL,
  default ``0``, CHECK ``>= 0``. Only read in ``ask_above_threshold``
  mode, where the existing receipt print dialog opens once the confirmed
  receipt total reaches it.

ADDITIVE ONLY: the two legacy print columns and every other setting are
untouched, so this revision changes nothing for an installation that
never edits the new dropdown. A server default is required (not only the
Python-side default) so existing singleton rows receive the value.

Downgrade drops ONLY what this revision added.
"""

from typing import Union

import sqlalchemy as sa
from alembic import op

# revision identifiers, used by Alembic.
revision: str = "b6c8f1a3d527"
down_revision: Union[str, None] = "e5b7d2c9a41f"  # type: ignore[assignment]
branch_labels: Union[str, list[str], None] = None  # type: ignore[assignment]
depends_on: Union[str, list[str], None] = None  # type: ignore[assignment]


def upgrade() -> None:
    op.add_column(
        "app_settings",
        sa.Column(
            "receipt_print_mode",
            sa.String(length=30),
            nullable=False,
            server_default="disabled",
        ),
    )
    op.add_column(
        "app_settings",
        sa.Column(
            "receipt_min_amount",
            sa.Numeric(18, 3),
            nullable=False,
            server_default="0",
        ),
    )
    op.create_check_constraint(
        "ck_app_settings_receipt_print_mode",
        "app_settings",
        "receipt_print_mode IN ('disabled', 'auto_print', 'ask_above_threshold')",
    )
    op.create_check_constraint(
        "ck_app_settings_receipt_min_amount",
        "app_settings",
        "receipt_min_amount >= 0",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_app_settings_receipt_min_amount", "app_settings", type_="check"
    )
    op.drop_constraint(
        "ck_app_settings_receipt_print_mode", "app_settings", type_="check"
    )
    op.drop_column("app_settings", "receipt_min_amount")
    op.drop_column("app_settings", "receipt_print_mode")
