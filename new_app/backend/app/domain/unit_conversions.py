"""Base-stock conversion calculations (Phase 6).

All money/quantity math uses Decimal — never binary float. Selling units
convert to base units only via explicit multipliers; there is NO implicit
cross-unit conversion (kg↔g etc.) unless both sides share the same unit_type.

Stock is always stored in base units (product.quantity).
"""

from __future__ import annotations

from decimal import Decimal, ROUND_FLOOR, InvalidOperation

# Quantity precision used by NUMERIC(18,3) columns.
QTY_QUANTUM = Decimal("0.001")


def to_decimal(value: Decimal | int | float | str) -> Decimal:
    """Coerce to Decimal safely (float only as last-resort display path)."""
    if isinstance(value, Decimal):
        return value
    try:
        return Decimal(str(value))
    except (InvalidOperation, ValueError) as exc:
        raise InvalidOperation(f"not a valid decimal: {value!r}") from exc


def validate_multiplier(multiplier: Decimal | int | float | str) -> Decimal:
    """Multiplier must be a positive finite decimal (base units per selling unit)."""
    m = to_decimal(multiplier)
    if not m.is_finite() or m <= 0:
        raise InvalidOperation(f"multiplier must be > 0, got {m}")
    return m


def selling_to_base(selling_qty: Decimal | int | float | str, multiplier: Decimal | int | float | str) -> Decimal:
    """Convert a quantity expressed in selling units to base units.

    base_qty = selling_qty × multiplier
    """
    q = to_decimal(selling_qty)
    m = validate_multiplier(multiplier)
    if q < 0:
        raise InvalidOperation(f"selling_qty must be >= 0, got {q}")
    return (q * m).quantize(QTY_QUANTUM)


def base_to_selling_available(base_stock: Decimal | int | float | str, multiplier: Decimal | int | float | str) -> Decimal:
    """How many whole selling units can be fulfilled from base stock.

    available_selling_qty = floor(base_stock / multiplier)
    Partial selling units are never offered (cannot sell 0.4 of a box).
    """
    stock = to_decimal(base_stock)
    m = validate_multiplier(multiplier)
    if stock <= 0:
        return Decimal("0.000")
    raw = stock / m
    whole = raw.to_integral_value(rounding=ROUND_FLOOR)
    return whole.quantize(QTY_QUANTUM)


def can_fulfill(base_stock: Decimal | int | float | str, base_needed: Decimal | int | float | str) -> bool:
    """True when base stock covers the required base quantity (ignores allow_negative_stock)."""
    return to_decimal(base_stock) >= to_decimal(base_needed)


def mixed_sale_base_cost(lines: list[tuple[Decimal | int | float | str, Decimal | int | float | str]]) -> Decimal:
    """Total base units consumed by a mixed multi-unit sale line list.

    lines = [(selling_qty, multiplier), ...]
    Returns Σ(qty_i × multiplier_i). Raises on negative qty.
    """
    total = Decimal("0.000")
    for qty, mult in lines:
        total += selling_to_base(qty, mult)
    return total.quantize(QTY_QUANTUM)


def effective_unit_price(
    selling_price: Decimal | int | float | str | None,
    product_price: Decimal | int | float | str,
) -> Decimal:
    """Price for a selling unit.

    selling_price is independent — when present it wins. When NULL/None the
    product base price is used as-is (never multiplier × base_price).
    """
    if selling_price is None:
        return to_decimal(product_price)
    price = to_decimal(selling_price)
    return price
