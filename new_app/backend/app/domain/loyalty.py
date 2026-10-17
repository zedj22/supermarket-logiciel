"""Loyalty reward formulas — pure Decimal math, no I/O.

Reward redesign (milestone-based percentage discounts):

* **Points earning** — ``points = floor(amount x points_rate)``.  With the
  default rate of 0.01 points per 1 DA, 100 DA earns exactly 1 point
  (the merchant-facing rule is the inverse: "100 DA per point", served as
  ``amount_per_point``).  Points are WHOLE numbers and always floored.
  On a SALE the qualifying amount is :func:`sale_points_qualifying_amount`
  — the settled part of the amount due plus the reward discount, capped
  at the sale total — so a fully paid redeemed cart earns exactly what
  the same cart earns unredeemed (the discount never earns beyond the
  cart), change never earns and a sale that settles nothing earns 0.
  Cashback keeps its own money basis (:func:`settled_amount`).
* **Milestones** — ``available_rewards = floor(balance / min_points)``
  and ``remaining_points = balance % min_points``.  Every
  ``min_points`` points unlock exactly ONE reward (default 100,
  merchant-configurable through ``loyalty_settings.min_reward_points``);
  a customer with 130 points at the default milestone has 1 reward and
  30 points toward the next one.  Redeeming consumes exactly
  ``min_points`` points (never the same number of DA — a point balance
  is never a monetary balance).  A reward is available when the balance
  HOLDS the milestone or THIS SALE's own earning reaches it, which is
  how a zero-point customer can redeem on a first purchase.
* **Reward discount** — ``discount = amount x percent / 100``, quantized
  with the project money convention (``quantize_money``: NUMERIC(18,3),
  ROUND_HALF_EVEN) and capped at the amount itself, so the payable
  amount can never go negative.  The cashier picks ``percent`` within
  ``0 < percent <= max_reward_discount_percent`` (owner-configured).
* Cashback (a separate monetary reward, not points) keeps its existing
  formula: ``amount x cashback_rate%`` with ``quantize_money``.
* Every input is validated: negative amounts/rates/balances, a percent
  outside the owner's cap, a percent above 100 or a negative percent
  raise :class:`LoyaltyMathError`.  Nothing is silently coerced.

The *qualifying amount* (what earns rewards) is decided by the caller;
these helpers only do the arithmetic.
"""

from __future__ import annotations

from decimal import ROUND_FLOOR, ROUND_HALF_EVEN, Decimal

from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money

#: Default milestone: every POINTS_PER_REWARD points unlock exactly one
#: reward.  It is the DEFAULT of the merchant-configurable
#: ``loyalty_settings.min_reward_points`` (1..1_000_000, default 100) —
#: every helper that takes a milestone accepts the configured value and
#: falls back to this constant.
POINTS_PER_REWARD = 100

#: 100% as a Decimal — percentages are percent, not fractions.
PERCENT = Decimal("100")


class LoyaltyMathError(ValueError):
    """Domain error for loyalty formula inputs or invariants."""


def _milestone(min_points: Decimal | int | float | str) -> Decimal:
    """Validate and normalize a reward milestone (points per reward).

    Must be a whole number >= 1: 0 or a fraction would unlock a reward on
    every cart (or no reward at all) and break the "one reward costs a
    whole number of points" invariant.  Raises :class:`LoyaltyMathError`.
    """
    value = to_decimal(min_points)
    if value < 1:
        raise LoyaltyMathError(f"min reward points must be >= 1: {value}")
    if value != value.to_integral_value():
        raise LoyaltyMathError(
            f"min reward points must be a whole number: {value}"
        )
    return value


def points_earned(
    amount: Decimal | int | float | str,
    points_rate: Decimal | int | float | str,
) -> Decimal:
    """Whole points earned on ``amount`` at ``points_rate`` points per 1 DA.

    Always floors — never rounds up.  Returns a scale-0 Decimal.
    """
    base = to_decimal(amount)
    rate = to_decimal(points_rate)
    if base < 0:
        raise LoyaltyMathError(f"earning amount cannot be negative: {base}")
    if rate < 0:
        raise LoyaltyMathError(f"points rate cannot be negative: {rate}")
    return (base * rate).to_integral_value(rounding=ROUND_FLOOR)


def cashback_earned(
    amount: Decimal | int | float | str,
    cashback_rate: Decimal | int | float | str,
    *,
    enabled: bool,
) -> Decimal:
    """Cashback in DA earned on ``amount`` at ``cashback_rate`` percent.

    Quantized with the project money convention (0.001, ROUND_HALF_EVEN).
    Disabled cashback is exactly 0.000 — the rate is never half-applied.
    """
    base = to_decimal(amount)
    rate = to_decimal(cashback_rate)
    if base < 0:
        raise LoyaltyMathError(f"cashback amount cannot be negative: {base}")
    if rate < 0:
        raise LoyaltyMathError(f"cashback rate cannot be negative: {rate}")
    if not enabled or base == 0 or rate == 0:
        return quantize_money(0)
    return quantize_money(base * rate / PERCENT)


#: Money scale for the merchant-facing rate (3 dp, project convention).
AMOUNT_PER_POINT_QUANTUM = Decimal("0.001")
#: Stored scale of ``loyalty_settings.points_rate`` (NUMERIC(18, 6)).
POINTS_RATE_QUANTUM = Decimal("0.000001")


def derive_amount_per_point(
    points_rate: Decimal | int | float | str,
) -> Decimal:
    """Merchant-facing earning rate: DA of a sale that buy ONE point.

    The inverse of ``points_rate`` (points per DA): the default 0.01
    becomes 100 ("spend 100 DA, earn 1 point").  Quantized to the money
    convention (0.001).  A rate of 0 (earning parked) reports exactly 0
    instead of dividing by zero.
    """
    rate = to_decimal(points_rate)
    if rate < 0:
        raise LoyaltyMathError(f"points rate cannot be negative: {rate}")
    if rate == 0:
        return Decimal(0)
    return (Decimal(1) / rate).quantize(
        AMOUNT_PER_POINT_QUANTUM, rounding=ROUND_HALF_EVEN
    )


def derive_points_rate(
    amount_per_point: Decimal | int | float | str,
) -> Decimal:
    """Stored earning rate from the merchant-facing DA-per-point value.

    The inverse of :func:`derive_amount_per_point`, quantized to the
    column scale (0.000001) so what is persisted is exactly what the
    response reports.  The amount must be strictly positive — a rate of
    0 is only ever set explicitly through ``points_rate``.
    """
    amount = to_decimal(amount_per_point)
    if amount <= 0:
        raise LoyaltyMathError(
            f"amount per point must be > 0: {amount}"
        )
    return (Decimal(1) / amount).quantize(
        POINTS_RATE_QUANTUM, rounding=ROUND_HALF_EVEN
    )


def sale_points_qualifying_amount(
    *,
    total: Decimal | int | float | str,
    paid: Decimal | int | float | str,
    amount_due: Decimal | int | float | str,
    redeem_value: Decimal | int | float | str,
) -> Decimal:
    """Points-qualifying amount of ONE sale (the ``sale_earn`` base).

    **The settled part of the amount due PLUS the reward discount, capped
    at the sale total** — with one guard: a sale that settles nothing
    (``paid <= 0``: credit / a cart covered 100% by the reward, or
    ``amount_due <= 0``: fully redeemed) earns 0.

    Consequences, all deliberate:

    * a fully paid sale earns exactly like the same cart WITHOUT the
      reward (``amount_due + redeem_value == total``) — the discount
      never creates points beyond what the cart itself is worth;
    * change never earns (``min(paid, amount_due)``), and cash/card/partial
      sales keep earning only on what they cover;
    * credit sales earn nothing — no points for money not yet received.

    Returned money-quantized and never negative; negative inputs raise
    :class:`LoyaltyMathError`.
    """
    gross = to_decimal(total)
    paid_value = to_decimal(paid)
    due = to_decimal(amount_due)
    redeem = to_decimal(redeem_value)
    for label, value in (
        ("total", gross),
        ("paid", paid_value),
        ("amount_due", due),
        ("redeem_value", redeem),
    ):
        if value < 0:
            raise LoyaltyMathError(
                f"sale {label} cannot be negative: {value}"
            )
    if paid_value <= 0 or due <= 0:
        return quantize_money(0)
    basis = min(paid_value, due) + redeem
    if basis > gross:
        basis = gross
    return quantize_money(basis)


def settled_amount(
    paid: Decimal | int | float | str,
    amount_due: Decimal | int | float | str,
) -> Decimal:
    """Money actually settled on a sale: ``min(paid, amount_due)``.

    Cash/card may tender more than is due (the change leaves the till)
    and credit settles nothing, so the CASHBACK qualifying amount is the
    part of the amount due the customer really paid — never the tendered
    total, never the gross cart.  Returns a money-quantized value >= 0;
    negative inputs raise :class:`LoyaltyMathError`.
    """
    paid_value = to_decimal(paid)
    due = to_decimal(amount_due)
    if paid_value < 0:
        raise LoyaltyMathError(f"paid amount cannot be negative: {paid_value}")
    if due < 0:
        raise LoyaltyMathError(
            f"amount due cannot be negative: {due}"
        )
    return quantize_money(min(paid_value, due))


def available_rewards(
    points_balance: Decimal | int | float | str,
    min_points: Decimal | int | float | str = POINTS_PER_REWARD,
) -> Decimal:
    """Whole rewards unlocked by ``points_balance`` (scale-0 Decimal).

    ``floor(balance / min_points)`` — at the default 100-point milestone
    30 points → 0 rewards, 130 → 1 reward, 230 → 2.  ``min_points`` is
    the configured ``loyalty_settings.min_reward_points`` (defaults to
    :data:`POINTS_PER_REWARD`).  A negative balance is invalid (the
    ledger and the DB CHECK both forbid it).
    """
    balance = to_decimal(points_balance)
    if balance < 0:
        raise LoyaltyMathError(f"points balance cannot be negative: {balance}")
    milestone = _milestone(min_points)
    return (balance / milestone).to_integral_value(rounding=ROUND_FLOOR)


def remaining_points(
    points_balance: Decimal | int | float | str,
    min_points: Decimal | int | float | str = POINTS_PER_REWARD,
) -> Decimal:
    """Points held beyond whole rewards: ``balance % min_points``.

    At the default milestone: 30 → 30, 100 → 0, 130 → 30, 230 → 30.
    Always in ``[0, min_points)``.
    """
    balance = to_decimal(points_balance)
    if balance < 0:
        raise LoyaltyMathError(f"points balance cannot be negative: {balance}")
    return balance % _milestone(min_points)


def validate_reward_percent(
    selected: Decimal | int | float | str,
    max_percent: Decimal | int | float | str,
) -> Decimal:
    """Validate the cashier's chosen reward discount percentage.

    Rules: ``max_percent`` must sit within ``[0, 100]`` (0 parks the
    feature), the selection must be strictly positive and must not
    exceed the owner's cap.  Returns the validated percent as a
    Decimal; raises :class:`LoyaltyMathError` otherwise — a bad percent
    is never silently clamped.
    """
    selected_value = to_decimal(selected)
    maximum = to_decimal(max_percent)

    if maximum < 0 or maximum > PERCENT:
        raise LoyaltyMathError(
            f"max reward discount percent must be within [0, 100]: {maximum}"
        )
    if selected_value <= 0:
        raise LoyaltyMathError(
            f"reward percent must be > 0: {selected_value}"
        )
    if selected_value > PERCENT:
        raise LoyaltyMathError(
            f"reward percent cannot exceed 100: {selected_value}"
        )
    if selected_value > maximum:
        raise LoyaltyMathError(
            f"reward percent {selected_value} exceeds the owner maximum "
            f"{maximum}"
        )
    return selected_value


def reward_discount(
    amount: Decimal | int | float | str,
    percent: Decimal | int | float | str,
) -> Decimal:
    """Money discount of ``percent``% of ``amount`` (money-quantized).

    Capped at ``amount`` so the payable amount can never go negative
    (``percent`` above 100 is rejected by :func:`validate_reward_percent`
    first; the cap is defense in depth against rounding).
    """
    base = to_decimal(amount)
    rate = to_decimal(percent)
    if base < 0:
        raise LoyaltyMathError(f"discount amount cannot be negative: {base}")
    if rate < 0 or rate > PERCENT:
        raise LoyaltyMathError(
            f"reward percent must be within [0, 100]: {rate}"
        )
    discount = quantize_money(base * rate / PERCENT)
    if discount > base:
        return quantize_money(base)
    return discount
