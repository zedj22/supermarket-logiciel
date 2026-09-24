"""Moving weighted average cost (PMP / WAC) domain helpers (Phase 7).

Authoritative formula (product-level, BASE units only):

    new_avg = (old_qty × old_avg + recv_qty × recv_cost)
              / (old_qty + recv_qty)

Rules:
- Sales / decreases NEVER change avg_cost.
- Increase without unit_cost leaves avg_cost unchanged.
- Receive into zero (or negative) stock sets avg_cost = recv_cost.
- Package receive: document unit_cost is divided by the purchase-unit
  multiplier to obtain a BASE unit cost; document quantity is never rewritten.
- All math is Decimal; quantize only at persistence (NUMERIC(18,3)).
- Variant-level PMP is deferred (documented) — variants share product avg_cost.
"""

from __future__ import annotations

from decimal import Decimal

from app.domain.unit_conversions import QTY_QUANTUM, to_decimal


class ValuationError(ValueError):
    """Domain error for PMP / valuation calculations."""


def weighted_average_cost(
    old_qty: Decimal | int | float | str,
    old_avg: Decimal | int | float | str,
    recv_qty: Decimal | int | float | str,
    recv_unit_cost: Decimal | int | float | str,
) -> Decimal:
    """Compute new moving weighted average cost after a receipt.

    Returns the new avg_cost (full precision — quantize only at persistence).
    """
    oq = to_decimal(old_qty)
    oa = to_decimal(old_avg)
    rq = to_decimal(recv_qty)
    uc = to_decimal(recv_unit_cost)

    if uc < 0:
        raise ValuationError(f"unit cost cannot be negative: {uc}")
    if rq <= 0:
        raise ValuationError(f"receipt quantity must be > 0: {rq}")

    # Receive into empty / non-positive stock → seed PMP with this cost.
    if oq <= 0:
        return uc

    total_value = (oq * oa) + (rq * uc)
    total_qty = oq + rq
    if total_qty == 0:
        raise ValuationError("total quantity cannot be zero after receipt")
    return total_value / total_qty


def inventory_value(
    qty: Decimal | int | float | str,
    avg_cost: Decimal | int | float | str,
) -> Decimal:
    """Stock valuation = quantity × avg_cost (base units)."""
    q = to_decimal(qty)
    a = to_decimal(avg_cost)
    if q < 0:
        # Negative stock valuation is still qty × avg (sign carries).
        pass
    return (q * a).quantize(QTY_QUANTUM)


def base_unit_cost_from_package(
    document_unit_cost: Decimal | int | float | str,
    multiplier: Decimal | int | float | str,
) -> Decimal:
    """BASE unit cost from a package document line cost.

    10 Box × 200 DA → base unit cost = 200 / 24 (not 2000/240 — same value
    but derived per package so the document stays authoritative).
    """
    cost = to_decimal(document_unit_cost)
    m = to_decimal(multiplier)
    if cost < 0:
        raise ValuationError(f"document unit cost cannot be negative: {cost}")
    if m <= 0:
        raise ValuationError(f"multiplier must be > 0: {m}")
    return cost / m


def quantize_money(value: Decimal | int | float | str) -> Decimal:
    """Quantize a money value to NUMERIC(18,3) scale for persistence."""
    return to_decimal(value).quantize(QTY_QUANTUM)
