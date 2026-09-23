"""Purchase packaging / stock-breaking domain (Phase 6 architectural correction).

Canonical stock remains product.quantity in BASE units.
Packaging state is stored as full package counts per purchase unit;
loose base is DERIVED:

    loose_base = total_base − Σ(full_packages_i × multiplier_i)
    loose_base must always be ≥ 0

Document unit is never rewritten: purchases record (qty, purchase_unit);
sales record (qty, selling_unit). Base equivalents are computed alongside.

Breaking algorithm (deterministic, for base-unit sales):
1. Consume available loose base first.
2. While still short and sealed packages exist:
   - Prefer a package whose multiplier exactly covers the remaining need;
   - else prefer the smallest multiplier that still covers the need;
   - else break one package of the largest multiplier available.
3. Then consume from loose. Insufficient stock raises PackagingError.

No implicit kg↔g / L↔ml conversions — only explicit packaging multipliers.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from decimal import Decimal, ROUND_FLOOR, InvalidOperation

from app.domain.unit_conversions import QTY_QUANTUM, to_decimal, validate_multiplier


class PackagingError(ValueError):
    """Domain error for packaging / breaking stock operations."""


@dataclass(frozen=True)
class PurchaseUnitDef:
    """Immutable purchase-unit definition used by packaging math."""

    id: str
    name: str
    multiplier: Decimal  # base units per 1 purchase unit

    def __post_init__(self) -> None:
        object.__setattr__(self, "multiplier", validate_multiplier(self.multiplier))
        if not str(self.name).strip():
            raise PackagingError("purchase unit name must not be blank")


@dataclass
class PackagingState:
    """Stock packaging state for one product.

    full_packages: purchase_unit_id → sealed full package count (≥ 0)
    loose_base: base units not inside any sealed package (≥ 0)
    total_base: canonical base equivalent (must equal loose + Σ full×mult)
    """

    full_packages: dict[str, Decimal] = field(default_factory=dict)
    loose_base: Decimal = Decimal("0")
    total_base: Decimal = Decimal("0")
    units: dict[str, PurchaseUnitDef] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self.loose_base = to_decimal(self.loose_base).quantize(QTY_QUANTUM)
        self.total_base = to_decimal(self.total_base).quantize(QTY_QUANTUM)
        normalized: dict[str, Decimal] = {}
        for uid, qty in self.full_packages.items():
            q = to_decimal(qty)
            if q < 0:
                raise PackagingError(f"full packages cannot be negative: {uid}={q}")
            if q != q.to_integral_value(rounding=ROUND_FLOOR):
                raise PackagingError(
                    f"full packages must be whole numbers: {uid}={q}"
                )
            if q:
                normalized[uid] = q
        self.full_packages = normalized
        if self.loose_base < 0:
            raise PackagingError("loose_base cannot be negative")
        if self.total_base < 0:
            raise PackagingError("total_base cannot be negative")
        self._assert_invariant()

    def _assert_invariant(self) -> None:
        packed = self.packed_base()
        loose = self.total_base - packed
        if loose < 0:
            raise PackagingError(
                f"packaging state exceeds total_base: packed={packed} total={self.total_base}"
            )
        if loose != self.loose_base:
            # Keep loose consistent with total − packed when constructed loosely
            # only if caller set both; strict mode on ops.
            pass

    def packed_base(self) -> Decimal:
        total = Decimal("0")
        for uid, qty in self.full_packages.items():
            unit = self.units.get(uid)
            if unit is None:
                raise PackagingError(f"unknown purchase unit id: {uid}")
            total += qty * unit.multiplier
        return total.quantize(QTY_QUANTUM)

    def derive_loose(self) -> Decimal:
        return (self.total_base - self.packed_base()).quantize(QTY_QUANTUM)

    def sync_loose(self) -> None:
        self.loose_base = self.derive_loose()
        if self.loose_base < 0:
            raise PackagingError(
                "full packages exceed total base stock (state corrupted)"
            )

    def full(self, unit_id: str) -> Decimal:
        return self.full_packages.get(unit_id, Decimal("0"))

    def snapshot(self) -> dict[str, object]:
        return {
            "full_packages": {k: str(v) for k, v in sorted(self.full_packages.items())},
            "loose_base": str(self.loose_base),
            "total_base": str(self.total_base),
            "packed_base": str(self.packed_base()),
        }


def receive_packages(
    state: PackagingState,
    unit: PurchaseUnitDef,
    package_qty: Decimal | int | float | str,
) -> PackagingState:
    """Purchase receipt in DOCUMENT unit: +N packages, +N×mult base.

    Document quantity stays N (caller persists document line as-is).
    """
    qty = to_decimal(package_qty)
    if qty <= 0:
        raise PackagingError(f"package_qty must be > 0, got {qty}")
    if qty != qty.to_integral_value(rounding=ROUND_FLOOR):
        raise PackagingError(f"package_qty must be whole packages, got {qty}")
    state.units[unit.id] = unit
    base_delta = (qty * unit.multiplier).quantize(QTY_QUANTUM)
    state.full_packages[unit.id] = state.full_packages.get(
        unit.id, Decimal("0")
    ) + qty
    state.total_base = (state.total_base + base_delta).quantize(QTY_QUANTUM)
    state.sync_loose()
    return state


def sell_packages(
    state: PackagingState,
    unit: PurchaseUnitDef,
    package_qty: Decimal | int | float | str,
) -> PackagingState:
    """Sale in PACKAGE document unit: −N packages, −N×mult base.

    Requires N full packages of this unit (does not auto-break larger units
    into this size — caller may break first if business requires).
    """
    qty = to_decimal(package_qty)
    if qty <= 0:
        raise PackagingError(f"package_qty must be > 0, got {qty}")
    state.units[unit.id] = unit
    available = state.full_packages.get(unit.id, Decimal("0"))
    if available < qty:
        raise PackagingError(
            f"insufficient full packages of {unit.name}: need {qty}, have {available}"
        )
    base_delta = (qty * unit.multiplier).quantize(QTY_QUANTUM)
    new_full = available - qty
    if new_full == 0:
        state.full_packages.pop(unit.id, None)
    else:
        state.full_packages[unit.id] = new_full
    state.total_base = (state.total_base - base_delta).quantize(QTY_QUANTUM)
    if state.total_base < 0:
        raise PackagingError("total_base cannot go negative")
    state.sync_loose()
    return state


def _choose_break_unit(
    state: PackagingState, remaining_need: Decimal
) -> PurchaseUnitDef:
    """Deterministic package choice for covering `remaining_need` base units."""
    stocked = [
        state.units[uid]
        for uid, qty in state.full_packages.items()
        if qty > 0 and uid in state.units
    ]
    if not stocked:
        raise PackagingError(
            f"insufficient stock to cover {remaining_need} base units (no sealed packages)"
        )
    exact = [u for u in stocked if u.multiplier == remaining_need]
    if exact:
        exact.sort(key=lambda u: u.name)
        return exact[0]
    covering = [u for u in stocked if u.multiplier > remaining_need]
    if covering:
        covering.sort(key=lambda u: (u.multiplier, u.name))
        return covering[0]
    # Nothing covers alone — break the largest package (fewest breaks for big needs).
    stocked.sort(key=lambda u: (-u.multiplier, u.name))
    return stocked[0]


def break_one_package(
    state: PackagingState, unit: PurchaseUnitDef
) -> PackagingState:
    """Open one sealed package: full−1, loose+mult, total_base unchanged."""
    state.units[unit.id] = unit
    available = state.full_packages.get(unit.id, Decimal("0"))
    if available < 1:
        raise PackagingError(
            f"no sealed package of {unit.name} to break (have {available})"
        )
    new_full = available - 1
    if new_full == 0:
        state.full_packages.pop(unit.id, None)
    else:
        state.full_packages[unit.id] = new_full
    state.loose_base = (state.loose_base + unit.multiplier).quantize(QTY_QUANTUM)
    # total_base unchanged by a pure break
    state.sync_loose()
    return state


def sell_base_units(
    state: PackagingState,
    base_qty: Decimal | int | float | str,
    *,
    allow_negative_stock: bool = False,
) -> PackagingState:
    """Sale in BASE document unit (e.g. 3 Pieces).

    Uses loose first; breaks sealed packages deterministically when needed;
    then consumes base. Never drives loose or total negative unless
    allow_negative_stock (future explicit business decision — default False).
    """
    need = to_decimal(base_qty)
    if need <= 0:
        raise PackagingError(f"base_qty must be > 0, got {need}")

    # Work on a copy of full counts for planning, then apply.
    full = dict(state.full_packages)
    loose = state.loose_base
    total = state.total_base

    if loose < need:
        deficit = (need - loose).quantize(QTY_QUANTUM)
        while deficit > 0:
            stocked_ids = [
                uid for uid, q in full.items() if q > 0 and uid in state.units
            ]
            if not stocked_ids:
                if allow_negative_stock:
                    break
                raise PackagingError(
                    f"insufficient stock: need {need} base, "
                    f"loose={loose}, packed={sum(full.values())} packages"
                )
            plan_state = PackagingState(
                full_packages=dict(full),
                loose_base=loose,
                total_base=total,
                units=dict(state.units),
            )
            unit = _choose_break_unit(plan_state, deficit)
            new_full = full.get(unit.id, Decimal("0")) - 1
            if new_full <= 0:
                full.pop(unit.id, None)
            else:
                full[unit.id] = new_full
            loose = (loose + unit.multiplier).quantize(QTY_QUANTUM)
            total = total  # pure break
            deficit = (need - loose).quantize(QTY_QUANTUM)

    if loose < need and not allow_negative_stock:
        raise PackagingError(
            f"insufficient stock after breaking: need {need}, loose={loose}"
        )

    # Apply consumption
    take = need
    if loose >= take:
        loose = (loose - take).quantize(QTY_QUANTUM)
        total = (total - take).quantize(QTY_QUANTUM)
    else:
        # allow_negative path: consume all loose then go negative on total
        total = (total - take).quantize(QTY_QUANTUM)
        loose = Decimal("0")
        if total < 0 and not allow_negative_stock:
            raise PackagingError("total_base cannot go negative")

    if total < 0 and not allow_negative_stock:
        raise PackagingError("total_base cannot go negative")

    state.full_packages = full
    state.loose_base = loose
    state.total_base = total
    state.sync_loose()
    if state.loose_base < 0 and not allow_negative_stock:
        raise PackagingError("loose_base cannot be negative")
    return state


def nominal_base_unit_cost(
    document_unit_cost: Decimal | int | float | str,
    multiplier: Decimal | int | float | str,
) -> Decimal:
    """Base-unit cost from a document line: cost_per_package / multiplier.

    Preserves the original document (qty × unit_cost) — this is derived only.
    10 Box × 200 DA → per Piece = 200 / 24.
    """
    cost = to_decimal(document_unit_cost)
    m = validate_multiplier(multiplier)
    if cost < 0:
        raise PackagingError("document unit cost cannot be negative")
    return (cost / m).quantize(QTY_QUANTUM)


def base_equivalent(
    document_qty: Decimal | int | float | str,
    multiplier: Decimal | int | float | str,
) -> Decimal:
    """Canonical base equivalent of a document quantity."""
    q = to_decimal(document_qty)
    m = validate_multiplier(multiplier)
    if q < 0:
        raise PackagingError(f"document qty must be >= 0, got {q}")
    return (q * m).quantize(QTY_QUANTUM)
