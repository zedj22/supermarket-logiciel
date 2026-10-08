"""Promotion price resolution (Phase 18, pure functions).

Where promotions sit in the price precedence
--------------------------------------------
Promotions do NOT create a parallel pricing engine and never write
``products.price``. They are a *retail-branch modifier*, exactly like the
Phase 17 wholesale rule documented in ``app/domain/wholesale.py``::

    1. explicit selling-unit price   (product_selling_units.selling_price)
    2. explicit variant price        (product_variants.price)
    3. product retail price          (products.price)
         ├─ promotion may discount it     (this module)
         └─ wholesale threshold may replace it (wholesale module)
    4. pack price                    (packs.price) — NEVER promoted

So a promotion only ever rewrites the price a line would take from
``products.price`` — the same ``line_uses_product_retail`` gate wholesale
uses. A variant / selling unit with its own configured price, and a pack,
are never promoted.

Promotion vs wholesale (documented decision)
--------------------------------------------
Both rules live on the retail branch and are applied in this order:

    retail ──promotion──▶ promo price ──wholesale threshold──▶ wholesale price

* below the wholesale threshold the customer pays the promotion price;
* at/above the threshold the configured wholesale price replaces it —
  the SAME "the configured wholesale price wins once the threshold is
  met" semantics wholesale already has versus retail (no never-charge-
  more rule, see test_wholesale_pricing.py::test_wholesale_higher_than_retail).
* with no active promotion the promo price IS the retail price, so
  behaviour is bit-for-bit identical to Phase 17.

Types
-----
* ``percentage``  — ``value`` is the percent OFF (20 → pay 80% of retail).
  Valid range 0 < value <= 100; anything else is "not configured" and
  returns the retail price unchanged (defensive, never an error).
* ``fixed_price`` — ``value`` replaces the retail unit price (>= 0).
  Only legal for single-product promotions; the API rejects the
  multi-product combination (MULTI_PRODUCT_FIXED_PRICE_NOT_ALLOWED).
  A value ABOVE the retail price never raises the charge — the retail
  price wins (a promotion is a discount: invariant ``promo <= retail``).

Money math is Decimal end to end, quantized to 0.001 with ROUND_HALF_UP —
never binary float, matching ``_money`` in app/services/sale.py.
"""

from __future__ import annotations

from decimal import Decimal, ROUND_HALF_UP, InvalidOperation

from app.domain.unit_conversions import to_decimal

MONEY_QUANTUM = Decimal("0.001")

PERCENTAGE_MAX = Decimal("100")

# PromotionType values (app/models/enums.py), duplicated as literals to
# keep this module I/O-free — the domain layer never imports app.models.
PROMOTION_TYPE_PERCENTAGE = "percentage"
PROMOTION_TYPE_FIXED_PRICE = "fixed_price"


def _finite(value: Decimal | int | float | str | None) -> Decimal | None:
    """Decimal view of [value]; None when absent, malformed or non-finite."""
    if value is None:
        return None
    try:
        parsed = to_decimal(value)
    except (InvalidOperation, ValueError):
        return None
    if not parsed.is_finite():
        return None
    return parsed


def promotion_is_configured(
    promotion_type: str | None,
    value: Decimal | int | float | str | None,
) -> bool:
    """True when a promotion rule may be evaluated at all.

    NULL / malformed / out-of-range values mean "promotion disabled" —
    a defensive mirror of ``wholesale_is_configured``.
    """
    amount = _finite(value)
    if amount is None:
        return False
    if promotion_type == PROMOTION_TYPE_PERCENTAGE:
        return Decimal("0") < amount <= PERCENTAGE_MAX
    if promotion_type == PROMOTION_TYPE_FIXED_PRICE:
        return amount >= 0
    return False


def promotional_unit_price(
    *,
    retail_price: Decimal | int | float | str,
    promotion_type: str | None,
    value: Decimal | int | float | str | None,
) -> Decimal:
    """Effective unit price after the promotion (retail branch only).

    Returns ``retail_price`` unchanged whenever the promotion is not
    configured (wrong type, out-of-range percent, malformed value) —
    "disabled, never an error", same contract as wholesale.

    The caller is responsible for only reaching this function on lines
    that price off ``products.price`` (the retail branch) — a custom
    selling unit, explicit variant price or pack price must never get
    here.
    """
    retail = to_decimal(retail_price)
    if not promotion_is_configured(promotion_type, value):
        return retail

    amount = _finite(value)
    if amount is None:  # pragma: no cover - guarded above
        return retail

    if promotion_type == PROMOTION_TYPE_PERCENTAGE:
        if retail < 0:  # pragma: no cover - schema keeps price >= 0
            return retail
        discounted = retail * (PERCENTAGE_MAX - amount) / PERCENTAGE_MAX
        return discounted.quantize(MONEY_QUANTUM, rounding=ROUND_HALF_UP)

    # fixed_price — the configured replacement price, quantized to money.
    fixed = amount.quantize(MONEY_QUANTUM, rounding=ROUND_HALF_UP)
    # A promotion is a DISCOUNT: it can never charge more than the shelf
    # price (invariant: promotional_unit_price <= retail_price for both
    # types). A fixed value above retail is treated as "not configured" —
    # unlike wholesale (a negotiated contract price may legitimately
    # exceed retail, see test_wholesale_pricing), nobody's contract is
    # broken by falling back to the original price.
    if fixed > retail:
        return retail
    return fixed
