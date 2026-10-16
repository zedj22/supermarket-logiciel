"""Zakat application service.

Operations:

- ``context``           GET  /zakat/context   — screen seed + imports
- ``calculate``         POST /zakat/calculate — stateless preview
- ``save``              POST /zakat           — immutable snapshot
- ``list``              GET  /zakat           — history
- ``get``               GET  /zakat/{id}      — one snapshot
- ``record_payment``    POST /zakat/{id}/payment
- ``pdf``               GET  /zakat/{id}/pdf  — snapshot report
- ``pdf_for_request``   POST /zakat/pdf       — ad-hoc preview report

Hard rules:

- The server is the only place the formula runs; the client never
  multiplies.  All math goes through ``app.domain.zakat`` (Decimal).
- Nothing here writes to sales / inventory / accounting / POS tables:
  the only writes are the two zakat tables plus the audit log.
- A saved calculation is immutable.  Corrections are a new snapshot.
- Payments are a separate append-only record; a payment never edits the
  snapshot's numbers.
"""

from __future__ import annotations

import math
import uuid
from datetime import date, datetime, timezone
from decimal import Decimal

import structlog
from sqlalchemy.orm import Session

from app.core.exceptions import ConflictError, NotFoundError
from app.domain.unit_conversions import to_decimal
from app.domain.zakat import (
    HAWL_DAYS,
    NISAB_GOLD_GRAMS,
    OFFICIAL_NISAB_REFERENCE,
    ZAKAT_RATE,
    InventoryRow,
    LineItem,
    ZakatResult,
    calculate_zakat,
)
from app.models.audit import AuditLog
from app.models.catalog import Product
from app.models.enums import AuditAction
from app.models.zakat import ZakatCalculation, ZakatPayment
from app.printing.labels import CURRENCY, is_rtl, label
from app.printing.render import render_report_pdf
from app.printing.templates.report_table import ReportTableBlock, ReportTableInput
from app.printing.text import group_thousands
from app.repositories.zakat import ZakatPaymentRepository, ZakatRepository
from app.schemas.common import PaginatedResponse
from app.schemas.zakat import (
    INVENTORY_LINES_LIMIT,
    OfficialNisabReference,
    ZakatCalculationCreateRequest,
    ZakatCalculationDetail,
    ZakatCalculationSummary,
    ZakatCalculateRequest,
    ZakatCalculateResponse,
    ZakatContext,
    ZakatContextInventory,
    ZakatContextLiabilities,
    ZakatContextReceivables,
    ZakatDebtor,
    ZakatDefaults,
    ZakatInventoryLine,
    ZakatPayable,
    ZakatPaymentCreateRequest,
    ZakatPaymentResponse,
    ZakatResultResponse,
    ZakatWarningModel,
)
from app.services.base import BaseService
from app.services.settings import SettingsService

logger = structlog.get_logger(__name__)

LOCALES = ("ar", "fr", "en")
DEFAULT_LOCALE = "ar"


def _money(value: Decimal | None) -> str:
    """Money cell for the report PDF: space-grouped thousands + DA suffix.

    Presentation only — the snapshot rows keep the raw dot-decimal strings.
    """
    if value is None:
        return "—"
    return f"{group_thousands(str(value))} {CURRENCY}"


def _yes_no(value: bool | None, locale: str) -> str:
    if value is None:
        return label("zakat_unknown", locale)
    return label("zakat_yes" if value else "zakat_no", locale)


def to_result_response(result: ZakatResult) -> ZakatResultResponse:
    return ZakatResultResponse(
        zakat_date=result.zakat_date,
        status=result.status,
        missing_fields=list(result.missing_fields),
        warnings=[
            ZakatWarningModel(code=w.code, detail=dict(w.detail)) for w in result.warnings
        ],
        hawl_start_date=result.hawl_start_date,
        hawl_days_elapsed=result.hawl_days_elapsed,
        hawl_completed=result.hawl_completed,
        gold_price_per_gram=result.gold_price_per_gram,
        nisab_amount=result.nisab_amount,
        nisab_source=result.nisab_source,
        inventory_basis=result.inventory_basis,
        inventory_value=result.inventory_value,
        inventory_source=result.inventory_source,
        inventory_imported_value=result.inventory_imported_value,
        inventory_excluded_value=result.inventory_excluded_value,
        inventory_product_count=result.inventory_product_count,
        inventory_included_count=result.inventory_included_count,
        cash_provided=result.cash_provided,
        cash_total=result.cash_total,
        cash_item_count=result.cash_item_count,
        collectible_receivables=result.collectible_receivables,
        doubtful_receivables=result.doubtful_receivables,
        other_receivables_total=result.other_receivables_total,
        receivables_included_total=result.receivables_included_total,
        receivable_item_count=result.receivable_item_count,
        debt_treatment=result.debt_treatment,
        liabilities_total_entered=result.liabilities_total_entered,
        deductions_applied=result.deductions_applied,
        liabilities_skipped_amount=result.liabilities_skipped_amount,
        liabilities_skipped_count=result.liabilities_skipped_count,
        liability_item_count=result.liability_item_count,
        net_zakatable=result.net_zakatable,
        zakat_rate=result.zakat_rate,
        zakat_due=result.zakat_due,
        provisional_zakat_due=result.provisional_zakat_due,
        reaches_nisab=result.reaches_nisab,
        eligibility_reasons=list(result.eligibility_reasons),
    )


def to_payment_response(payment: ZakatPayment) -> ZakatPaymentResponse:
    return ZakatPaymentResponse(
        id=payment.id,
        calculation_id=payment.calculation_id,
        amount=to_decimal(payment.amount),
        method=payment.method,
        paid_at=payment.paid_at,
        note=payment.note,
        created_by=payment.created_by,
        created_at=payment.created_at,
    )


def _result_from_row(row: ZakatCalculation) -> ZakatResultResponse:
    payload = dict(row.result or {})
    payload.setdefault("warnings", [])
    payload.setdefault("missing_fields", [])
    payload.setdefault("eligibility_reasons", [])
    return ZakatResultResponse.model_validate(payload)


def to_summary(row: ZakatCalculation) -> ZakatCalculationSummary:
    payments_total = sum(
        (to_decimal(p.amount) for p in row.payments), Decimal("0.000")
    )
    return ZakatCalculationSummary(
        id=row.id,
        zakat_date=row.zakat_date,
        status=row.status,
        net_zakatable=to_decimal(row.net_zakatable),
        zakat_due=to_decimal(row.zakat_due) if row.zakat_due is not None else None,
        provisional_zakat_due=(
            to_decimal(row.provisional_zakat_due)
            if row.provisional_zakat_due is not None
            else None
        ),
        nisab_amount=(
            to_decimal(row.nisab_amount) if row.nisab_amount is not None else None
        ),
        reaches_nisab=row.reaches_nisab,
        hawl_completed=row.hawl_completed,
        payments_total=payments_total,
        notes=row.notes,
        created_by=row.created_by,
        created_at=row.created_at,
    )


def to_detail(row: ZakatCalculation) -> ZakatCalculationDetail:
    summary = to_summary(row)
    return ZakatCalculationDetail(
        **summary.model_dump(),
        result=_result_from_row(row),
        inputs=ZakatCalculateRequest.model_validate(row.inputs or {}),
        payments=[to_payment_response(p) for p in row.payments],
    )


class ZakatService(BaseService):
    """Read-mostly service for the zakat calculator."""

    def __init__(self, db: Session):
        super().__init__(db)
        self.repo = ZakatRepository(db)
        self.payment_repo = ZakatPaymentRepository(db)
        self.settings = SettingsService(db)

    # ------------------------------------------------------------------
    # Context (screen seed)
    # ------------------------------------------------------------------

    def context(self) -> ZakatContext:
        store = self.settings.get()
        products = self.repo.product_valuation_rows()
        market_total = Decimal("0.000")
        cost_total = Decimal("0.000")
        lines: list[ZakatInventoryLine] = []
        for product in products:
            qty = to_decimal(product.quantity)
            market_unit = to_decimal(product.price)
            cost_unit = to_decimal(product.avg_cost)
            market_value = qty * market_unit
            cost_value = qty * cost_unit
            market_total += market_value
            cost_total += cost_value
            if len(lines) < INVENTORY_LINES_LIMIT:
                lines.append(
                    ZakatInventoryLine(
                        product_id=product.id,
                        name=product.name,
                        unit=product.unit,
                        quantity=qty,
                        market_unit_price=market_unit,
                        cost_unit_price=cost_unit,
                        market_value=market_value,
                        cost_value=cost_value,
                    )
                )
        ar_total, debtor_count, debtors = self.repo.ar_summary()
        ap_total, supplier_count, suppliers = self.repo.ap_summary()
        return ZakatContext(
            store_name=store.store_name,
            store_phone=store.store_phone,
            store_address=store.store_address,
            today=date.today(),
            official_nisab_reference=OfficialNisabReference(
                **OFFICIAL_NISAB_REFERENCE  # type: ignore[arg-type]
            ),
            defaults=ZakatDefaults(
                zakat_rate=ZAKAT_RATE,
                hawl_days=HAWL_DAYS,
                nisab_gold_grams=NISAB_GOLD_GRAMS,
                inventory_basis="market",
                debt_treatment="deduct_all",
            ),
            inventory=ZakatContextInventory(
                product_count=len(products),
                total_market_value=market_total,
                total_cost_value=cost_total,
                truncated=len(products) > INVENTORY_LINES_LIMIT,
                lines=lines,
            ),
            receivables_reference=ZakatContextReceivables(
                ledger_total=ar_total,
                debtor_count=debtor_count,
                debtors=[
                    ZakatDebtor(
                        customer_id=c.id,
                        name=c.name,
                        phone=c.phone,
                        balance=to_decimal(c.balance),
                    )
                    for c in debtors
                ],
            ),
            liabilities_reference=ZakatContextLiabilities(
                supplier_balance_total=ap_total,
                supplier_count=supplier_count,
                suppliers=[
                    ZakatPayable(
                        supplier_id=s.id,
                        name=s.name,
                        phone=s.phone,
                        balance=to_decimal(s.balance),
                    )
                    for s in suppliers
                ],
            ),
        )

    # ------------------------------------------------------------------
    # Calculation
    # ------------------------------------------------------------------

    def calculate(self, request: ZakatCalculateRequest) -> ZakatCalculateResponse:
        store = self.settings.get()
        result, _products = self._compute(request)
        return ZakatCalculateResponse(
            store_name=store.store_name,
            generated_at=datetime.now(timezone.utc),
            result=to_result_response(result),
        )

    def _compute(
        self, request: ZakatCalculateRequest
    ) -> tuple[ZakatResult, list[Product]]:
        excluded = {str(pid) for pid in request.excluded_product_ids}
        products: list[Product] = []
        rows: list[InventoryRow] = []
        if request.use_imported_inventory:
            products = self.repo.product_valuation_rows()
            for product in products:
                rows.append(
                    InventoryRow(
                        product_id=str(product.id),
                        name=product.name,
                        quantity=to_decimal(product.quantity),
                        market_unit_price=to_decimal(product.price),
                        cost_unit_price=to_decimal(product.avg_cost),
                        included=str(product.id) not in excluded,
                    )
                )
        ar_total, _count, _debtors = self.repo.ar_summary()
        result = calculate_zakat(
            zakat_date=request.zakat_date,
            hawl_start_date=request.hawl_start_date,
            gold_price_per_gram=request.gold_price_per_gram,
            nisab_override=request.nisab_override,
            inventory_basis=request.inventory_basis,
            inventory_override_value=request.inventory_override_value,
            inventory_override_reason=request.inventory_override_reason,
            inventory_rows=rows,
            inventory_imported=request.use_imported_inventory,
            cash_provided=request.cash_provided,
            cash_items=[
                LineItem(label=i.label, amount=to_decimal(i.amount))
                for i in request.cash_items
            ],
            collectible_receivables=(
                to_decimal(request.collectible_receivables)
                if request.collectible_receivables is not None
                else None
            ),
            doubtful_receivables=(
                to_decimal(request.doubtful_receivables)
                if request.doubtful_receivables is not None
                else None
            ),
            other_receivable_items=[
                LineItem(label=i.label, amount=to_decimal(i.amount))
                for i in request.other_receivable_items
            ],
            debt_treatment=request.debt_treatment,
            liability_items=[
                LineItem(label=i.label, amount=to_decimal(i.amount), due=i.due)
                for i in request.liability_items
            ],
            ledger_receivable_total=ar_total,
        )
        return result, products

    # ------------------------------------------------------------------
    # Save / history
    # ------------------------------------------------------------------

    def save(
        self,
        request: ZakatCalculationCreateRequest,
        *,
        user=None,
        locale: str = DEFAULT_LOCALE,
    ) -> ZakatCalculationDetail:
        actor_id = user.id if user is not None else None
        key = request.client_request_id

        existing = self.repo.find_by_client_request_id(key)
        if existing is not None:
            self._assert_same_payload(existing, request)
            logger.info(
                "zakat_idempotent_replay",
                client_request_id=key,
                calculation_id=str(existing.id),
            )
            return to_detail(existing)

        result, _products = self._compute(request.calculation)
        inputs_payload = request.calculation.model_dump(mode="json")
        try:
            created_id = self._insert(
                request,
                result=result,
                inputs_payload=inputs_payload,
                actor_id=actor_id,
            )
        except ConflictError:
            winner = self.repo.find_by_client_request_id(key)
            if winner is not None:
                self._assert_same_payload(winner, request)
                return to_detail(winner)
            raise

        saved = self.repo.get_by_id(created_id)
        if saved is None:  # pragma: no cover - commit succeeded
            raise ConflictError(
                message="Zakat calculation committed but could not be re-read",
                details={"calculation_id": str(created_id)},
            )
        logger.info(
            "zakat_calculation_saved",
            calculation_id=str(saved.id),
            status=saved.status,
            net_zakatable=str(to_decimal(saved.net_zakatable)),
            zakat_due=(
                str(to_decimal(saved.zakat_due)) if saved.zakat_due is not None else None
            ),
        )
        return to_detail(saved)

    def _insert(
        self,
        request: ZakatCalculationCreateRequest,
        *,
        result: ZakatResult,
        inputs_payload: dict,
        actor_id: uuid.UUID | None,
    ) -> uuid.UUID:
        calc = request.calculation
        with self.transaction():
            row = ZakatCalculation(
                zakat_date=calc.zakat_date,
                hawl_start_date=calc.hawl_start_date,
                hawl_days_elapsed=result.hawl_days_elapsed,
                hawl_completed=result.hawl_completed,
                gold_price_per_gram=result.gold_price_per_gram,
                nisab_amount=result.nisab_amount,
                nisab_source=result.nisab_source,
                inventory_basis=calc.inventory_basis,
                inventory_value=result.inventory_value,
                inventory_override_reason=calc.inventory_override_reason,
                cash_total=result.cash_total,
                collectible_receivables=result.collectible_receivables,
                doubtful_receivables=result.doubtful_receivables,
                other_receivables_total=result.other_receivables_total,
                receivables_included_total=result.receivables_included_total,
                debt_treatment=calc.debt_treatment,
                liabilities_total_entered=result.liabilities_total_entered,
                deductions_applied=result.deductions_applied,
                net_zakatable=result.net_zakatable,
                zakat_rate=result.zakat_rate,
                zakat_due=result.zakat_due,
                provisional_zakat_due=result.provisional_zakat_due,
                reaches_nisab=result.reaches_nisab,
                status=result.status,
                warnings=[
                    {"code": w.code, "detail": dict(w.detail)} for w in result.warnings
                ],
                missing_fields=list(result.missing_fields),
                result=to_result_response(result).model_dump(mode="json"),
                inputs=inputs_payload,
                notes=request.notes,
                created_by=actor_id,
                client_request_id=request.client_request_id,
            )
            self.repo.create(row)
            self._audit(
                AuditAction.CREATE,
                entity_id=row.id,
                actor_id=actor_id,
                details=(
                    f"saved zakat calculation [{row.status}] "
                    f"net={to_decimal(row.net_zakatable)} "
                    f"due={to_decimal(row.zakat_due) if row.zakat_due is not None else 'n/a'}"
                ),
            )
            return row.id

    def list(
        self, *, page: int = 1, page_size: int = 40
    ) -> PaginatedResponse[ZakatCalculationSummary]:
        rows, total = self.repo.page(page=page, page_size=page_size)
        pages = max(1, math.ceil(total / page_size)) if total else 1
        return PaginatedResponse[ZakatCalculationSummary](
            items=[to_summary(row) for row in rows],
            total=total,
            page=page,
            page_size=page_size,
            pages=pages,
        )

    def get(self, calculation_id: uuid.UUID) -> ZakatCalculationDetail:
        row = self.repo.get_by_id(calculation_id)
        if row is None:
            raise self._not_found(calculation_id)
        return to_detail(row)

    # ------------------------------------------------------------------
    # Payments
    # ------------------------------------------------------------------

    def record_payment(
        self,
        calculation_id: uuid.UUID,
        request: ZakatPaymentCreateRequest,
        *,
        user=None,
    ) -> ZakatCalculationDetail:
        actor_id = user.id if user is not None else None

        calculation = self.repo.get_by_id(calculation_id)
        if calculation is None:
            raise self._not_found(calculation_id)

        existing = self.payment_repo.find_by_client_request_id(request.client_request_id)
        if existing is not None:
            if (
                existing.calculation_id != calculation_id
                or to_decimal(existing.amount) != to_decimal(request.amount)
                or existing.method != request.method
            ):
                raise ConflictError(
                    message=(
                        "client_request_id was already used with a different "
                        "zakat payment payload"
                    ),
                    code="IDEMPOTENCY_CONFLICT",
                    details={"client_request_id": request.client_request_id},
                )
            return to_detail(calculation)

        paid_at = request.paid_at or date.today()
        with self.transaction():
            payment = ZakatPayment(
                calculation_id=calculation_id,
                amount=request.amount,
                method=request.method,
                paid_at=paid_at,
                note=request.note,
                created_by=actor_id,
                client_request_id=request.client_request_id,
            )
            self.payment_repo.create(payment)
            self._audit(
                AuditAction.PAYMENT,
                entity_id=payment.id,
                actor_id=actor_id,
                details=(
                    f"recorded zakat payment {to_decimal(payment.amount)} "
                    f"[{payment.method}] for calculation {calculation_id}"
                ),
            )

        self.db.expire_all()
        refreshed = self.repo.get_by_id(calculation_id)
        if refreshed is None:  # pragma: no cover - commit succeeded
            raise self._not_found(calculation_id)
        return to_detail(refreshed)

    # ------------------------------------------------------------------
    # PDF
    # ------------------------------------------------------------------

    def pdf(
        self, calculation_id: uuid.UUID, *, locale: str = DEFAULT_LOCALE
    ) -> tuple[bytes, str]:
        row = self.repo.get_by_id(calculation_id)
        if row is None:
            raise self._not_found(calculation_id)
        result = _result_from_row(row)
        inputs = ZakatCalculateRequest.model_validate(row.inputs or {})
        store = self.settings.get()
        inp = self._report_input(
            result=result,
            inputs=inputs,
            store_name=store.store_name,
            locale=locale,
            notes=row.notes,
            calculation_id=str(row.id),
            created_at=row.created_at,
        )
        return render_report_pdf(inp), self._pdf_filename(row, locale)

    def pdf_for_request(
        self, request: ZakatCalculateRequest, *, locale: str = DEFAULT_LOCALE
    ) -> tuple[bytes, str]:
        result, _products = self._compute(request)
        store = self.settings.get()
        inp = self._report_input(
            result=to_result_response(result),
            inputs=request,
            store_name=store.store_name,
            locale=locale,
            notes=request.notes,
            calculation_id=None,
            created_at=datetime.now(timezone.utc),
        )
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        return render_report_pdf(inp), f"zakat_preview_{stamp}.pdf"

    def _report_input(
        self,
        *,
        result: ZakatResultResponse,
        inputs: ZakatCalculateRequest,
        store_name: str,
        locale: str,
        notes: str | None,
        calculation_id: str | None,
        created_at: datetime,
    ) -> ReportTableInput:
        rtl = is_rtl(locale)
        meta: list[str] = [
            f"{label('zakat_calculation_date', locale)}: {result.zakat_date.isoformat()}",
        ]
        if calculation_id:
            meta.append(f"{label('zakat_reference', locale)}: {calculation_id}")
        if result.hawl_start_date is not None:
            meta.append(
                f"{label('zakat_hawl_start', locale)}: "
                f"{result.hawl_start_date.isoformat()} — "
                f"{label('zakat_hawl_completed', locale)}: "
                f"{_yes_no(result.hawl_completed, locale)}"
            )
        if result.nisab_amount is not None:
            meta.append(
                f"{label('zakat_nisab', locale)}: {_money(result.nisab_amount)} "
                f"({label('zakat_nisab_source_' + (result.nisab_source or 'none'), locale)})"
            )
        meta.append(
            f"{label('zakat_inventory_basis', locale)}: "
            f"{label('zakat_basis_' + result.inventory_basis, locale)}"
        )
        meta.append(
            f"{label('zakat_debt_treatment', locale)}: "
            f"{label('zakat_method_' + result.debt_treatment, locale)}"
        )
        if notes:
            meta.append(f"{label('notes', locale)}: {notes}")

        for warning in result.warnings:
            key = f"zakat_warn_{warning.code.lower()}"
            meta.append(f"{label(key, locale)}")

        assets_rows = [
            [
                label("zakat_row_inventory", locale),
                _money(result.inventory_value),
                label("zakat_basis_" + result.inventory_basis, locale),
            ],
            [
                label("zakat_row_cash", locale),
                _money(result.cash_total),
                label("zakat_source_entered", locale),
            ],
            [
                label("zakat_row_collectible", locale),
                _money(result.collectible_receivables),
                label("zakat_source_entered", locale),
            ],
            [
                label("zakat_row_other_receivables", locale),
                _money(result.other_receivables_total),
                label("zakat_source_entered", locale),
            ],
        ]
        assets_total = sum(
            (
                to_decimal(value)
                for value in (
                    result.inventory_value,
                    result.cash_total,
                    result.collectible_receivables,
                    result.other_receivables_total,
                )
                if value is not None
            ),
            Decimal("0.000"),
        )
        assets_block = ReportTableBlock(
            headers=[
                label("zakat_col_item", locale),
                label("zakat_col_amount", locale),
                label("zakat_col_source", locale),
            ],
            rows=assets_rows,
            totals=[label("zakat_total_assets", locale), _money(assets_total), ""],
        )

        liability_rows: list[list[str]] = []
        for item in inputs.liability_items:
            if item.due is True:
                due_text = label("zakat_due_yes", locale)
            elif item.due is False:
                due_text = label("zakat_due_no", locale)
            else:
                due_text = label("zakat_unknown", locale)
            liability_rows.append([item.label, _money(item.amount), due_text])
        if not liability_rows:
            liability_rows.append(
                [
                    label("zakat_row_no_liabilities", locale),
                    _money(Decimal("0.000")),
                    "",
                ]
            )
        liabilities_block = ReportTableBlock(
            headers=[
                label("zakat_col_item", locale),
                label("zakat_col_amount", locale),
                label("zakat_col_due", locale),
            ],
            rows=liability_rows,
            totals=[
                label("zakat_total_deducted", locale),
                _money(result.deductions_applied),
                label("zakat_method_" + result.debt_treatment, locale),
            ],
        )

        due_label = (
            label("zakat_provisional_due", locale)
            if result.zakat_due is None
            else label("zakat_due_amount", locale)
        )
        due_value = (
            result.provisional_zakat_due
            if result.zakat_due is None
            else result.zakat_due
        )
        result_block = ReportTableBlock(
            headers=[
                label("zakat_col_item", locale),
                label("zakat_col_amount", locale),
                label("zakat_col_note", locale),
            ],
            rows=[
                [
                    label("zakat_net_zakatable", locale),
                    _money(result.net_zakatable),
                    label("zakat_status_" + result.status, locale),
                ],
                [
                    label("zakat_nisab", locale),
                    _money(result.nisab_amount),
                    _yes_no(result.reaches_nisab, locale),
                ],
                [
                    label("zakat_hawl", locale),
                    "",
                    _yes_no(result.hawl_completed, locale),
                ],
                [
                    label("zakat_rate", locale),
                    "2.5%",
                    label("zakat_rate_note", locale),
                ],
                [
                    due_label,
                    _money(due_value),
                    label("zakat_status_" + result.status, locale),
                ],
            ],
        )

        generated = (
            f"{label('generated', locale)}: "
            f"{created_at.isoformat(timespec='seconds')}"
        )
        meta.append(label("zakat_disclaimer", locale))

        return ReportTableInput(
            title=label("zakat_report_title", locale),
            store_name=store_name,
            meta_lines=meta,
            blocks=[assets_block, liabilities_block, result_block],
            landscape=False,
            rtl=rtl,
            locale=locale,
            generated_at=generated,
            empty_message="",
        )

    @staticmethod
    def _pdf_filename(row: ZakatCalculation, locale: str) -> str:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        return f"zakat_{row.zakat_date.isoformat()}_{stamp}.pdf"

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

    @staticmethod
    def _not_found(calculation_id: uuid.UUID) -> NotFoundError:
        return NotFoundError(
            message="Zakat calculation not found",
            code="ZAKAT_CALCULATION_NOT_FOUND",
            details={"calculation_id": str(calculation_id)},
        )

    @staticmethod
    def _request_signature(request: ZakatCalculationCreateRequest) -> tuple:
        return (
            request.calculation.model_dump(mode="json"),
            request.notes,
        )

    @classmethod
    def _assert_same_payload(
        cls, existing: ZakatCalculation, request: ZakatCalculationCreateRequest
    ) -> None:
        if cls._request_signature(request) != (
            existing.inputs,
            existing.notes,
        ):
            raise ConflictError(
                message=(
                    "client_request_id was already used with a different "
                    "zakat calculation"
                ),
                code="IDEMPOTENCY_CONFLICT",
                details={"client_request_id": request.client_request_id},
            )

    def _audit(
        self,
        action: AuditAction,
        *,
        entity_id: uuid.UUID,
        actor_id: uuid.UUID | None,
        details: str = "",
    ) -> None:
        self.db.add(
            AuditLog(
                user_id=actor_id,
                action=action.value,
                entity_type="zakat",
                entity_id=entity_id,
                details=details,
            )
        )
