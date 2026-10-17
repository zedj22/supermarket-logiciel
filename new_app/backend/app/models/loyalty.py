"""Loyalty models: loyalty_settings, loyalty_accounts, loyalty_ledger_entries.

Phase A of the loyalty system (points + cashback). Three tables and five
nullable sale-summary columns — nothing else ships in this phase.

Design principles (mirroring debt_ledger_entries, Phase 9):

* ``loyalty_settings`` — one row (``id = 1``), merchant-configurable rules.
  Created on demand by ``LoyaltySettingsService`` exactly like
  ``app_settings`` (``SettingsService``), so a brand-new database *and* an
  in-memory test database built with ``Base.metadata.create_all`` behave
  identically.  All value columns are NOT NULL with Python-side defaults
  only (no server defaults), matching the Phase 17 settings convention.
* ``loyalty_accounts`` — one row per customer; ``points_balance`` /
  ``cashback_balance`` are cached projections, never client-writable,
  moved only together with a ledger entry.  Balances carry CHECK >= 0 so
  no write path can leave a negative balance even under a bug.
* ``loyalty_ledger_entries`` — append-only event log, the single source of
  truth for every points/cashback mutation.  ``source_event_key`` is the
  idempotency key: one logical event maps to exactly one entry, enforced
  by a UNIQUE index, so a retried command can never double-earn or
  double-redeem.

Sale summary columns (``sales.loyalty_points_earned`` etc.) are NULLABLE
with no defaults: every pre-loyalty sale stays NULL and remains
distinguishable from a loyalty sale that legitimately earned zero.
"""

from __future__ import annotations

import uuid
from decimal import Decimal

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    ForeignKey,
    Index,
    Integer,
    Numeric,
    String,
    Text,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base, TimestampMixin, UUIDMixin, numeric_money

#: Primary key of the one and only loyalty settings row.
LOYALTY_SETTINGS_SINGLETON_ID = 1

# -- approved initial merchant-configurable defaults (Phase 1 spec) --------
#: Points enabled on a fresh install.
DEFAULT_POINTS_ENABLED = True
#: Points earned per 1 DA spent — 0.01 = one point per 100 DA.
DEFAULT_POINTS_RATE = Decimal("0.01")
#: Cashback disabled on a fresh install.
DEFAULT_CASHBACK_ENABLED = False
#: Cashback percentage of the amount due — 1.000%.
DEFAULT_CASHBACK_RATE = Decimal("1.000")
#: DEPRECATED (reward redesign): DA per point.  Points are no longer a
#: monetary balance — the column is retained for schema/history
#: compatibility but no read path uses it anymore.
DEFAULT_POINT_VALUE = Decimal("1.000")
#: DEPRECATED (reward redesign): retained, unused by any read path.
DEFAULT_MIN_REDEMPTION_POINTS = Decimal("1")
#: DEPRECATED (reward redesign): superseded by
#: ``max_reward_discount_percent``; retained for schema compatibility.
DEFAULT_MAX_REDEMPTION_PERCENT = Decimal("100.000")
#: Points are also earned when a customer debt is settled in full.
DEFAULT_EARN_ON_DEBT_SETTLEMENT = True

#: Maximum percentage a cashier may select when redeeming ONE reward
#: (approved example: 20%).  Merchant-configurable, 0 disables reward
#: redemption without disabling point earning.  The default milestone
#: ``POINTS_PER_REWARD`` lives in ``app.domain.loyalty`` (formula layer).
DEFAULT_MAX_REWARD_DISCOUNT_PERCENT = Decimal("20.000")

#: Points needed to unlock ONE reward on a fresh install — the approved
#: milestone of the reward redesign (100 points).  Merchant-configurable
#: through ``loyalty_settings.min_reward_points`` (1..1_000_000): it is
#: BOTH the balance required before a reward may be selected and the
#: exact cost deducted when one is redeemed.
DEFAULT_MIN_REWARD_POINTS = Decimal("100")

#: Upper bound of ``min_reward_points`` (mirrors the CHECK constraint).
#: A milestone beyond a million points could never be reached in practice.
MAX_MIN_REWARD_POINTS = Decimal("1000000")

#: Every ledger event type Phase B posting code may write. Enforced by a
#: CHECK constraint so a typo can never land an unmapped event in the
#: append-only history.
LEDGER_EVENT_TYPES = (
    "sale_earn",
    "debt_settlement_earn",
    "redeem",
    "return_clawback",
    "void_clawback",
    "adjustment",
    "expiry",
)

_EVENT_TYPE_CHECK_SQL = "event_type IN (%s)" % ", ".join(
    f"'{event}'" for event in LEDGER_EVENT_TYPES
)


class LoyaltySetting(Base, TimestampMixin):
    """One row: the store's loyalty rules (points + cashback)."""

    __tablename__ = "loyalty_settings"
    __table_args__ = (
        CheckConstraint("id = 1", name="ck_loyalty_settings_singleton"),
        CheckConstraint(
            "points_rate >= 0",
            name="ck_loyalty_settings_points_rate",
        ),
        CheckConstraint(
            "cashback_rate >= 0",
            name="ck_loyalty_settings_cashback_rate",
        ),
        CheckConstraint(
            "point_value > 0",
            name="ck_loyalty_settings_point_value",
        ),
        CheckConstraint(
            "min_redemption_points >= 0",
            name="ck_loyalty_settings_min_redemption_points",
        ),
        CheckConstraint(
            "max_redemption_percent > 0 AND max_redemption_percent <= 100",
            name="ck_loyalty_settings_max_redemption_percent",
        ),
        CheckConstraint(
            "max_reward_discount_percent >= 0 "
            "AND max_reward_discount_percent <= 100",
            name="ck_loyalty_settings_max_reward_discount_percent",
        ),
        CheckConstraint(
            "min_reward_points >= 1 AND min_reward_points <= 1000000",
            name="ck_loyalty_settings_min_reward_points",
        ),
    )

    id: Mapped[int] = mapped_column(
        Integer, primary_key=True, default=LOYALTY_SETTINGS_SINGLETON_ID
    )

    # -- points --------------------------------------------------------------
    points_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=DEFAULT_POINTS_ENABLED
    )
    #: Points earned per 1 DA spent (0.01 = one point per 100 DA).
    points_rate: Mapped[Decimal] = mapped_column(
        Numeric(18, 6), nullable=False, default=DEFAULT_POINTS_RATE
    )
    #: Whether a cashback percentage is granted alongside (or instead of)
    #: points. Disabled by default per the approved Phase 1 spec.
    cashback_enabled: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=DEFAULT_CASHBACK_ENABLED
    )
    #: Cashback percentage of the amount due (1.000 = 1%).
    cashback_rate: Mapped[Decimal] = mapped_column(
        Numeric(18, 3), nullable=False, default=DEFAULT_CASHBACK_RATE
    )

    # -- redemption (reward redesign: the first three columns are
    #    DEPRECATED and read by no code path; they stay for schema and
    #    history compatibility) --------------------------------------------
    #: DA redeemable per one point (DEPRECATED — points are never money).
    point_value: Mapped[Decimal] = mapped_column(
        Numeric(18, 3), nullable=False, default=DEFAULT_POINT_VALUE
    )
    #: Minimum points redeemable in one operation (DEPRECATED).
    min_redemption_points: Mapped[Decimal] = mapped_column(
        Numeric(18, 0), nullable=False, default=DEFAULT_MIN_REDEMPTION_POINTS
    )
    #: Old value-cap percentage (DEPRECATED, see
    #: ``max_reward_discount_percent`` below).
    max_redemption_percent: Mapped[Decimal] = mapped_column(
        Numeric(18, 3), nullable=False, default=DEFAULT_MAX_REDEMPTION_PERCENT
    )
    #: Maximum percentage a cashier may select when redeeming ONE reward
    #: (the milestone points) — the owner-configured cap of the reward
    #: redesign.  0 parks reward redemption while point earning continues.
    max_reward_discount_percent: Mapped[Decimal] = mapped_column(
        Numeric(18, 3),
        nullable=False,
        default=DEFAULT_MAX_REWARD_DISCOUNT_PERCENT,
    )
    #: Points required to unlock ONE reward — both the balance the
    #: customer must hold (alone or reached by THIS sale) and the exact
    #: cost deducted when the reward is redeemed.  1..1_000_000.
    min_reward_points: Mapped[Decimal] = mapped_column(
        Numeric(18, 0),
        nullable=False,
        default=DEFAULT_MIN_REWARD_POINTS,
    )

    # -- earning -------------------------------------------------------------
    earn_on_debt_settlement: Mapped[bool] = mapped_column(
        Boolean, nullable=False, default=DEFAULT_EARN_ON_DEBT_SETTLEMENT
    )


class LoyaltyAccount(Base, UUIDMixin, TimestampMixin):
    """Per-customer loyalty balances (cached projection of the ledger)."""

    __tablename__ = "loyalty_accounts"
    __table_args__ = (
        CheckConstraint(
            "points_balance >= 0",
            name="ck_loyalty_accounts_points_balance",
        ),
        CheckConstraint(
            "cashback_balance >= 0",
            name="ck_loyalty_accounts_cashback_balance",
        ),
    )

    customer_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("customers.id", ondelete="CASCADE"),
        nullable=False,
        unique=True,
        index=True,
    )
    #: Whole points (fractional accrual is not supported in v1).
    points_balance: Mapped[Decimal] = mapped_column(
        Numeric(18, 0), nullable=False, default=0, server_default="0"
    )
    #: Cashback accumulated in DA.
    cashback_balance: Mapped[Decimal] = numeric_money()

    # Relationships
    customer: Mapped["Customer"] = relationship(  # noqa: F821
        "Customer",
        lazy="selectin",
    )


class LoyaltyLedgerEntry(Base, UUIDMixin, TimestampMixin):
    """Immutable append-only entry: every points/cashback mutation."""

    __tablename__ = "loyalty_ledger_entries"
    __table_args__ = (
        CheckConstraint(
            _EVENT_TYPE_CHECK_SQL,
            name="ck_loyalty_ledger_entries_event_type",
        ),
        CheckConstraint(
            "balance_after_points >= 0",
            name="ck_loyalty_ledger_entries_balance_after_points",
        ),
        CheckConstraint(
            "balance_after_cashback >= 0",
            name="ck_loyalty_ledger_entries_balance_after_cashback",
        ),
        # Account history scans: newest entries for one customer first.
        Index(
            "ix_loyalty_ledger_entries_account_created",
            "account_id",
            "created_at",
        ),
    )

    account_id: Mapped[uuid.UUID] = mapped_column(
        ForeignKey("loyalty_accounts.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    event_type: Mapped[str] = mapped_column(String(30), nullable=False)
    #: Signed whole points: positive = earn, negative = redeem/clawback.
    points_delta: Mapped[Decimal] = mapped_column(
        Numeric(18, 0), nullable=False, default=0, server_default="0"
    )
    #: Signed cashback in DA: positive = grant, negative = clawback.
    cashback_delta: Mapped[Decimal] = numeric_money()
    #: Balance snapshot after this entry — makes the history auditable
    #: without replaying it.
    balance_after_points: Mapped[Decimal] = mapped_column(
        Numeric(18, 0), nullable=False, default=0, server_default="0"
    )
    balance_after_cashback: Mapped[Decimal] = numeric_money()
    #: Idempotency key: one logical event, one entry (UNIQUE). Built by
    #: the posting code as ``<event_type>:<source-id>`` (Phase B).
    source_event_key: Mapped[str] = mapped_column(
        String(120), nullable=False, unique=True, index=True
    )
    sale_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("sales.id", ondelete="RESTRICT"),
        nullable=True,
        index=True,
    )
    return_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("returns.id", ondelete="RESTRICT"),
        nullable=True,
        index=True,
    )
    created_by: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("users.id", ondelete="SET NULL"),
        nullable=True,
    )
    note: Mapped[str | None] = mapped_column(Text)

    # Relationships
    account: Mapped["LoyaltyAccount"] = relationship(
        "LoyaltyAccount",
        lazy="selectin",
    )
    sale: Mapped["Sale | None"] = relationship(  # noqa: F821
        "Sale",
        lazy="selectin",
    )
