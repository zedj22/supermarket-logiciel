"""Report / dashboard response schemas (Phase 14).

Field names mirror the formula tables of
``docs/PHASE_14_REPORTS_DASHBOARD_ANALYSIS.md`` §5 exactly: every money and
quantity field is a ``Decimal`` (FastAPI serialises ``Decimal`` as a JSON
string, the same convention every other module already relies on) and every
percentage is a 2-decimal value computed server-side.
"""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

from app.schemas.common import StrictBaseModel

# ---------------------------------------------------------------------------
# §5.1–§5.5 + §8 R15
# ---------------------------------------------------------------------------


class DeviceBreakdownRow(StrictBaseModel):
    """§8 R15 — no device → ``device_id`` is null (client localises "unknown")."""

    device_id: str | None = None
    invoice_count: int
    net_sales: Decimal
    share_pct: Decimal


class FinancialReportResponse(StrictBaseModel):
    date_from: date
    date_to: date
    device_id: str | None = None

    # §5.1 sales block
    gross_sales: Decimal
    line_discounts: Decimal
    invoice_discounts: Decimal
    discounts_total: Decimal
    sales_after_discounts: Decimal
    returns_count: int
    returns_total: Decimal
    net_sales: Decimal
    invoice_count: int
    items_sold: Decimal

    # §5.2 cost block
    cogs: Decimal
    returns_cost: Decimal
    cogs_net: Decimal

    # §5.3 profit block
    expenses_total: Decimal
    expenses_drawer: Decimal
    expenses_external: Decimal
    gross_profit: Decimal
    net_profit: Decimal
    profit_margin_pct: Decimal

    # §5.4 payment split
    paid_cash: Decimal
    paid_card: Decimal
    paid_partial: Decimal
    collected_total: Decimal
    debt_created: Decimal
    change_total: Decimal

    # §5.5 debt block
    outstanding_debt: Decimal
    debt_collected: Decimal
    ar_outstanding: Decimal
    customers_with_debt: int

    # §8 R15 device breakdown (aggregated server-side)
    device_breakdown: list[DeviceBreakdownRow]


# ---------------------------------------------------------------------------
# §5.8 — product / category rows and their totals row
# ---------------------------------------------------------------------------


class ReportTotals(StrictBaseModel):
    """Totals row of §5.8 reports — computed from the same §5.1/§5.2 query."""

    gross_sales: Decimal
    discounts_total: Decimal
    sales_after_discounts: Decimal
    returns_count: int
    returns_total: Decimal
    net_sales: Decimal
    cogs: Decimal
    returns_cost: Decimal
    cogs_net: Decimal
    gross_profit: Decimal
    expenses_total: Decimal
    net_profit: Decimal
    invoice_count: int
    items_sold: Decimal


class ProductReportRow(StrictBaseModel):
    """§5.8 columns. ``kind`` is ``product`` | ``pack`` | ``component``."""

    item_id: UUID
    kind: str
    name: str
    sku: str | None = None
    category_id: UUID | None = None
    category: str | None = None
    qty_sold: Decimal
    gross: Decimal
    line_discounts: Decimal
    invoice_discount_share: Decimal
    net_revenue: Decimal
    return_qty: Decimal
    return_amount: Decimal
    cogs: Decimal
    return_cost: Decimal
    gross_profit: Decimal
    margin_pct: Decimal


class ProductReportResponse(StrictBaseModel):
    date_from: date
    date_to: date
    device_id: str | None = None
    sort: str = "net_revenue"
    items: list[ProductReportRow]
    total: int
    page: int
    page_size: int
    pages: int
    totals: ReportTotals


class CategoryReportRow(StrictBaseModel):
    """§5.8 aggregated by category; ``category`` null → "uncategorized"."""

    category_id: UUID | None = None
    category: str | None = None
    qty_sold: Decimal
    gross: Decimal
    line_discounts: Decimal
    invoice_discount_share: Decimal
    net_revenue: Decimal
    return_qty: Decimal
    return_amount: Decimal
    cogs: Decimal
    return_cost: Decimal
    gross_profit: Decimal
    margin_pct: Decimal


class CategoryReportResponse(StrictBaseModel):
    date_from: date
    date_to: date
    device_id: str | None = None
    items: list[CategoryReportRow]
    totals: ReportTotals


# ---------------------------------------------------------------------------
# §8 R4/R5/R6 — time buckets
# ---------------------------------------------------------------------------


class DailyReportRow(StrictBaseModel):
    date: date
    net_sales: Decimal
    cogs_net: Decimal
    gross_profit: Decimal
    expenses: Decimal
    net_profit: Decimal
    invoice_count: int
    items_sold: Decimal
    returns_total: Decimal


class DailyReportResponse(StrictBaseModel):
    date_from: date
    date_to: date
    device_id: str | None = None
    items: list[DailyReportRow]
    totals: ReportTotals


class HourlyReportRow(StrictBaseModel):
    hour: datetime
    net_sales: Decimal
    sales_total: Decimal
    returns_total: Decimal
    invoice_count: int


class HourlyReportResponse(StrictBaseModel):
    date_from: date
    date_to: date
    device_id: str | None = None
    items: list[HourlyReportRow]
    totals: ReportTotals


class PeakHourRow(StrictBaseModel):
    hour: int
    net_sales: Decimal
    invoice_count: int
    items_sold: Decimal


class PeakHoursReportResponse(StrictBaseModel):
    lookback_days: int
    date_from: date
    date_to: date
    items: list[PeakHourRow]
    totals: ReportTotals


# ---------------------------------------------------------------------------
# §8 R7 — slow-moving stock
# ---------------------------------------------------------------------------


class SlowMovingRow(StrictBaseModel):
    product_id: UUID
    name: str
    sku: str | None = None
    category: str | None = None
    quantity: Decimal
    low_stock_threshold: Decimal
    stock_value: Decimal
    last_sale_date: datetime | None = None


class SlowMovingResponse(StrictBaseModel):
    days: int
    threshold: Decimal
    items: list[SlowMovingRow]
    total: int
    page: int
    page_size: int
    pages: int


# ---------------------------------------------------------------------------
# §8 R8 / R9 — voided invoices and sales detail
# ---------------------------------------------------------------------------


class VoidedSaleRow(StrictBaseModel):
    sale_id: UUID
    invoice_number: str
    sale_date: datetime
    voided_at: datetime | None = None
    total: Decimal
    payment_method: str
    void_reason: str | None = None
    voided_by: UUID | None = None
    voided_by_name: str | None = None
    device_id: str | None = None
    line_count: int


class VoidedReportResponse(StrictBaseModel):
    date_from: date
    date_to: date
    device_id: str | None = None
    items: list[VoidedSaleRow]
    total: int
    page: int
    page_size: int
    pages: int


class SalesDetailRow(StrictBaseModel):
    sale_id: UUID
    invoice_number: str
    sale_date: datetime
    status: str
    customer_id: UUID | None = None
    customer_name: str | None = None
    user_name: str | None = None
    payment_method: str
    subtotal: Decimal
    discounts: Decimal
    total: Decimal
    paid: Decimal
    change: Decimal
    device_id: str | None = None


class SalesDetailTotals(StrictBaseModel):
    count: int
    subtotal: Decimal
    discounts: Decimal
    total: Decimal
    paid: Decimal
    change: Decimal


class SalesDetailResponse(StrictBaseModel):
    date_from: date
    date_to: date
    status: str
    items: list[SalesDetailRow]
    total: int
    page: int
    page_size: int
    pages: int
    totals: SalesDetailTotals


# ---------------------------------------------------------------------------
# §5.6 — supplier block
# ---------------------------------------------------------------------------


class SupplierReportResponse(StrictBaseModel):
    date_from: date
    date_to: date
    supplier_payable: Decimal
    purchases_total: Decimal
    supplier_paid: Decimal
    suppliers_with_balance: int


# ---------------------------------------------------------------------------
# §7 — dashboard
# ---------------------------------------------------------------------------


class DashboardRecentSale(StrictBaseModel):
    sale_id: UUID
    invoice_number: str
    sale_date: datetime
    total: Decimal
    payment_method: str
    customer_name: str | None = None


class DashboardTopProduct(StrictBaseModel):
    item_id: UUID
    kind: str
    name: str
    net_revenue: Decimal
    qty_sold: Decimal
    gross_profit: Decimal


class DashboardResponse(StrictBaseModel):
    date_from: date
    date_to: date
    today_sales: Decimal
    today_invoices: int
    today_net_profit: Decimal
    today_expenses: Decimal
    total_products: int
    total_customers: int
    stock_value: Decimal
    low_stock_count: int
    customers_with_debt: int
    total_debt: Decimal
    recent_sales: list[DashboardRecentSale]
    top_products: list[DashboardTopProduct]
