"""Wholesale price resolution (Phase 17 pricing, pure functions).

Price precedence for ONE cart line — the single documented rule, locked by
tests (``tests/unit/test_wholesale_pricing.py``)::

    1. explicit selling-unit price   (product_selling_units.selling_price)
    2. explicit variant price        (product_variants.price)
    3. product retail price          (products.price)
         └─ wholesale threshold may replace it (this module)
    4. pack price                    (packs.price) — NEVER wholesale

So wholesale is a *retail-price branch*: it may only replace the price the
line would otherwise take from ``products.price``. A variant or selling unit
that carries its own configured price is authoritative for that line and is
left untouched, and a pack keeps its fixed price.

Selling units vs wholesale (mutually exclusive)
-----------------------------------------------
Wholesale pricing belongs ONLY to the product's base/default unit — the
commercial unit the POS calls "Piece". A line sold in a custom selling unit
(Box, Carton, Pack, …) NEVER reaches this module, even when that unit has no
configured price and therefore falls back to the retail price: it keeps
retail. Its multiplier (Box = 24) converts the line quantity into the base
quantity for inventory only — it can never turn ``qty * multiplier`` into a
wholesale qualification. Expressed on the precedence above: selling-unit
pricing (explicit price or retail fallback) wins outright over wholesale.

Threshold semantics
-------------------
``wholesale_min_qty`` is expressed in the product's own (base) unit, so the
comparison uses the line's BASE quantity — the effective quantity of the
product actually sold:

* base product   qty -> quantity_base = qty
* weighted prod. qty -> quantity_base (same unit, 3 decimals)
* selling unit   qty -> quantity_base = qty * multiplier, but such a line
  never calls this function (see above)

``wholesale_min_qty = 5`` therefore means "5 product units sold as the base
unit", exactly as the POS shows it. Base quantity >= threshold -> wholesale
price, else retail.

Disabled wholesale (all four are "never apply", never an error):
    * ``wholesale_price`` is NULL
    * ``wholesale_min_qty`` is NULL
    * ``wholesale_min_qty`` <= 0 (rejected by the API schema anyway)
    * ``wholesale_price`` is negative / not a finite decimal (defensive)

Money math is Decimal end to end — never binary float.
"""

from __future__ import annotations

from decimal import Decimal, InvalidOperation

from app.domain.unit_conversions import to_decimal


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


def wholesale_is_configured(
    wholesale_price: Decimal | int | float | str | None,
    wholesale_min_qty: Decimal | int | float | str | None,
) -> bool:
    """True when a product's wholesale rule may be evaluated at all.

    NULL / zero-or-negative minimum / negative or malformed price all mean
    "wholesale disabled" — existing products keep their current behaviour
    without a data migration.
    """
    price = _finite(wholesale_price)
    min_qty = _finite(wholesale_min_qty)
    if price is None or min_qty is None:
        return False
    if price < 0:
        return False
    if min_qty <= 0:
        return False
    return True


def resolve_wholesale_unit_price(
    *,
    retail_price: Decimal | int | float | str,
    wholesale_price: Decimal | int | float | str | None,
    wholesale_min_qty: Decimal | int | float | str | None,
    quantity_base: Decimal | int | float | str,
) -> Decimal:
    """Effective unit price for one product line (retail vs wholesale).

    Returns ``retail_price`` unless wholesale is configured AND the line's
    base quantity reaches ``wholesale_min_qty``. The caller is responsible
    for only reaching this function on BASE-unit lines that price off
    ``products.price`` (see the precedence rule above) — a custom selling
    unit line must never get here, whatever its multiplier.
    """
    retail = to_decimal(retail_price)
    if not wholesale_is_configured(wholesale_price, wholesale_min_qty):
        return retail

    price = _finite(wholesale_price)
    min_qty = _finite(wholesale_min_qty)
    if price is None or min_qty is None:  # pragma: no cover - guarded above
        return retail

    qty = _finite(quantity_base)
    if qty is None or qty < min_qty:
        return retail
    return price
