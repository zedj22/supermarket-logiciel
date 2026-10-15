"""Return document service (Phase 12).

Owns the return lifecycle: posting (document + lines + stock + movements +
debt reversal + audit in ONE transaction), history and detail reads.

Transaction policy: every mutation runs inside ONE
``BaseService.transaction()`` (services are not nestable — an inner commit
would break atomicity), so the helpers here never open their own
transaction. Locking order (decision record §19) is sale row → customer
row → affected product/variant rows in ascending id order.

Lifecycle (GATE 2): posted immediately, no draft/cancel state, no edit and
no delete path — append-only is structural.

This module also hosts the Phase 12 primitives shared with
``app.services.void`` (stock restoration, movement journal rows and the
debt credit/reversal sums). Void and return restore the same stock and
reverse the same debt, so one implementation of each keeps them provably
symmetric; ``void.py`` imports them from here instead of duplicating them
or editing a Phase 7 service.

Phase D (loyalty): a linked return of a loyalty sale claws back the
pro-rata share of the checkout rewards (floored at the current balance —
an unreversed shortfall goes in the ledger note, never a negative
balance), restores the pro-rata share of the redeemed points and settles
exactly one compensation per financing source: points for the redeemed
share, credit for the debt share, cash for the rest — never a second
cash refund for the redeemed portion.  All of it posts through
:class:`app.services.loyalty.LoyaltyEngine` inside the SAME transaction
as the return document, under lock order sale → customer → loyalty
account → stock.
"""

from __future__ import annotations

import json
import math
import uuid
from datetime import datetime, timezone
from decimal import ROUND_FLOOR, Decimal
from typing import Any

import structlog
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.core.exceptions import (
    ConflictError,
    NotFoundError,
    ValidationError,
)
from app.domain.unit_conversions import QTY_QUANTUM, selling_to_base, to_decimal
from app.domain.valuation import quantize_money
from app.models.audit import AuditLog
from app.models.catalog import Product, ProductVariant
from app.models.debt import DebtLedgerEntry
from app.models.enums import (
    AuditAction,
    ProductUnit,
    SaleStatus,
    StockMovementType,
)
from app.models.inventory import InventoryMovement
from app.models.loyalty import LoyaltyLedgerEntry
from app.models.return_doc import Return, ReturnLine
from app.models.sale import Sale, SaleLine
from app.repositories.catalog import ProductRepository, ProductVariantRepository
from app.repositories.debt import DebtLedgerEntryRepository
from app.repositories.party import CustomerRepository
from app.repositories.returns import ReturnRepository
from app.repositories.sale import SaleRepository
from app.schemas.returns import (
    ReturnCreateRequest,
    ReturnCreateResponse,
    ReturnLineResponse,
    ReturnListResponse,
    ReturnResponse,
)
from app.services.base import BaseService
from app.services.loyalty import LoyaltyEngine

logger = structlog.get_logger(__name__)

_ZERO = Decimal("0")


def _floor_money(value: Decimal) -> Decimal:
    """Floor to the money quantum (0.001) — never round a clawback UP."""
    return value.quantize(Decimal("0.001"), rounding=ROUND_FLOOR)


def _generate_return_number() -> str:
    """RET-YYYYMMDD-HHMMSS-mmm-xxxx (Phase 8 INV- pattern, own prefix)."""
    now = datetime.now(timezone.utc)
    suffix = uuid.uuid4().hex[:4]
    return (
        f"RET-{now.strftime('%Y%m%d-%H%M%S')}-"
        f"{now.microsecond // 1000:03d}-{suffix}"
    )


# ---------------------------------------------------------------------------
# Shared Phase 12 primitives (used by ReturnService and VoidService)
# ---------------------------------------------------------------------------


def lock_restore_targets(
    session: Session,
    product_ids: set[uuid.UUID],
    variant_ids: set[uuid.UUID],
) -> tuple[dict[uuid.UUID, Product], dict[uuid.UUID, ProductVariant]]:
    """Lock every affected product/variant row FOR UPDATE, ascending id.

    Deterministic order keeps a return/void from deadlocking against a
    concurrent checkout that touches the same rows (§19). Missing rows are
    a 404: the FK guarantees existence for linked lines, so this can only
    fire for an unknown id on an independent return.
    """
    products: dict[uuid.UUID, Product] = {}
    if product_ids:
        rows = session.execute(
            select(Product)
            .where(Product.id.in_(sorted(product_ids)))
            .order_by(Product.id)
            .with_for_update()
        ).scalars()
        products = {p.id: p for p in rows}
        missing = product_ids - set(products)
        if missing:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(sorted(missing)[0])},
            )
    variants: dict[uuid.UUID, ProductVariant] = {}
    if variant_ids:
        rows = session.execute(
            select(ProductVariant)
            .where(ProductVariant.id.in_(sorted(variant_ids)))
            .order_by(ProductVariant.id)
            .with_for_update()
        ).scalars()
        variants = {v.id: v for v in rows}
        missing = variant_ids - set(variants)
        if missing:
            raise NotFoundError(
                message="Variant not found",
                details={"variant_id": str(sorted(missing)[0])},
            )
    return products, variants


def record_restore_movement(
    session: Session,
    *,
    product_id: uuid.UUID,
    movement_type: StockMovementType,
    quantity_change: Decimal,
    quantity_before: Decimal,
    quantity_after: Decimal,
    variant_id: uuid.UUID | None = None,
    document_quantity: Decimal | None = None,
    document_unit: str | None = None,
    unit_cost: Decimal | None = None,
    avg_cost_after: Decimal | None = None,
    reason: str | None = None,
    user_id: uuid.UUID | None = None,
    device_id: str | None = None,
    source_document_type: str | None = None,
    source_document_id: uuid.UUID | None = None,
) -> InventoryMovement:
    """Append one stock-restoration row to the movement journal.

    Increments never carry the negative-stock guard that
    ``SaleService._decrement_stock`` applies — an increment cannot
    oversell — but before/after are still captured so the journal
    explains the change (§14, GATE 7).
    """
    movement = InventoryMovement(
        product_id=product_id,
        variant_id=variant_id,
        movement_type=movement_type.value,
        quantity_change=float(quantity_change),
        quantity_before=float(quantity_before),
        quantity_after=float(quantity_after),
        document_quantity=(
            float(document_quantity) if document_quantity is not None else None
        ),
        document_unit=document_unit,
        unit_cost=float(unit_cost) if unit_cost is not None else None,
        avg_cost_after=(
            float(avg_cost_after) if avg_cost_after is not None else None
        ),
        reason=reason,
        user_id=user_id,
        device_id=device_id,
        source_document_type=source_document_type,
        source_document_id=source_document_id,
    )
    session.add(movement)
    return movement


def apply_restore(
    session: Session,
    restore: dict[str, Any],
    *,
    products: dict[uuid.UUID, Product],
    variants: dict[uuid.UUID, ProductVariant],
    movement_type: StockMovementType,
    document_quantity: Decimal | None,
    document_unit: str | None,
    reason: str,
    user_id: uuid.UUID | None,
    device_id: str | None,
    source_document_type: str,
    source_document_id: uuid.UUID,
) -> None:
    """Add ``quantity_base`` back to stock and journal it (§14).

    Variant lines touch ``variant.quantity`` ONLY — Phase 8's decided sale
    semantics, mirrored (legacy defect V7 is not ported). Pack summary
    lines never reach here: they own no stock.
    """
    product = products[restore["product_id"]]
    variant = (
        variants[restore["variant_id"]]
        if restore["variant_id"] is not None
        else None
    )
    target = variant if variant is not None else product
    qty = to_decimal(restore["quantity_base"])
    before = to_decimal(target.quantity)
    after = (before + qty).quantize(QTY_QUANTUM)
    target.quantity = float(after)
    # GATE 6: PMP never moves on a return — snapshot the unchanged value.
    record_restore_movement(
        session,
        product_id=product.id,
        variant_id=restore["variant_id"],
        movement_type=movement_type,
        quantity_change=qty,
        quantity_before=before,
        quantity_after=after,
        document_quantity=document_quantity,
        document_unit=document_unit,
        unit_cost=restore["unit_cost"],
        avg_cost_after=quantize_money(to_decimal(product.avg_cost)),
        reason=reason,
        user_id=user_id,
        device_id=device_id,
        source_document_type=source_document_type,
        source_document_id=source_document_id,
    )


def sale_credit_and_reversed(
    session: Session, sale_id: uuid.UUID
) -> tuple[Decimal, Decimal]:
    """``(credit, reversed)`` for one sale (§17).

    ``credit``   = Σ debt_ledger_entries.amount WHERE entry_type = 'sale'
    ``reversed`` = Σ ... WHERE entry_type IN ('sale_void', 'sale_refund')
    both scoped to ``reference_sale_id = sale_id``.
    """
    rows = session.execute(
        select(
            DebtLedgerEntry.entry_type,
            func.coalesce(func.sum(DebtLedgerEntry.amount), 0),
        )
        .where(
            DebtLedgerEntry.reference_sale_id == sale_id,
            DebtLedgerEntry.entry_type.in_(("sale", "sale_void", "sale_refund")),
        )
        .group_by(DebtLedgerEntry.entry_type)
    ).all()
    totals = {entry_type: to_decimal(amount) for entry_type, amount in rows}
    credit = totals.get("sale", _ZERO)
    reversed_amount = quantize_money(
        totals.get("sale_void", _ZERO) + totals.get("sale_refund", _ZERO)
    )
    return quantize_money(credit), reversed_amount


def credit_reversed_for_key(session: Session, client_request_id: str) -> Decimal:
    """Debt actually forgiven by one return (idempotent replay path).

    §17 stores the return's ``client_request_id`` on its ledger row, so a
    per-document reversal stays derivable without a new column. A return
    that reversed nothing simply has no row → 0.
    """
    if not client_request_id:
        return _ZERO
    amount = session.execute(
        select(func.coalesce(func.sum(DebtLedgerEntry.amount), 0)).where(
            DebtLedgerEntry.entry_type == "sale_refund",
            DebtLedgerEntry.client_request_id == client_request_id,
        )
    ).scalar()
    return quantize_money(to_decimal(amount))


def restored_points_for_return(session: Session, return_id: uuid.UUID) -> Decimal:
    """Points restored by one return (idempotent replay path, Phase D).

    The redemption-restoration entry is written with
    ``source_event_key = return_redemption:{return_id}`` in the same
    transaction as the return, so a replayed response derives the same
    settlement (``cash_pending``) without re-running the plan.
    """
    if return_id is None:
        return _ZERO
    points = session.execute(
        select(func.coalesce(func.sum(LoyaltyLedgerEntry.points_delta), 0)).where(
            LoyaltyLedgerEntry.return_id == return_id,
            LoyaltyLedgerEntry.event_type == "adjustment",
            LoyaltyLedgerEntry.source_event_key.like("return_redemption:%"),
        )
    ).scalar()
    return to_decimal(points)


def reverse_customer_debt(
    session: Session,
    ledger: DebtLedgerEntryRepository,
    *,
    customer,
    credit: Decimal,
    reversed_before: Decimal,
    refund_total: Decimal,
    reference_sale_id: uuid.UUID,
    note: str,
    client_request_id: str | None,
    actor_id: uuid.UUID | None,
    entry_type: str = "sale_refund",
) -> Decimal:
    """Capped debt reversal with an explicit shortfall (§17, GATE 8).

    ``reverse = min(refund, credit − reversed_before, balance)``. The
    shortfall (goods paid for in cash, or credit already settled by later
    payments) is written into the ledger note — never a silent clamp and
    never a negative balance (Phase 9 "no advance credit").

    ``entry_type`` separates the two Phase 12 operations in the journal
    (GATE 7): returns append ``sale_refund``, voids append ``sale_void``.
    Both are subtracted by the ledger projections.

    Reconciles ``customers.balance`` against the append-only ledger
    afterwards, exactly like Phase 11's purchase cancellation.
    """
    if refund_total <= _ZERO:
        return _ZERO
    balance = quantize_money(to_decimal(customer.balance))
    remaining_credit = quantize_money(max(_ZERO, credit - reversed_before))
    reverse = quantize_money(min(refund_total, remaining_credit, balance))
    shortfall = quantize_money(refund_total - reverse)

    if reverse > _ZERO:
        full_note = note
        if shortfall > _ZERO:
            full_note = (
                f"{note} (shortfall {shortfall} pending cash refund)"
            )
        session.add(
            DebtLedgerEntry(
                customer_id=customer.id,
                entry_type=entry_type,
                amount=reverse,
                reference_sale_id=reference_sale_id,
                note=full_note,
                client_request_id=client_request_id,
                user_id=actor_id,
            )
        )
        customer.balance = float(quantize_money(balance - reverse))

    # Reconciliation (Phase 11 §13 pattern): the cached balance must equal
    # the ledger. Flush first so the SQL projection sees the new entry.
    session.flush()
    expected = quantize_money(ledger.ledger_sum_for_customer(customer.id))
    actual = quantize_money(to_decimal(customer.balance))
    if expected != actual:
        raise ConflictError(
            message="Customer ledger/balance mismatch after reversal",
            details={
                "customer_id": str(customer.id),
                "ledger_sum": str(expected),
                "balance": str(actual),
            },
        )
    return reverse


# ---------------------------------------------------------------------------
# Service
# ---------------------------------------------------------------------------


class ReturnService(BaseService):
    """Application service for return documents."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = ReturnRepository(db)
        self.sales = SaleRepository(db)
        self.customers = CustomerRepository(db)
        self.ledger = DebtLedgerEntryRepository(db)
        self.products = ProductRepository(db)
        self.variants = ProductVariantRepository(db)

    # ------------------------------------------------------------------
    # Reads
    # ------------------------------------------------------------------

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        sale_id: uuid.UUID | None = None,
        invoice_number: str | None = None,
        date_from: datetime | None = None,
        date_to: datetime | None = None,
        reason: str | None = None,
    ) -> ReturnListResponse:
        page = max(1, page)
        page_size = max(1, min(page_size, 100))
        rows, total = self.repo.search(
            page=page,
            page_size=page_size,
            sale_id=sale_id,
            invoice_number=invoice_number,
            date_from=date_from,
            date_to=date_to,
            reason=reason,
        )
        return ReturnListResponse(
            items=[self._to_response(r) for r in rows],
            total=total,
            page=page,
            page_size=page_size,
            pages=max(1, math.ceil(total / page_size)) if page_size else 1,
        )

    def get(self, return_id: uuid.UUID) -> ReturnResponse:
        ret = self.repo.get_by_id(return_id)
        if ret is None:
            raise NotFoundError(
                message="Return not found",
                details={"return_id": str(return_id)},
            )
        return self._to_response(ret)

    # ------------------------------------------------------------------
    # Post (THE transaction)
    # ------------------------------------------------------------------

    def post(
        self,
        request: ReturnCreateRequest,
        *,
        user=None,
        device_id: str | None = None,
    ) -> ReturnCreateResponse:
        """Post a fully-formed return document atomically.

        Idempotency (GATE 16): ``client_request_id`` is required; a repeat
        with the same key and payload returns the original document with
        ``idempotent_replay=true``, a repeat with a different payload is
        409 IDEMPOTENCY_CONFLICT, and a unique-key race rolls back and
        re-fetches the winner (the Phase 8 ``create_sale`` shape).
        """
        actor_id = user.id if user is not None else None
        effective_device = device_id or request.device_id or request.device
        key = request.client_request_id

        existing = self.repo.find_by_client_request_id(key)
        if existing is not None:
            self._assert_same_payload(existing, request)
            logger.info(
                "return_idempotent_replay",
                client_request_id=key,
                return_id=str(existing.id),
            )
            return self._to_create_response(existing, idempotent_replay=True)

        try:
            outcome = self._post(
                request, actor_id=actor_id, device_id=effective_device
            )
        except IntegrityError as exc:
            # Unique client_request_id race: another request won between the
            # fast-path check and our insert — return theirs.
            self.db.rollback()
            winner = self.repo.find_by_client_request_id(key)
            if winner is not None:
                self._assert_same_payload(winner, request)
                logger.info(
                    "return_idempotent_race_replay",
                    client_request_id=key,
                    return_id=str(winner.id),
                )
                return self._to_create_response(winner, idempotent_replay=True)
            logger.error(
                "return_integrity_error",
                exc_message=str(exc),
                client_request_id=key,
            )
            raise ConflictError(
                message="Return could not be saved due to a conflict",
                details={"client_request_id": key},
            ) from exc

        # A concurrent retry with the same key can commit while we hold the
        # locks; the service already replayed it inside the transaction.
        if isinstance(outcome, ReturnCreateResponse):
            return outcome

        return_id, refund_total, credit_reversed = outcome

        saved = self.repo.get_by_id(return_id)
        if saved is None:  # pragma: no cover — commit succeeded
            raise ConflictError(
                message="Return committed but could not be re-read",
                details={"return_id": str(return_id)},
            )
        logger.info(
            "return_posted",
            return_id=str(saved.id),
            return_number=saved.return_number,
            sale_id=str(saved.sale_id),
            refund_total=str(refund_total),
            credit_reversed=str(credit_reversed),
            lines=len(saved.lines),
        )
        return self._to_create_response(
            saved,
            idempotent_replay=False,
            credit_reversed=credit_reversed,
        )

    def _post(
        self,
        request: ReturnCreateRequest,
        *,
        actor_id: uuid.UUID | None,
        device_id: str | None,
    ) -> tuple[uuid.UUID, Decimal, Decimal] | ReturnCreateResponse:
        with self.transaction():
            # 1. Sale row lock FIRST (§19) — the cap (§11), the void
            #    exclusion (§16) and the debt credit all read from here.
            sale: Sale | None = None
            customer_id: uuid.UUID | None = None
            if request.sale_id is not None:
                sale = self.sales.get_for_update(request.sale_id)
                if sale is None:
                    raise NotFoundError(
                        message="Sale not found",
                        details={"sale_id": str(request.sale_id)},
                    )
                if sale.status == SaleStatus.VOID.value:
                    raise ConflictError(
                        message="Voided sales cannot be returned",
                        code="SALE_ALREADY_VOID",
                        details={
                            "sale_id": str(sale.id),
                            "invoice_number": sale.invoice_number,
                        },
                    )
                if sale.status != SaleStatus.COMPLETED.value:
                    raise ConflictError(
                        message="Sale cannot be returned in this status",
                        code="SALE_NOT_VOIDABLE",
                        details={
                            "sale_id": str(sale.id),
                            "status": sale.status,
                        },
                    )
                customer_id = sale.customer_id
                if (
                    request.customer_id is not None
                    and request.customer_id != sale.customer_id
                ):
                    raise ValidationError(
                        message="customer_id must match the sale's customer",
                        details={
                            "sale_id": str(sale.id),
                            "customer_id": str(request.customer_id),
                        },
                    )
            elif request.customer_id is not None:
                raise ValidationError(
                    message="customer_id is only valid on a linked return",
                    details={"customer_id": str(request.customer_id)},
                )

            # 1b. GATE 16 again, now UNDER the lock: a concurrent retry with
            #     the same key may have committed while we waited for the
            #     sale row. Replaying it here keeps the ceiling check from
            #     rejecting a caller for its own already-committed quantity.
            replay = self._replay_if_committed(request)
            if replay is not None:
                return replay

            # 2. Validate + merge lines, enforce the cap, value the refund.
            plans = self._build_plans(request, sale)

            subtotal = quantize_money(sum((p["refund"] for p in plans), _ZERO))
            share = self._invoice_discount_share(sale, subtotal)
            total = quantize_money(subtotal - share)

            # 3. Customer row lock when a debt reversal can apply (§19).
            customer = None
            if customer_id is not None:
                customer = self.customers.get_for_update(customer_id)
                if customer is None:  # pragma: no cover — FK guarantees it
                    raise NotFoundError(
                        message="Customer not found",
                        details={"customer_id": str(customer_id)},
                    )

            # 3b. Phase D: loyalty plan + account lock.  The plan is pure
            #     arithmetic on the SALE's stored loyalty columns and on
            #     prior returns of this sale (this return's document row
            #     is written in step 5, after the plan).  Computed under
            #     the sale row lock — competing returns/voids of the same
            #     sale serialize there — and BEFORE any stock or document
            #     write, so a rejected return leaves zero loyalty residue.
            #     Lock order extends §19 exactly like the sale
            #     transaction: sale → customer → loyalty account → stock.
            loyalty_engine: LoyaltyEngine | None = None
            loyalty_account = None
            claw_points = _ZERO
            claw_cashback = _ZERO
            clawed_points = _ZERO
            clawed_cashback = _ZERO
            restored_points = _ZERO
            restored_value = _ZERO
            if sale is not None and customer is not None and (
                sale.loyalty_points_earned is not None
                or sale.loyalty_cashback_earned is not None
                or (sale.loyalty_points_redeemed or 0) > 0
            ):
                sale_total = to_decimal(sale.total)
                if sale_total > 0:
                    # Cumulative refunded value of PRIOR returns of this
                    # sale (cap §11 keeps the sum ≤ sale.total, so the
                    # fraction can never exceed 1).
                    returned_before = to_decimal(
                        self.db.execute(
                            select(func.coalesce(func.sum(Return.total), 0)).where(
                                Return.sale_id == sale.id
                            )
                        ).scalar()
                    )
                    fraction = (returned_before + total) / sale_total

                    # Redemption restoration — entitlement pattern
                    # mirrored from _pro_rata_refund: cumulative restores
                    # land on EXACTLY the full redeemed points once the
                    # sale is fully returned, and partial restores are
                    # floored (never over-restore).
                    redeemed_points = to_decimal(
                        sale.loyalty_points_redeemed or _ZERO
                    )
                    if redeemed_points > 0:
                        entitlement = (redeemed_points * fraction).to_integral_value(
                            rounding=ROUND_FLOOR
                        )
                        restored_before = to_decimal(
                            self.db.execute(
                                select(
                                    func.coalesce(
                                        func.sum(LoyaltyLedgerEntry.points_delta), 0
                                    )
                                ).where(
                                    LoyaltyLedgerEntry.sale_id == sale.id,
                                    LoyaltyLedgerEntry.source_event_key.like(
                                        "return_redemption:%"
                                    ),
                                )
                            ).scalar()
                        )
                        restored_points = max(_ZERO, entitlement - restored_before)
                        if restored_points > 0:
                            # Value follows the points restored, derived
                            # from the STORED redeemed value: a later
                            # settings change cannot rewrite what this
                            # return settles in cash.
                            restored_value = quantize_money(
                                to_decimal(sale.loyalty_redeemed_value)
                                * restored_points
                                / redeemed_points
                            )

                    # Earn clawback — the appropriate share of the
                    # checkout rewards, floored (a clawback never rounds
                    # UP) and entitlement-exact across partial returns.
                    if sale.loyalty_points_earned is not None:
                        earned_points = to_decimal(sale.loyalty_points_earned)
                        earned_cashback = to_decimal(
                            sale.loyalty_cashback_earned or _ZERO
                        )
                        claw_points = max(
                            _ZERO,
                            min(
                                earned_points,
                                (earned_points * fraction).to_integral_value(
                                    rounding=ROUND_FLOOR
                                ),
                            ),
                        )
                        claw_cashback = max(
                            _ZERO,
                            min(
                                earned_cashback,
                                _floor_money(earned_cashback * fraction),
                            ),
                        )
                        prior_claw = self.db.execute(
                            select(
                                func.coalesce(
                                    func.sum(LoyaltyLedgerEntry.points_delta), 0
                                ),
                                func.coalesce(
                                    func.sum(LoyaltyLedgerEntry.cashback_delta), 0
                                ),
                            ).where(
                                LoyaltyLedgerEntry.sale_id == sale.id,
                                LoyaltyLedgerEntry.event_type == "return_clawback",
                            )
                        ).one()
                        # Prior clawback entries are strictly negative.
                        claw_points = max(
                            _ZERO, claw_points + to_decimal(prior_claw[0])
                        )
                        claw_cashback = max(
                            _ZERO, claw_cashback + to_decimal(prior_claw[1])
                        )

                if claw_points > 0 or claw_cashback > 0 or restored_points > 0:
                    loyalty_engine = LoyaltyEngine(self.db)
                    loyalty_account = loyalty_engine.get_or_create_account(
                        customer.id, for_update=True
                    )

            # 4. Stock target locks, ascending id (§19).
            product_ids: set[uuid.UUID] = set()
            variant_ids: set[uuid.UUID] = set()
            for plan in plans:
                for restore in plan["restores"]:
                    product_ids.add(restore["product_id"])
                    if restore["variant_id"] is not None:
                        variant_ids.add(restore["variant_id"])
            products, variants = lock_restore_targets(
                self.db, product_ids, variant_ids
            )

            # 5. Persist the document (header + snapshot lines).
            ret = Return(
                return_number=_generate_return_number(),
                sale_id=sale.id if sale is not None else None,
                customer_id=customer_id,
                user_id=actor_id,
                reason=request.reason,
                subtotal=float(subtotal),
                discount=float(share),
                total=float(total),
                note=request.note,
                device_id=device_id,
                client_request_id=request.client_request_id,
            )
            self.db.add(ret)
            self.db.flush()

            for plan in plans:
                self.db.add(
                    ReturnLine(
                        return_id=ret.id,
                        sale_line_id=plan["sale_line_id"],
                        product_id=plan["product_id"],
                        pack_id=plan["pack_id"],
                        variant_id=plan["variant_id"],
                        product_name=plan["product_name"],
                        product_sku=plan["product_sku"],
                        product_barcode=plan["product_barcode"],
                        product_unit=plan["product_unit"],
                        variant_name=plan["variant_name"],
                        selling_unit_name=plan["selling_unit_name"],
                        selling_unit_multiplier=plan["selling_unit_multiplier"],
                        unit_price=plan["unit_price"],
                        unit_cost=plan["unit_cost"],
                        quantity=plan["quantity"],
                        quantity_base=plan["quantity_base"],
                        line_discount=plan["line_discount"],
                        line_total=plan["refund"],
                    )
                )
            self.db.flush()

            # 6. Stock restoration + journal (GATE 6/7/11/12/13).
            reason_text = f"Return {ret.return_number}"
            for plan in plans:
                for restore in plan["restores"]:
                    apply_restore(
                        self.db,
                        restore,
                        products=products,
                        variants=variants,
                        movement_type=StockMovementType.RETURN,
                        document_quantity=plan["document_quantity"],
                        document_unit=plan["document_unit"],
                        reason=reason_text,
                        user_id=actor_id,
                        device_id=device_id,
                        source_document_type="return",
                        source_document_id=ret.id,
                    )

            # 7. Debt reversal (§17): capped, shortfall never silent.
            #    Phase D: the redeemed share of this return is settled in
            #    POINTS (step 7b) — carve it out of the settlement base so
            #    no portion of the refund is compensated twice (never a
            #    second cash refund for the redeemed portion).  With
            #    restored_value = 0 the base is the untouched `total`.
            credit_base = quantize_money(total - restored_value)
            credit_reversed = _ZERO
            if customer is not None and sale is not None:
                credit, reversed_before = sale_credit_and_reversed(
                    self.db, sale.id
                )
                credit_reversed = reverse_customer_debt(
                    self.db,
                    self.ledger,
                    customer=customer,
                    credit=credit,
                    reversed_before=reversed_before,
                    refund_total=credit_base,
                    reference_sale_id=sale.id,
                    note=f"Return {ret.return_number} refund",
                    client_request_id=request.client_request_id,
                    actor_id=actor_id,
                )

            # 7b. Phase D: loyalty ledger — SAME transaction as the
            #     return.  Order matters: the earn clawback runs FIRST,
            #     floored at the balance as it stands BEFORE this
            #     return's restoration, so points being restored for the
            #     returned goods are never consumed by an earn reversal;
            #     any unreversed shortfall is written into the ledger
            #     note and the return itself stays valid.  The
            #     restoration follows (positive adjustment — it reverses
            #     a checkout ``redeem``, it is not itself a clawback).
            if loyalty_engine is not None and loyalty_account is not None:
                if claw_points > 0 or claw_cashback > 0:
                    actual_points = min(
                        claw_points, to_decimal(loyalty_account.points_balance)
                    )
                    actual_cashback = min(
                        claw_cashback, to_decimal(loyalty_account.cashback_balance)
                    )
                    clawed_points = actual_points
                    clawed_cashback = actual_cashback
                    shortfalls = []
                    if claw_points - actual_points > 0:
                        shortfalls.append(
                            f"{claw_points - actual_points} points already spent"
                        )
                    if claw_cashback - actual_cashback > 0:
                        shortfalls.append(
                            f"{claw_cashback - actual_cashback} cashback "
                            "already spent"
                        )
                    note = f"Return {ret.return_number} reward reversal"
                    if shortfalls:
                        note = f"{note} (shortfall: {', '.join(shortfalls)})"
                    loyalty_engine.post(
                        customer_id=customer.id,
                        event_type="return_clawback",
                        source_event_key=f"return_clawback:{ret.id}",
                        points_delta=-actual_points,
                        cashback_delta=-actual_cashback,
                        sale_id=sale.id,
                        return_id=ret.id,
                        created_by=actor_id,
                        note=note,
                    )
                if restored_points > 0:
                    loyalty_engine.post(
                        customer_id=customer.id,
                        event_type="adjustment",
                        source_event_key=f"return_redemption:{ret.id}",
                        points_delta=restored_points,
                        cashback_delta=_ZERO,
                        sale_id=sale.id,
                        return_id=ret.id,
                        created_by=actor_id,
                        note=(
                            f"Return {ret.return_number}: redeemed points "
                            "restored for returned goods"
                        ),
                    )

            # 8. Audit (§21): one structured row per operation.
            self._audit(
                AuditAction.RETURN,
                entity_id=ret.id,
                actor_id=actor_id,
                details=json.dumps(
                    {
                        "return_number": ret.return_number,
                        "invoice_number": (
                            sale.invoice_number if sale is not None else None
                        ),
                        "mode": (
                            "linked" if sale is not None else "independent"
                        ),
                        "reason": request.reason,
                        "lines": len(plans),
                        "quantities": [str(p["quantity"]) for p in plans],
                        "subtotal": str(subtotal),
                        "discount": str(share),
                        "refund_total": str(total),
                        "credit_reversed": str(credit_reversed),
                        "cash_pending": str(
                            quantize_money(credit_base - credit_reversed)
                        ),
                        "loyalty_points_clawed": str(clawed_points),
                        "loyalty_cashback_clawed": str(clawed_cashback),
                        "loyalty_points_restored": str(restored_points),
                        "loyalty_restored_value": str(restored_value),
                    },
                    ensure_ascii=True,
                ),
            )
            self.db.flush()
            return_id = ret.id

        return return_id, total, credit_reversed

    # ------------------------------------------------------------------
    # Planning / validation
    # ------------------------------------------------------------------

    def _replay_if_committed(
        self, request: ReturnCreateRequest
    ) -> ReturnCreateResponse | None:
        """Return the already-committed document for this key, if any.

        Called both at the fast path (before any lock) and again under the
        sale row lock, so a concurrent retry that lost the row-lock race
        replays the winner instead of failing its own ceiling check with
        the winner's quantity (GATE 16).
        """
        existing = self.repo.find_by_client_request_id(
            request.client_request_id
        )
        if existing is None:
            return None
        self._assert_same_payload(existing, request)
        logger.info(
            "return_idempotent_replay",
            client_request_id=request.client_request_id,
            return_id=str(existing.id),
        )
        return self._to_create_response(existing, idempotent_replay=True)

    def _build_plans(
        self, request: ReturnCreateRequest, sale: Sale | None
    ) -> list[dict[str, Any]]:
        """Validate every requested line and compute its effects.

        Raises before anything is written: unknown/foreign/component source
        lines are ``RETURN_LINE_INVALID``, non-whole pack quantities are
        ``RETURN_PACK_NOT_WHOLE`` (both 422), and a cumulative cap breach is
        ``RETURN_EXCEEDS_SOLD`` (409, §11). Duplicate request lines for the
        same target are merged first, so the cap and the pro-rata refund
        stay correct when a client submits one target twice.
        """
        plans_by_key: dict[tuple, dict[str, Any]] = {}
        for line in request.lines:
            if sale is None:
                key: tuple = ("product", line.product_id, line.variant_id)
            elif line.sale_line_id is not None:
                key = ("line", line.sale_line_id)
            else:
                key = ("product", line.product_id, line.variant_id)

            existing = plans_by_key.get(key)
            if existing is not None:
                # Merged target: re-plan from this line with the SUMMED
                # quantity so quantity_base, restores and
                # document_quantity stay consistent with `quantity`
                # (they are all derived from it). Planning the summed
                # line keeps stock restoration, the cap and the refund
                # identical to a single line of the same total.
                merged = line.model_copy(
                    update={
                        "quantity": existing["quantity"]
                        + to_decimal(line.quantity)
                    }
                )
                plans_by_key[key] = self._plan_line(merged, sale)
                continue
            plans_by_key[key] = self._plan_line(line, sale)

        plans = list(plans_by_key.values())
        if sale is not None:
            self._enforce_caps(plans)
        self._compute_refunds(plans, sale)
        return plans

    def _plan_line(self, line, sale: Sale | None) -> dict[str, Any]:
        if sale is not None:
            if line.sale_line_id is None:
                # A linked return must reference source lines — otherwise the
                # ceiling, the refund valuation and the pack component
                # derivation all lose their source of truth.
                raise ValidationError(
                    message=(
                        "sale_line_id is required on a linked return "
                        "(omit sale_id for an independent return)"
                    ),
                    code="RETURN_LINE_INVALID",
                    details={"sale_line_id": None},
                )
            return self._plan_linked_line(line, sale)
        if line.pack_id is not None:
            # Pack components must be derived from the sale's own lines;
            # today's pack_items may already have changed (§14).
            raise ValidationError(
                message=(
                    "Pack returns must reference a sale line "
                    "(pack_id without sale_id is not supported)"
                ),
                code="RETURN_LINE_INVALID",
                details={"pack_id": str(line.pack_id)},
            )
        return self._plan_independent_line(line)

    # -- linked ---------------------------------------------------------

    def _plan_linked_line(self, line, sale: Sale) -> dict[str, Any]:
        source = next(
            (ln for ln in sale.lines if ln.id == line.sale_line_id), None
        )
        if source is None:
            raise ValidationError(
                message="Return line references an unknown sale line",
                code="RETURN_LINE_INVALID",
                details={
                    "sale_line_id": str(line.sale_line_id),
                    "sale_id": str(sale.id),
                },
            )
        # Component lines are derived, never independently requestable (§11).
        if source.pack_id is not None and source.product_id is not None:
            raise ValidationError(
                message="Pack component lines cannot be returned directly",
                code="RETURN_LINE_INVALID",
                details={
                    "sale_line_id": str(source.id),
                    "product_id": str(source.product_id),
                },
            )
        for name, requested, actual in (
            ("product_id", line.product_id, source.product_id),
            ("variant_id", line.variant_id, source.variant_id),
            ("pack_id", line.pack_id, source.pack_id),
        ):
            if requested is not None and requested != actual:
                raise ValidationError(
                    message=f"{name} does not match the source sale line",
                    code="RETURN_LINE_INVALID",
                    details={
                        "sale_line_id": str(source.id),
                        name: str(requested),
                        f"source_{name}": str(actual),
                    },
                )

        is_pack = source.pack_id is not None and source.product_id is None
        qty = to_decimal(line.quantity)
        self._validate_quantity(qty, source=source, is_pack=is_pack)

        if is_pack:
            # Whole packs only (§11/§14). The charged summary owns no
            # stock, so no base quantity is stored on the return line.
            quantity_base: Decimal | None = None
            restores = self._pack_restores(sale, source, qty)
            document_quantity = qty
            document_unit = ProductUnit.PACK.value
        else:
            multiplier = source.selling_unit_multiplier
            quantity_base = (
                selling_to_base(qty, multiplier)
                if multiplier is not None
                else qty.quantize(QTY_QUANTUM)
            )
            restores = [
                {
                    "product_id": source.product_id,
                    "variant_id": source.variant_id,
                    "quantity_base": quantity_base,
                    "unit_cost": to_decimal(source.unit_cost),
                }
            ]
            document_quantity = qty
            document_unit = source.selling_unit_name or source.product_unit

        return {
            "source": source,
            "sale_line_id": source.id,
            "product_id": source.product_id,
            "pack_id": source.pack_id,
            "variant_id": source.variant_id,
            "product_name": source.product_name,
            "product_sku": source.product_sku,
            "product_barcode": source.product_barcode,
            "product_unit": source.product_unit,
            "variant_name": source.variant_name,
            "selling_unit_name": source.selling_unit_name,
            "selling_unit_multiplier": source.selling_unit_multiplier,
            "unit_price": to_decimal(source.unit_price),
            "unit_cost": to_decimal(source.unit_cost),
            "quantity": qty,
            "quantity_base": quantity_base,
            "line_discount": to_decimal(source.line_discount),
            "refund": _ZERO,
            "document_quantity": document_quantity,
            "document_unit": document_unit,
            "restores": restores,
        }

    def _pack_restores(
        self, sale: Sale, summary: SaleLine, packs: Decimal
    ) -> list[dict[str, Any]]:
        """Component restorations for ``packs`` packs of one sale (§14).

        ``per_pack`` is derived from THIS sale's own component lines::

            per_pack(p) = Σ component lines of p (same pack)
                          ÷ Σ summary lines of that pack in this sale

        Deriving from the sale (never from today's ``pack_items``) keeps a
        composition change between two sales from rewriting history, and
        the group totals make two cart lines of the same pack attribute
        correctly (risk R2).
        """
        summaries = [
            ln
            for ln in sale.lines
            if ln.pack_id == summary.pack_id and ln.product_id is None
        ]
        summary_qty = sum((to_decimal(ln.quantity) for ln in summaries), _ZERO)
        components = [
            ln
            for ln in sale.lines
            if ln.pack_id == summary.pack_id and ln.product_id is not None
        ]
        if summary_qty <= _ZERO or not components:  # pragma: no cover
            raise ValidationError(
                message="Sale has no pack components to restore",
                code="RETURN_LINE_INVALID",
                details={"sale_line_id": str(summary.id)},
            )

        per_product: dict[uuid.UUID, Decimal] = {}
        for component in components:
            per_product[component.product_id] = per_product.get(
                component.product_id, _ZERO
            ) + to_decimal(component.quantity)

        restores: list[dict[str, Any]] = []
        seen: set[uuid.UUID] = set()
        for component in components:
            if component.product_id in seen:
                continue
            seen.add(component.product_id)
            per_pack = per_product[component.product_id] / summary_qty
            restores.append(
                {
                    "product_id": component.product_id,
                    "variant_id": None,
                    "quantity_base": (per_pack * packs).quantize(QTY_QUANTUM),
                    "unit_cost": to_decimal(component.unit_cost),
                }
            )
        return restores

    # -- independent ----------------------------------------------------

    def _plan_independent_line(self, line) -> dict[str, Any]:
        if line.product_id is None:
            raise ValidationError(
                message="product_id is required for an independent return",
                code="RETURN_LINE_INVALID",
                details={"line": "product_id"},
            )
        product = self.products.get_by_id(line.product_id)
        if product is None:
            raise NotFoundError(
                message="Product not found",
                details={"product_id": str(line.product_id)},
            )
        variant: ProductVariant | None = None
        if line.variant_id is not None:
            variant = self.variants.get_by_id(line.variant_id)
            if variant is None or variant.product_id != product.id:
                raise ValidationError(
                    message="Variant does not belong to this product",
                    code="RETURN_LINE_INVALID",
                    details={
                        "variant_id": str(line.variant_id),
                        "product_id": str(product.id),
                    },
                )

        qty = to_decimal(line.quantity)
        self._validate_quantity(qty, source=None, is_pack=False, product=product)
        quantity_base = qty.quantize(QTY_QUANTUM)

        if variant is not None and variant.price is not None:
            unit_price = to_decimal(variant.price)
            unit_cost = (
                to_decimal(variant.cost)
                if variant.cost is not None
                else to_decimal(product.avg_cost)
            )
        else:
            unit_price = to_decimal(product.price)
            unit_cost = to_decimal(product.avg_cost)

        return {
            "source": None,
            "sale_line_id": None,
            "product_id": product.id,
            "pack_id": None,
            "variant_id": variant.id if variant is not None else None,
            "product_name": product.name,
            "product_sku": product.sku,
            "product_barcode": (
                variant.barcode
                if variant is not None and variant.barcode
                else product.barcode
            ),
            "product_unit": product.unit,
            "variant_name": variant.name if variant is not None else None,
            "selling_unit_name": None,
            "selling_unit_multiplier": None,
            "unit_price": unit_price,
            "unit_cost": unit_cost,
            "quantity": qty,
            "quantity_base": quantity_base,
            "line_discount": _ZERO,
            "refund": _ZERO,
            "document_quantity": qty,
            "document_unit": product.unit,
            "restores": [
                {
                    "product_id": product.id,
                    "variant_id": variant.id if variant is not None else None,
                    "quantity_base": quantity_base,
                    "unit_cost": unit_cost,
                }
            ],
        }

    # -- shared validation ----------------------------------------------

    @staticmethod
    def _validate_quantity(
        qty: Decimal,
        *,
        source: SaleLine | None,
        is_pack: bool,
        product: Product | None = None,
    ) -> None:
        if qty <= _ZERO:
            raise ValidationError(
                message="Return quantity must be > 0",
                details={"quantity": str(qty)},
            )
        if is_pack:
            if qty != qty.to_integral_value():
                raise ValidationError(
                    message="Pack returns are whole packs only",
                    code="RETURN_PACK_NOT_WHOLE",
                    details={"quantity": str(qty)},
                )
            return
        # Whole-piece check (§15): a base-unit piece line can only come
        # back in whole pieces. Selling-unit, weight and length lines stay
        # fractional — the legacy piece check is preserved, nothing more.
        if source is not None:
            if source.selling_unit_multiplier is not None:
                return
            piece_line = source.product_unit == ProductUnit.PIECE.value
        else:
            assert product is not None
            piece_line = product.unit == ProductUnit.PIECE.value
        if piece_line and qty != qty.to_integral_value():
            raise ValidationError(
                message="Piece quantities must be whole numbers",
                details={"quantity": str(qty), "unit": ProductUnit.PIECE.value},
            )

    def _enforce_caps(self, plans: list[dict[str, Any]]) -> None:
        """Cumulative per-source-line ceiling, inside the transaction (§11).

        ``returned_before + requested > sold`` → 409 RETURN_EXCEEDS_SOLD
        with the numbers the operator needs to correct the entry. The
        ceiling is per ``sale_line_id`` (two lines of the same product in
        one invoice each carry their own) and is read from the DB, never
        from a client-supplied remaining quantity. Independent returns
        bypass it by construction — there is no sold quantity to cap
        against (§10).
        """
        linked = [p for p in plans if p["source"] is not None]
        if not linked:
            return
        aggregates = self.repo.returned_quantities_for_lines(
            [p["sale_line_id"] for p in linked]
        )
        for plan in linked:
            source: SaleLine = plan["source"]
            returned_before, _already = aggregates.get(source.id, (_ZERO, _ZERO))
            requested = plan["quantity"]
            if returned_before + requested > to_decimal(source.quantity):
                raise ConflictError(
                    message="Return quantity exceeds the sold quantity",
                    code="RETURN_EXCEEDS_SOLD",
                    details={
                        "sale_line_id": str(source.id),
                        "product_name": source.product_name,
                        "sold": str(to_decimal(source.quantity)),
                        "already_returned": str(returned_before),
                        "requested": str(requested),
                    },
                )

    def _compute_refunds(
        self, plans: list[dict[str, Any]], sale: Sale | None
    ) -> None:
        """Value every merged plan from persisted economics (§12, GATE 5)."""
        for plan in plans:
            if plan["source"] is not None:
                plan["refund"] = self._pro_rata_refund(
                    plan["source"], plan["quantity"]
                )
            else:
                # Independent return: no sale exists to value against, so
                # the refund uses the product/variant price at posting time.
                # The "never the current catalog price" rule governs
                # HISTORICAL refunds, which only linked returns have.
                plan["refund"] = quantize_money(
                    plan["unit_price"] * plan["quantity"]
                )

    def _pro_rata_refund(self, source: SaleLine, qty: Decimal) -> Decimal:
        """Refund for ``qty`` of one source line (§12).

        refund = quantize(line_total × (already_returned + qty) / quantity)
                 − already_refunded

        so a fully returned line refunds exactly ``line_total`` no matter
        how many partial returns it took (rounding residue ≤ 0.001 lands in
        the last return of the document), and the invoice-level discount is
        shared afterwards in :meth:`_invoice_discount_share`.
        """
        aggregates = self.repo.returned_quantities_for_lines([source.id])
        qty_before, already = aggregates.get(source.id, (_ZERO, _ZERO))
        line_total = to_decimal(source.line_total)
        source_qty = to_decimal(source.quantity)
        if source_qty <= _ZERO:  # pragma: no cover — sale lines are > 0
            raise ValidationError(
                message="Source sale line has no quantity",
                code="RETURN_LINE_INVALID",
                details={"sale_line_id": str(source.id)},
            )
        entitlement = quantize_money(line_total * (qty_before + qty) / source_qty)
        refund = quantize_money(entitlement - already)
        return refund if refund > _ZERO else _ZERO

    @staticmethod
    def _invoice_discount_share(sale: Sale | None, subtotal: Decimal) -> Decimal:
        """Invoice-discount share of the refund (§12, GATE 14)."""
        if sale is None:
            return _ZERO
        discount = quantize_money(to_decimal(sale.discount))
        if discount <= _ZERO or subtotal <= _ZERO:
            return _ZERO
        charged_total = sum(
            (to_decimal(ln.line_total) for ln in sale.lines), _ZERO
        )
        if charged_total <= _ZERO:
            return _ZERO
        share = quantize_money(discount * subtotal / charged_total)
        # Never let rounding push the refund negative (defense in depth).
        return min(share, subtotal)

    # ------------------------------------------------------------------
    # Audit
    # ------------------------------------------------------------------

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction.

        A committed return always has its audit entry and a rolled-back one
        leaves no orphan (Phase 0 rule #4, §21).
        """
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="return",
                entity_id=entity_id,
                details=details,
            )
        )

    # ------------------------------------------------------------------
    # Response mapping
    # ------------------------------------------------------------------

    @staticmethod
    def _to_line_response(line: ReturnLine) -> ReturnLineResponse:
        return ReturnLineResponse(
            id=line.id,
            sale_line_id=line.sale_line_id,
            product_id=line.product_id,
            pack_id=line.pack_id,
            variant_id=line.variant_id,
            product_name=line.product_name,
            product_sku=line.product_sku,
            product_barcode=line.product_barcode,
            product_unit=line.product_unit,
            variant_name=line.variant_name,
            selling_unit_name=line.selling_unit_name,
            selling_unit_multiplier=(
                to_decimal(line.selling_unit_multiplier)
                if line.selling_unit_multiplier is not None
                else None
            ),
            unit_price=to_decimal(line.unit_price),
            unit_cost=to_decimal(line.unit_cost),
            quantity=to_decimal(line.quantity),
            quantity_base=(
                to_decimal(line.quantity_base)
                if line.quantity_base is not None
                else None
            ),
            line_discount=to_decimal(line.line_discount),
            line_total=to_decimal(line.line_total),
        )

    @classmethod
    def _to_response(cls, ret: Return) -> ReturnResponse:
        return ReturnResponse(
            id=ret.id,
            return_number=ret.return_number,
            sale_id=ret.sale_id,
            invoice_number=ret.sale.invoice_number if ret.sale else None,
            customer_id=ret.customer_id,
            user_id=ret.user_id,
            reason=ret.reason,
            subtotal=to_decimal(ret.subtotal),
            discount=to_decimal(ret.discount),
            total=to_decimal(ret.total),
            note=ret.note,
            device_id=ret.device_id,
            client_request_id=ret.client_request_id,
            return_date=ret.return_date,
            lines=[cls._to_line_response(ln) for ln in ret.lines],
        )

    def _to_create_response(
        self,
        ret: Return,
        *,
        idempotent_replay: bool,
        credit_reversed: Decimal | None = None,
    ) -> ReturnCreateResponse:
        refund_total = quantize_money(to_decimal(ret.total))
        if credit_reversed is None:
            # Replay: derive this document's own reversal from the ledger
            # row written with its client_request_id (§17).
            credit_reversed = credit_reversed_for_key(
                self.db, ret.client_request_id or ""
            )
        cash_pending = quantize_money(refund_total - credit_reversed)
        # Phase D: the redeemed share of a loyalty return is settled in
        # restored POINTS — cash must never cover it a second time.  The
        # restoration is derived from this return's own committed ledger
        # entry, so fresh responses and idempotent replays agree.
        restored = restored_points_for_return(self.db, ret.id)
        sale = ret.sale
        if (
            restored > 0
            and sale is not None
            and (sale.loyalty_points_redeemed or 0) > 0
        ):
            restored_value = quantize_money(
                to_decimal(sale.loyalty_redeemed_value)
                * restored
                / to_decimal(sale.loyalty_points_redeemed)
            )
            cash_pending = max(
                _ZERO, quantize_money(cash_pending - restored_value)
            )
        return ReturnCreateResponse(
            return_=self._to_response(ret),
            idempotent_replay=idempotent_replay,
            refund_total=refund_total,
            credit_reversed=credit_reversed,
            cash_pending=cash_pending,
        )

    # ------------------------------------------------------------------
    # Idempotency payload comparison
    # ------------------------------------------------------------------

    @staticmethod
    def _qty_key(qty) -> str:
        """Canonical quantity text for idempotency comparison.

        The request carries ``Decimal('2')`` while the persisted
        ``NUMERIC(18,3)`` value comes back as ``Decimal('2.000')``;
        comparing the raw strings reported a false ``IDEMPOTENCY_CONFLICT``
        for an exact replay sent with a shorter quantity (the UI sends
        ``2``, not ``2.000``). Normalizing the exponent makes the comparison
        numeric while keeping the tuple elements plain strings.
        """
        return format(to_decimal(qty).normalize(), "f")

    @classmethod
    def _line_signature(cls, ln) -> tuple:
        """Identity of one line for idempotent replay comparison.

        A linked line is identified by its source ``sale_line_id`` alone —
        the product/pack/variant fields on a stored line are derived from
        that source (the request only asserts they match), so including
        them would report a false conflict on an exact replay. An
        independent line has no source and is identified by its target.
        """
        if ln.sale_line_id is not None:
            return (str(ln.sale_line_id), cls._qty_key(ln.quantity))
        return (
            None,
            str(ln.product_id) if ln.product_id else None,
            str(ln.variant_id) if ln.variant_id else None,
            str(ln.pack_id) if ln.pack_id else None,
            cls._qty_key(ln.quantity),
        )

    @classmethod
    def _request_signature(cls, request: ReturnCreateRequest) -> tuple:
        return (
            request.sale_id,
            request.customer_id,
            request.reason,
            (request.note or "").strip(),
            tuple(sorted(cls._line_signature(ln) for ln in request.lines)),
        )

    @classmethod
    def _document_signature(cls, ret: Return) -> tuple:
        return (
            ret.sale_id,
            ret.customer_id,
            ret.reason,
            (ret.note or "").strip(),
            tuple(sorted(cls._line_signature(ln) for ln in ret.lines)),
        )

    @classmethod
    def _assert_same_payload(
        cls, existing: Return, request: ReturnCreateRequest
    ) -> None:
        if cls._document_signature(existing) != cls._request_signature(request):
            raise ConflictError(
                message=(
                    "client_request_id was already used with a different "
                    "return payload"
                ),
                code="IDEMPOTENCY_CONFLICT",
                details={
                    "client_request_id": request.client_request_id,
                    "return_id": str(existing.id),
                },
            )
