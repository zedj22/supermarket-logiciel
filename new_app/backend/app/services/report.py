"""Report service (Phase 14).

Owns range/cap validation (§6), single-quantisation of every output field
(§5) and the derived values (profits, margins, shares) that must never be
computed by Flutter.  All sums come from ``ReportRepository``; expenses and
the AR snapshot are reused from the Phase 13 / Phase 9 repositories.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta, timezone
from decimal import ROUND_DOWN, Decimal
from typing import Any

from app.core.exceptions import ValidationError
from app.domain.unit_conversions import to_decimal
from app.domain.valuation import quantize_money
from app.models.enums import SaleStatus
from app.repositories.expense import ExpenseRepository
from app.repositories.inventory import InventoryMovementRepository
from app.repositories.party import CustomerRepository
from app.repositories.report import ReportRepository
from app.schemas.report import (
    CategoryReportResponse,
    CategoryReportRow,
    DailyReportResponse,
    DailyReportRow,
    DashboardRecentSale,
    DashboardResponse,
    DashboardTopProduct,
    DeviceBreakdownRow,
    FinancialReportResponse,
    HourlyReportResponse,
    HourlyReportRow,
    LoyaltyEventTotals,
    LoyaltyLedgerRow,
    LoyaltyReportResponse,
    PeakHourRow,
    PeakHoursReportResponse,
    ProductReportResponse,
    ProductReportRow,
    ReportTotals,
    SalesDetailResponse,
    SalesDetailRow,
    SlowMovingResponse,
    SlowMovingRow,
    SupplierReportResponse,
    VoidedReportResponse,
    VoidedSaleRow,
)

_PCT = Decimal("0.01")
_ZERO = Decimal("0")

_EMPTY_DAY: dict[str, Any] = {
    "sales_total": Decimal("0"),
    "invoice_count": 0,
    "items_sold": Decimal("0"),
    "cogs": Decimal("0"),
    "returns_total": Decimal("0"),
    "returns_count": 0,
    "returns_cost": Decimal("0"),
    "expenses": Decimal("0"),
}

_EMPTY_HOUR: dict[str, Any] = {
    "sales_total": Decimal("0"),
    "invoice_count": 0,
    "returns_total": Decimal("0"),
    "returns_count": 0,
    "items_sold": Decimal("0"),
}


def _money(value: Decimal | int | float | str) -> Decimal:
    return quantize_money(to_decimal(value))


def _percent(numerator: Decimal, denominator: Decimal) -> Decimal:
    """2-decimal percentage, 0.00 whenever the denominator is not positive.

    Accounting percentages (net margin on revenue, device share, …) — NOT
    the app-wide profit figure, which is `_markup_percent` below.
    """
    if denominator <= 0:
        return _ZERO.quantize(_PCT)
    return (to_decimal(numerator) / to_decimal(denominator) * 100).quantize(_PCT)


def _markup_percent(gross_profit: Decimal, cogs_net: Decimal) -> Decimal | None:
    """Markup ON COST for a §5.8 product/category row.

    ``((selling_price - cost_price) / cost_price) * 100`` — for a report row
    that is ``gross_profit / (cogs - return_cost) * 100`` (returns are cost
    back out of the denominator too), never profit over revenue.

    Truncated toward zero to 2 decimals so the export carries byte-identical
    digits to the Flutter table and the client CSV
    (`core/markup_percent.dart` truncates its integer hundredths the same
    way). ``None`` when there is no positive net cost to divide by (free /
    missing cost): the cell exports empty, exactly like the client CSV and
    the table's em dash — never a fabricated 0.00 or an infinity.
    """
    if cogs_net <= 0:
        return None
    return (to_decimal(gross_profit) / to_decimal(cogs_net) * 100).quantize(
        _PCT, rounding=ROUND_DOWN
    )


class ReportService:
    """Builds every Phase 14 report surface."""

    MAX_DAILY_DAYS = 400
    MAX_HOURLY_DAYS = 31
    MIN_LOOKBACK_DAYS = 1
    MAX_LOOKBACK_DAYS = 90
    MIN_SLOW_DAYS = 1
    MAX_SLOW_DAYS = 365
    PRODUCT_SORTS = (
        "net_revenue",
        "qty_sold",
        "gross_profit",
        "return_qty",
        "margin_pct",
    )

    def __init__(self, db) -> None:
        self.db = db
        self.repo = ReportRepository(db)
        self.expenses = ExpenseRepository(db)
        self.customers = CustomerRepository(db)
        self.inventory = InventoryMovementRepository(db)

    # ------------------------------------------------------------------
    # §6 validation
    # ------------------------------------------------------------------

    @staticmethod
    def _span(date_from: date, date_to: date) -> int:
        return (date_to - date_from).days + 1

    @classmethod
    def _validate_range(cls, date_from: date, date_to: date) -> int:
        if date_to < date_from:
            raise ValidationError(
                message="date_to must be on or after date_from",
                details={"date_from": date_from.isoformat(), "date_to": date_to.isoformat()},
                code="REPORT_INVALID_RANGE",
                message_key="reports.invalidRange",
            )
        return cls._span(date_from, date_to)

    @classmethod
    def _validate_span(cls, date_from: date, date_to: date, max_days: int) -> int:
        span = cls._validate_range(date_from, date_to)
        if span > max_days:
            raise ValidationError(
                message=f"Date range may not exceed {max_days} days",
                details={
                    "date_from": date_from.isoformat(),
                    "date_to": date_to.isoformat(),
                    "days": span,
                    "max_days": max_days,
                },
                code="REPORT_RANGE_TOO_WIDE",
                message_key="reports.rangeTooWide",
            )
        return span

    @staticmethod
    def _validate_lookback(lookback_days: int, minimum: int, maximum: int) -> None:
        if lookback_days < minimum or lookback_days > maximum:
            raise ValidationError(
                message=f"lookback_days must be between {minimum} and {maximum}",
                details={"lookback_days": lookback_days, "min": minimum, "max": maximum},
                code="REPORT_INVALID_RANGE",
                message_key="reports.invalidRange",
            )

    @staticmethod
    def _pages(total: int, page_size: int) -> int:
        return (total + page_size - 1) // page_size if page_size else 0

    @staticmethod
    def _utc_today() -> date:
        return datetime.now(timezone.utc).date()

    # ------------------------------------------------------------------
    # §5.1–§5.5 shared derivation
    # ------------------------------------------------------------------

    def _financial_fields(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        sales_values: dict[str, Any] | None = None,
        line_values: dict[str, Any] | None = None,
        include_device_rows: bool = False,
    ) -> tuple[dict[str, Any], dict[str, Any]]:
        """Quantised §5.1–§5.5 fields plus the raw block they derive from.

        ``sales_values`` / ``line_values`` carry window totals from a report's
        own grouped query (§15) so ``financial_block`` skips its
        sales/sale_lines scan; they must cover the exact same window/filters.
        """
        block = self.repo.financial_block(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            sales_values=sales_values,
            line_values=line_values,
            include_device_rows=include_device_rows,
        )
        _count, exp_total, exp_drawer, exp_external = self.expenses.summary(
            date_from=date_from, date_to=date_to, status="posted"
        )
        ar_outstanding, customers_with_debt = self.customers.total_outstanding()

        net_sales = block["sales_after_discounts"] - block["returns_total"]
        cogs_net = block["cogs"] - block["returns_cost"]
        gross_profit = net_sales - cogs_net
        net_profit = gross_profit - exp_total
        collected_total = block["paid_cash"] + block["paid_card"] + block["paid_partial"]

        fields: dict[str, Any] = {
            "gross_sales": _money(block["gross_sales"]),
            "line_discounts": _money(block["line_discounts"]),
            "invoice_discounts": _money(block["invoice_discounts"]),
            "discounts_total": _money(block["discounts_total"]),
            "sales_after_discounts": _money(block["sales_after_discounts"]),
            "returns_count": block["returns_count"],
            "returns_total": _money(block["returns_total"]),
            "net_sales": _money(net_sales),
            "invoice_count": block["invoice_count"],
            "items_sold": _money(block["items_sold"]),
            "cogs": _money(block["cogs"]),
            "returns_cost": _money(block["returns_cost"]),
            "cogs_net": _money(cogs_net),
            "expenses_total": _money(exp_total),
            "expenses_drawer": _money(exp_drawer),
            "expenses_external": _money(exp_external),
            "gross_profit": _money(gross_profit),
            "net_profit": _money(net_profit),
            "profit_margin_pct": _percent(net_profit, net_sales),
            "paid_cash": _money(block["paid_cash"]),
            "paid_card": _money(block["paid_card"]),
            "paid_partial": _money(block["paid_partial"]),
            "collected_total": _money(collected_total),
            "debt_created": _money(block["debt_created"]),
            "change_total": _money(block["change_total"]),
            "outstanding_debt": _money(block["outstanding_debt"]),
            "debt_collected": _money(block["debt_collected"]),
            "ar_outstanding": _money(ar_outstanding),
            "customers_with_debt": customers_with_debt,
        }
        return fields, block

    def _report_totals(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        sales_values: dict[str, Any] | None = None,
        line_values: dict[str, Any] | None = None,
    ) -> ReportTotals:
        """§5.8 totals row — the unrounded §5.1/§5.2 aggregate, not summed rows."""
        fields, _block = self._financial_fields(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            sales_values=sales_values,
            line_values=line_values,
        )
        return ReportTotals(
            gross_sales=fields["gross_sales"],
            discounts_total=fields["discounts_total"],
            sales_after_discounts=fields["sales_after_discounts"],
            returns_count=fields["returns_count"],
            returns_total=fields["returns_total"],
            net_sales=fields["net_sales"],
            cogs=fields["cogs"],
            returns_cost=fields["returns_cost"],
            cogs_net=fields["cogs_net"],
            gross_profit=fields["gross_profit"],
            expenses_total=fields["expenses_total"],
            net_profit=fields["net_profit"],
            invoice_count=fields["invoice_count"],
            items_sold=fields["items_sold"],
        )

    # ------------------------------------------------------------------
    # §5.1–§5.5 + §8 R15
    # ------------------------------------------------------------------

    def financial(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
    ) -> FinancialReportResponse:
        self._validate_range(date_from, date_to)
        fields, block = self._financial_fields(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            include_device_rows=True,
        )
        net_sales = block["sales_after_discounts"] - block["returns_total"]
        breakdown = [
            DeviceBreakdownRow(
                device_id=row["device_id"],
                invoice_count=row["invoice_count"],
                net_sales=_money(row["sales_total"] - row["returns_total"]),
                share_pct=_percent(row["sales_total"] - row["returns_total"], net_sales),
            )
            for row in block["device_rows"]  # §5.7 from the device-grouped branch
        ]
        return FinancialReportResponse(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            device_breakdown=breakdown,
            **fields,
        )

    # ------------------------------------------------------------------
    # §5.8 row reports
    # ------------------------------------------------------------------

    @staticmethod
    def _product_row(raw: dict[str, Any]) -> ProductReportRow:
        net_revenue = raw["gross"] - raw["line_discounts"] - raw["invoice_discount_share"]
        net_after_returns = net_revenue - raw["return_amount"]
        cogs_net = raw["cogs"] - raw["return_cost"]
        gross_profit = net_after_returns - cogs_net
        # Quantise first, then divide: the markup is derived from exactly
        # the digits the client shows for `gross_profit` / `cogs` /
        # `return_cost`, so table, client CSV and export always agree.
        gross_profit_q = _money(gross_profit)
        cogs_net_q = _money(raw["cogs"]) - _money(raw["return_cost"])
        return ProductReportRow(
            item_id=raw["item_id"],
            kind=raw["kind"],
            name=raw["name"],
            sku=raw["sku"],
            category_id=raw["category_id"],
            category=raw["category"],
            qty_sold=_money(raw["qty_sold"]),
            gross=_money(raw["gross"]),
            line_discounts=_money(raw["line_discounts"]),
            invoice_discount_share=_money(raw["invoice_discount_share"]),
            net_revenue=_money(net_revenue),
            return_qty=_money(raw["return_qty"]),
            return_amount=_money(raw["return_amount"]),
            cogs=_money(raw["cogs"]),
            return_cost=_money(raw["return_cost"]),
            gross_profit=gross_profit_q,
            margin_pct=_markup_percent(gross_profit_q, cogs_net_q),
        )

    @classmethod
    def _category_row(cls, raw: dict[str, Any]) -> CategoryReportRow:
        net_revenue = raw["gross"] - raw["line_discounts"] - raw["invoice_discount_share"]
        net_after_returns = net_revenue - raw["return_amount"]
        cogs_net = raw["cogs"] - raw["return_cost"]
        gross_profit = net_after_returns - cogs_net
        gross_profit_q = _money(gross_profit)
        cogs_net_q = _money(raw["cogs"]) - _money(raw["return_cost"])
        return CategoryReportRow(
            category_id=raw["category_id"],
            category=raw["category"],
            qty_sold=_money(raw["qty_sold"]),
            gross=_money(raw["gross"]),
            line_discounts=_money(raw["line_discounts"]),
            invoice_discount_share=_money(raw["invoice_discount_share"]),
            net_revenue=_money(net_revenue),
            return_qty=_money(raw["return_qty"]),
            return_amount=_money(raw["return_amount"]),
            cogs=_money(raw["cogs"]),
            return_cost=_money(raw["return_cost"]),
            gross_profit=gross_profit_q,
            margin_pct=_markup_percent(gross_profit_q, cogs_net_q),
        )

    def products(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        sort: str = "net_revenue",
        page: int = 1,
        page_size: int = 100,
    ) -> ProductReportResponse:
        self._validate_range(date_from, date_to)
        if sort not in self.PRODUCT_SORTS:
            raise ValidationError(
                message="Unsupported report sort field",
                details={"sort": sort, "allowed": list(self.PRODUCT_SORTS)},
                code="REPORT_SORT_INVALID",
                message_key="reports.sortInvalid",
            )
        rows, total, line_values = self.repo.product_rows(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            sort=sort,
            page=page,
            page_size=page_size,
        )
        return ProductReportResponse(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            sort=sort,
            items=[self._product_row(row) for row in rows],
            total=total,
            page=page,
            page_size=page_size,
            pages=self._pages(total, page_size),
            totals=self._report_totals(
                date_from=date_from,
                date_to=date_to,
                device_id=device_id,
                line_values=line_values,
            ),
        )

    def categories(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
    ) -> CategoryReportResponse:
        self._validate_range(date_from, date_to)
        rows, line_values = self.repo.category_rows(
            date_from=date_from, date_to=date_to, device_id=device_id
        )
        return CategoryReportResponse(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            items=[self._category_row(row) for row in rows],
            totals=self._report_totals(
                date_from=date_from,
                date_to=date_to,
                device_id=device_id,
                line_values=line_values,
            ),
        )

    # ------------------------------------------------------------------
    # §8 R4/R5/R6 — time buckets
    # ------------------------------------------------------------------

    def daily(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
    ) -> DailyReportResponse:
        self._validate_span(date_from, date_to, self.MAX_DAILY_DAYS)
        data, sales_values, line_values = self.repo.daily_rows(
            date_from=date_from, date_to=date_to, device_id=device_id
        )

        items: list[DailyReportRow] = []
        cursor = date_from
        while cursor <= date_to:
            values = data.get((cursor.year, cursor.month, cursor.day), _EMPTY_DAY)
            net_sales = values["sales_total"] - values["returns_total"]
            cogs_net = values["cogs"] - values["returns_cost"]
            gross_profit = net_sales - cogs_net
            net_profit = gross_profit - values["expenses"]
            items.append(
                DailyReportRow(
                    date=cursor,
                    net_sales=_money(net_sales),
                    cogs_net=_money(cogs_net),
                    gross_profit=_money(gross_profit),
                    expenses=_money(values["expenses"]),
                    net_profit=_money(net_profit),
                    invoice_count=values["invoice_count"],
                    items_sold=_money(values["items_sold"]),
                    returns_total=_money(values["returns_total"]),
                )
            )
            cursor += timedelta(days=1)

        return DailyReportResponse(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            items=items,
            totals=self._report_totals(
                date_from=date_from,
                date_to=date_to,
                device_id=device_id,
                sales_values=sales_values,
                line_values=line_values,
            ),
        )

    def hourly(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
    ) -> HourlyReportResponse:
        self._validate_span(date_from, date_to, self.MAX_HOURLY_DAYS)
        data, sales_values, line_values = self.repo.hourly_rows(
            date_from=date_from, date_to=date_to, device_id=device_id
        )

        items: list[HourlyReportRow] = []
        cursor = datetime.combine(date_from, time.min, tzinfo=timezone.utc)
        end = datetime.combine(date_to + timedelta(days=1), time.min, tzinfo=timezone.utc)
        while cursor < end:
            values = data.get(
                (cursor.year, cursor.month, cursor.day, cursor.hour), _EMPTY_HOUR
            )
            sales_total = values["sales_total"]
            returns_total = values["returns_total"]
            items.append(
                HourlyReportRow(
                    hour=cursor,
                    net_sales=_money(sales_total - returns_total),
                    sales_total=_money(sales_total),
                    returns_total=_money(returns_total),
                    invoice_count=values["invoice_count"],
                )
            )
            cursor += timedelta(hours=1)

        return HourlyReportResponse(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            items=items,
            totals=self._report_totals(
                date_from=date_from,
                date_to=date_to,
                device_id=device_id,
                sales_values=sales_values,
                line_values=line_values,
            ),
        )

    def peak_hours(
        self,
        *,
        lookback_days: int = 30,
        device_id: str | None = None,
    ) -> PeakHoursReportResponse:
        self._validate_lookback(lookback_days, self.MIN_LOOKBACK_DAYS, self.MAX_LOOKBACK_DAYS)
        date_to = self._utc_today()
        date_from = date_to - timedelta(days=lookback_days - 1)
        data, sales_values, line_values = self.repo.peak_rows(
            date_from=date_from, date_to=date_to, device_id=device_id
        )

        items: list[PeakHourRow] = []
        for hour in range(24):
            values = data.get(hour, _EMPTY_HOUR)
            items.append(
                PeakHourRow(
                    hour=hour,
                    net_sales=_money(values["sales_total"] - values["returns_total"]),
                    invoice_count=values["invoice_count"],
                    items_sold=_money(values["items_sold"]),
                )
            )
        return PeakHoursReportResponse(
            lookback_days=lookback_days,
            date_from=date_from,
            date_to=date_to,
            items=items,
            totals=self._report_totals(
                date_from=date_from,
                date_to=date_to,
                device_id=device_id,
                sales_values=sales_values,
                line_values=line_values,
            ),
        )

    # ------------------------------------------------------------------
    # §8 R7/R8/R9 + §5.6
    # ------------------------------------------------------------------

    def slow_moving(
        self,
        *,
        days: int = 30,
        threshold: Decimal = Decimal("0"),
        page: int = 1,
        page_size: int = 100,
    ) -> SlowMovingResponse:
        self._validate_lookback(days, self.MIN_SLOW_DAYS, self.MAX_SLOW_DAYS)
        if threshold < 0:
            raise ValidationError(
                message="threshold must be >= 0",
                details={"threshold": str(threshold)},
                code="REPORT_INVALID_RANGE",
                message_key="reports.invalidRange",
            )
        date_to = self._utc_today()
        date_from = date_to - timedelta(days=days - 1)
        rows, total = self.repo.slow_moving_rows(
            threshold=to_decimal(threshold),
            date_from=date_from,
            date_to=date_to,
            page=page,
            page_size=page_size,
        )
        items = [
            SlowMovingRow(
                product_id=row["product"].id,
                name=row["product"].name,
                sku=row["product"].sku,
                category=row["category"],
                quantity=_money(row["product"].quantity),
                low_stock_threshold=_money(row["product"].low_stock_threshold),
                stock_value=_money(
                    to_decimal(row["product"].quantity) * to_decimal(row["product"].avg_cost)
                ),
                last_sale_date=row["last_sale_date"],
            )
            for row in rows
        ]
        return SlowMovingResponse(
            days=days,
            threshold=to_decimal(threshold),
            items=items,
            total=total,
            page=page,
            page_size=page_size,
            pages=self._pages(total, page_size),
        )

    def voided(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        page: int = 1,
        page_size: int = 100,
    ) -> VoidedReportResponse:
        self._validate_range(date_from, date_to)
        rows, total = self.repo.voided_rows(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            page=page,
            page_size=page_size,
        )
        items = [
            VoidedSaleRow(
                sale_id=row["sale"].id,
                invoice_number=row["sale"].invoice_number,
                sale_date=row["sale"].sale_date,
                voided_at=row["sale"].voided_at,
                total=_money(row["sale"].total),
                payment_method=row["sale"].payment_method,
                void_reason=row["sale"].void_reason,
                voided_by=row["sale"].voided_by,
                voided_by_name=row["voided_by_name"],
                device_id=row["sale"].device_id,
                line_count=row["line_count"],
            )
            for row in rows
        ]
        return VoidedReportResponse(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            items=items,
            total=total,
            page=page,
            page_size=page_size,
            pages=self._pages(total, page_size),
        )

    def sales(
        self,
        *,
        date_from: date,
        date_to: date,
        status: str = SaleStatus.COMPLETED.value,
        payment_method: str | None = None,
        user_id: uuid.UUID | None = None,
        device_id: str | None = None,
        page: int = 1,
        page_size: int = 100,
    ) -> SalesDetailResponse:
        self._validate_range(date_from, date_to)
        rows, totals = self.repo.sales_rows(
            date_from=date_from,
            date_to=date_to,
            status=status,
            payment_method=payment_method,
            user_id=user_id,
            device_id=device_id,
            page=page,
            page_size=page_size,
        )
        items = [
            SalesDetailRow(
                sale_id=row["sale"].id,
                invoice_number=row["sale"].invoice_number,
                sale_date=row["sale"].sale_date,
                status=row["sale"].status,
                customer_id=row["sale"].customer_id,
                customer_name=row["customer_name"],
                user_name=row["user_name"],
                payment_method=row["sale"].payment_method,
                subtotal=_money(row["sale"].subtotal),
                discounts=_money(
                    to_decimal(row["sale"].subtotal) - to_decimal(row["sale"].total)
                ),
                total=_money(row["sale"].total),
                paid=_money(row["sale"].paid),
                change=_money(row["sale"].change),
                device_id=row["sale"].device_id,
            )
            for row in rows
        ]
        total = int(totals["count"])
        return SalesDetailResponse(
            date_from=date_from,
            date_to=date_to,
            status=status,
            items=items,
            total=total,
            page=page,
            page_size=page_size,
            pages=self._pages(total, page_size),
            totals={
                "count": totals["count"],
                "subtotal": _money(totals["subtotal"]),
                "discounts": _money(totals["discounts"]),
                "total": _money(totals["total"]),
                "paid": _money(totals["paid"]),
                "change": _money(totals["change"]),
            },
        )

    def suppliers(self, *, date_from: date, date_to: date) -> SupplierReportResponse:
        self._validate_range(date_from, date_to)
        block = self.repo.supplier_block(date_from=date_from, date_to=date_to)
        return SupplierReportResponse(
            date_from=date_from,
            date_to=date_to,
            supplier_payable=_money(block["supplier_payable"]),
            purchases_total=_money(block["purchases_total"]),
            supplier_paid=_money(block["supplier_paid"]),
            suppliers_with_balance=block["suppliers_with_balance"],
        )

    # ------------------------------------------------------------------
    # Loyalty report (Loyalty Phase F)
    # ------------------------------------------------------------------

    #: Ledger event types in canonical report order (models/loyalty.py).
    _LOYALTY_EVENT_ORDER = (
        "sale_earn",
        "debt_settlement_earn",
        "redeem",
        "return_clawback",
        "void_clawback",
        "adjustment",
        "expiry",
    )
    #: Event types that grant rewards (never a negative delta).
    _LOYALTY_EARN_EVENTS = ("sale_earn", "debt_settlement_earn")

    def loyalty(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        page: int = 1,
        page_size: int = 100,
    ) -> LoyaltyReportResponse:
        """Loyalty activity for the window plus the current reward liability.

        Every figure comes from the append-only ledger (or, for balances,
        from the cached account projection): points/cashback earned, points
        redeemed and the cash value they removed from the invoices, the
        reversals and restorations posted by returns/voids, and the
        shortfall a floored reversal could not recover.  Sales totals keep
        the §5.1 formulas untouched — reward value sits beside them and
        never inside them.
        """
        self._validate_range(date_from, date_to)
        block = self.repo.loyalty_block(
            date_from=date_from, date_to=date_to, device_id=device_id
        )
        shortfall_points, shortfall_cashback = self.repo.loyalty_shortfalls(
            date_from=date_from, date_to=date_to, device_id=device_id
        )
        rows, total = self.repo.loyalty_ledger_rows(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            page=page,
            page_size=page_size,
        )
        events = block["events"]

        def _aggregate(keys: tuple[str, ...]) -> tuple[int, Decimal, Decimal]:
            entries = 0
            points = _ZERO
            cashback = _ZERO
            for key in keys:
                count, key_points, key_cashback = events.get(
                    key, (0, _ZERO, _ZERO)
                )
                entries += count
                points += key_points
                cashback += key_cashback
            return entries, points, cashback

        earn_entries, points_earned, cashback_earned = _aggregate(
            self._LOYALTY_EARN_EVENTS
        )
        redeem_entries, redeem_points, _redeem_cashback = _aggregate(("redeem",))
        reversal_entries, reverse_points, reverse_cashback = _aggregate(
            ("return_clawback", "void_clawback")
        )
        settlement_points = events.get(
            "debt_settlement_earn", (0, _ZERO, _ZERO)
        )[1]

        # Read-only settings lookup (never creates the singleton row).
        outstanding_points = block["outstanding_points"]
        outstanding_cashback = block["outstanding_cashback"]

        return LoyaltyReportResponse(
            date_from=date_from,
            date_to=date_to,
            device_id=device_id,
            sales_gross=_money(block["sales_gross"]),
            sales_after_discounts=_money(block["sales_after_discounts"]),
            invoice_count=block["invoice_count"],
            points_earned=to_decimal(points_earned),
            cashback_earned=_money(cashback_earned),
            earn_entries=earn_entries,
            settlement_points=to_decimal(settlement_points),
            points_redeemed=to_decimal(-redeem_points),
            redemption_value=_money(block["redemption_value"]),
            redeem_entries=redeem_entries,
            points_reversed=to_decimal(-reverse_points),
            cashback_reversed=_money(-reverse_cashback),
            reversal_entries=reversal_entries,
            points_restored=to_decimal(block["restore_points"]),
            restored_value=_money(block["restore_value"]),
            restore_entries=block["restore_entries"],
            shortfall_points=to_decimal(shortfall_points),
            shortfall_cashback=_money(shortfall_cashback),
            adjustment_points=to_decimal(block["adjustment_points"]),
            adjustment_cashback=_money(block["adjustment_cashback"]),
            outstanding_points=to_decimal(outstanding_points),
            outstanding_cashback=_money(outstanding_cashback),
            accounts_with_balance=block["accounts_with_balance"],
            events=[
                LoyaltyEventTotals(
                    event_type=event_type,
                    entries=events[event_type][0],
                    points_delta=to_decimal(events[event_type][1]),
                    cashback_delta=_money(events[event_type][2]),
                )
                for event_type in self._LOYALTY_EVENT_ORDER
                if events.get(event_type, (0,))[0] > 0
            ],
            items=[
                LoyaltyLedgerRow(
                    entry_id=row["entry"].id,
                    created_at=row["entry"].created_at,
                    customer_id=row["customer_id"],
                    customer_name=row["customer_name"],
                    event_type=row["entry"].event_type,
                    points_delta=to_decimal(row["entry"].points_delta),
                    cashback_delta=_money(row["entry"].cashback_delta),
                    balance_after_points=to_decimal(
                        row["entry"].balance_after_points
                    ),
                    balance_after_cashback=_money(
                        row["entry"].balance_after_cashback
                    ),
                    invoice_number=row["invoice_number"],
                    sale_id=row["entry"].sale_id,
                    return_id=row["entry"].return_id,
                    note=row["entry"].note,
                )
                for row in rows
            ],
            total=total,
            page=page,
            page_size=page_size,
            pages=self._pages(total, page_size),
        )

    # ------------------------------------------------------------------
    # §7 dashboard
    # ------------------------------------------------------------------

    def dashboard(
        self,
        *,
        date_from: date | None = None,
        date_to: date | None = None,
    ) -> DashboardResponse:
        today = self._utc_today()
        date_from = date_from or today
        date_to = date_to or today
        self._validate_range(date_from, date_to)

        # "today" KPIs reuse the very same §5.1–§5.3 formulas (C1: UTC day).
        today_fields, _block = self._financial_fields(date_from=today, date_to=today)
        counts = self.repo.snapshot_counts()
        stock_value = self.inventory.total_stock_value()
        ar_outstanding, customers_with_debt = self.customers.total_outstanding()

        recent = self.repo.recent_sales(date_from=date_from, date_to=date_to, limit=5)
        top_rows, _total, _line_values = self.repo.product_rows(
            date_from=date_from,
            date_to=date_to,
            sort="net_revenue",
            page=1,
            page_size=5,
        )

        return DashboardResponse(
            date_from=date_from,
            date_to=date_to,
            today_sales=today_fields["sales_after_discounts"],
            today_invoices=today_fields["invoice_count"],
            today_net_profit=today_fields["net_profit"],
            today_expenses=today_fields["expenses_total"],
            total_products=counts["total_products"],
            total_customers=counts["total_customers"],
            stock_value=_money(stock_value),
            low_stock_count=counts["low_stock_count"],
            customers_with_debt=customers_with_debt,
            total_debt=_money(ar_outstanding),
            recent_sales=[
                DashboardRecentSale(
                    sale_id=row["sale"].id,
                    invoice_number=row["sale"].invoice_number,
                    sale_date=row["sale"].sale_date,
                    total=_money(row["sale"].total),
                    payment_method=row["sale"].payment_method,
                    customer_name=row["customer_name"],
                )
                for row in recent
            ],
            top_products=self._top_products(top_rows),
        )

    @classmethod
    def _top_products(cls, rows: list[dict[str, Any]]) -> list[DashboardTopProduct]:
        out: list[DashboardTopProduct] = []
        for row in rows:
            product = cls._product_row(row)
            out.append(
                DashboardTopProduct(
                    item_id=product.item_id,
                    kind=product.kind,
                    name=product.name,
                    net_revenue=product.net_revenue,
                    qty_sold=product.qty_sold,
                    gross_profit=product.gross_profit,
                )
            )
        return out
