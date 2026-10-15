"""Invoice void service (Phase 12).

One operation: ``completed → void`` — a one-way terminal transition (GATE 1)
that restores stock, writes ``sale_void`` movements, reverses the debt
attributable to the sale and appends one audit row, all inside ONE
``BaseService.transaction()``.

Hard rules (Phase 0 #3/#4, decision record §7/§8):
- the sale row, its lines, payments and snapshot totals are RETAINED
  unchanged — totals are never zeroed (legacy defect V3),
- no ``unvoid``: corrections are new documents, not reversal-of-reversal,
- a voided sale is never returned, and a sale with returns is never voided
  (§16 mutual exclusion, checked here under the sale row lock).

Phase D (loyalty): the void claws back the checkout rewards exactly once
(floored at the current balance — spent rewards become a shortfall note,
never a negative balance), restores the points redeemed on the sale and
settles ``cash_pending`` net of the redeemed value, all in the SAME
transaction, under lock order sale → customer → loyalty account → stock.

Stock restoration and debt reversal are imported from
``app.services.void``'s sibling module so both Phase 12 operations share
one implementation of each (see that module's header).
"""

from __future__ import annotations

import json
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import ConflictError, NotFoundError
from app.domain.unit_conversions import QTY_QUANTUM, selling_to_base, to_decimal
from app.domain.valuation import quantize_money
from app.models.enums import AuditAction, AuditModule, AuditOutcome, SaleStatus, StockMovementType
from app.models.sale import Sale
from app.repositories.debt import DebtLedgerEntryRepository
from app.repositories.party import CustomerRepository
from app.repositories.returns import ReturnRepository
from app.repositories.sale import SaleRepository
from app.schemas.returns import VoidRequest, VoidResponse
from app.services.audit import AuditService
from app.services.base import BaseService
from app.services.loyalty import LoyaltyEngine
from app.services.returns import (
    apply_restore,
    lock_restore_targets,
    reverse_customer_debt,
    sale_credit_and_reversed,
)
from app.services.sale import SaleService

logger = structlog.get_logger(__name__)

_ZERO = Decimal("0")


def void_restores(sale: Sale) -> list[dict[str, Any]]:
    """Stock restorations for a whole invoice (§14).

    Every stock-owning line is restored by its own persisted
    ``quantity_base``:

    * product line   → ``products.quantity += quantity_base``
    * variant line   → ``product_variants.quantity += quantity_base`` ONLY
      (Phase 8's decided sale semantics mirrored — legacy defect V7)
    * pack component → ``products.quantity += quantity_base``
    * pack summary   → owns no stock, produces no restoration and no
      movement row (its components are the lines above)

    The selling-unit multiplier comes from the line's own snapshot, never
    from the catalog (§15), so a later multiplier change cannot rewrite
    how much stock comes back.
    """
    restores: list[dict[str, Any]] = []
    for line in sale.lines:
        if line.product_id is None:
            # Charged pack summary: no stock of its own (Phase 10 shape).
            continue
        multiplier = line.selling_unit_multiplier
        qty = to_decimal(line.quantity)
        quantity_base = (
            selling_to_base(qty, multiplier)
            if multiplier is not None
            else qty.quantize(QTY_QUANTUM)
        )
        restores.append(
            {
                "product_id": line.product_id,
                "variant_id": line.variant_id,
                "quantity_base": quantity_base,
                "unit_cost": to_decimal(line.unit_cost),
            }
        )
    return restores


class VoidService(BaseService):
    """Application service for invoice voids."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.sales = SaleRepository(db)
        self.customers = CustomerRepository(db)
        self.ledger = DebtLedgerEntryRepository(db)
        self.returns = ReturnRepository(db)

    def void_sale(
        self,
        sale_id: uuid.UUID,
        request: VoidRequest,
        *,
        user=None,
        device_id: str | None = None,
    ) -> VoidResponse:
        """Void one sale atomically. Reason is mandatory (§8).

        Idempotency (§19): the natural key is the sale itself — a second
        call returns 409 SALE_ALREADY_VOID and, crucially, restores nothing
        a second time.
        """
        actor_id = user.id if user is not None else None
        effective_device = device_id or None

        voided_id, refund_due, credit_reversed = self._void(
            sale_id,
            reason=request.reason,
            actor_id=actor_id,
            device_id=effective_device,
        )

        # Re-read after commit (Phase 8/9 pattern) so the response carries
        # the committed void fields and the frozen snapshot totals.
        sale_response = SaleService(self.db).get_sale(voided_id)
        # Phase D: the void restores the redeemed points, so the cash
        # still owed excludes the redeemed value — that share is settled
        # in points, never in cash.
        redeemed_value = to_decimal(sale_response.loyalty_redeemed_value or _ZERO)
        cash_pending = quantize_money(
            quantize_money(sale_response.total) - credit_reversed - redeemed_value
        )
        logger.info(
            "sale_voided",
            sale_id=str(voided_id),
            invoice_number=sale_response.invoice_number,
            refund_due=str(refund_due),
            credit_reversed=str(credit_reversed),
            cash_pending=str(cash_pending),
            loyalty_redeemed_value=str(redeemed_value),
        )
        return VoidResponse(
            sale=sale_response,
            credit_reversed=credit_reversed,
            refund_due=refund_due,
            cash_pending=cash_pending,
        )

    def _void(
        self,
        sale_id: uuid.UUID,
        *,
        reason: str,
        actor_id: uuid.UUID | None,
        device_id: str | None,
    ) -> tuple[uuid.UUID, Decimal, Decimal]:
        with self.transaction():
            # 1. Sale row lock FIRST (§19): status transition, mutual
            #    exclusion and the debt credit all serialize here.
            sale = self.sales.get_for_update(sale_id)
            if sale is None:
                raise NotFoundError(
                    message="Sale not found",
                    details={"sale_id": str(sale_id)},
                )
            if sale.status == SaleStatus.VOID.value:
                raise ConflictError(
                    message="Sale is already voided",
                    code="SALE_ALREADY_VOID",
                    details={
                        "sale_id": str(sale.id),
                        "invoice_number": sale.invoice_number,
                    },
                )
            if sale.status != SaleStatus.COMPLETED.value:
                raise ConflictError(
                    message="Only completed sales can be voided",
                    code="SALE_NOT_VOIDABLE",
                    details={
                        "sale_id": str(sale.id),
                        "status": sale.status,
                    },
                )

            # 2. Mutual exclusion (§16): both operations restore the same
            #    stock and reverse the same debt — never both.
            return_numbers = self.returns.return_numbers_for_sale(sale.id)
            if return_numbers:
                raise ConflictError(
                    message="Sale has returns and cannot be voided",
                    code="SALE_HAS_RETURNS",
                    details={
                        "sale_id": str(sale.id),
                        "invoice_number": sale.invoice_number,
                        "returns": return_numbers,
                    },
                )

            # 3. Customer row lock when a debt reversal can apply (§19).
            customer = None
            if sale.customer_id is not None:
                customer = self.customers.get_for_update(sale.customer_id)
                if customer is None:  # pragma: no cover — FK guarantees it
                    raise NotFoundError(
                        message="Customer not found",
                        details={"customer_id": str(sale.customer_id)},
                    )

            # 3b. Phase D: loyalty plan + account lock — placed with the
            #     customer lock and BEFORE the stock locks so the global
            #     order stays sale → customer → loyalty account → stock,
            #     identical to the checkout transaction (a cycle between
            #     account and stock locks is thereby impossible).  A void
            #     reverses the WHOLE document: full clawback of the
            #     checkout rewards, floored at the balance as it stands
            #     (spent rewards become a shortfall note — never a
            #     negative balance), then full restoration of the points
            #     redeemed on this sale.
            loyalty_engine: LoyaltyEngine | None = None
            loyalty_account = None
            claw_points = _ZERO
            claw_cashback = _ZERO
            clawed_points = _ZERO
            clawed_cashback = _ZERO
            restored_points = _ZERO
            restored_value = _ZERO
            if customer is not None and (
                sale.loyalty_points_earned is not None
                or sale.loyalty_cashback_earned is not None
                or (sale.loyalty_points_redeemed or 0) > 0
            ):
                claw_points = to_decimal(sale.loyalty_points_earned or _ZERO)
                claw_cashback = to_decimal(sale.loyalty_cashback_earned or _ZERO)
                restored_points = to_decimal(sale.loyalty_points_redeemed or _ZERO)
                restored_value = to_decimal(sale.loyalty_redeemed_value or _ZERO)
                if (
                    claw_points > 0
                    or claw_cashback > 0
                    or restored_points > 0
                ):
                    loyalty_engine = LoyaltyEngine(self.db)
                    loyalty_account = loyalty_engine.get_or_create_account(
                        customer.id, for_update=True
                    )

            # 4. Stock target locks, ascending id (§19).
            restores = void_restores(sale)
            product_ids = {r["product_id"] for r in restores}
            variant_ids = {
                r["variant_id"] for r in restores if r["variant_id"] is not None
            }
            products, variants = lock_restore_targets(
                self.db, product_ids, variant_ids
            )

            # 5. Stock restoration + journal (GATE 7: typed SALE_VOID).
            reason_text = f"Void {sale.invoice_number}"
            for restore in restores:
                apply_restore(
                    self.db,
                    restore,
                    products=products,
                    variants=variants,
                    movement_type=StockMovementType.SALE_VOID,
                    document_quantity=None,
                    document_unit=None,
                    reason=reason_text,
                    user_id=actor_id,
                    device_id=device_id,
                    source_document_type="sale",
                    source_document_id=sale.id,
                )

            # 6. Debt reversal (§17): reverse = min(credit(S), balance).
            #    The journal row is typed ``sale_void`` (GATE 7) and carries
            #    client_request_id = NULL by design — the sale id is already
            #    the natural key (§19).
            refund_due = quantize_money(to_decimal(sale.total))
            credit_reversed = _ZERO
            if customer is not None:
                credit, reversed_before = sale_credit_and_reversed(
                    self.db, sale.id
                )
                credit_reversed = reverse_customer_debt(
                    self.db,
                    self.ledger,
                    customer=customer,
                    credit=credit,
                    reversed_before=reversed_before,
                    # The refund base is the whole invoice; the cap and the
                    # shortfall note then name the cash portion still owed
                    # (§17, GATE 8) instead of hiding it.
                    refund_total=refund_due,
                    reference_sale_id=sale.id,
                    note=f"Sale {sale.invoice_number} voided",
                    client_request_id=None,
                    actor_id=actor_id,
                    entry_type="sale_void",
                )

            # 6b. Phase D: loyalty ledger — clawback FIRST (floored at
            #     the pre-void balance, so rewards the customer already
            #     spent are recorded as a shortfall note instead of a
            #     negative balance), then the redemption restoration.
            #     Both post in the SAME transaction as the void.
            #     Exactly-once is enforced twice: the SALE_ALREADY_VOID
            #     gate under the sale row lock (step 1) runs before this
            #     block, and the unique source_event_keys make a second
            #     reversal entry impossible even if a caller retries the
            #     post itself.
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
                    note = f"Sale {sale.invoice_number} voided"
                    if shortfalls:
                        note = f"{note} (shortfall: {', '.join(shortfalls)})"
                    loyalty_engine.post(
                        customer_id=customer.id,
                        event_type="void_clawback",
                        source_event_key=f"void_clawback:{sale.id}",
                        points_delta=-actual_points,
                        cashback_delta=-actual_cashback,
                        sale_id=sale.id,
                        created_by=actor_id,
                        note=note,
                    )
                if restored_points > 0:
                    loyalty_engine.post(
                        customer_id=customer.id,
                        event_type="adjustment",
                        source_event_key=f"void_redemption:{sale.id}",
                        points_delta=restored_points,
                        cashback_delta=_ZERO,
                        sale_id=sale.id,
                        created_by=actor_id,
                        note=(
                            f"Sale {sale.invoice_number} voided: redeemed "
                            "points restored"
                        ),
                    )

            # 7. Terminal flip + attribution (GATE 9). Totals stay frozen:
            #    never rewrite subtotal/discount/total/paid/change.
            sale.status = SaleStatus.VOID.value
            sale.voided_at = datetime.now(timezone.utc)
            sale.voided_by = actor_id
            sale.void_reason = reason

            # 8. Audit (§21): one structured row per void, in this
            #    transaction, so no void commits without its trail.
            self._audit(
                AuditAction.VOID,
                entity_id=sale.id,
                actor_id=actor_id,
                reason=reason,
                entity_ref=sale.invoice_number,
                device_id=device_id,
                details=json.dumps(
                    {
                        "invoice_number": sale.invoice_number,
                        "reason": reason,
                        "device_id": device_id,
                        "lines_restored": len(restores),
                        "refund_due": str(refund_due),
                        "credit_reversed": str(credit_reversed),
                        "cash_pending": str(
                            quantize_money(
                                refund_due - credit_reversed - restored_value
                            )
                        ),
                        "loyalty_points_clawed": str(clawed_points),
                        "loyalty_cashback_clawed": str(clawed_cashback),
                        "loyalty_points_restored": str(restored_points),
                        "loyalty_restored_value": str(restored_value),
                        "totals_preserved": {
                            "subtotal": str(to_decimal(sale.subtotal)),
                            "discount": str(to_decimal(sale.discount)),
                            "total": str(to_decimal(sale.total)),
                            "paid": str(to_decimal(sale.paid)),
                            "change": str(to_decimal(sale.change)),
                        },
                    },
                    ensure_ascii=True,
                ),
            )
            self.db.flush()
            voided_id = sale.id

        return voided_id, refund_due, credit_reversed

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
        reason: str | None = None,
        entity_ref: str | None = None,
        device_id: str | None = None,
    ) -> None:
        """Append an audit row inside the current transaction (§21).

        A committed void always has its audit entry and a rolled-back one
        leaves no orphan (Phase 0 rule #4).
        """
        AuditService(self.db).record(
            action=action,
            module=AuditModule.SALES,
            outcome=AuditOutcome.SUCCESS,
            entity_type="sale",
            entity_id=entity_id,
            entity_ref=entity_ref,
            user_id=actor_id,
            device_id=device_id,
            reason=reason,
            details=details,
        )


__all__ = ["VoidService", "void_restores"]
