"""Export service (Phase 15 §5, §12, §14, §17–§18).

One row truth, one fetch path: every export calls the SAME
``ReportService`` methods as ``GET /reports/*`` (identical query, filters
and validation), assembles the frozen ``ExportSpec`` contract, then
renders XLSX or report PDF. Row-level reports are page-walked (1 000 rows
per call) behind the §12.2 ``EXPORT_ROW_LIMIT`` cap.

Audit (§12.2): exactly one ``export`` row per attempt — success carries
rows/bytes/duration/filename, failure carries the error code — written in
its own transaction so a failure still leaves its trace.

The service returns bytes + filename; the endpoint owns the HTTP
``Response`` (base service rule).
"""

from __future__ import annotations

import json
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from typing import Any

import structlog

from app.core.exceptions import AppError, ValidationError
from app.core.filenames import sanitize_filename
from app.exporting.contract import (
    EXPORT_ROW_LIMIT,
    REPORT_SLUGS,
    ExportFilters,
    build_spec,
    pdf_blocks,
)
from app.exporting.xlsx import render_xlsx
from app.models.audit import AuditLog
from app.models.enums import AuditAction
from app.printing.labels import is_rtl, label
from app.printing.render import render_report_pdf
from app.printing.templates.report_table import ReportTableBlock, ReportTableInput
from app.schemas.export import ExportRequest
from app.services.base import BaseService
from app.services.report import ReportService

logger = structlog.get_logger(__name__)

WALK_PAGE_SIZE = 1000
MAX_EXPORT_BYTES = 50 * 1024 * 1024  # §12.2 EXPORT_TOO_LARGE byte cap

_XLSX_MEDIA_TYPE = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
_PDF_MEDIA_TYPE = "application/pdf"

# Reports that need an explicit date window (the rest derive it).
_DATE_RANGE_REPORTS = frozenset(
    {"financial", "products", "categories", "daily", "hourly", "voided", "sales", "suppliers"}
)
_SUPPORTED_FORMATS = ("xlsx", "pdf")


def _unsupported(message: str, details: dict[str, Any]) -> AppError:
    return AppError(
        message,
        details,
        code="EXPORT_FORMAT_UNSUPPORTED",
        status_code=422,
        message_key="export_format_unsupported",
    )


@dataclass
class ExportResult:
    filename: str
    media_type: str
    data: bytes
    rows: int
    duration_ms: int


class ExportService(BaseService):
    def __init__(self, db):
        super().__init__(db)
        self.reports = ReportService(db)

    # ------------------------------------------------------------------
    # Public entry
    # ------------------------------------------------------------------

    def export(
        self,
        req: ExportRequest,
        *,
        user_id: uuid.UUID | None,
        ip_address: str | None = None,
        device_id: str | None = None,
    ) -> ExportResult:
        started = time.perf_counter()
        audit_device = device_id or req.device_id
        try:
            payload, filters = self._fetch(req)
            spec = build_spec(req.report, payload, locale=req.locale, filters=filters)
            data, media_type = self._render(req, payload, spec)
            if len(data) > MAX_EXPORT_BYTES:
                raise AppError(
                    "Export exceeds the maximum allowed size",
                    {"bytes": len(data), "limit": MAX_EXPORT_BYTES},
                    code="EXPORT_TOO_LARGE",
                    status_code=413,
                    message_key="export_too_large",
                )
            filename = self._filename(req, filters, ext=req.format.lower())
        except AppError as exc:
            self._audit(
                req,
                user_id=user_id,
                ip_address=ip_address,
                device_id=audit_device,
                result="failure",
                error_code=exc.code,
                duration_ms=_ms(started),
                rows=0,
                size=0,
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
                rows=0,
                size=0,
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
            rows=spec.row_count,
            size=len(data),
            filename=filename,
        )
        return ExportResult(
            filename=filename,
            media_type=media_type,
            data=data,
            rows=spec.row_count,
            duration_ms=duration_ms,
        )

    # ------------------------------------------------------------------
    # Fetch (§5 — same path as GET /reports/*)
    # ------------------------------------------------------------------

    def _validate_request(self, req: ExportRequest) -> None:
        fmt = req.format.lower()
        if fmt not in _SUPPORTED_FORMATS:
            raise _unsupported(
                "Unsupported export format",
                {"format": req.format, "supported": list(_SUPPORTED_FORMATS)},
            )
        if req.report not in REPORT_SLUGS:
            raise _unsupported(
                "Unsupported report",
                {"report": req.report, "supported": list(REPORT_SLUGS)},
            )
        if req.report in _DATE_RANGE_REPORTS and (req.date_from is None or req.date_to is None):
            raise ValidationError(
                message="date_from and date_to are required for this report",
                details={"report": req.report},
            )

    def _fetch(self, req: ExportRequest) -> tuple[Any, ExportFilters]:
        self._validate_request(req)
        svc = self.reports
        date_from, date_to = req.date_from, req.date_to
        device_id = req.device_id
        report = req.report

        if report == "financial":
            payload = svc.financial(date_from=date_from, date_to=date_to, device_id=device_id)
        elif report == "products":
            payload = self._walk(
                lambda page, size: svc.products(
                    date_from=date_from,
                    date_to=date_to,
                    device_id=device_id,
                    sort=req.sort or "net_revenue",
                    page=page,
                    page_size=size,
                )
            )
        elif report == "categories":
            payload = svc.categories(date_from=date_from, date_to=date_to, device_id=device_id)
        elif report == "daily":
            payload = svc.daily(date_from=date_from, date_to=date_to, device_id=device_id)
        elif report == "hourly":
            payload = svc.hourly(date_from=date_from, date_to=date_to, device_id=device_id)
        elif report == "peak-hours":
            payload = svc.peak_hours(
                lookback_days=req.lookback_days if req.lookback_days is not None else 30,
                device_id=device_id,
            )
        elif report == "slow-moving":
            payload = self._walk(
                lambda page, size: svc.slow_moving(
                    days=req.days if req.days is not None else 30,
                    threshold=req.threshold if req.threshold is not None else Decimal("0"),
                    page=page,
                    page_size=size,
                )
            )
        elif report == "voided":
            payload = self._walk(
                lambda page, size: svc.voided(
                    date_from=date_from,
                    date_to=date_to,
                    device_id=device_id,
                    page=page,
                    page_size=size,
                )
            )
        elif report == "sales":
            payload = self._walk(
                lambda page, size: svc.sales(
                    date_from=date_from,
                    date_to=date_to,
                    status=req.status or "completed",
                    payment_method=req.payment_method,
                    user_id=req.user_id,
                    device_id=device_id,
                    page=page,
                    page_size=size,
                )
            )
        else:  # suppliers
            payload = svc.suppliers(date_from=date_from, date_to=date_to)

        return payload, self._filters(req, payload)

    def _walk(self, call: Callable[[int, int], Any]) -> Any:
        """Page a row-level report into one payload behind the row cap."""
        first = call(1, WALK_PAGE_SIZE)
        total = getattr(first, "total", None)
        if total is not None and total > EXPORT_ROW_LIMIT:
            raise AppError(
                f"Export exceeds {EXPORT_ROW_LIMIT} rows",
                {"total": total, "limit": EXPORT_ROW_LIMIT},
                code="EXPORT_ROW_LIMIT",
                status_code=422,
                message_key="export_row_limit",
            )
        items = list(first.items)
        if total is None or len(items) >= total:
            return first
        page = 2
        while len(items) < total:
            nxt = call(page, WALK_PAGE_SIZE)
            if not nxt.items:
                break
            items.extend(nxt.items)
            page += 1
        return first.model_copy(update={"items": items})

    def _filters(self, req: ExportRequest, payload: Any) -> ExportFilters:
        """Echo the request filters; take the period from the payload.

        Peak-hours carries its own window; slow-moving does not, so its
        window is derived from ``days`` (same rule as the service).
        """
        report = req.report
        date_from = getattr(payload, "date_from", None) or req.date_from
        date_to = getattr(payload, "date_to", None) or req.date_to
        if date_from is None or date_to is None:
            days = getattr(payload, "days", None) or req.days or 30
            today = datetime.now(timezone.utc).date()
            date_from = today - timedelta(days=days - 1)
            date_to = today
        return ExportFilters(
            date_from=date_from,
            date_to=date_to,
            device_id=req.device_id,
            status=getattr(payload, "status", None) if report == "sales" else None,
            payment_method=req.payment_method if report == "sales" else None,
            user_id=str(req.user_id) if req.user_id is not None and report == "sales" else None,
            sort=getattr(payload, "sort", None) if report == "products" else None,
            days=getattr(payload, "days", None) if report == "slow-moving" else None,
            threshold=getattr(payload, "threshold", None) if report == "slow-moving" else None,
            lookback_days=(
                getattr(payload, "lookback_days", None) if report == "peak-hours" else None
            ),
        )

    # ------------------------------------------------------------------
    # Render
    # ------------------------------------------------------------------

    def _render(self, req: ExportRequest, payload: Any, spec) -> tuple[bytes, str]:
        generated_at = datetime.utcnow()
        fmt = req.format.lower()
        if fmt == "xlsx":
            return self._guard_render(lambda: render_xlsx(spec, generated_at=generated_at)), (
                _XLSX_MEDIA_TYPE
            )

        blocks = pdf_blocks(req.report, payload, req.locale)
        inp = ReportTableInput(
            title=spec.title,
            store_name=spec.store_name,
            meta_lines=spec.meta_lines,
            blocks=[
                ReportTableBlock(headers=b.headers, rows=b.rows, totals=b.totals)
                for b in blocks
            ],
            landscape=spec.landscape,
            rtl=is_rtl(req.locale),
            locale=req.locale,
            generated_at=(
                f"{label('generated', req.locale)}: "
                f"{generated_at.isoformat(timespec='seconds')}"
            ),
            empty_message=label("no_data", req.locale),
        )
        return self._guard_render(lambda: render_report_pdf(inp)), _PDF_MEDIA_TYPE

    @staticmethod
    def _guard_render(fn: Callable[[], bytes]) -> bytes:
        """Map renderer failures to EXPORT_RENDER_FAILED (§12.2).

        AppError passes through untouched so `MISSING_FONT` keeps its
        documented code.
        """
        try:
            return fn()
        except AppError:
            raise
        except Exception as exc:  # noqa: BLE001 - §12.2 render catch-all
            raise AppError(
                "Export rendering failed",
                {"error": str(exc)},
                code="EXPORT_RENDER_FAILED",
                status_code=500,
                message_key="export_render_failed",
            ) from exc

    def _filename(self, req: ExportRequest, filters: ExportFilters, *, ext: str) -> str:
        stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
        raw = (
            f"reports_{req.report}_{filters.date_from.isoformat()}_"
            f"{filters.date_to.isoformat()}_{stamp}.{ext}"
        )
        return sanitize_filename(raw)

    # ------------------------------------------------------------------
    # Audit (§12.2)
    # ------------------------------------------------------------------

    def _audit(
        self,
        req: ExportRequest,
        *,
        user_id: uuid.UUID | None,
        ip_address: str | None,
        device_id: str | None,
        result: str,
        error_code: str | None,
        duration_ms: int,
        rows: int,
        size: int,
        filename: str | None,
    ) -> None:
        details = {
            "report": req.report,
            "format": req.format.lower(),
            "locale": req.locale,
            "date_from": req.date_from.isoformat() if req.date_from else None,
            "date_to": req.date_to.isoformat() if req.date_to else None,
            "filters": {
                key: value
                for key, value in {
                    "device_id": req.device_id,
                    "status": req.status,
                    "payment_method": req.payment_method,
                    "user_id": str(req.user_id) if req.user_id else None,
                    "sort": req.sort,
                    "days": req.days,
                    "threshold": str(req.threshold) if req.threshold is not None else None,
                    "lookback_days": req.lookback_days,
                }.items()
                if value is not None
            },
            "rows": rows,
            "bytes": size,
            "duration_ms": duration_ms,
            "filename": filename,
            "result": result,
            "error_code": error_code,
        }
        # A failure must never be masked by its own audit write: roll the
        # session back first, and swallow audit trouble on that path only.
        if result == "failure":
            self.db.rollback()
        try:
            with self.transaction():
                self.db.add(
                    AuditLog(
                        user_id=user_id,
                        action=AuditAction.EXPORT.value,
                        entity_type="export",
                        entity_id=None,
                        details=json.dumps(details, ensure_ascii=True),
                        ip_address=ip_address,
                        device_id=device_id,
                    )
                )
        except Exception:
            if result == "failure":
                logger.warning(
                    "export_audit_failed",
                    report=req.report,
                    result=result,
                    error_code=error_code,
                )
            else:
                raise


def _ms(started: float) -> int:
    return int((time.perf_counter() - started) * 1000)
