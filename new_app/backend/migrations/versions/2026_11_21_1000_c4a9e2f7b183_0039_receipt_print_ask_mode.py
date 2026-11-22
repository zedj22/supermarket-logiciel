"""0039_receipt_print_ask_mode

Revision ID: c4a9e2f7b183
Revises: b6c8f1a3d527 (0038_receipt_print_mode)
Create Date: 2026-11-21

Folds the receipt-printing controls into ONE setting.

* ``app_settings.receipt_print_mode`` accepts a fourth value, ``ask``:
  after a sale the cashier is asked whether to print.  The CHECK constraint
  is recreated with the full vocabulary
  ``'disabled' | 'ask' | 'auto_print' | 'ask_above_threshold'``.
* Existing installations are migrated from the legacy pair exactly the way
  the old client resolved them, so upgrading changes nothing the operator
  sees:
    - an explicit non-``disabled`` mode is already a real choice → kept;
    - otherwise ``ask_before_print = true``  → ``ask`` (it had precedence);
    - otherwise ``auto_print_invoice = true`` → ``auto_print``;
    - otherwise the mode stays ``disabled`` (nothing printed).
* Both legacy booleans are then zeroed.  They stay in the table for wire
  compatibility, but a stale ``true`` can no longer influence anything —
  the unified mode is the only authority.

Downgrade restores the three-value constraint, translating ``ask`` back to
``disabled`` and writing the equivalent legacy booleans, so a downgraded
build keeps prompting/auto-printing as it did before.
"""

from typing import Union

from alembic import op

# revision identifiers, used by Alembic.
revision: str = "c4a9e2f7b183"
down_revision: Union[str, None] = "b6c8f1a3d527"  # type: ignore[assignment]
branch_labels: Union[str, list[str], None] = None  # type: ignore[assignment]
depends_on: Union[str, list[str], None] = None  # type: ignore[assignment]

_MODE_CHECK = "ck_app_settings_receipt_print_mode"
_FOUR_MODES = (
    "receipt_print_mode IN ('disabled', 'ask', 'auto_print', "
    "'ask_above_threshold')"
)
_THREE_MODES = (
    "receipt_print_mode IN ('disabled', 'auto_print', 'ask_above_threshold')"
)


def upgrade() -> None:
    op.drop_constraint(_MODE_CHECK, "app_settings", type_="check")
    op.create_check_constraint(_MODE_CHECK, "app_settings", _FOUR_MODES)

    # Legacy pair → unified mode, in the old precedence order.
    op.execute(
        """
        UPDATE app_settings
           SET receipt_print_mode = CASE
                 WHEN receipt_print_mode <> 'disabled' THEN receipt_print_mode
                 WHEN ask_before_print = TRUE THEN 'ask'
                 WHEN auto_print_invoice = TRUE THEN 'auto_print'
                 ELSE 'disabled'
               END
        """
    )
    # The mode is now the single source of truth: neutralize the legacy
    # flags so they can never stack a second behaviour on top of it.
    op.execute(
        """
        UPDATE app_settings
           SET ask_before_print = FALSE,
               auto_print_invoice = FALSE
        """
    )


def downgrade() -> None:
    # Encode the unified choice back into the legacy pair.
    op.execute(
        """
        UPDATE app_settings
           SET ask_before_print = (receipt_print_mode = 'ask'),
               auto_print_invoice = (receipt_print_mode = 'auto_print')
        """
    )
    op.execute(
        "UPDATE app_settings SET receipt_print_mode = 'disabled' "
        "WHERE receipt_print_mode = 'ask'"
    )
    op.drop_constraint(_MODE_CHECK, "app_settings", type_="check")
    op.create_check_constraint(_MODE_CHECK, "app_settings", _THREE_MODES)
