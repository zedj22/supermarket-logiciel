"""Purchase document service (Phase 11).

Owns the purchase lifecycle: create (atomic create+receive or draft),
draft editing, receive posting, cancellation reversal, draft deletion.

Transaction policy: every mutation runs inside ONE
``BaseService.transaction()`` (services are not nestable — an inner
commit would break atomicity). The inventory receipt/reversal helpers
on ``InventoryService`` therefore run WITHOUT opening their own
transaction; the supplier ledger and status flip commit together with
stock, movements and audit (decision record §16).

State machine: draft -> received -> cancelled.
- draft: editable, hard-deletable (audited)
- received: immutable; only cancellable (reversal, never deletion)
- cancelled: terminal, immutable
"""

from __future__ import annotations

import math
import uuid
from datetime import datetime, timezone
from decimal import Decimal
from typing import Any

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import (
    BusinessRuleError,
    ConflictError,
    NotFoundError,
    ValidationError,
)
from app.domain.unit_conversions import QTY_QUANTUM, to_decimal
from app.domain.valuation import quantize_money
from app.models.audit import AuditLog
from app.models.enums import AuditAction, PurchaseStatus
from app.models.purchase import Purchase, PurchaseLine
from app.models.supplier_ledger import SupplierLedgerEntry
from app.repositories.catalog import (
    ProductRepository,
    ProductVariantRepository,
    PurchaseUnitRepository,
)
from app.repositories.party import SupplierRepository
from app.repositories.purchase import (
    PurchaseRepository,
    SupplierLedgerEntryRepository,
)
from app.schemas.purchase import (
    PurchaseCreateRequest,
    PurchaseLineRequest,
    PurchaseLineResponse,
    PurchaseListResponse,
    PurchaseResponse,
    PurchaseUpdateRequest,
)
from app.services.base import BaseService
from app.services.inventory import InventoryService

logger = structlog.get_logger(__name__)

VALID_STATUSES = frozenset(s.value for s in PurchaseStatus)


def _generate_invoice_number() -> str:
    """PUR-YYYYMMDD-HHMMSS-mmm-xxxx (Phase 8 INV- pattern, own prefix)."""
    now = datetime.now(timezone.utc)
    suffix = uuid.uuid4().hex[:4]
    return (
        f"PUR-{now.strftime('%Y%m%d-%H%M%S')}-"
        f"{now.microsecond // 1000:03d}-{suffix}"
    )


class PurchaseService(BaseService):
    """Application service for purchase documents."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = PurchaseRepository(db)
        self.suppliers = SupplierRepository(db)
        self.ledger = SupplierLedgerEntryRepository(db)
        self.products = ProductRepository(db)
        self.variants = ProductVariantRepository(db)
        self.units = PurchaseUnitRepository(db)
        self.inventory = InventoryService(db)

    # ── Reads ──────────────────────────────────────────────────────────

    def list(
        self,
        *,
        page: int = 1,
        page_size: int = 20,
        q: str | None = None,
        status: str | None = None,
        supplier_id: uuid.UUID | None = None,
    ) -> PurchaseListResponse:
        if status is not None and status not in VALID_STATUSES:
            raise ValidationError(
                message="Invalid purchase status filter",
                details={"status": status, "allowed": sorted(VALID_STATUSES)},
            )
        rows, total = self.repo.search(
            q=q,
            status=status,
            supplier_id=supplier_id,
            page=page,
            page_size=page_size,
        )
        return PurchaseListResponse(
            items=[to_response(p) for p in rows],
            total=total,
            page=page,
            page_size=page_size,
            pages=max(1, math.ceil(total / page_size)) if page_size else 1,
        )

    def get(self, purchase_id: uuid.UUID) -> Purchase:
        return self.repo.get_by_id_or_none(purchase_id)

    # ── Create ─────────────────────────────────────────────────────────

    def create(
        self,
        request: PurchaseCreateRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> tuple[Purchase, bool]:
        """Create a purchase; ``receive=True`` posts it atomically.

        Idempotency (GATE 18): a repeat ``client_request_id`` returns the
        original document with ``idempotent_replay=True`` and never
        receives stock twice.
        """
        crid = request.client_request_id
        if crid is not None:
            existing = self.repo.find_by_client_request_id(crid)
            if existing is not None:
                logger.info(
                    "purchase_idempotent_replay",
                    client_request_id=crid,
                    purchase_id=str(existing.id),
                )
                return existing, True

        supplier = self.suppliers.get_by_id(request.supplier_id)
        if supplier is None:
            raise NotFoundError(
                message="Supplier not found",
                details={"supplier_id": str(request.supplier_id)},
            )
        lines = self._resolve_lines(request.lines)
        totals = self._compute_totals(lines, request.discount, request.paid)
        invoice_number = _generate_invoice_number()
        device_id = request.device_id
        user_id = actor_id

        try:
            with self.transaction():
                purchase = Purchase(
                    invoice_number=invoice_number,
                    status=PurchaseStatus.DRAFT.value,
                    supplier_id=supplier.id,
                    user_id=user_id,
                    subtotal=float(totals["subtotal"]),
                    discount=float(totals["discount"]),
                    total=float(totals["total"]),
                    paid=float(totals["paid"]),
                    note=request.note,
                    device_id=device_id,
                    client_request_id=crid,
                )
                self.repo.create(purchase)
                for snap in lines:
                    self.db.add(_build_line(purchase.id, snap))
                self.db.flush()
                # The header was constructed in-session, so its `lines`
                # collection still holds the constructor's empty value —
                # reload it from the just-flushed rows before posting.
                self.db.refresh(purchase, ["lines"])

                self._audit(
                    AuditAction.CREATE,
                    entity_id=purchase.id,
                    actor_id=actor_id,
                    details=(
                        f"created purchase {invoice_number} "
                        f"({len(lines)} lines, total {totals['total']})"
                    ),
                )

                if request.receive:
                    self._post_receive(purchase, actor_id=actor_id)
                    purchase_id = purchase.id
                else:
                    purchase_id = purchase.id

            saved = self.repo.get_by_id(purchase_id)
            if saved is None:  # pragma: no cover — commit succeeded
                raise ConflictError(
                    message="Purchase committed but could not be re-read",
                    details={"purchase_id": str(purchase_id)},
                )
            logger.info(
                "purchase_created",
                purchase_id=str(saved.id),
                invoice_number=invoice_number,
                status=saved.status,
                total=str(totals["total"]),
                lines=len(lines),
            )
            return saved, False

        except ConflictError:
            # Unique client_request_id race: another request won — return
            # theirs (Phase 8/9 pattern; failed attempts never consume keys).
            if crid is not None:
                winner = self.repo.find_by_client_request_id(crid)
                if winner is not None:
                    logger.info(
                        "purchase_idempotent_race_replay",
                        client_request_id=crid,
                        purchase_id=str(winner.id),
                    )
                    return winner, True
            raise

    # ── Draft editing ──────────────────────────────────────────────────

    def update(
        self,
        purchase_id: uuid.UUID,
        request: PurchaseUpdateRequest,
        *,
        actor_id: uuid.UUID | None,
    ) -> Purchase:
        """Partial update of a DRAFT purchase (GATE 13).

        Received and cancelled documents are immutable: any PUT returns
        409 (INVALID_PURCHASE_STATE / PURCHASE_ALREADY_CANCELLED).
        ``lines`` (when present) replace the whole line set and the
        snapshots + totals are recomputed.
        """
        updates = request.model_dump(exclude_unset=True)

        with self.transaction():
            purchase = self._lock(purchase_id)
            self._require_editable(purchase)

            if (
                "supplier_id" in updates
                and updates["supplier_id"] != purchase.supplier_id
            ):
                supplier = self.suppliers.get_by_id(updates["supplier_id"])
                if supplier is None:
                    raise NotFoundError(
                        message="Supplier not found",
                        details={"supplier_id": str(updates["supplier_id"])},
                    )
                purchase.supplier_id = supplier.id

            if request.lines is not None:
                lines = self._resolve_lines(request.lines)
                # Replace the whole set through the relationship so the
                # delete-orphan cascade removes old rows and the in-memory
                # collection matches what totals are computed from.
                purchase.lines.clear()
                for snap in lines:
                    purchase.lines.append(_build_line(purchase.id, snap))
            else:
                lines = None  # totals stay anchored on existing lines

            subtotal = self._lines_subtotal(purchase)
            discount = (
                quantize_money(to_decimal(request.discount))
                if request.discount is not None
                else quantize_money(to_decimal(purchase.discount))
            )
            if discount > subtotal:
                raise ValidationError(
                    message="Discount cannot exceed the subtotal",
                    details={
                        "discount": str(discount),
                        "subtotal": str(subtotal),
                    },
                )
            total = quantize_money(subtotal - discount)
            paid = (
                quantize_money(to_decimal(request.paid))
                if request.paid is not None
                else quantize_money(to_decimal(purchase.paid))
            )
            if paid > total:
                raise ValidationError(
                    message="Paid amount cannot exceed the total",
                    details={"paid": str(paid), "total": str(total)},
                )

            purchase.subtotal = float(subtotal)
            purchase.discount = float(discount)
            purchase.total = float(total)
            purchase.paid = float(paid)
            if "note" in updates:
                purchase.note = request.note
            if "device_id" in updates:
                purchase.device_id = request.device_id

            self._audit(
                AuditAction.UPDATE,
                entity_id=purchase.id,
                actor_id=actor_id,
                details=(
                    "updated draft "
                    + ", ".join(sorted(updates))
                    + (f" ({len(lines)} lines)" if lines is not None else "")
                ),
            )
            self.db.flush()

        logger.info(
            "purchase_updated",
            purchase_id=str(purchase_id),
            fields=sorted(updates),
        )
        return self.repo.get_by_id_or_none(purchase_id)

    # ── Receive / cancel / delete ──────────────────────────────────────

    def receive(
        self, purchase_id: uuid.UUID, *, actor_id: uuid.UUID | None
    ) -> Purchase:
        """draft -> received: ONE atomic transaction (§16).

        The FOR UPDATE row lock + state guard IS the receive
        idempotency (GATE 18): a duplicate request waits, then returns
        409 PURCHASE_ALREADY_RECEIVED — stock is never increased twice.
        """
        with self.transaction():
            purchase = self._lock(purchase_id)
            invoice_number = purchase.invoice_number
            self._post_receive(purchase, actor_id=actor_id)
        logger.info(
            "purchase_received",
            purchase_id=str(purchase_id),
            invoice_number=invoice_number,
        )
        return self.repo.get_by_id_or_none(purchase_id)

    def cancel(
        self, purchase_id: uuid.UUID, *, actor_id: uuid.UUID | None
    ) -> Purchase:
        """received -> cancelled: symmetric reversal transaction.

        Stock -base qty (movements ``purchase_delete``), packaging
        reduced, payable reversed CAPPED at the current balance (§13 —
        shortfall recorded in the ledger note, never a silent clamp),
        PMP untouched (GATE 12).
        """
        with self.transaction():
            purchase = self._lock(purchase_id)
            invoice_number = purchase.invoice_number
            self._post_cancel(purchase, actor_id=actor_id)
        logger.info(
            "purchase_cancelled",
            purchase_id=str(purchase_id),
            invoice_number=invoice_number,
        )
        return self.repo.get_by_id_or_none(purchase_id)

    def delete(
        self, purchase_id: uuid.UUID, *, actor_id: uuid.UUID | None
    ) -> None:
        """Hard-delete a DRAFT only (Phase 0 rule 4, audited).

        Received documents are never deleted — cancel is the reversible
        replacement; cancelled documents are terminal.
        """
        with self.transaction():
            purchase = self._lock(purchase_id)
            invoice_number = purchase.invoice_number
            if purchase.status == PurchaseStatus.CANCELLED.value:
                raise ConflictError(
                    message="Cancelled purchases are never deleted",
                    code="PURCHASE_ALREADY_CANCELLED",
                    details={"purchase_id": str(purchase_id)},
                )
            if purchase.status != PurchaseStatus.DRAFT.value:
                raise ConflictError(
                    message=(
                        "Received purchases cannot be deleted — cancel "
                        "them instead"
                    ),
                    code="INVALID_PURCHASE_STATE",
                    details={
                        "purchase_id": str(purchase_id),
                        "status": purchase.status,
                    },
                )
            self._audit(
                AuditAction.DELETE,
                entity_id=purchase.id,
                actor_id=actor_id,
                details=f"deleted draft {invoice_number}",
            )
            self.repo.delete(purchase)
        logger.info(
            "purchase_deleted",
            purchase_id=str(purchase_id),
            invoice_number=invoice_number,
        )

    # ── Internals: posting ─────────────────────────────────────────────

    def _post_receive(
        self, purchase: Purchase, *, actor_id: uuid.UUID | None
    ) -> None:
        """Draft -> received posting. Caller owns the transaction."""
        self._require_status(
            purchase,
            expected=PurchaseStatus.DRAFT.value,
            operation="receive",
        )
        self._assert_totals(purchase)

        supplier = self.suppliers.get_for_update(purchase.supplier_id)
        if supplier is None:  # pragma: no cover — FK guarantees existence
            raise NotFoundError(
                message="Supplier not found",
                details={"supplier_id": str(purchase.supplier_id)},
            )

        summaries = self.inventory.receive_purchase(
            purchase,
            user_id=actor_id,
            device_id=purchase.device_id,
        )

        unpaid = quantize_money(
            to_decimal(purchase.total) - to_decimal(purchase.paid)
        )
        if unpaid > 0:
            balance = quantize_money(to_decimal(supplier.balance))
            self.db.add(
                SupplierLedgerEntry(
                    supplier_id=supplier.id,
                    entry_type="purchase",
                    amount=unpaid,
                    reference_purchase_id=purchase.id,
                    note=f"Purchase {purchase.invoice_number}",
                    user_id=actor_id,
                )
            )
            supplier.balance = float(quantize_money(balance + unpaid))

        purchase.status = PurchaseStatus.RECEIVED.value
        purchase.received_at = datetime.now(timezone.utc)
        self._audit(
            AuditAction.RECEIVE,
            entity_id=purchase.id,
            actor_id=actor_id,
            details=(
                f"received {purchase.invoice_number}: "
                f"{len(summaries)} lines, payable +{unpaid}"
            ),
        )
        self.db.flush()

    def _post_cancel(
        self, purchase: Purchase, *, actor_id: uuid.UUID | None
    ) -> None:
        """received -> cancelled reversal. Caller owns the transaction."""
        self._require_status(
            purchase,
            expected=PurchaseStatus.RECEIVED.value,
            operation="cancel",
        )
        self._assert_totals(purchase)

        supplier = self.suppliers.get_for_update(purchase.supplier_id)
        if supplier is None:  # pragma: no cover — FK guarantees existence
            raise NotFoundError(
                message="Supplier not found",
                details={"supplier_id": str(purchase.supplier_id)},
            )

        summaries = self.inventory.reverse_purchase(
            purchase,
            user_id=actor_id,
            device_id=purchase.device_id,
        )

        # Payable reversal capped at the current balance (§13): pooled
        # balance may already have been settled by later payments —
        # the shortfall is explicit in the note, never a silent clamp.
        unpaid = quantize_money(
            to_decimal(purchase.total) - to_decimal(purchase.paid)
        )
        balance = quantize_money(to_decimal(supplier.balance))
        reverse = min(unpaid, balance)
        if reverse > 0:
            note = f"Purchase {purchase.invoice_number} cancelled"
            shortfall = quantize_money(unpaid - reverse)
            if shortfall > 0:
                note = (
                    f"{note} (shortfall {shortfall} already settled "
                    f"by later payments)"
                )
            self.db.add(
                SupplierLedgerEntry(
                    supplier_id=supplier.id,
                    entry_type="purchase_cancel",
                    amount=reverse,
                    reference_purchase_id=purchase.id,
                    note=note,
                    user_id=actor_id,
                )
            )
            supplier.balance = float(quantize_money(balance - reverse))

        # Reconciliation (§13): cached balance must equal Σ ledger entries.
        # Flush first — sessions may run with autoflush off, and the SQL
        # projection must see the just-appended cancel entry.
        self.db.flush()
        expected = quantize_money(
            self.ledger.ledger_sum_for_supplier(supplier.id)
        )
        actual = quantize_money(to_decimal(supplier.balance))
        if expected != actual:
            raise ConflictError(
                message="Supplier ledger/balance mismatch after cancellation",
                details={
                    "supplier_id": str(supplier.id),
                    "ledger_sum": str(expected),
                    "balance": str(actual),
                },
            )

        purchase.status = PurchaseStatus.CANCELLED.value
        purchase.cancelled_at = datetime.now(timezone.utc)
        self._audit(
            AuditAction.VOID,
            entity_id=purchase.id,
            actor_id=actor_id,
            details=(
                f"cancelled {purchase.invoice_number}: "
                f"{len(summaries)} lines reversed, payable -{reverse}"
            ),
        )
        self.db.flush()

    # ── Internals: guards / validation ─────────────────────────────────

    def _lock(self, purchase_id: uuid.UUID) -> Purchase:
        purchase = self.repo.get_for_update(purchase_id)
        if purchase is None:
            raise NotFoundError(
                message="Purchase not found",
                details={"purchase_id": str(purchase_id)},
            )
        return purchase

    @staticmethod
    def _require_status(
        purchase: Purchase, *, expected: str, operation: str
    ) -> None:
        status = purchase.status
        if status == expected:
            return
        if operation == "receive":
            if status == PurchaseStatus.RECEIVED.value:
                raise ConflictError(
                    message="Purchase already received",
                    code="PURCHASE_ALREADY_RECEIVED",
                    details={"purchase_id": str(purchase.id)},
                )
            if status == PurchaseStatus.CANCELLED.value:
                raise ConflictError(
                    message="Cancelled purchases are never re-received",
                    code="PURCHASE_ALREADY_CANCELLED",
                    details={"purchase_id": str(purchase.id)},
                )
        else:  # cancel
            if status == PurchaseStatus.CANCELLED.value:
                raise ConflictError(
                    message="Purchase already cancelled",
                    code="PURCHASE_ALREADY_CANCELLED",
                    details={"purchase_id": str(purchase.id)},
                )
            if status == PurchaseStatus.DRAFT.value:
                raise ConflictError(
                    message="Draft purchases are deleted, not cancelled",
                    code="INVALID_PURCHASE_STATE",
                    details={
                        "purchase_id": str(purchase.id),
                        "status": status,
                    },
                )
        raise ConflictError(
            message=f"Purchase cannot be {operation}ed in status {status}",
            code="INVALID_PURCHASE_STATE",
            details={"purchase_id": str(purchase.id), "status": status},
        )

    @staticmethod
    def _require_editable(purchase: Purchase) -> None:
        if purchase.status == PurchaseStatus.RECEIVED.value:
            raise ConflictError(
                message="Received purchases are immutable — cancel instead",
                code="INVALID_PURCHASE_STATE",
                details={
                    "purchase_id": str(purchase.id),
                    "status": purchase.status,
                },
            )
        if purchase.status == PurchaseStatus.CANCELLED.value:
            raise ConflictError(
                message="Cancelled purchases are immutable",
                code="PURCHASE_ALREADY_CANCELLED",
                details={"purchase_id": str(purchase.id)},
            )

    @staticmethod
    def _assert_totals(purchase: Purchase) -> None:
        """Re-assert stored header totals against persisted lines (§16)."""
        subtotal = sum(
            (to_decimal(ln.line_total) for ln in purchase.lines),
            Decimal("0"),
        )
        expected_subtotal = quantize_money(subtotal)
        stored_subtotal = quantize_money(to_decimal(purchase.subtotal))
        expected_total = quantize_money(
            expected_subtotal - to_decimal(purchase.discount)
        )
        stored_total = quantize_money(to_decimal(purchase.total))
        if expected_subtotal != stored_subtotal or expected_total != stored_total:
            raise ConflictError(
                message="Purchase totals are inconsistent with its lines",
                details={
                    "purchase_id": str(purchase.id),
                    "subtotal": f"{stored_subtotal}/{expected_subtotal}",
                    "total": f"{stored_total}/{expected_total}",
                },
            )

    @staticmethod
    def _lines_subtotal(purchase: Purchase) -> Decimal:
        return quantize_money(
            sum(
                (to_decimal(ln.line_total) for ln in purchase.lines),
                Decimal("0"),
            )
        )

    @staticmethod
    def _compute_totals(
        lines: list[dict[str, Any]],
        discount: Decimal,
        paid: Decimal,
    ) -> dict[str, Decimal]:
        subtotal = quantize_money(
            sum((ln["line_total"] for ln in lines), Decimal("0"))
        )
        disc = quantize_money(to_decimal(discount))
        if disc > subtotal:
            raise ValidationError(
                message="Discount cannot exceed the subtotal",
                details={"discount": str(disc), "subtotal": str(subtotal)},
            )
        total = quantize_money(subtotal - disc)
        paid_amount = quantize_money(to_decimal(paid))
        if paid_amount > total:
            raise ValidationError(
                message="Paid amount cannot exceed the total",
                details={"paid": str(paid_amount), "total": str(total)},
            )
        return {
            "subtotal": subtotal,
            "discount": disc,
            "total": total,
            "paid": paid_amount,
        }

    def _resolve_lines(
        self, request_lines: list[PurchaseLineRequest]
    ) -> list[dict[str, Any]]:
        """Validate each line and build its persistence snapshot.

        Raises structured errors (NOT_FOUND for missing products,
        PURCHASE_LINE_INVALID for archived/invalid targets) before any
        row is written. Snapshots mirror GATE 15: name/SKU/unit/cost are
        frozen at document time.
        """
        resolved: list[dict[str, Any]] = []
        for idx, req in enumerate(request_lines):
            product = self.products.get_by_id(req.product_id)
            if product is None:
                raise NotFoundError(
                    message="Product not found on purchase line",
                    details={"line": idx, "product_id": str(req.product_id)},
                )
            if product.archived_at is not None:
                raise BusinessRuleError(
                    message="Purchase lines cannot reference archived products",
                    code="PURCHASE_LINE_INVALID",
                    details={"line": idx, "product_id": str(product.id)},
                )

            variant = None
            if req.variant_id is not None:
                variant = self.variants.get_by_id(req.variant_id)
                if (
                    variant is None
                    or variant.product_id != product.id
                    or variant.archived_at is not None
                ):
                    raise BusinessRuleError(
                        message="Purchase line references an invalid variant",
                        code="PURCHASE_LINE_INVALID",
                        details={"line": idx, "variant_id": str(req.variant_id)},
                    )

            unit = None
            if req.purchase_unit_id is not None:
                unit = self.units.get_by_id(req.purchase_unit_id)
                if (
                    unit is None
                    or unit.product_id != product.id
                    or unit.archived_at is not None
                    or to_decimal(unit.multiplier) <= 0
                ):
                    raise BusinessRuleError(
                        message="Purchase line has an invalid purchase unit",
                        code="PURCHASE_LINE_INVALID",
                        details={
                            "line": idx,
                            "purchase_unit_id": str(req.purchase_unit_id),
                        },
                    )

            qty = to_decimal(req.quantity)
            cost = to_decimal(req.unit_cost)
            if unit is not None and qty != qty.to_integral_value():
                # Whole packages only (Phase 6 receive_packages constraint) —
                # rejected at draft time, not deferred to receive time.
                raise BusinessRuleError(
                    message="Package lines must be whole packages",
                    code="PURCHASE_LINE_INVALID",
                    details={"line": idx, "quantity": str(qty)},
                )
            multiplier = to_decimal(unit.multiplier) if unit else Decimal("1")
            base_qty = (qty * multiplier).quantize(QTY_QUANTUM)

            name = product.name
            sku = product.sku
            barcode = product.barcode
            if variant is not None:
                name = f"{product.name} ({variant.name})"
                sku = variant.sku or sku
                barcode = variant.barcode or barcode

            resolved.append(
                {
                    "product_id": product.id,
                    "variant_id": variant.id if variant else None,
                    "product_name": name,
                    "product_sku": sku,
                    "product_barcode": barcode,
                    "product_unit": product.unit,
                    "purchase_unit_id": unit.id if unit else None,
                    "purchase_unit_name": unit.name if unit else None,
                    "unit_multiplier": multiplier if unit else None,
                    "quantity": qty,
                    "unit_cost": cost,
                    "base_qty_equivalent": base_qty,
                    "line_total": quantize_money(qty * cost),
                }
            )
        return resolved

    # ── Audit ──────────────────────────────────────────────────────────

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        """Append an audit row inside the current transaction."""
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="purchase",
                entity_id=entity_id,
                details=details,
            )
        )


# ── Mapping helpers ─────────────────────────────────────────────────────


def _build_line(purchase_id: uuid.UUID, snap: dict[str, Any]) -> PurchaseLine:
    return PurchaseLine(
        purchase_id=purchase_id,
        product_id=snap["product_id"],
        variant_id=snap["variant_id"],
        product_name=snap["product_name"],
        product_sku=snap["product_sku"],
        product_barcode=snap["product_barcode"],
        product_unit=snap["product_unit"],
        unit_cost=float(snap["unit_cost"]),
        quantity=float(snap["quantity"]),
        line_total=float(snap["line_total"]),
        purchase_unit_id=snap["purchase_unit_id"],
        purchase_unit_name=snap["purchase_unit_name"],
        unit_multiplier=snap["unit_multiplier"],
        base_qty_equivalent=snap["base_qty_equivalent"],
    )


def to_response(
    purchase: Purchase, *, idempotent_replay: bool = False
) -> PurchaseResponse:
    """Map a purchase header + lines onto the API response."""
    supplier_name = (
        purchase.supplier.name if purchase.supplier is not None else None
    )
    return PurchaseResponse(
        id=purchase.id,
        invoice_number=purchase.invoice_number,
        status=purchase.status,
        supplier_id=purchase.supplier_id,
        supplier_name=supplier_name,
        user_id=purchase.user_id,
        subtotal=quantize_money(to_decimal(purchase.subtotal)),
        discount=quantize_money(to_decimal(purchase.discount)),
        total=quantize_money(to_decimal(purchase.total)),
        paid=quantize_money(to_decimal(purchase.paid)),
        note=purchase.note,
        device_id=purchase.device_id,
        client_request_id=purchase.client_request_id,
        purchase_date=purchase.purchase_date,
        received_at=purchase.received_at,
        cancelled_at=purchase.cancelled_at,
        created_at=purchase.created_at,
        updated_at=purchase.updated_at,
        lines=[
            PurchaseLineResponse(
                id=ln.id,
                product_id=ln.product_id,
                variant_id=ln.variant_id,
                product_name=ln.product_name,
                product_sku=ln.product_sku,
                product_barcode=ln.product_barcode,
                product_unit=ln.product_unit,
                purchase_unit_id=ln.purchase_unit_id,
                purchase_unit_name=ln.purchase_unit_name,
                unit_multiplier=(
                    to_decimal(ln.unit_multiplier)
                    if ln.unit_multiplier is not None
                    else None
                ),
                quantity=to_decimal(ln.quantity),
                unit_cost=quantize_money(to_decimal(ln.unit_cost)),
                base_qty_equivalent=(
                    to_decimal(ln.base_qty_equivalent)
                    if ln.base_qty_equivalent is not None
                    else None
                ),
                line_total=quantize_money(to_decimal(ln.line_total)),
            )
            for ln in purchase.lines
        ],
        idempotent_replay=idempotent_replay,
    )
