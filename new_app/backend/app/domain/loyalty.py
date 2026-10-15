"""Loyalty reward formulas — pure Decimal math, no I/O.

Reward redesign (milestone-based percentage discounts):

* **Points earning** (unchanged) — ``points = floor(amount x points_rate)``.
  With the default rate of 0.01 points per 1 DA, 100 DA earns exactly 1
  point.  Points are WHOLE numbers and always floored.
* **Milestones** — ``available_rewards = floor(balance / 100)`` and
  ``remaining_points = balance % 100``.  Every 100 points unlock exactly
  ONE reward; a customer with 130 points has 1 reward and 30 points
  toward the next one.  Redeeming consumes exactly 100 points (never
  100 DA — a point balance is never a monetary balance).
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

from decimal import ROUND_FLOOR, Decimal

from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money

#: Milestone: every POINTS_PER_REWARD points unlock exactly one reward.
#: Fixed business rule of the reward redesign (not merchant-configurable).
POINTS_PER_REWARD = 100

#: 100% as a Decimal — percentages are percent, not fractions.
PERCENT = Decimal("100")


class LoyaltyMathError(ValueError):
    """Domain error for loyalty formula inputs or invariants."""


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


def available_rewards(
    points_balance: Decimal | int | float | str,
) -> Decimal:
    """Whole rewards unlocked by ``points_balance`` (scale-0 Decimal).

    ``floor(balance / POINTS_PER_REWARD)`` — 30 points → 0 rewards,
    130 → 1 reward, 230 → 2 rewards.  A negative balance is invalid
    (the ledger and the DB CHECK both forbid it).
    """
    balance = to_decimal(points_balance)
    if balance < 0:
        raise LoyaltyMathError(f"points balance cannot be negative: {balance}")
    return (balance / POINTS_PER_REWARD).to_integral_value(
        rounding=ROUND_FLOOR
    )


def remaining_points(
    points_balance: Decimal | int | float | str,
) -> Decimal:
    """Points held beyond whole rewards: ``balance % POINTS_PER_REWARD``.

    30 → 30, 100 → 0, 130 → 30, 230 → 30.  Always in
    ``[0, POINTS_PER_REWARD)``.
    """
    balance = to_decimal(points_balance)
    if balance < 0:
        raise LoyaltyMathError(f"points balance cannot be negative: {balance}")
    return balance % POINTS_PER_REWARD


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
