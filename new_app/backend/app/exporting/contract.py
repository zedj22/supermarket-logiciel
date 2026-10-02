"""Export contract (Phase 15 §5, §6-§10): one source of row truth for
XLSX **and** PDF exports.

Mirrors the frozen client CSV builder `new_app/lib/features/reports/
report_csv.dart` exactly: same localized header keys in the same column
order, same per-report totals rules (including the deliberate empty
cells where no server aggregate exists), same value derivation. Cells
are raw strings (dot-decimal verbatim from the server, ISO 8601 dates
verbatim) — formatting/typing happens in the renderers, never here.

Column kinds (`money|int|percent|date|text`) drive Excel number formats
(§10.1) without changing the raw cell values.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timedelta
from decimal import Decimal
from typing import Any

from app.core.config import settings
from app.printing.labels import label

# §12.2 client cap mirrored server-side (50 000 rows).
EXPORT_ROW_LIMIT = 50000

REPORT_SLUGS = (
    "financial",
    "products",
    "categories",
    "daily",
    "hourly",
    "peak-hours",
    "slow-moving",
    "voided",
    "sales",
    "suppliers",
)

# Row-level reports (§9 note): paged endpoints, 50 000-row cap, autofilter.
ROW_LEVEL_REPORTS = ("products", "slow-moving", "voided", "sales")

_TITLE_KEYS = {
    "financial": "report_financial",
    "products": "report_products",
    "categories": "report_categories",
    "daily": "report_daily",
    "hourly": "report_hourly",
    "peak-hours": "report_peak_hours",
    "slow-moving": "report_slow_moving",
    "voided": "report_voided",
    "sales": "report_sales",
    "suppliers": "report_suppliers",
}

# §9 + §10.1: wide tables print landscape (same set for PDF and XLSX).
_LANDSCAPE = {"products", "slow-moving", "voided", "sales"}


@dataclass
class ExportBlock:
    """One table: localized headers, raw cells, column kinds, totals."""

    headers: list[str]
    rows: list[list[str]]
    kinds: list[str]
    totals: list[str] | None = None


@dataclass
class ExportSpec:
    report: str
    title: str
    store_name: str
    locale: str
    meta_lines: list[str]
    blocks: list[ExportBlock]
    landscape: bool
    row_count: int


@dataclass
class ExportFilters:
    """Approved filter set (§4.4): screen filter + faithful extras."""

    date_from: date | None = None
    date_to: date | None = None
    device_id: str | None = None
    status: str | None = None
    payment_method: str | None = None
    user_id: str | None = None
    sort: str | None = None
    days: int | None = None
    threshold: Decimal | None = None
    lookback_days: int | None = None

    def meta_lines(self, locale: str) -> list[str]:
        """§9/§10 meta block: period + provided filters (defaults omitted)."""
        lines: list[str] = []
        if self.date_from and self.date_to:
            lines.append(
                f"{label('label_period', locale)}: {self.date_from.isoformat()} - "
                f"{self.date_to.isoformat()}"
            )
        if self.days is not None:
            lines.append(f"{label('filter_lookback', locale)}: {self.days}")
        if self.lookback_days is not None:
            lines.append(f"{label('filter_lookback', locale)}: {self.lookback_days}")
        if self.threshold is not None:
            lines.append(f"{label('filter_threshold', locale)}: {self.threshold}")
        if self.device_id:
            lines.append(f"{label('filter_device', locale)}: {self.device_id}")
        if self.status and self.status != "completed":  # completed = default
            lines.append(
                f"{label('filter_status', locale)}: {label(f'status_{self.status}', locale)}"
            )
        if self.payment_method:
            lines.append(
                f"{label('filter_payment', locale)}: "
                f"{label(f'label_{self.payment_method}', locale)}"
            )
        if self.user_id:
            lines.append(f"{label('col_user', locale)}: {self.user_id}")
        if self.sort and self.sort != "net_revenue":  # net_revenue = default
            lines.append(f"{label('filter_sort', locale)}: {self.sort}")
        return lines


def cell(value: Any) -> str:
    """Raw cell exactly as the frozen CSV would show it (§12.2)."""
    if value is None:
        return ""
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, datetime):
        if value.tzinfo is not None and value.utcoffset() == timedelta(0):
            return value.strftime("%Y-%m-%dT%H:%M:%SZ")
        return value.isoformat()
    if isinstance(value, date):
        return value.isoformat()
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, float):
        return repr(value)
    return str(value)


def _t(key: str, locale: str) -> str:
    return label(key, locale)


# ---------------------------------------------------------------------------
# R1 — financial (single aggregate + device block)
# ---------------------------------------------------------------------------

_FIN_MAIN_KINDS = [
    "text",  # period
    "money", "money", "money", "money", "money",  # gross .. sales_after_discounts
    "int",  # returns_count
    "money",  # returns_total
    "money",  # net_sales
    "int",  # invoice_count
    "money",  # items_sold
    "money", "money", "money",  # cogs, returns_cost, cogs_net
    "money", "money", "money",  # expenses*
    "money", "money",  # gross_profit, net_profit
    "percent",  # profit_margin_pct
    "money", "money", "money",  # paid_cash/card/partial
    "money", "money", "money",  # collected, debt_created, change
    "money", "money", "money",  # debt block
    "int",  # customers_with_debt
]

_DEVICE_KINDS = ["text", "int", "money", "percent"]


def _financial(payload, locale: str) -> list[ExportBlock]:
    r = payload
    main_headers = [
        _t("label_period", locale),
        _t("kpi_gross_sales", locale),
        _t("kpi_line_discounts", locale),
        _t("kpi_invoice_discounts", locale),
        _t("kpi_discounts_total", locale),
        _t("kpi_sales_after_discounts", locale),
        _t("kpi_returns_count", locale),
        _t("kpi_returns_total", locale),
        _t("kpi_net_sales", locale),
        _t("kpi_invoices", locale),
        _t("kpi_items_sold", locale),
        _t("kpi_cogs", locale),
        _t("kpi_returns_cost", locale),
        _t("kpi_cogs_net", locale),
        _t("kpi_expenses", locale),
        _t("kpi_expenses_drawer", locale),
        _t("kpi_expenses_external", locale),
        _t("kpi_gross_profit", locale),
        _t("kpi_net_profit", locale),
        _t("kpi_margin", locale),
        _t("kpi_paid_cash", locale),
        _t("kpi_paid_card", locale),
        _t("kpi_paid_partial", locale),
        _t("kpi_collected", locale),
        _t("kpi_debt_created", locale),
        _t("kpi_change", locale),
        _t("kpi_outstanding_debt", locale),
        _t("kpi_debt_collected", locale),
        _t("kpi_ar_outstanding", locale),
        _t("kpi_customers_with_debt", locale),
    ]
    main_row = [
        f"{cell(r.date_from)} - {cell(r.date_to)}",
        cell(r.gross_sales),
        cell(r.line_discounts),
        cell(r.invoice_discounts),
        cell(r.discounts_total),
        cell(r.sales_after_discounts),
        cell(r.returns_count),
        cell(r.returns_total),
        cell(r.net_sales),
        cell(r.invoice_count),
        cell(r.items_sold),
        cell(r.cogs),
        cell(r.returns_cost),
        cell(r.cogs_net),
        cell(r.expenses_total),
        cell(r.expenses_drawer),
        cell(r.expenses_external),
        cell(r.gross_profit),
        cell(r.net_profit),
        cell(r.profit_margin_pct),
        cell(r.paid_cash),
        cell(r.paid_card),
        cell(r.paid_partial),
        cell(r.collected_total),
        cell(r.debt_created),
        cell(r.change_total),
        cell(r.outstanding_debt),
        cell(r.debt_collected),
        cell(r.ar_outstanding),
        cell(r.customers_with_debt),
    ]
    device_headers = [
        _t("col_device", locale),
        _t("col_count", locale),
        _t("col_net_revenue", locale),
        _t("col_share", locale),
    ]
    device_rows = [
        [
            d.device_id if d.device_id else _t("label_unknown_device", locale),
            cell(d.invoice_count),
            cell(d.net_sales),
            cell(d.share_pct),
        ]
        for d in r.device_breakdown
    ]
    return [
        ExportBlock(headers=main_headers, rows=[main_row], kinds=_FIN_MAIN_KINDS),
        ExportBlock(headers=device_headers, rows=device_rows, kinds=_DEVICE_KINDS),
    ]


def _financial_pdf(payload, locale: str) -> list[ExportBlock]:
    """§9 R1: multi-section PDF — sales / cost+profit / payment / debt / device."""
    r = payload
    sections: list[tuple[list[str], list[str], list[str]]] = [
        (
            [
                _t("kpi_gross_sales", locale),
                _t("kpi_line_discounts", locale),
                _t("kpi_invoice_discounts", locale),
                _t("kpi_discounts_total", locale),
                _t("kpi_sales_after_discounts", locale),
                _t("kpi_returns_count", locale),
                _t("kpi_returns_total", locale),
                _t("kpi_net_sales", locale),
                _t("kpi_invoices", locale),
                _t("kpi_items_sold", locale),
            ],
            [
                cell(r.gross_sales), cell(r.line_discounts), cell(r.invoice_discounts),
                cell(r.discounts_total), cell(r.sales_after_discounts),
                cell(r.returns_count), cell(r.returns_total), cell(r.net_sales),
                cell(r.invoice_count), cell(r.items_sold),
            ],
            ["money"] * 5 + ["int", "money", "money", "int", "money"],
        ),
        (
            [
                _t("kpi_cogs", locale),
                _t("kpi_returns_cost", locale),
                _t("kpi_cogs_net", locale),
                _t("kpi_expenses", locale),
                _t("kpi_expenses_drawer", locale),
                _t("kpi_expenses_external", locale),
                _t("kpi_gross_profit", locale),
                _t("kpi_net_profit", locale),
                _t("kpi_margin", locale),
            ],
            [
                cell(r.cogs), cell(r.returns_cost), cell(r.cogs_net),
                cell(r.expenses_total), cell(r.expenses_drawer), cell(r.expenses_external),
                cell(r.gross_profit), cell(r.net_profit), cell(r.profit_margin_pct),
            ],
            ["money"] * 8 + ["percent"],
        ),
        (
            [
                _t("kpi_paid_cash", locale),
                _t("kpi_paid_card", locale),
                _t("kpi_paid_partial", locale),
                _t("kpi_collected", locale),
                _t("kpi_debt_created", locale),
                _t("kpi_change", locale),
            ],
            [
                cell(r.paid_cash), cell(r.paid_card), cell(r.paid_partial),
                cell(r.collected_total), cell(r.debt_created), cell(r.change_total),
            ],
            ["money"] * 6,
        ),
        (
            [
                _t("kpi_outstanding_debt", locale),
                _t("kpi_debt_collected", locale),
                _t("kpi_ar_outstanding", locale),
                _t("kpi_customers_with_debt", locale),
            ],
            [
                cell(r.outstanding_debt), cell(r.debt_collected),
                cell(r.ar_outstanding), cell(r.customers_with_debt),
            ],
            ["money", "money", "money", "int"],
        ),
    ]
    blocks = [
        ExportBlock(headers=headers, rows=[values], kinds=kinds)
        for headers, values, kinds in sections
    ]
    device_headers = [
        _t("col_device", locale),
        _t("col_count", locale),
        _t("col_net_revenue", locale),
        _t("col_share", locale),
    ]
    device_rows = [
        [
            d.device_id if d.device_id else _t("label_unknown_device", locale),
            cell(d.invoice_count),
            cell(d.net_sales),
            cell(d.share_pct),
        ]
        for d in r.device_breakdown
    ]
    blocks.append(
        ExportBlock(headers=device_headers, rows=device_rows, kinds=_DEVICE_KINDS)
    )
    return blocks


# ---------------------------------------------------------------------------
# R2 / R3 — §5.8 rows
# ---------------------------------------------------------------------------

_PRODUCTS_KINDS = [
    "text", "text", "text",
    "money", "money", "money", "money", "money",
    "money", "money", "money", "money", "money",
    "percent",
]

_CATEGORIES_KINDS = [
    "text",
    "money", "money", "money", "money", "money",
    "money", "money", "money", "money", "money",
    "percent",
]


def _products_totals(t, locale: str) -> list[str]:
    return [
        _t("label_total", locale),
        "",
        "",
        cell(t.items_sold),
        cell(t.gross_sales),
        # No server aggregate for the split discounts / return quantity
        # (§5 combined figure only) — cells stay empty, like the CSV.
        "",
        "",
        cell(t.net_sales),
        "",
        cell(t.returns_total),
        cell(t.cogs),
        cell(t.returns_cost),
        cell(t.gross_profit),
        "",
    ]


def _products(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_product", locale),
        _t("col_sku", locale),
        _t("col_category", locale),
        _t("col_qty", locale),
        _t("col_gross", locale),
        _t("col_line_discounts", locale),
        _t("col_invoice_discount", locale),
        _t("col_net_revenue", locale),
        _t("col_returns_qty", locale),
        _t("col_returns_amount", locale),
        _t("col_cogs", locale),
        _t("kpi_returns_cost", locale),
        _t("col_gross_profit", locale),
        _t("col_margin", locale),
    ]
    rows = [
        [
            row.name,
            cell(row.sku),
            row.category if row.category else _t("label_uncategorized", locale),
            cell(row.qty_sold),
            cell(row.gross),
            cell(row.line_discounts),
            cell(row.invoice_discount_share),
            cell(row.net_revenue),
            cell(row.return_qty),
            cell(row.return_amount),
            cell(row.cogs),
            cell(row.return_cost),
            cell(row.gross_profit),
            cell(row.margin_pct),
        ]
        for row in payload.items
    ]
    return [
        ExportBlock(
            headers=headers,
            rows=rows,
            kinds=_PRODUCTS_KINDS,
            totals=_products_totals(payload.totals, locale),
        )
    ]


def _categories(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_category", locale),
        _t("col_qty", locale),
        _t("col_gross", locale),
        _t("col_line_discounts", locale),
        _t("col_invoice_discount", locale),
        _t("col_net_revenue", locale),
        _t("col_returns_qty", locale),
        _t("col_returns_amount", locale),
        _t("col_cogs", locale),
        _t("kpi_returns_cost", locale),
        _t("col_gross_profit", locale),
        _t("col_margin", locale),
    ]
    rows = [
        [
            row.category if row.category else _t("label_uncategorized", locale),
            cell(row.qty_sold),
            cell(row.gross),
            cell(row.line_discounts),
            cell(row.invoice_discount_share),
            cell(row.net_revenue),
            cell(row.return_qty),
            cell(row.return_amount),
            cell(row.cogs),
            cell(row.return_cost),
            cell(row.gross_profit),
            cell(row.margin_pct),
        ]
        for row in payload.items
    ]
    t = payload.totals
    totals = [
        _t("label_total", locale),
        cell(t.items_sold),
        cell(t.gross_sales),
        "",
        "",
        cell(t.net_sales),
        "",
        cell(t.returns_total),
        cell(t.cogs),
        cell(t.returns_cost),
        cell(t.gross_profit),
        "",
    ]
    return [
        ExportBlock(headers=headers, rows=rows, kinds=_CATEGORIES_KINDS, totals=totals)
    ]


# ---------------------------------------------------------------------------
# R4 / R5 / R6 — time buckets
# ---------------------------------------------------------------------------


def _daily(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_date", locale),
        _t("kpi_net_sales", locale),
        _t("col_cogs", locale),
        _t("col_gross_profit", locale),
        _t("col_expenses", locale),
        _t("col_net_profit", locale),
        _t("kpi_invoices", locale),
        _t("kpi_items_sold", locale),
        _t("kpi_returns_total", locale),
    ]
    kinds = ["date", "money", "money", "money", "money", "money", "int", "money", "money"]
    rows = [
        [
            cell(row.date),
            cell(row.net_sales),
            cell(row.cogs_net),
            cell(row.gross_profit),
            cell(row.expenses),
            cell(row.net_profit),
            cell(row.invoice_count),
            cell(row.items_sold),
            cell(row.returns_total),
        ]
        for row in payload.items
    ]
    t = payload.totals
    totals = [
        _t("label_total", locale),
        cell(t.net_sales),
        cell(t.cogs_net),
        cell(t.gross_profit),
        cell(t.expenses_total),
        cell(t.net_profit),
        cell(t.invoice_count),
        cell(t.items_sold),
        cell(t.returns_total),
    ]
    return [ExportBlock(headers=headers, rows=rows, kinds=kinds, totals=totals)]


def _hourly(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_hour", locale),
        _t("kpi_net_sales", locale),
        _t("col_gross", locale),
        _t("kpi_returns_total", locale),
        _t("kpi_invoices", locale),
    ]
    kinds = ["date", "money", "money", "money", "int"]
    rows = [
        [
            cell(row.hour),
            cell(row.net_sales),
            cell(row.sales_total),
            cell(row.returns_total),
            cell(row.invoice_count),
        ]
        for row in payload.items
    ]
    t = payload.totals
    totals = [
        _t("label_total", locale),
        cell(t.net_sales),
        # No aggregate for gross sales_total (§5 reports discounted figures).
        "",
        cell(t.returns_total),
        cell(t.invoice_count),
    ]
    return [ExportBlock(headers=headers, rows=rows, kinds=kinds, totals=totals)]


def _peak(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_hour", locale),
        _t("kpi_net_sales", locale),
        _t("kpi_invoices", locale),
        _t("kpi_items_sold", locale),
    ]
    kinds = ["int", "money", "int", "money"]
    rows = [
        [cell(row.hour), cell(row.net_sales), cell(row.invoice_count), cell(row.items_sold)]
        for row in payload.items
    ]
    t = payload.totals
    totals = [
        _t("label_total", locale),
        cell(t.net_sales),
        cell(t.invoice_count),
        cell(t.items_sold),
    ]
    return [ExportBlock(headers=headers, rows=rows, kinds=kinds, totals=totals)]


# ---------------------------------------------------------------------------
# R7 / R8 / R9 — detail lists (no totals row for R7/R8)
# ---------------------------------------------------------------------------


def _slow_moving(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_product", locale),
        _t("col_sku", locale),
        _t("col_category", locale),
        _t("col_qty", locale),
        _t("col_stock_value", locale),
        _t("col_last_sale", locale),
    ]
    kinds = ["text", "text", "text", "money", "money", "date"]
    rows = [
        [
            row.name,
            cell(row.sku),
            cell(row.category),
            cell(row.quantity),
            cell(row.stock_value),
            cell(row.last_sale_date),
        ]
        for row in payload.items
    ]
    return [ExportBlock(headers=headers, rows=rows, kinds=kinds)]


def _voided(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_invoice", locale),
        _t("col_date", locale),
        _t("col_voided_at", locale),
        _t("col_total", locale),
        _t("col_method", locale),
        _t("col_void_reason", locale),
        _t("col_user", locale),
        _t("col_device", locale),
        _t("col_count", locale),
    ]
    kinds = ["text", "date", "date", "money", "text", "text", "text", "text", "int"]
    rows = [
        [
            row.invoice_number,
            cell(row.sale_date),
            cell(row.voided_at),
            cell(row.total),
            _t(f"label_{row.payment_method}", locale) if row.payment_method else "",
            cell(row.void_reason),
            cell(row.voided_by_name),
            row.device_id if row.device_id else _t("label_unknown_device", locale),
            cell(row.line_count),
        ]
        for row in payload.items
    ]
    return [ExportBlock(headers=headers, rows=rows, kinds=kinds)]


def _sales(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("col_invoice", locale),
        _t("col_date", locale),
        _t("filter_status", locale),
        _t("col_customer", locale),
        _t("col_user", locale),
        _t("col_method", locale),
        _t("col_subtotal", locale),
        _t("kpi_discounts_total", locale),
        _t("col_total", locale),
        _t("col_paid", locale),
        _t("col_change", locale),
        _t("col_device", locale),
    ]
    kinds = [
        "text", "date", "text", "text", "text", "text",
        "money", "money", "money", "money", "money", "text",
    ]
    rows = [
        [
            row.invoice_number,
            cell(row.sale_date),
            _t(f"status_{row.status}", locale),
            cell(row.customer_name),
            cell(row.user_name),
            _t(f"label_{row.payment_method}", locale) if row.payment_method else "",
            cell(row.subtotal),
            cell(row.discounts),
            cell(row.total),
            cell(row.paid),
            cell(row.change),
            row.device_id if row.device_id else _t("label_unknown_device", locale),
        ]
        for row in payload.items
    ]
    t = payload.totals
    totals = [
        _t("label_total", locale),
        "",
        "",
        "",
        "",
        "",
        cell(t.subtotal),
        cell(t.discounts),
        cell(t.total),
        cell(t.paid),
        cell(t.change),
        "",
    ]
    return [ExportBlock(headers=headers, rows=rows, kinds=kinds, totals=totals)]


# ---------------------------------------------------------------------------
# R13 — supplier payables
# ---------------------------------------------------------------------------


def _suppliers(payload, locale: str) -> list[ExportBlock]:
    headers = [
        _t("label_period", locale),
        _t("kpi_supplier_payable", locale),
        _t("kpi_purchases_total", locale),
        _t("kpi_supplier_paid", locale),
        _t("kpi_suppliers_with_balance", locale),
    ]
    kinds = ["text", "money", "money", "money", "int"]
    rows = [
        [
            f"{cell(payload.date_from)} - {cell(payload.date_to)}",
            cell(payload.supplier_payable),
            cell(payload.purchases_total),
            cell(payload.supplier_paid),
            cell(payload.suppliers_with_balance),
        ]
    ]
    return [ExportBlock(headers=headers, rows=rows, kinds=kinds)]


_BUILDERS = {
    "financial": _financial,
    "products": _products,
    "categories": _categories,
    "daily": _daily,
    "hourly": _hourly,
    "peak-hours": _peak,
    "slow-moving": _slow_moving,
    "voided": _voided,
    "sales": _sales,
    "suppliers": _suppliers,
}


def _default_filters(report: str, payload, locale: str) -> ExportFilters:
    return ExportFilters(
        date_from=getattr(payload, "date_from", None),
        date_to=getattr(payload, "date_to", None),
        device_id=getattr(payload, "device_id", None),
        days=getattr(payload, "days", None),
        threshold=getattr(payload, "threshold", None),
        lookback_days=getattr(payload, "lookback_days", None),
        sort=getattr(payload, "sort", None),
        status=getattr(payload, "status", None) if report == "sales" else None,
    )


def build_spec(
    report: str,
    payload,
    *,
    locale: str,
    filters: ExportFilters | None = None,
) -> ExportSpec:
    """Assemble the export contract for `report` from its report payload."""
    if report not in _BUILDERS:
        raise KeyError(report)
    if filters is None:
        filters = _default_filters(report, payload, locale)
    blocks = _BUILDERS[report](payload, locale)
    row_count = sum(len(block.rows) for block in blocks)
    return ExportSpec(
        report=report,
        title=label(_TITLE_KEYS[report], locale),
        store_name=settings.STORE_NAME,
        locale=locale,
        meta_lines=filters.meta_lines(locale),
        blocks=blocks,
        landscape=report in _LANDSCAPE,
        row_count=row_count,
    )


def pdf_blocks(report: str, payload, locale: str) -> list[ExportBlock]:
    """Block layout for the PDF renderer (§9 — financial is sectioned)."""
    if report == "financial":
        return _financial_pdf(payload, locale)
    return _BUILDERS[report](payload, locale)
