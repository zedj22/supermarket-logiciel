"""Print service (Phase 15 §7, §12, §16).

Renders a sale / return as PDF bytes (80 mm thermal receipt or A4)
from the same response payloads the API already serves. Display names
the payloads do not carry (return customer + cashier) are looked
up here — builders stay DB-free (G19). Purchase printing is deferred
(Step A scope): ``document_type`` is allowlisted to sale/return at the
schema boundary, so no purchase path exists here.

Barcode labels (barcode-label subphase): ``render_labels`` resolves the
selected products, their effective prices (same promotion domain
function as checkout — one source of truth) and the store identity, then
hands a list of ``PriceLabel`` rows to the DB-free renderer. Audit keeps
its one-row-per-attempt contract for both paths; the label row uses
``entity_type="product_label"``.

Audit (§12.2): exactly one ``print`` row per attempt with paper, locale,
bytes, duration and the result/error code. The service returns bytes +
filename; the endpoint owns the HTTP ``Response``.
"""

from __future__ import annotations

import json
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from decimal import Decimal

import structlog
from sqlalchemy import select

from app.core.config import settings
from app.core.exceptions import AppError, NotFoundError, ValidationError
from app.core.filenames import sanitize_filename
from app.models.audit import AuditLog
from app.models.catalog import Product
from app.models.enums import AuditAction
from app.models.party import Customer
from app.models.user import User
from app.printing.document_data import (
    DocumentData,
    DocumentNames,
    StoreBlock,
    build_return_document,
    build_sale_document,
)
from app.printing.price_labels import PriceLabel, render_price_labels
from app.printing.render import render_invoice
from app.schemas.export import LabelPrintRequest, PrintRequest
from app.schemas.returns import ReturnResponse
from app.schemas.sale import SaleResponse
from app.services.base import BaseService
from app.services.promotions import PromotionService
from app.services.returns import ReturnService
from app.services.sale import SaleService
from app.services.settings import SettingsService

logger = structlog.get_logger(__name__)


@dataclass
class PrintResult:
    filename: str
    media_type: str
    data: bytes
    document_number: str
    duration_ms: int


class PrintService(BaseService):
    def render(
        self,
        req: PrintRequest,
        *,
        user_id: uuid.UUID | None,
        ip_address: str | None = None,
        device_id: str | None = None,
    ) -> PrintResult:
        started = time.perf_counter()
        audit_device = device_id or req.device_id
        document_number = ""
        try:
            data, document_number = self._build(req)
            pdf = self._guard_render(lambda: render_invoice(data, req.paper))
            if not pdf:
                raise AppError(
                    "Print rendering produced no output",
                    {"document_type": req.document_type},
                    code="PRINT_RENDER_FAILED",
                    status_code=500,
                    message_key="print_render_failed",
                )
            filename = self._filename(req, document_number)
        except AppError as exc:
            self._audit(
                req,
                user_id=user_id,
                ip_address=ip_address,
                device_id=audit_device,
                result="failure",
                error_code=exc.code,
                duration_ms=_ms(started),
                size=0,
                document_number=document_number,
                filename=None,
            )
            raise
        except Exception:
            self._audit(
                req,
                user_id=user_id,
                ip_address=ip_address,
                device_id=audit_device,
                result="failure",
                error_code="INTERNAL_ERROR",
                duration_ms=_ms(started),
                size=0,
                document_number=document_number,
                filename=None,
            )
            raise

        duration_ms = _ms(started)
        self._audit(
            req,
            user_id=user_id,
            ip_address=ip_address,
            device_id=audit_device,
            result="success",
            error_code=None,
            duration_ms=duration_ms,
            size=len(pdf),
            document_number=document_number,
            filename=filename,
        )
        return PrintResult(
            filename=filename,
            media_type="application/pdf",
            data=pdf,
            document_number=document_number,
            duration_ms=duration_ms,
        )

    # ------------------------------------------------------------------
    # Document loading + view-model assembly
    # ------------------------------------------------------------------

    def _build(self, req: PrintRequest) -> tuple[DocumentData, str]:
        if req.document_type == "sale":
            sale: SaleResponse = SaleService(self.db).get_sale(req.document_id)
            return (
                self._with_store_identity(
                    build_sale_document(sale, locale=req.locale)
                ),
                sale.invoice_number,
            )
        if req.document_type == "return":
            ret: ReturnResponse = ReturnService(self.db).get(req.document_id)
            names = DocumentNames(
                customer=self._customer_name(ret.customer_id),
                cashier=self._user_name(ret.user_id),
            )
            return (
                self._with_store_identity(
                    build_return_document(ret, locale=req.locale, names=names)
                ),
                ret.return_number,
            )
        # ``document_type`` is allowlisted to sale/return at the schema
        # boundary (purchase printing deferred from Phase 15) — unreachable,
        # kept as a defensive guard so a future leak fails loudly.
        raise AppError(
            "Unsupported document type",
            {"document_type": req.document_type},
            code="PRINT_RENDER_FAILED",
            status_code=500,
            message_key="print_render_failed",
        )

    def _with_store_identity(self, data: DocumentData) -> DocumentData:
        """Stamp the receipt header with the stored store identity (§17.6).

        The builders are deliberately DB-free (G19), so the print path is
        where ``app_settings`` is read: name, phone, address and the
        invoice footer the owner typed into Settings.  ``SettingsService``
        never writes, so an install that has never saved Settings renders
        exactly what it rendered before — ``STORE_NAME`` from ``.env`` and
        no contact block.
        """
        row = SettingsService(self.db).get()
        data.store = StoreBlock(
            name=row.store_name or settings.STORE_NAME,
            phone=_present(row.store_phone),
            address=_present(row.store_address),
            footer=_present(row.invoice_footer),
        )
        return data

    def _customer_name(self, customer_id: uuid.UUID | None) -> str | None:
        if customer_id is None:
            return None
        row = self.db.get(Customer, customer_id)
        return row.name if row is not None else None

    def _user_name(self, user_id: uuid.UUID | None) -> str | None:
        if user_id is None:
            return None
        row = self.db.get(User, user_id)
        return row.full_name if row is not None else None

    @staticmethod
    def _guard_render(fn) -> bytes:  # noqa: ANN001 - zero-arg renderer
        """Map renderer failures to PRINT_RENDER_FAILED (§12.2).

        AppError passes through untouched so `MISSING_FONT` keeps its
        documented code.
        """
        try:
            return fn()
        except AppError:
            raise
        except Exception as exc:  # noqa: BLE001 - §12.2 render catch-all
            raise AppError(
                "Print rendering failed",
                {"error": str(exc)},
                code="PRINT_RENDER_FAILED",
                status_code=500,
                message_key="print_render_failed",
            ) from exc

    @staticmethod
    def _filename(req: PrintRequest, document_number: str) -> str:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
        return sanitize_filename(f"{req.document_type}_{document_number}_{stamp}.pdf")

    # ------------------------------------------------------------------
    # Audit (§12.2)
    # ------------------------------------------------------------------

    def _audit(
        self,
        req: PrintRequest,
        *,
        user_id: uuid.UUID | None,
        ip_address: str | None,
        device_id: str | None,
        result: str,
        error_code: str | None,
        duration_ms: int,
        size: int,
        document_number: str,
        filename: str | None,
    ) -> None:
        details = {
            "document_type": req.document_type,
            "document_number": document_number,
            "paper": req.paper,
            "locale": req.locale,
            "bytes": size,
            "duration_ms": duration_ms,
            "filename": filename,
            "result": result,
            "error_code": error_code,
        }
        self._write_audit(
            user_id=user_id,
            ip_address=ip_address,
            device_id=device_id,
            entity_type=req.document_type,
            entity_id=req.document_id,
            details=details,
        )

    # ------------------------------------------------------------------
    # Barcode labels (barcode-label subphase)
    # ------------------------------------------------------------------

    def render_labels(
        self,
        req: LabelPrintRequest,
        *,
        user_id: uuid.UUID | None,
        ip_address: str | None = None,
        device_id: str | None = None,
    ) -> PrintResult:
        """Render product price / barcode labels as one PDF batch.

        Effective prices come from ``PromotionService.promotion_info_for``
        — the same domain function POS and catalog display use — so the
        shelf label, the receipt and the product list can never disagree
        on what the customer pays. Audit contract mirrors ``render``:
        exactly one ``print`` row per attempt.
        """
        started = time.perf_counter()
        audit_device = device_id or req.device_id
        try:
            labels = self._build_labels(req)
            pdf = self._guard_render(
                lambda: render_price_labels(
                    labels, req.layout, req.paper, req.locale
                )
            )
            if not pdf:
                raise AppError(
                    "Label rendering produced no output",
                    {"labels": len(labels)},
                    code="PRINT_RENDER_FAILED",
                    status_code=500,
                    message_key="print_render_failed",
                )
            filename = sanitize_filename(
                f"labels_{datetime.now(timezone.utc).strftime('%Y-%m-%d-%H%M%S')}.pdf"
            )
        except AppError as exc:
            self._labels_audit(
                req,
                user_id=user_id,
                ip_address=ip_address,
                device_id=audit_device,
                result="failure",
                error_code=exc.code,
                duration_ms=_ms(started),
                size=0,
                filename=None,
            )
            raise
        except Exception:
            self._labels_audit(
                req,
                user_id=user_id,
                ip_address=ip_address,
                device_id=audit_device,
                result="failure",
                error_code="INTERNAL_ERROR",
                duration_ms=_ms(started),
                size=0,
                filename=None,
            )
            raise

        duration_ms = _ms(started)
        self._labels_audit(
            req,
            user_id=user_id,
            ip_address=ip_address,
            device_id=audit_device,
            result="success",
            error_code=None,
            duration_ms=duration_ms,
            size=len(pdf),
            filename=filename,
        )
        return PrintResult(
            filename=filename,
            media_type="application/pdf",
            data=pdf,
            document_number="",
            duration_ms=duration_ms,
        )

    def _build_labels(self, req: LabelPrintRequest) -> list[PriceLabel]:
        """Resolve products + effective prices into render rows (G19)."""
        ids = [item.product_id for item in req.items]
        rows = list(
            self.db.execute(
                select(Product).where(Product.id.in_(ids))
            ).scalars().all()
        )
        by_id = {product.id: product for product in rows}
        for product_id in ids:
            if product_id not in by_id:
                raise NotFoundError(
                    message="Product not found",
                    details={"product_id": str(product_id)},
                )

        promos = PromotionService(self.db).promotion_info_for(
            {product.id: product.price for product in rows}
        )
        settings_row = SettingsService(self.db).get()
        store_name = settings_row.store_name or settings.STORE_NAME

        labels: list[PriceLabel] = []
        for item in req.items:
            product = by_id[item.product_id]
            barcode = (product.barcode or "").strip() or None
            if barcode is not None and not barcode.isascii():
                # Code128 encodes ASCII only — never substitute another
                # symbology or invent a value (STOP condition).
                raise ValidationError(
                    message="Barcode is not Code128-encodable",
                    details={
                        "product_id": str(product.id),
                        "barcode": barcode,
                    },
                )
            promo = promos.get(product.id)
            retail = _money(product.price)
            effective = _money(promo.price) if promo is not None else retail
            discount = (
                _percent_text(promo.value)
                if promo is not None and promo.promotion_type == "percentage"
                else None
            )
            row = PriceLabel(
                name=product.name,
                barcode=barcode,
                retail=retail,
                price=effective,
                promo=promo is not None,
                unit=product.unit,
                store_name=store_name,
                discount_percent=discount,
            )
            labels.extend([row] * item.quantity)
        return labels

    def _labels_audit(
        self,
        req: LabelPrintRequest,
        *,
        user_id: uuid.UUID | None,
        ip_address: str | None,
        device_id: str | None,
        result: str,
        error_code: str | None,
        duration_ms: int,
        size: int,
        filename: str | None,
    ) -> None:
        details = {
            "document_type": "product_label",
            "products": len(req.items),
            "total_labels": sum(item.quantity for item in req.items),
            "paper": req.paper,
            "locale": req.locale,
            "bytes": size,
            "duration_ms": duration_ms,
            "filename": filename,
            "result": result,
            "error_code": error_code,
        }
        self._write_audit(
            user_id=user_id,
            ip_address=ip_address,
            device_id=device_id,
            entity_type="product_label",
            entity_id=None,
            details=details,
        )

    def _write_audit(
        self,
        *,
        user_id: uuid.UUID | None,
        ip_address: str | None,
        device_id: str | None,
        entity_type: str,
        entity_id: uuid.UUID | None,
        details: dict,
    ) -> None:
        if details.get("result") == "failure":
            self.db.rollback()
        try:
            with self.transaction():
                self.db.add(
                    AuditLog(
                        user_id=user_id,
                        action=AuditAction.PRINT.value,
                        entity_type=entity_type,
                        entity_id=entity_id,
                        details=json.dumps(details, ensure_ascii=True),
                        ip_address=ip_address,
                        device_id=device_id,
                    )
                )
        except Exception:
            if details.get("result") == "failure":
                logger.warning(
                    "print_audit_failed",
                    document_type=details.get("document_type"),
                    error_code=details.get("error_code"),
                )
            else:
                raise


def _ms(started: float) -> int:
    return int((time.perf_counter() - started) * 1000)


def _money(value: object) -> Decimal:
    """Exact decimal for display (never binary-float rounding on labels)."""
    if isinstance(value, Decimal):
        return value
    return Decimal(str(value))


def _percent_text(value: object) -> str:
    """Presentation-only percent text: trailing zeros stripped (`20`,
    `12.5`) — the declared promotion value, never a computed discount."""
    amount = _money(value).normalize()
    if amount == amount.to_integral_value():
        amount = amount.to_integral_value()
    return f"{amount:f}"


def _present(value: object) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    return text or None
