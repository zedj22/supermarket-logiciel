"""Loyalty API schemas (settings contract + read/preview/adjustment).

Settings: `LoyaltySettingsResponse` is the flat payload for
``GET /api/v1/loyalty/settings``.  `LoyaltySettingsUpdateRequest` is a
**partial** update: only the keys present in the body change, exactly like
``SettingsUpdateRequest`` for store settings, so two admins editing
different rules cannot clobber each other.

Reward redesign: the merchant-facing rule is
``max_reward_discount_percent`` (0–100, 0 parks reward redemption).  The
deprecated money-from-points fields (``point_value``,
``min_redemption_points``, ``max_redemption_percent``) are gone from the
contract — a point balance is never a monetary balance.  Numeric
boundaries are validated here (pydantic) AND again in
``LoyaltySettingsService`` (server-side domain guard).

Read/preview/adjustment payloads: every balance, reward and monetary
value in a RESPONSE is computed server-side; no request may carry a
claimed balance, a claimed discount or an earned amount —
`LoyaltyPreviewRequest` accepts only the cart inputs (customer, gross
total, selected reward percent) and the server answers with the
authoritative numbers.
"""

from __future__ import annotations

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import Field, model_validator

from app.schemas.common import StrictBaseModel


class LoyaltySettingsResponse(StrictBaseModel):
    """Current loyalty rules."""

    points_enabled: bool
    #: Points earned per 1 DA spent (0.01 = one point per 100 DA).
    #: Stored value; the merchant-facing inverse is ``amount_per_point``.
    points_rate: Decimal = Field(ge=0)
    #: Merchant-facing earning rate: how many DA of a sale buy ONE point
    #: (100 = "spend 100 DA, get 1 point").  Read-only DERIVED view of
    #: ``points_rate`` (``1 / points_rate``, 6 dp); 0 when earning is
    #: parked at a rate of 0.  Send it back in a PUT to change the rate.
    amount_per_point: Decimal = Field(ge=0)
    cashback_enabled: bool
    #: Cashback percentage of the amount due (1.000 = 1%).
    cashback_rate: Decimal = Field(ge=0)
    #: Maximum percent a cashier may select when redeeming ONE reward;
    #: 0 parks reward redemption while earning continues.
    max_reward_discount_percent: Decimal = Field(ge=0, le=100)
    #: Points required to unlock ONE reward — both the balance needed
    #: (alone or reached by the sale in progress) and the exact cost
    #: deducted when it is redeemed.  Default 100, range 1..1_000_000.
    min_reward_points: Decimal = Field(ge=1, le=Decimal("1000000"))
    earn_on_debt_settlement: bool


class LoyaltySettingsUpdateRequest(StrictBaseModel):
    """Partial update — every field optional, at least one required.

    The earning rate may be expressed either way round: ``points_rate``
    (points per DA, legacy/stored form) or ``amount_per_point`` (DA per
    point, the merchant-facing form).  When BOTH are present,
    ``amount_per_point`` wins — a settings form edits DA-per-point and
    echoes the stale ``points_rate`` alongside it.
    """

    points_enabled: bool | None = None
    points_rate: Decimal | None = Field(None, ge=0)
    amount_per_point: Decimal | None = Field(None, gt=0, le=Decimal("1000000"))
    cashback_enabled: bool | None = None
    cashback_rate: Decimal | None = Field(None, ge=0)
    max_reward_discount_percent: Decimal | None = Field(None, ge=0, le=100)
    min_reward_points: Decimal | None = Field(
        None, ge=1, le=Decimal("1000000")
    )
    earn_on_debt_settlement: bool | None = None

    @model_validator(mode="after")
    def _at_least_one_field(self) -> LoyaltySettingsUpdateRequest:
        if not self.provided():
            raise ValueError("at least one loyalty setting must be provided")
        return self

    def provided(self) -> dict[str, object]:
        """Only the fields the caller actually sent, keyed by setting name.

        ``amount_per_point`` is a WRITE-ONLY alias (it is not a column):
        the service converts it into ``points_rate`` before persisting.
        """
        return {
            name: getattr(self, name)
            for name in self.model_fields_set
            if getattr(self, name) is not None
        }


# ---------------------------------------------------------------------------
# Phase E — balance, history, preview, adjustment, (lookup reuses
# CustomerListResponse from app.schemas.party)
# ---------------------------------------------------------------------------


class LoyaltyBalanceResponse(StrictBaseModel):
    """GET /api/v1/customers/{id}/loyalty — server-computed balances.

    ``has_account`` distinguishes "no loyalty activity yet" (zeros, no
    account row) from a real zero balance; the read NEVER creates the
    account row (read-never-writes contract).  The reward view
    (``available_rewards`` / ``remaining_points``) is derived
    server-side so the client never reimplements the milestone rule.
    """

    customer_id: uuid.UUID
    has_account: bool
    points_balance: Decimal = Field(ge=0)
    cashback_balance: Decimal = Field(ge=0)
    #: Whole rewards unlocked by the balance (every min_reward_points).
    available_rewards: int = Field(ge=0)
    #: Points held beyond whole rewards: [0, min_reward_points - 1].
    remaining_points: Decimal = Field(ge=0)
    #: Configured milestone, so the client can render the progress bar
    #: (``remaining_points / min_reward_points``) without a settings read.
    min_reward_points: Decimal = Field(ge=1, le=Decimal("1000000"))


class LoyaltyLedgerEntryResponse(StrictBaseModel):
    """One loyalty ledger row (append-only history)."""

    id: uuid.UUID
    event_type: str
    points_delta: Decimal
    cashback_delta: Decimal
    balance_after_points: Decimal
    balance_after_cashback: Decimal
    note: str | None = None
    sale_id: uuid.UUID | None = None
    invoice_number: str | None = None
    return_id: uuid.UUID | None = None
    created_at: datetime | None = None


class LoyaltyHistoryResponse(StrictBaseModel):
    items: list[LoyaltyLedgerEntryResponse]
    total: int
    page: int = 1
    page_size: int = 20
    pages: int = 1


class LoyaltyPreviewRequest(StrictBaseModel):
    """POST /api/v1/loyalty/preview — authoritative checkout preview.

    Only cart inputs: never a claimed balance or claimed discount.
    ``reward_percent`` is the percentage the cashier selected (0 = no
    reward); the server answers with what is actually allowed, what it
    is worth in DA and whether the customer has a reward to spend.

    ``paid`` is optional: the amount the checkout will collect.  When it
    is omitted the preview assumes the sale settles IN FULL at
    ``amount_due`` (the most favourable view — a POS asks before the
    cashier has typed the paid amount).  The checkout itself always
    re-checks with the real amount, so a partial/credit sale that cannot
    reach the milestone is refused before it mutates anything.
    """

    customer_id: uuid.UUID
    gross_total: Decimal = Field(ge=0, le=Decimal("999999999999.999"))
    reward_percent: Decimal = Field(
        default=Decimal("0"), ge=0, le=100
    )
    paid: Decimal | None = Field(None, ge=0)


class LoyaltyPreviewResponse(StrictBaseModel):
    """Server-computed preview for the current cart + customer."""

    customer_id: uuid.UUID
    gross_total: Decimal
    #: Percent the cashier selected (echo; 0 = none).
    reward_percent: Decimal = Field(ge=0, le=100)
    #: DA discount the server derived for that percent (0 when none).
    reward_discount: Decimal = Field(ge=0)
    #: gross_total - reward_discount: what the payment must cover.
    amount_due: Decimal = Field(ge=0)
    #: Whole rewards unlocked by the balance right now (every
    #: min_reward_points).
    available_rewards: int = Field(ge=0)
    #: Points held beyond whole rewards: [0, min_reward_points - 1].
    remaining_points: Decimal = Field(ge=0)
    #: Configured milestone (cost of ONE reward) — travels with every
    #: preview so the POS renders the threshold without a settings read.
    min_reward_points: Decimal = Field(ge=1, le=Decimal("1000000"))
    #: True when the customer may spend a reward on THIS cart: the
    #: configured milestone is already held, or this sale's own earning
    #: reaches it (first-purchase redemption).  Server-computed so the
    #: client never reimplements the eligibility rule.
    reward_eligible: bool
    #: Owner-configured cap for the percent selector — lets the POS
    #: render its dropdown without a separate settings read.
    max_reward_discount_percent: Decimal = Field(ge=0, le=100)
    points_balance: Decimal = Field(ge=0)
    cashback_balance: Decimal = Field(ge=0)
    #: Points this sale would post: on the settled part of the amount
    #: due PLUS the reward discount, capped at the sale total (nothing
    #: when the sale settles nothing — see
    #: ``app.domain.loyalty.sale_points_qualifying_amount``).
    points_earned: Decimal = Field(ge=0)
    #: Cashback this sale would post: on the settled amount
    #: (``min(paid, amount_due)``) — credit earns nothing.
    cashback_earned: Decimal = Field(ge=0)
    #: points_balance + points_earned: what the balance becomes once this
    #: sale is posted (never negative).
    points_after_sale: Decimal = Field(ge=0)


class LoyaltyAdjustmentRequest(StrictBaseModel):
    """POST /api/v1/customers/{id}/loyalty/adjustment — admin correction.

    ``reason`` and ``client_request_id`` are MANDATORY: an adjustment
    without a stated reason is not auditable, and the key makes retries
    idempotent (same key + same payload replays, never double-posts).
    At least one nonzero delta is required.
    """

    reason: str = Field(..., min_length=3, max_length=200)
    client_request_id: str = Field(..., min_length=1, max_length=100)
    #: Signed whole points; may be negative.  Omit to adjust cashback only.
    points_delta: int | None = None
    #: Signed cashback in DA; may be negative.  Omit for points only.
    cashback_delta: Decimal | None = None

    @model_validator(mode="after")
    def _one_nonzero_delta(self) -> LoyaltyAdjustmentRequest:
        if self.points_delta is None and self.cashback_delta is None:
            raise ValueError("points_delta or cashback_delta is required")
        if self.points_delta == 0 and (
            self.cashback_delta is None or self.cashback_delta == 0
        ):
            raise ValueError("adjustment must move at least one balance")
        return self


class LoyaltyAdjustmentResponse(StrictBaseModel):
    """Resulting ledger entry + the balances AFTER the adjustment."""

    id: uuid.UUID
    customer_id: uuid.UUID
    points_delta: Decimal
    cashback_delta: Decimal
    points_balance: Decimal = Field(ge=0)
    cashback_balance: Decimal = Field(ge=0)
    idempotent_replay: bool
    created_at: datetime | None = None
