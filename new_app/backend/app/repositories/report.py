"""Report aggregates (Phase 14).

Every report is ONE ``GROUP BY`` per fact source, merged with ``UNION ALL`` so
that no figure is ever summed in Python.  The service layer only quantises and
derives per-row values (margins, percentages, filled time buckets).

Date window (``docs/PHASE_14_REPORTS_DASHBOARD_ANALYSIS.md`` §6): a range is
``[date_from 00:00Z, (date_to + 1 day) 00:00Z)`` — byte-for-byte the expenses
convention (``repositories/expense.py``).  The timestamp column used by each
report is fixed by §5.9 (``sale_date`` / ``return_date`` / ``voided_at`` /
``expense_date`` / ``entry_date`` / ``purchase_date``).

§5.8 rows are keyed by ``(kind, item_id)`` so a pack summary is attributed to
its pack while component lines keep their own product row: the pack's COGS is
therefore counted exactly once and the row totals equal §5.1/§5.2.
"""

from __future__ import annotations

import uuid
from datetime import date, datetime, time, timedelta, timezone
from decimal import Decimal
from typing import Any

from sqlalchemy import and_, case, exists, extract, func, literal, or_, select, union_all
from sqlalchemy.ext.compiler import compiles
from sqlalchemy.orm import Session
from sqlalchemy.sql.functions import FunctionElement

from app.domain.unit_conversions import to_decimal
from app.models.catalog import Category, Product
from app.models.debt import DebtLedgerEntry
from app.models.enums import PaymentMethod, SaleStatus
from app.models.expense import Expense
from app.models.party import Customer, Supplier
from app.models.purchase import Purchase
from app.models.return_doc import Return, ReturnLine
from app.models.sale import Sale, SaleLine
from app.models.supplier_ledger import SupplierLedgerEntry
from app.models.user import User

# ---------------------------------------------------------------------------
# Window / expression helpers
# ---------------------------------------------------------------------------


def _start_of_day(value: date) -> datetime:
    return datetime.combine(value, time.min, tzinfo=timezone.utc)


def _window(column, date_from: date | None, date_to: date | None) -> list:
    """Inclusive calendar-day window on a UTC timestamp column (§6.1)."""
    conds: list = []
    if date_from is not None:
        conds.append(column >= _start_of_day(date_from))
    if date_to is not None:
        conds.append(column < _start_of_day(date_to + timedelta(days=1)))
    return conds


def _charged():
    """Charged lines only: product lines + pack summaries (§5.1 / §5.8).

    Pack component lines are never charged (``line_total = 0``); their COGS is
    reported on their own §5.8 row so it is counted exactly once.
    """
    return or_(SaleLine.product_id.is_(None), SaleLine.pack_id.is_(None))


def _sale_base_qty():
    """Document quantity expressed in base units (§5.2 ``base_qty``)."""
    return SaleLine.quantity * func.coalesce(SaleLine.selling_unit_multiplier, 1)


def _return_base_qty():
    """Return base quantity: stored when present, otherwise derived (§5.2)."""
    return func.coalesce(
        ReturnLine.quantity_base,
        ReturnLine.quantity * func.coalesce(ReturnLine.selling_unit_multiplier, 1),
    )


def _line_kind():
    """``product`` / ``pack`` / ``component`` discriminator for §5.8 rows."""
    return case(
        (SaleLine.product_id.is_(None), "pack"),
        (SaleLine.product_id.isnot(None) & SaleLine.pack_id.isnot(None), "component"),
        else_="product",
    )


def _return_line_kind():
    return case(
        (ReturnLine.product_id.is_(None), "pack"),
        (ReturnLine.product_id.isnot(None) & ReturnLine.pack_id.isnot(None), "component"),
        else_="product",
    )


def _year(column):
    return extract("year", column)


def _month(column):
    return extract("month", column)


def _day(column):
    return extract("day", column)


def _hour(column):
    return extract("hour", column)


class DayBucket(FunctionElement):
    """UTC calendar day of a timestamp column (§6.1 bucketing, assumption A1).

    ``CAST(ts AT TIME ZONE 'UTC' AS DATE)`` on PostgreSQL and
    ``strftime('%Y-%m-%d', ts)`` on SQLite. Both forms are the *UTC* calendar
    day — the same boundary rule as the aware-UTC window filters in
    ``_window()`` (A1/C1) — expressed as one value expression so the planner
    can HashAggregate instead of sorting every row by three EXTRACT
    expressions (§15 mechanism). Explicit ``AT TIME ZONE 'UTC'`` keeps the
    buckets session-timezone independent on PostgreSQL.
    """

    name = "day_bucket"
    inherit_cache = True


class HourBucket(FunctionElement):
    """UTC hour-truncated timestamp (§6.1 hourly/peak bucketing, A1/C1)."""

    name = "hour_bucket"
    inherit_cache = True


@compiles(DayBucket)
def _default_day_bucket(element, compiler, **kw):  # noqa: ANN001
    return (
        f"CAST({compiler.process(element.clauses, **kw)} "
        "AT TIME ZONE 'UTC' AS DATE)"
    )


@compiles(DayBucket, "sqlite")
def _sqlite_day_bucket(element, compiler, **kw):  # noqa: ANN001
    return f"strftime('%Y-%m-%d', {compiler.process(element.clauses, **kw)})"


@compiles(HourBucket)
def _default_hour_bucket(element, compiler, **kw):  # noqa: ANN001
    return (
        f"date_trunc('hour', {compiler.process(element.clauses, **kw)} "
        "AT TIME ZONE 'UTC')"
    )


@compiles(HourBucket, "sqlite")
def _sqlite_hour_bucket(element, compiler, **kw):  # noqa: ANN001
    return (
        "strftime('%Y-%m-%d %H:00:00', "
        f"{compiler.process(element.clauses, **kw)})"
    )


def _union(parts: list):
    if len(parts) == 1:
        return parts[0]
    return union_all(*parts)


# §5.8 / §8 R2 — the §5.8 row-identity reports never return more rows than
# this (products capped at 500, categories ≤ 500 by construction).
REPORT_ROW_CAP = 500


class ReportRepository:
    """Read-only aggregates behind every Phase 14 report surface."""

    def __init__(self, db: Session) -> None:
        self.db = db

    # ------------------------------------------------------------------
    # §5.1–§5.5 financial building blocks
    # ------------------------------------------------------------------

    @staticmethod
    def _sales_sums() -> list:
        """§5.1/§5.3/§5.4 aggregates over the window (raw, unquantised)."""
        return [
            func.coalesce(func.sum(Sale.subtotal), 0),
            func.coalesce(func.sum(Sale.total), 0),
            func.count(Sale.id),
            func.coalesce(func.sum(Sale.subtotal - Sale.total - Sale.discount), 0),
            func.coalesce(func.sum(Sale.discount), 0),
            func.coalesce(func.sum(Sale.subtotal - Sale.total), 0),
            func.coalesce(
                func.sum(
                    case(
                        (Sale.payment_method == PaymentMethod.CASH.value, Sale.paid - Sale.change),
                        else_=0,
                    )
                ),
                0,
            ),
            func.coalesce(
                func.sum(
                    case(
                        (Sale.payment_method == PaymentMethod.CARD.value, Sale.paid - Sale.change),
                        else_=0,
                    )
                ),
                0,
            ),
            func.coalesce(
                func.sum(
                    case((Sale.payment_method == PaymentMethod.PARTIAL.value, Sale.paid), else_=0)
                ),
                0,
            ),
            func.coalesce(func.sum(Sale.change), 0),
            # §5.4/§5.5: identical formula, so both fields share one sum.
            func.coalesce(
                func.sum(case((Sale.total > Sale.paid, Sale.total - Sale.paid), else_=0)),
                0,
            ),
        ]

    def financial_block(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        sales_values: dict[str, Any] | None = None,
        line_values: dict[str, Any] | None = None,
        include_device_rows: bool = False,
    ) -> dict[str, Any]:
        """Raw (unquantised) sums for the financial report.

        Covers §5.1 (sales), §5.2 (cost), §5.4 (payment split) and the period
        part of §5.5 (debt movement).  Expenses and the AR snapshot are added
        by the service through the existing repositories.

        ``sales_values`` / ``line_values`` let a report that already grouped
        the same window (§5.8 time reports) feed its window totals in instead
        of re-scanning ``sales`` / ``sale_lines`` (§15 mechanism).
        ``include_device_rows`` adds the §5.7 breakdown (financial report
        only — it needs a per-device grouping the time reports don't do).
        """
        sale_where = [
            Sale.status == SaleStatus.COMPLETED.value,
            *_window(Sale.sale_date, date_from, date_to),
        ]
        if device_id:
            sale_where.append(Sale.device_id == device_id)

        if sales_values is None:
            sums = self._sales_sums()
            if include_device_rows:
                # §15: ONE scan of `sales` — per-device rows (§5.7) plus the
                # §5.1/§5.3/§5.4 grand totals as window columns over those
                # grouped rows (`SUM(...) OVER ()` after GROUP BY; portable
                # where GROUPING SETS/ROLLUP are not).
                stmt = (
                    select(Sale.device_id, *sums, *(func.sum(expr).over() for expr in sums))
                    .where(*sale_where)
                    .group_by(Sale.device_id)
                )
                rows = self.db.execute(stmt).all()
                if rows:
                    (
                        gross,
                        total,
                        invoice_count,
                        line_discounts,
                        invoice_discounts,
                        discounts_total,
                        paid_cash,
                        paid_card,
                        paid_partial,
                        change_total,
                        debt_created,
                    ) = rows[0][12:23]
                else:
                    (
                        gross,
                        total,
                        invoice_count,
                        line_discounts,
                        invoice_discounts,
                        discounts_total,
                        paid_cash,
                        paid_card,
                        paid_partial,
                        change_total,
                        debt_created,
                    ) = (0,) * 11
                device_sales = {
                    # select is (device_id, *sums, *windows) with _sales_sums()
                    # = subtotal, total, count, … → breakdown stores
                    # (invoice_count, sales_total).
                    row[0]: (int(row[3] or 0), to_decimal(row[2] or 0)) for row in rows
                }
            else:
                (
                    gross,
                    total,
                    invoice_count,
                    line_discounts,
                    invoice_discounts,
                    discounts_total,
                    paid_cash,
                    paid_card,
                    paid_partial,
                    change_total,
                    debt_created,
                ) = self.db.execute(select(*sums).where(*sale_where)).one()
                device_sales = {}
        else:
            gross = sales_values["gross_sales"]
            total = sales_values["sales_after_discounts"]
            invoice_count = sales_values["invoice_count"]
            line_discounts = sales_values["line_discounts"]
            invoice_discounts = sales_values["invoice_discounts"]
            discounts_total = sales_values["discounts_total"]
            paid_cash = sales_values["paid_cash"]
            paid_card = sales_values["paid_card"]
            paid_partial = sales_values["paid_partial"]
            change_total = sales_values["change_total"]
            debt_created = sales_values["debt_created"]
            device_sales = {}

        if line_values is None:
            # One scan of sale_lines: document units (charged lines only) plus
            # §5.2 cost, which counts *every* line — pack summaries carry cost
            # 0 and their component lines carry the real cost, so both are
            # needed here.
            items_sold, cogs = self.db.execute(
                select(
                    func.coalesce(
                        func.sum(case((_charged(), SaleLine.quantity), else_=0)),
                        0,
                    ),
                    func.coalesce(func.sum(SaleLine.unit_cost * _sale_base_qty()), 0),
                )
                .select_from(SaleLine)
                .join(Sale, Sale.id == SaleLine.sale_id)
                .where(*sale_where)
            ).one()
        else:
            items_sold = line_values["items_sold"]
            cogs = line_values["cogs"]

        return_where: list = list(_window(Return.return_date, date_from, date_to))
        if device_id:
            return_where.append(Return.device_id == device_id)

        # §5.7 device rows AND the §5.1 returns totals from ONE grouping:
        # the grand count/total come from SUM() OVER () across the grouped
        # rows (the grand total of cnt is not COUNT(*).over(), which would
        # only count device groups), so the standalone count+sum scan is
        # unnecessary (§15 mechanism).
        _ret_g = (
            select(
                Return.device_id,
                func.count(Return.id).label("invoice_count"),
                func.coalesce(func.sum(Return.total), 0).label("returns_total"),
            )
            .where(*return_where)
            .group_by(Return.device_id)
            .subquery()
        )
        returns_rows = self.db.execute(
            select(
                _ret_g.c.device_id,
                _ret_g.c.invoice_count,
                _ret_g.c.returns_total,
                func.sum(_ret_g.c.invoice_count).over(),
                func.sum(_ret_g.c.returns_total).over(),
            ).select_from(_ret_g)
        ).all()
        if returns_rows:
            returns_count = returns_rows[0][3]
            returns_total = returns_rows[0][4]
        else:
            returns_count, returns_total = 0, 0

        # §5.7 device rows: sales side came from the grouped branch above,
        # returns side from the grouping above — merged like the legacy
        # UNION did, without a second full scan of `sales`.
        device_rows: list[dict[str, Any]] = []
        if include_device_rows:
            device_returns: dict[str | None, Any] = {
                row[0]: to_decimal(row[2] or 0) for row in returns_rows
            }

            device_rows = [
                {
                    "device_id": device_id,
                    "invoice_count": invoice_count,
                    "sales_total": sales_total,
                    "returns_total": device_returns.get(device_id, Decimal("0")),
                }
                for device_id, (invoice_count, sales_total) in device_sales.items()
            ]
            for device_id, returns_total in device_returns.items():
                if device_id not in device_sales:
                    device_rows.append(
                        {
                            "device_id": device_id,
                            "invoice_count": 0,
                            "sales_total": Decimal("0"),
                            "returns_total": returns_total,
                        }
                    )
            device_rows.sort(key=lambda row: row["sales_total"], reverse=True)

        # One round trip for the two remaining independent scalars
        # (§5.2 return cost, §5.5 debt collected): each scalar subquery is
        # always single-row, so both fit in one SELECT.
        cost_subq = (
            select(func.coalesce(func.sum(ReturnLine.unit_cost * _return_base_qty()), 0))
            .select_from(ReturnLine)
            .join(Return, Return.id == ReturnLine.return_id)
            .where(*return_where)
            .scalar_subquery()
        )
        debt_subq = (
            select(func.coalesce(func.sum(DebtLedgerEntry.amount), 0))
            .where(
                DebtLedgerEntry.entry_type == "payment",
                *_window(DebtLedgerEntry.entry_date, date_from, date_to),
            )
            .scalar_subquery()
        )
        returns_cost, debt_collected = self.db.execute(
            select(cost_subq, debt_subq)
        ).one()

        return {
            "gross_sales": to_decimal(gross),
            "line_discounts": to_decimal(line_discounts),
            "invoice_discounts": to_decimal(invoice_discounts),
            "discounts_total": to_decimal(discounts_total),
            "sales_after_discounts": to_decimal(total),
            "invoice_count": int(invoice_count or 0),
            "items_sold": to_decimal(items_sold),
            "paid_cash": to_decimal(paid_cash),
            "paid_card": to_decimal(paid_card),
            "paid_partial": to_decimal(paid_partial),
            "change_total": to_decimal(change_total),
            "debt_created": to_decimal(debt_created),
            "outstanding_debt": to_decimal(debt_created),
            "cogs": to_decimal(cogs),
            "returns_count": int(returns_count or 0),
            "returns_total": to_decimal(returns_total),
            "returns_cost": to_decimal(returns_cost or 0),
            "debt_collected": to_decimal(debt_collected or 0),
            "device_rows": device_rows,
        }

    # ------------------------------------------------------------------
    # §5.8 — product / category row aggregation
    # ------------------------------------------------------------------

    # §15 mechanism: a report's OWN grouped rows carry grand-total window
    # columns (`SUM(SUM(x)) OVER ()`), which the service feeds into
    # financial_block() as sales_values/line_values instead of letting it
    # re-scan `sales` / `sale_lines`.  Keys are financial_block's value keys,
    # values are the parts' column names (day parts label sales net_sales,
    # hour parts label it sales_total; the item aggregation names its charged
    # quantity column charged_qty while the time parts call it items_sold).
    _LINE_TOTALS_ITEM: dict[str, str] = {"items_sold": "charged_qty", "cogs": "cogs"}
    _LINE_TOTALS_TIME: dict[str, str] = {"items_sold": "items_sold", "cogs": "cogs"}
    _SALES_TOTALS_DAY: dict[str, str] = {
        "sales_after_discounts": "net_sales",
        "invoice_count": "invoice_count",
        "gross_sales": "gross",
        "line_discounts": "line_discounts",
        "invoice_discounts": "invoice_discounts",
        "discounts_total": "discounts_total",
        "paid_cash": "paid_cash",
        "paid_card": "paid_card",
        "paid_partial": "paid_partial",
        "change_total": "change_total",
        "debt_created": "debt_created",
    }
    _SALES_TOTALS_HOUR: dict[str, str] = dict(
        _SALES_TOTALS_DAY, sales_after_discounts="sales_total"
    )

    @staticmethod
    def _window_totals(mapping: dict[str, str], agg) -> list:
        """Grand totals over the full grouped set (computed before LIMIT)."""
        return [
            func.sum(func.sum(getattr(agg.c, column))).over().label(key)
            for key, column in mapping.items()
        ]

    @staticmethod
    def _parse_totals(mapping: dict[str, str], row, offset: int) -> dict[str, Any]:
        values: dict[str, Any] = {}
        for index, key in enumerate(mapping):
            raw = row[offset + index]
            values[key] = int(raw or 0) if key == "invoice_count" else to_decimal(raw or 0)
        return values

    @staticmethod
    def _zero_totals(mapping: dict[str, str]) -> dict[str, Any]:
        return {key: (0 if key == "invoice_count" else Decimal("0")) for key in mapping}

    def _item_agg(self, *, date_from: date, date_to: date, device_id: str | None):
        """Sales side UNION ALL returns side, grouped by ``(kind, item_id)``."""
        sale_where = [
            Sale.status == SaleStatus.COMPLETED.value,
            *_window(Sale.sale_date, date_from, date_to),
        ]
        return_where: list = list(_window(Return.return_date, date_from, date_to))
        if device_id:
            sale_where.append(Sale.device_id == device_id)
            return_where.append(Return.device_id == device_id)

        # §15 mechanism: aggregate on (kind, item_id) alone first — name,
        # sku and category are functionally determined by the item, so the
        # catalog joins below run against the ~hundreds of grouped rows
        # instead of every sale line in the window.
        sales_grouped = (
            select(
                func.coalesce(SaleLine.product_id, SaleLine.pack_id).label("item_id"),
                _line_kind().label("kind"),
                func.max(SaleLine.product_name).label("line_name"),
                func.coalesce(func.sum(_sale_base_qty()), 0).label("qty_sold"),
                func.coalesce(func.sum(SaleLine.line_total + SaleLine.line_discount), 0).label(
                    "gross"
                ),
                func.coalesce(func.sum(SaleLine.line_discount), 0).label("line_discounts"),
                func.coalesce(
                    func.sum(
                        Sale.discount
                        * (SaleLine.line_total + SaleLine.line_discount)
                        / func.nullif(Sale.subtotal, 0)
                    ),
                    0,
                ).label("invoice_share"),
                func.coalesce(func.sum(SaleLine.unit_cost * _sale_base_qty()), 0).label("cogs"),
                # §5.1 items_sold (charged-line document units) — exposed so
                # product/category statements can carry window totals for the
                # report's own items_sold instead of re-scanning sale_lines.
                func.coalesce(
                    func.sum(case((_charged(), SaleLine.quantity), else_=0)),
                    0,
                ).label("charged_qty"),
            )
            .select_from(SaleLine)
            .join(Sale, Sale.id == SaleLine.sale_id)
            .where(*sale_where)
            .group_by(
                func.coalesce(SaleLine.product_id, SaleLine.pack_id),
                _line_kind(),
            )
            .subquery("sales_item_group")
        )

        sales_part = (
            select(
                sales_grouped.c.item_id,
                sales_grouped.c.kind,
                func.coalesce(Product.name, sales_grouped.c.line_name).label("name"),
                Product.sku.label("sku"),
                Product.category_id.label("category_id"),
                Category.name.label("category"),
                sales_grouped.c.qty_sold,
                sales_grouped.c.gross,
                sales_grouped.c.line_discounts,
                sales_grouped.c.invoice_share,
                sales_grouped.c.cogs,
                literal(0).label("return_qty"),
                literal(0).label("return_amount"),
                literal(0).label("return_cost"),
                sales_grouped.c.charged_qty,
            )
            # Packs have no product row: their line snapshot carries the name.
            .outerjoin(
                Product,
                and_(
                    Product.id == sales_grouped.c.item_id,
                    sales_grouped.c.kind != "pack",
                ),
            )
            .outerjoin(Category, Category.id == Product.category_id)
        )

        returns_part = (
            select(
                func.coalesce(ReturnLine.product_id, ReturnLine.pack_id).label("item_id"),
                _return_line_kind().label("kind"),
                func.coalesce(Product.name, ReturnLine.product_name).label("name"),
                Product.sku.label("sku"),
                Product.category_id.label("category_id"),
                Category.name.label("category"),
                func.coalesce(func.sum(0), 0).label("qty_sold"),
                func.coalesce(func.sum(0), 0).label("gross"),
                func.coalesce(func.sum(0), 0).label("line_discounts"),
                func.coalesce(func.sum(0), 0).label("invoice_share"),
                func.coalesce(func.sum(0), 0).label("cogs"),
                func.coalesce(func.sum(_return_base_qty()), 0).label("return_qty"),
                # Refund net of the pro-rata invoice share — same rule as
                # services/returns.py:1158-1166 — so §5.8 row totals equal
                # returns_total of §5.1.
                func.coalesce(
                    func.sum(
                        ReturnLine.line_total
                        - Return.discount * ReturnLine.line_total / func.nullif(Return.subtotal, 0)
                    ),
                    0,
                ).label("return_amount"),
                func.coalesce(func.sum(ReturnLine.unit_cost * _return_base_qty()), 0).label(
                    "return_cost"
                ),
                literal(0).label("charged_qty"),
            )
            .select_from(ReturnLine)
            .join(Return, Return.id == ReturnLine.return_id)
            .outerjoin(Product, Product.id == ReturnLine.product_id)
            .outerjoin(Category, Category.id == Product.category_id)
            .where(*return_where)
            .group_by(
                func.coalesce(ReturnLine.product_id, ReturnLine.pack_id),
                _return_line_kind(),
                func.coalesce(Product.name, ReturnLine.product_name),
                Product.sku,
                Product.category_id,
                Category.name,
            )
        )

        # Each side is already at (kind, item_id) grain; the caller's outer
        # GROUP BY merges the sales row with the returns row per item (§15:
        # one GROUP BY per side plus one cheap merge over grouped rows).
        return _union([sales_part, returns_part])

    def product_rows(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        sort: str = "net_revenue",
        page: int = 1,
        page_size: int = 100,
    ) -> tuple[list[dict[str, Any]], int, dict[str, Any]]:
        """§5.8 rows for one item, sorted and paginated server-side (§8 R2).

        Also returns the report's own line totals (window over the grouped
        set) so the caller can skip financial_block's sale_lines scan (§15).
        """
        agg = self._item_agg(
            date_from=date_from, date_to=date_to, device_id=device_id
        ).subquery("product_agg")

        revenue = func.sum(agg.c.gross) - func.sum(agg.c.line_discounts) - func.sum(
            agg.c.invoice_share
        )
        return_amount = func.sum(agg.c.return_amount)
        profit = revenue - return_amount - (func.sum(agg.c.cogs) - func.sum(agg.c.return_cost))
        margin = case(
            (revenue - return_amount > 0, profit * 100 / (revenue - return_amount)),
            else_=0,
        )
        order_map = {
            "net_revenue": revenue,
            "qty_sold": func.sum(agg.c.qty_sold),
            "gross_profit": profit,
            "return_qty": func.sum(agg.c.return_qty),
            "margin_pct": margin,
        }

        # §5.8 caps this report at REPORT_ROW_CAP rows: aggregate once, order
        # and cap in SQL, then take the requested page window from that capped
        # list. A separate COUNT would run the whole aggregation a second time
        # (§15: one GROUP BY per report).
        stmt = (
            select(
                agg.c.item_id,
                agg.c.kind,
                agg.c.name,
                agg.c.sku,
                agg.c.category_id,
                agg.c.category,
                func.sum(agg.c.qty_sold),
                func.sum(agg.c.gross),
                func.sum(agg.c.line_discounts),
                func.sum(agg.c.invoice_share),
                func.sum(agg.c.cogs),
                func.sum(agg.c.return_qty),
                func.sum(agg.c.return_amount),
                func.sum(agg.c.return_cost),
            )
            .group_by(
                agg.c.item_id,
                agg.c.kind,
                agg.c.name,
                agg.c.sku,
                agg.c.category_id,
                agg.c.category,
            )
            .order_by(order_map[sort].desc().nulls_last(), agg.c.name.asc())
            .limit(REPORT_ROW_CAP)
        )
        # Window columns: computed over ALL grouped rows (before LIMIT), so
        # the totals never depend on the row cap.
        stmt = stmt.add_columns(*self._window_totals(self._LINE_TOTALS_ITEM, agg))
        result = self.db.execute(stmt).all()
        line_values = (
            self._parse_totals(self._LINE_TOTALS_ITEM, result[0], 14)
            if result
            else self._zero_totals(self._LINE_TOTALS_ITEM)
        )
        rows = [self._row_to_dict(row) for row in result]
        offset = (page - 1) * page_size
        return rows[offset : offset + page_size], len(rows), line_values

    def category_rows(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        limit: int = 500,
    ) -> tuple[list[dict[str, Any]], dict[str, Any]]:
        """§5.8 aggregated by category (NULL category → "uncategorized", §8 R3).

        Also returns the report's own line totals (window over the grouped
        set) so the caller can skip financial_block's sale_lines scan (§15).
        """
        agg = self._item_agg(
            date_from=date_from, date_to=date_to, device_id=device_id
        ).subquery("category_src")
        stmt = (
            select(
                agg.c.category_id,
                agg.c.category,
                func.sum(agg.c.qty_sold),
                func.sum(agg.c.gross),
                func.sum(agg.c.line_discounts),
                func.sum(agg.c.invoice_share),
                func.sum(agg.c.cogs),
                func.sum(agg.c.return_qty),
                func.sum(agg.c.return_amount),
                func.sum(agg.c.return_cost),
            )
            .group_by(agg.c.category_id, agg.c.category)
            .order_by(
                func.sum(agg.c.gross - agg.c.line_discounts - agg.c.invoice_share)
                .desc()
                .nulls_last(),
                agg.c.category.asc().nulls_last(),
            )
            .limit(limit)
        )
        stmt = stmt.add_columns(*self._window_totals(self._LINE_TOTALS_ITEM, agg))
        result = self.db.execute(stmt).all()
        line_values = (
            self._parse_totals(self._LINE_TOTALS_ITEM, result[0], 10)
            if result
            else self._zero_totals(self._LINE_TOTALS_ITEM)
        )
        rows = [
            {
                "category_id": row[0],
                "category": row[1],
                "qty_sold": to_decimal(row[2] or 0),
                "gross": to_decimal(row[3] or 0),
                "line_discounts": to_decimal(row[4] or 0),
                "invoice_discount_share": to_decimal(row[5] or 0),
                "cogs": to_decimal(row[6] or 0),
                "return_qty": to_decimal(row[7] or 0),
                "return_amount": to_decimal(row[8] or 0),
                "return_cost": to_decimal(row[9] or 0),
            }
            for row in result
        ]
        return rows, line_values

    @staticmethod
    def _row_to_dict(row) -> dict[str, Any]:
        return {
            "item_id": row[0],
            "kind": row[1],
            "name": row[2],
            "sku": row[3],
            "category_id": row[4],
            "category": row[5],
            "qty_sold": to_decimal(row[6] or 0),
            "gross": to_decimal(row[7] or 0),
            "line_discounts": to_decimal(row[8] or 0),
            "invoice_discount_share": to_decimal(row[9] or 0),
            "cogs": to_decimal(row[10] or 0),
            "return_qty": to_decimal(row[11] or 0),
            "return_amount": to_decimal(row[12] or 0),
            "return_cost": to_decimal(row[13] or 0),
        }

    # ------------------------------------------------------------------
    # §8 R4/R5/R6 — time buckets (every source aggregated in SQL)
    # ------------------------------------------------------------------

    _SALES_LEVEL_NAMES = (
        "gross",
        "line_discounts",
        "invoice_discounts",
        "discounts_total",
        "paid_cash",
        "paid_card",
        "paid_partial",
        "change_total",
        "debt_created",
    )

    @staticmethod
    def _sales_level_sums() -> list:
        """§5.1/§5.3/§5.4 sales-level sums for the sales part of a parts UNION."""
        return [
            func.coalesce(func.sum(Sale.subtotal), 0).label("gross"),
            func.coalesce(func.sum(Sale.subtotal - Sale.total - Sale.discount), 0).label(
                "line_discounts"
            ),
            func.coalesce(func.sum(Sale.discount), 0).label("invoice_discounts"),
            func.coalesce(func.sum(Sale.subtotal - Sale.total), 0).label("discounts_total"),
            func.coalesce(
                func.sum(
                    case(
                        (Sale.payment_method == PaymentMethod.CASH.value, Sale.paid - Sale.change),
                        else_=0,
                    )
                ),
                0,
            ).label("paid_cash"),
            func.coalesce(
                func.sum(
                    case(
                        (Sale.payment_method == PaymentMethod.CARD.value, Sale.paid - Sale.change),
                        else_=0,
                    )
                ),
                0,
            ).label("paid_card"),
            func.coalesce(
                func.sum(
                    case((Sale.payment_method == PaymentMethod.PARTIAL.value, Sale.paid), else_=0)
                ),
                0,
            ).label("paid_partial"),
            func.coalesce(func.sum(Sale.change), 0).label("change_total"),
            func.coalesce(
                func.sum(case((Sale.total > Sale.paid, Sale.total - Sale.paid), else_=0)), 0
            ).label("debt_created"),
        ]

    @staticmethod
    def _sales_level_zeros(zero) -> list:
        return [zero.label(name) for name in ReportRepository._SALES_LEVEL_NAMES]

    @staticmethod
    def _day_parts(date_from: date, date_to: date, device_id: str | None) -> list:
        sale_where = [
            Sale.status == SaleStatus.COMPLETED.value,
            *_window(Sale.sale_date, date_from, date_to),
        ]
        line_where = list(sale_where)
        return_where: list = list(_window(Return.return_date, date_from, date_to))
        if device_id:
            sale_where.append(Sale.device_id == device_id)
            line_where.append(Sale.device_id == device_id)
            return_where.append(Return.device_id == device_id)

        zero = func.coalesce(func.sum(0), 0)
        # §5.1/§5.3/§5.4 sales-level sums ride along on the sales part (same
        # scan) so the outer statement can emit grand totals as window columns
        # and financial_block can skip re-reading `sales` (§15).  Every other
        # part contributes the matching zero column so the UNION aligns.
        sales_level = ReportRepository._sales_level_sums()
        sales_level_zero = ReportRepository._sales_level_zeros(zero)
        # Each part groups by one day-bucket expression (§15: HashAggregate
        # instead of sorting every row by three EXTRACT expressions); the
        # y/m/d columns are derived from the bucket after the UNION merge.
        return [
            # sales (revenue, invoices)
            select(
                DayBucket(Sale.sale_date).label("bucket"),
                func.coalesce(func.sum(Sale.total), 0).label("net_sales"),
                func.count(Sale.id).label("invoice_count"),
                zero.label("items_sold"),
                zero.label("cogs"),
                zero.label("returns_total"),
                func.coalesce(func.sum(0), 0).label("returns_count"),
                zero.label("returns_cost"),
                zero.label("expenses"),
                *sales_level,
            )
            .where(*sale_where)
            .group_by(DayBucket(Sale.sale_date)),
            # sale lines (document items + cost): one scan — items count the
            # charged lines only, §5.2 cost counts every line.
            select(
                DayBucket(Sale.sale_date).label("bucket"),
                zero.label("net_sales"),
                zero.label("invoice_count"),
                func.coalesce(
                    func.sum(case((_charged(), SaleLine.quantity), else_=0)),
                    0,
                ).label("items_sold"),
                func.coalesce(func.sum(SaleLine.unit_cost * _sale_base_qty()), 0).label("cogs"),
                zero.label("returns_total"),
                func.coalesce(func.sum(0), 0).label("returns_count"),
                zero.label("returns_cost"),
                zero.label("expenses"),
                *sales_level_zero,
            )
            .select_from(SaleLine)
            .join(Sale, Sale.id == SaleLine.sale_id)
            .where(*line_where)
            .group_by(DayBucket(Sale.sale_date)),
            # returns (revenue reversal, count)
            select(
                DayBucket(Return.return_date).label("bucket"),
                zero.label("net_sales"),
                zero.label("invoice_count"),
                zero.label("items_sold"),
                zero.label("cogs"),
                func.coalesce(func.sum(Return.total), 0).label("returns_total"),
                func.count(Return.id).label("returns_count"),
                zero.label("returns_cost"),
                zero.label("expenses"),
                *sales_level_zero,
            )
            .where(*return_where)
            .group_by(DayBucket(Return.return_date)),
            # return lines (cost reversal)
            select(
                DayBucket(Return.return_date).label("bucket"),
                zero.label("net_sales"),
                zero.label("invoice_count"),
                zero.label("items_sold"),
                zero.label("cogs"),
                zero.label("returns_total"),
                func.coalesce(func.sum(0), 0).label("returns_count"),
                func.coalesce(func.sum(ReturnLine.unit_cost * _return_base_qty()), 0).label(
                    "returns_cost"
                ),
                zero.label("expenses"),
                *sales_level_zero,
            )
            .select_from(ReturnLine)
            .join(Return, Return.id == ReturnLine.return_id)
            .where(*return_where)
            .group_by(DayBucket(Return.return_date)),
            # posted expenses
            select(
                DayBucket(Expense.expense_date).label("bucket"),
                zero.label("net_sales"),
                zero.label("invoice_count"),
                zero.label("items_sold"),
                zero.label("cogs"),
                zero.label("returns_total"),
                func.coalesce(func.sum(0), 0).label("returns_count"),
                zero.label("returns_cost"),
                func.coalesce(func.sum(Expense.amount), 0).label("expenses"),
                *sales_level_zero,
            )
            .where(Expense.status == "posted", *_window(Expense.expense_date, date_from, date_to))
            .group_by(DayBucket(Expense.expense_date)),
        ]

    def daily_rows(
        self, *, date_from: date, date_to: date, device_id: str | None = None
    ) -> tuple[dict[tuple[int, int, int], dict[str, Any]], dict[str, Any], dict[str, Any]]:
        agg = _union(self._day_parts(date_from, date_to, device_id)).subquery("day_agg")
        # y/m/d are derived from the day bucket after the UNION merge (the
        # merged set is one row per source per day — a few thousand rows).
        y, m, d = _year(agg.c.bucket), _month(agg.c.bucket), _day(agg.c.bucket)
        stmt = select(
            y,
            m,
            d,
            func.sum(agg.c.net_sales),
            func.sum(agg.c.invoice_count),
            func.sum(agg.c.items_sold),
            func.sum(agg.c.cogs),
            func.sum(agg.c.returns_total),
            func.sum(agg.c.returns_count),
            func.sum(agg.c.returns_cost),
            func.sum(agg.c.expenses),
        ).group_by(y, m, d)
        # §15: grand totals from THIS report's own grouped rows (over all
        # days), fed to _report_totals instead of re-reading sales/sale_lines.
        sales_keys = list(self._SALES_TOTALS_DAY)
        stmt = stmt.add_columns(
            *self._window_totals(self._SALES_TOTALS_DAY, agg),
            *self._window_totals(self._LINE_TOTALS_TIME, agg),
        )
        result = self.db.execute(stmt).all()

        sales_values = (
            self._parse_totals(self._SALES_TOTALS_DAY, result[0], 11)
            if result
            else self._zero_totals(self._SALES_TOTALS_DAY)
        )
        line_values = (
            self._parse_totals(self._LINE_TOTALS_TIME, result[0], 11 + len(sales_keys))
            if result
            else self._zero_totals(self._LINE_TOTALS_TIME)
        )

        out: dict[tuple[int, int, int], dict[str, Any]] = {}
        for row in result:
            out[(int(row[0]), int(row[1]), int(row[2]))] = {
                "sales_total": to_decimal(row[3] or 0),
                "invoice_count": int(row[4] or 0),
                "items_sold": to_decimal(row[5] or 0),
                "cogs": to_decimal(row[6] or 0),
                "returns_total": to_decimal(row[7] or 0),
                "returns_count": int(row[8] or 0),
                "returns_cost": to_decimal(row[9] or 0),
                "expenses": to_decimal(row[10] or 0),
            }
        return out, sales_values, line_values

    @staticmethod
    def _hour_parts(date_from: date, date_to: date, device_id: str | None) -> list:
        sale_where = [
            Sale.status == SaleStatus.COMPLETED.value,
            *_window(Sale.sale_date, date_from, date_to),
        ]
        line_where = list(sale_where)
        return_where: list = list(_window(Return.return_date, date_from, date_to))
        if device_id:
            sale_where.append(Sale.device_id == device_id)
            line_where.append(Sale.device_id == device_id)
            return_where.append(Return.device_id == device_id)

        zero = func.coalesce(func.sum(0), 0)
        # Hour-truncated bucket per part — one value expression so the planner
        # can HashAggregate (§15); y/m/d/h derive from it after the merge.
        # cogs + §5.1/§5.3/§5.4 sums ride along so the outer statements can
        # emit grand totals as window columns (§15 — see _day_parts).
        sales_level = ReportRepository._sales_level_sums()
        sales_level_zero = ReportRepository._sales_level_zeros(zero)
        return [
            select(
                HourBucket(Sale.sale_date).label("bucket"),
                func.coalesce(func.sum(Sale.total), 0).label("sales_total"),
                func.count(Sale.id).label("invoice_count"),
                zero.label("returns_total"),
                func.coalesce(func.sum(0), 0).label("returns_count"),
                zero.label("items_sold"),
                zero.label("cogs"),
                *sales_level,
            )
            .where(*sale_where)
            .group_by(HourBucket(Sale.sale_date)),
            select(
                HourBucket(Sale.sale_date).label("bucket"),
                zero.label("sales_total"),
                zero.label("invoice_count"),
                zero.label("returns_total"),
                func.coalesce(func.sum(0), 0).label("returns_count"),
                func.coalesce(func.sum(SaleLine.quantity), 0).label("items_sold"),
                func.coalesce(func.sum(SaleLine.unit_cost * _sale_base_qty()), 0).label("cogs"),
                *sales_level_zero,
            )
            .select_from(SaleLine)
            .join(Sale, Sale.id == SaleLine.sale_id)
            .where(*line_where, _charged())
            .group_by(HourBucket(Sale.sale_date)),
            select(
                HourBucket(Return.return_date).label("bucket"),
                zero.label("sales_total"),
                zero.label("invoice_count"),
                func.coalesce(func.sum(Return.total), 0).label("returns_total"),
                func.count(Return.id).label("returns_count"),
                zero.label("items_sold"),
                zero.label("cogs"),
                *sales_level_zero,
            )
            .where(*return_where)
            .group_by(HourBucket(Return.return_date)),
        ]

    def hourly_rows(
        self, *, date_from: date, date_to: date, device_id: str | None = None
    ) -> tuple[dict[tuple[int, int, int, int], dict[str, Any]], dict[str, Any], dict[str, Any]]:
        agg = _union(self._hour_parts(date_from, date_to, device_id)).subquery("hour_agg")
        y, m, d, h = (
            _year(agg.c.bucket),
            _month(agg.c.bucket),
            _day(agg.c.bucket),
            _hour(agg.c.bucket),
        )
        stmt = select(
            y,
            m,
            d,
            h,
            func.sum(agg.c.sales_total),
            func.sum(agg.c.invoice_count),
            func.sum(agg.c.returns_total),
            func.sum(agg.c.returns_count),
            func.sum(agg.c.items_sold),
        ).group_by(y, m, d, h)
        # §15: grand totals from THIS report's own grouped rows, fed to
        # _report_totals instead of re-reading sales/sale_lines.
        sales_keys = list(self._SALES_TOTALS_HOUR)
        stmt = stmt.add_columns(
            *self._window_totals(self._SALES_TOTALS_HOUR, agg),
            *self._window_totals(self._LINE_TOTALS_TIME, agg),
        )
        result = self.db.execute(stmt).all()

        sales_values = (
            self._parse_totals(self._SALES_TOTALS_HOUR, result[0], 9)
            if result
            else self._zero_totals(self._SALES_TOTALS_HOUR)
        )
        line_values = (
            self._parse_totals(self._LINE_TOTALS_TIME, result[0], 9 + len(sales_keys))
            if result
            else self._zero_totals(self._LINE_TOTALS_TIME)
        )

        out: dict[tuple[int, int, int, int], dict[str, Any]] = {}
        for row in result:
            out[(int(row[0]), int(row[1]), int(row[2]), int(row[3]))] = {
                "sales_total": to_decimal(row[4] or 0),
                "invoice_count": int(row[5] or 0),
                "returns_total": to_decimal(row[6] or 0),
                "returns_count": int(row[7] or 0),
                "items_sold": to_decimal(row[8] or 0),
            }
        return out, sales_values, line_values

    def peak_rows(
        self, *, date_from: date, date_to: date, device_id: str | None = None
    ) -> tuple[dict[int, dict[str, Any]], dict[str, Any], dict[str, Any]]:
        """Bucket the lookback window by hour of day — exactly 24 rows (§8 R6)."""
        agg = _union(self._hour_parts(date_from, date_to, device_id)).subquery("peak_src")
        hour_of_day = _hour(agg.c.bucket)
        stmt = (
            select(
                hour_of_day,
                func.sum(agg.c.sales_total),
                func.sum(agg.c.invoice_count),
                func.sum(agg.c.returns_total),
                func.sum(agg.c.returns_count),
                func.sum(agg.c.items_sold),
            )
            .group_by(hour_of_day)
            .order_by(hour_of_day)
        )
        # §15: grand totals from THIS report's own grouped rows (the window
        # covers the same rows the §5.1 aggregate would for this lookback).
        sales_keys = list(self._SALES_TOTALS_HOUR)
        stmt = stmt.add_columns(
            *self._window_totals(self._SALES_TOTALS_HOUR, agg),
            *self._window_totals(self._LINE_TOTALS_TIME, agg),
        )
        result = self.db.execute(stmt).all()

        sales_values = (
            self._parse_totals(self._SALES_TOTALS_HOUR, result[0], 6)
            if result
            else self._zero_totals(self._SALES_TOTALS_HOUR)
        )
        line_values = (
            self._parse_totals(self._LINE_TOTALS_TIME, result[0], 6 + len(sales_keys))
            if result
            else self._zero_totals(self._LINE_TOTALS_TIME)
        )

        out: dict[int, dict[str, Any]] = {}
        for row in result:
            out[int(row[0])] = {
                "sales_total": to_decimal(row[1] or 0),
                "invoice_count": int(row[2] or 0),
                "returns_total": to_decimal(row[3] or 0),
                "returns_count": int(row[4] or 0),
                "items_sold": to_decimal(row[5] or 0),
            }
        return out, sales_values, line_values

    # ------------------------------------------------------------------
    # §8 R9 / R8 — sales detail and voided invoices
    # ------------------------------------------------------------------

    def sales_rows(
        self,
        *,
        date_from: date,
        date_to: date,
        status: str = "completed",
        payment_method: str | None = None,
        user_id: uuid.UUID | None = None,
        device_id: str | None = None,
        page: int = 1,
        page_size: int = 100,
    ) -> tuple[list[dict[str, Any]], dict[str, Decimal | int]]:
        where: list = list(_window(Sale.sale_date, date_from, date_to))
        if status != "all":
            where.append(Sale.status == status)
        if payment_method:
            where.append(Sale.payment_method == payment_method)
        if user_id:
            where.append(Sale.user_id == user_id)
        if device_id:
            where.append(Sale.device_id == device_id)

        count, subtotal, discounts, total, paid, change = self.db.execute(
            select(
                func.count(Sale.id),
                func.coalesce(func.sum(Sale.subtotal), 0),
                func.coalesce(func.sum(Sale.subtotal - Sale.total), 0),
                func.coalesce(func.sum(Sale.total), 0),
                func.coalesce(func.sum(Sale.paid), 0),
                func.coalesce(func.sum(Sale.change), 0),
            ).where(*where)
        ).one()

        totals: dict[str, Decimal | int] = {
            "count": int(count or 0),
            "subtotal": to_decimal(subtotal or 0),
            "discounts": to_decimal(discounts or 0),
            "total": to_decimal(total or 0),
            "paid": to_decimal(paid or 0),
            "change": to_decimal(change or 0),
        }

        stmt = (
            select(Sale, Customer.name, User.full_name)
            .outerjoin(Customer, Customer.id == Sale.customer_id)
            .outerjoin(User, User.id == Sale.user_id)
            .where(*where)
            .order_by(Sale.sale_date.desc().nulls_last(), Sale.invoice_number.desc())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
        rows = [
            {"sale": row[0], "customer_name": row[1], "user_name": row[2]}
            for row in self.db.execute(stmt).all()
        ]
        return rows, totals

    def voided_rows(
        self,
        *,
        date_from: date,
        date_to: date,
        device_id: str | None = None,
        page: int = 1,
        page_size: int = 100,
    ) -> tuple[list[dict[str, Any]], int]:
        where: list = [
            Sale.status == SaleStatus.VOID.value,
            Sale.voided_at.isnot(None),
            *_window(Sale.voided_at, date_from, date_to),
        ]
        if device_id:
            where.append(Sale.device_id == device_id)

        total = int(self.db.scalar(select(func.count(Sale.id)).where(*where)) or 0)

        line_count = (
            select(func.count(SaleLine.id)).where(SaleLine.sale_id == Sale.id).scalar_subquery()
        )
        stmt = (
            select(Sale, User.full_name, line_count.label("line_count"))
            .outerjoin(User, User.id == Sale.voided_by)
            .where(*where)
            .order_by(Sale.voided_at.desc().nulls_last())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
        rows = [
            {"sale": row[0], "voided_by_name": row[1], "line_count": int(row[2] or 0)}
            for row in self.db.execute(stmt).all()
        ]
        return rows, total

    # ------------------------------------------------------------------
    # §8 R7 — slow-moving stock
    # ------------------------------------------------------------------

    def slow_moving_rows(
        self,
        *,
        threshold: Decimal,
        date_from: date,
        date_to: date,
        page: int = 1,
        page_size: int = 100,
    ) -> tuple[list[dict[str, Any]], int]:
        """Active stock with no sale line inside the lookback window (§8 R7)."""
        recent = exists().where(
            SaleLine.product_id == Product.id,
            Sale.id == SaleLine.sale_id,
            *_window(Sale.sale_date, date_from, date_to),
        )
        where = [
            Product.archived_at.is_(None),
            Product.quantity > threshold,
            ~recent,
        ]
        total = int(self.db.scalar(select(func.count(Product.id)).where(*where)) or 0)

        last_sale = (
            select(func.max(Sale.sale_date))
            .where(SaleLine.product_id == Product.id, Sale.id == SaleLine.sale_id)
            .scalar_subquery()
        )
        stmt = (
            select(Product, Category.name, last_sale.label("last_sale_date"))
            .outerjoin(Category, Category.id == Product.category_id)
            .where(*where)
            .order_by(last_sale.asc().nulls_first(), Product.name.asc())
            .offset((page - 1) * page_size)
            .limit(page_size)
        )
        rows = [
            {"product": row[0], "category": row[1], "last_sale_date": row[2]}
            for row in self.db.execute(stmt).all()
        ]
        return rows, total

    # ------------------------------------------------------------------
    # §5.6 — supplier block
    # ------------------------------------------------------------------

    def supplier_block(self, *, date_from: date, date_to: date) -> dict[str, Any]:
        payable = self.db.scalar(
            select(
                func.coalesce(
                    func.sum(
                        case(
                            (SupplierLedgerEntry.entry_type == "purchase", SupplierLedgerEntry.amount),
                            (SupplierLedgerEntry.entry_type == "payment", -SupplierLedgerEntry.amount),
                            (
                                SupplierLedgerEntry.entry_type == "purchase_cancel",
                                -SupplierLedgerEntry.amount,
                            ),
                            else_=0,
                        )
                    ),
                    0,
                )
            )
        )
        purchases_total = self.db.scalar(
            select(func.coalesce(func.sum(Purchase.total), 0)).where(
                Purchase.status == "received",
                *_window(Purchase.purchase_date, date_from, date_to),
            )
        )
        supplier_paid = self.db.scalar(
            select(func.coalesce(func.sum(SupplierLedgerEntry.amount), 0)).where(
                SupplierLedgerEntry.entry_type == "payment",
                *_window(SupplierLedgerEntry.entry_date, date_from, date_to),
            )
        )
        suppliers_with_balance = int(
            self.db.scalar(select(func.count(Supplier.id)).where(Supplier.balance != 0)) or 0
        )
        return {
            "supplier_payable": to_decimal(payable or 0),
            "purchases_total": to_decimal(purchases_total or 0),
            "supplier_paid": to_decimal(supplier_paid or 0),
            "suppliers_with_balance": suppliers_with_balance,
        }

    # ------------------------------------------------------------------
    # Snapshots (§5.7 / §7)
    # ------------------------------------------------------------------

    def snapshot_counts(self) -> dict[str, int]:
        total_products = int(
            self.db.scalar(select(func.count(Product.id)).where(Product.archived_at.is_(None)))
            or 0
        )
        total_customers = int(self.db.scalar(select(func.count(Customer.id))) or 0)
        low_stock_count = int(
            self.db.scalar(
                select(func.count(Product.id)).where(
                    Product.archived_at.is_(None),
                    Product.quantity <= Product.low_stock_threshold,
                )
            )
            or 0
        )
        return {
            "total_products": total_products,
            "total_customers": total_customers,
            "low_stock_count": low_stock_count,
        }

    def recent_sales(
        self,
        *,
        date_from: date,
        date_to: date,
        limit: int = 5,
    ) -> list[dict[str, Any]]:
        stmt = (
            select(Sale, Customer.name)
            .outerjoin(Customer, Customer.id == Sale.customer_id)
            .where(
                Sale.status == SaleStatus.COMPLETED.value,
                *_window(Sale.sale_date, date_from, date_to),
            )
            .order_by(Sale.sale_date.desc().nulls_last())
            .limit(limit)
        )
        return [
            {"sale": row[0], "customer_name": row[1]}
            for row in self.db.execute(stmt).all()
        ]
