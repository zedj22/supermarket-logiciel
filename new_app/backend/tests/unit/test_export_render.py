"""Phase 15 Step B unit tests — export contract, renderers, DocumentData (§19.1).

Covers:

1.  ``cell()`` serialization parity with the frozen CSV builder.
2.  ``build_spec`` / ``pdf_blocks`` structure per report (titles, the
    landscape set, totals rules incl. deliberate empty cells, the
    sectioned financial PDF) and ``ExportFilters.meta_lines`` default
    omission rules.
3.  XLSX writer: title/meta/header/freeze/autofilter/RTL/formats/print
    setup, formula-injection guarding of data *and* label cells,
    write-only mode above 5 000 rows.
4.  ``sanitize_filename`` units (§17.2).
5.  PDF: 80 mm / A4 geometry, embedded fonts, Arabic shaping, report
    title/meta/generated_at/empty-message text (via the G7 ToUnicode
    extractor), RTL table structure via template flowables.
6.  DocumentData builders: pack line shapes, selling-unit base
    quantities, totals consistency, void/customer/cashier blocks and
    purchase lines without ``variant_name`` (regression).
"""

from __future__ import annotations

import io
import sys
import uuid
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from pathlib import Path
from types import SimpleNamespace

import pytest
from openpyxl import load_workbook
from reportlab.platypus import Table

from app.core.config import settings
from app.core.filenames import sanitize_filename
from app.exporting.contract import (
    EXPORT_ROW_LIMIT,
    ROW_LEVEL_REPORTS,
    ExportBlock,
    ExportFilters,
    ExportSpec,
    build_spec,
    cell,
    pdf_blocks,
)
from app.exporting.xlsx import render_xlsx
from app.printing.document_data import (
    DocumentNames,
    _line_name,
    build_purchase_document,
    build_return_document,
    build_sale_document,
    line_discounts_consistency,
)
from app.printing.labels import is_rtl, label
from app.printing.render import render_invoice, render_report_pdf
from app.printing.templates.invoice_a4 import _ITEM_HEADERS
from app.printing.templates.invoice_a4 import build_flowables as a4_flowables
from app.printing.templates.report_table import ReportTableBlock, ReportTableInput
from app.printing.text import format_datetime, format_money, format_qty, shape_text
from app.schemas.purchase import PurchaseLineResponse, PurchaseResponse
from app.schemas.report import (
    CategoryReportResponse,
    CategoryReportRow,
    DailyReportResponse,
    DailyReportRow,
    DeviceBreakdownRow,
    FinancialReportResponse,
    HourlyReportResponse,
    HourlyReportRow,
    PeakHourRow,
    PeakHoursReportResponse,
    ProductReportResponse,
    ProductReportRow,
    ReportTotals,
    SalesDetailResponse,
    SalesDetailRow,
    SalesDetailTotals,
    SlowMovingResponse,
    SlowMovingRow,
    SupplierReportResponse,
    VoidedReportResponse,
    VoidedSaleRow,
)
from app.schemas.returns import ReturnLineResponse, ReturnResponse
from app.schemas.sale import SaleLineResponse, SalePaymentResponse, SaleResponse

D = Decimal
_EPOCH = date(2026, 1, 1)
_END = date(2026, 1, 31)


# ── Helpers ───────────────────────────────────────────────────────────────


def _media_box(raw: bytes) -> tuple[float, float]:
    mb = raw.split(b"/MediaBox [")[1].split(b"]")[0].split()
    return float(mb[2]), float(mb[3])


def _pdf_text(raw: bytes) -> str:
    """Extract drawn text via the G7 spike ToUnicode extractor."""
    scripts = Path(__file__).resolve().parents[2] / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import g7_spike

    return "\n".join(text for _font, text in g7_spike.extract_text_blocks(raw))


def _report_totals(**over) -> ReportTotals:
    data = dict(
        gross_sales=D("1000.000"),
        discounts_total=D("50.000"),
        sales_after_discounts=D("950.000"),
        returns_count=1,
        returns_total=D("20.000"),
        net_sales=D("930.000"),
        cogs=D("600.000"),
        returns_cost=D("12.000"),
        cogs_net=D("588.000"),
        gross_profit=D("342.000"),
        expenses_total=D("30.000"),
        net_profit=D("312.000"),
        invoice_count=7,
        items_sold=D("42.000"),
    )
    data.update(over)
    return ReportTotals(**data)


_FIN_MONEY = [
    "gross_sales",
    "line_discounts",
    "invoice_discounts",
    "discounts_total",
    "sales_after_discounts",
    "returns_total",
    "net_sales",
    "items_sold",
    "cogs",
    "returns_cost",
    "cogs_net",
    "expenses_total",
    "expenses_drawer",
    "expenses_external",
    "gross_profit",
    "net_profit",
    "profit_margin_pct",
    "paid_cash",
    "paid_card",
    "paid_partial",
    "collected_total",
    "debt_created",
    "change_total",
    "outstanding_debt",
    "debt_collected",
    "ar_outstanding",
]


def _fin(**over) -> FinancialReportResponse:
    data: dict = {name: D("0.000") for name in _FIN_MONEY}
    data.update(
        date_from=_EPOCH,
        date_to=_END,
        returns_count=0,
        invoice_count=0,
        customers_with_debt=0,
        device_breakdown=[],
    )
    data.update(over)
    return FinancialReportResponse(**data)


def _products() -> ProductReportResponse:
    row = ProductReportRow(
        item_id=uuid.uuid4(),
        kind="product",
        name="Cola 1L",
        sku="SKU1",
        category="Drinks",
        qty_sold=D("10"),
        gross=D("1000.000"),
        line_discounts=D("0.000"),
        invoice_discount_share=D("0.000"),
        net_revenue=D("1000.000"),
        return_qty=D("0"),
        return_amount=D("0.000"),
        cogs=D("600.000"),
        return_cost=D("0.000"),
        gross_profit=D("400.000"),
        margin_pct=D("40.00"),
    )
    return ProductReportResponse(
        date_from=_EPOCH,
        date_to=_END,
        items=[row],
        total=1,
        page=1,
        page_size=500,
        pages=1,
        totals=_report_totals(),
    )


def _categories() -> CategoryReportResponse:
    row = CategoryReportRow(
        category="Drinks",
        qty_sold=D("10"),
        gross=D("1000.000"),
        line_discounts=D("0.000"),
        invoice_discount_share=D("0.000"),
        net_revenue=D("1000.000"),
        return_qty=D("0"),
        return_amount=D("0.000"),
        cogs=D("600.000"),
        return_cost=D("0.000"),
        gross_profit=D("400.000"),
        margin_pct=D("40.00"),
    )
    return CategoryReportResponse(
        date_from=_EPOCH, date_to=_END, items=[row], totals=_report_totals()
    )


def _daily() -> DailyReportResponse:
    row = DailyReportRow(
        date=_EPOCH,
        net_sales=D("930.000"),
        cogs_net=D("588.000"),
        gross_profit=D("342.000"),
        expenses=D("30.000"),
        net_profit=D("312.000"),
        invoice_count=7,
        items_sold=D("42.000"),
        returns_total=D("20.000"),
    )
    return DailyReportResponse(
        date_from=_EPOCH, date_to=_END, items=[row], totals=_report_totals()
    )


def _hourly() -> HourlyReportResponse:
    row = HourlyReportRow(
        hour=datetime(2026, 1, 1, 10, 0),
        net_sales=D("120.000"),
        sales_total=D("120.000"),
        returns_total=D("0.000"),
        invoice_count=2,
    )
    return HourlyReportResponse(
        date_from=_EPOCH, date_to=_END, items=[row], totals=_report_totals()
    )


def _peak() -> PeakHoursReportResponse:
    row = PeakHourRow(
        hour=10, net_sales=D("120.000"), invoice_count=2, items_sold=D("5.000")
    )
    return PeakHoursReportResponse(
        lookback_days=30,
        date_from=_EPOCH,
        date_to=_END,
        items=[row],
        totals=_report_totals(),
    )


def _slow() -> SlowMovingResponse:
    row = SlowMovingRow(
        product_id=uuid.uuid4(),
        name="Dust 500g",
        sku="SKU9",
        category="Clean",
        quantity=D("40.000"),
        low_stock_threshold=D("5.000"),
        stock_value=D("2400.000"),
        last_sale_date=None,
    )
    return SlowMovingResponse(
        days=30,
        threshold=D("0"),
        items=[row],
        total=1,
        page=1,
        page_size=100,
        pages=1,
    )


def _voided() -> VoidedReportResponse:
    row = VoidedSaleRow(
        sale_id=uuid.uuid4(),
        invoice_number="INV-00042",
        sale_date=datetime(2026, 1, 5, 12, 30),
        voided_at=datetime(2026, 1, 5, 13, 0),
        total=D("150.000"),
        payment_method="cash",
        void_reason="mistake",
        device_id="POS-1",
        line_count=3,
    )
    return VoidedReportResponse(
        date_from=_EPOCH,
        date_to=_END,
        items=[row],
        total=1,
        page=1,
        page_size=100,
        pages=1,
    )


def _sales() -> SalesDetailResponse:
    row = SalesDetailRow(
        sale_id=uuid.uuid4(),
        invoice_number="INV-00001",
        sale_date=datetime(2026, 1, 5, 9, 15),
        status="completed",
        customer_name="Bob",
        user_name="Admin",
        payment_method="cash",
        subtotal=D("200.000"),
        discounts=D("0.000"),
        total=D("200.000"),
        paid=D("200.000"),
        change=D("0.000"),
        device_id="POS-1",
    )
    totals = SalesDetailTotals(
        count=1,
        subtotal=D("200.000"),
        discounts=D("0.000"),
        total=D("200.000"),
        paid=D("200.000"),
        change=D("0.000"),
    )
    return SalesDetailResponse(
        date_from=_EPOCH,
        date_to=_END,
        status="completed",
        items=[row],
        total=1,
        page=1,
        page_size=100,
        pages=1,
        totals=totals,
    )


def _suppliers() -> SupplierReportResponse:
    return SupplierReportResponse(
        date_from=_EPOCH,
        date_to=_END,
        supplier_payable=D("500.000"),
        purchases_total=D("1500.000"),
        supplier_paid=D("1000.000"),
        suppliers_with_balance=2,
    )


def _payload(report: str):
    return {
        "financial": _fin,
        "products": _products,
        "categories": _categories,
        "daily": _daily,
        "hourly": _hourly,
        "peak-hours": _peak,
        "slow-moving": _slow,
        "voided": _voided,
        "sales": _sales,
        "suppliers": _suppliers,
    }[report]()


def _spec(report: str = "products", locale: str = "en", **over) -> ExportSpec:
    data = dict(
        report=report,
        title=label(f"report_{report.replace('-', '_')}", locale),
        store_name="Store X",
        locale=locale,
        meta_lines=["Period: 2026-01-01 - 2026-01-31"],
        blocks=[
            ExportBlock(
                headers=["Product", "Qty", "Margin"],
                rows=[["Widget", "10", "12.50"], ["Gadget", "3", "7.00"]],
                kinds=["text", "money", "percent"],
                totals=["Total", "13", ""],
            )
        ],
        landscape=report in ("products", "slow-moving", "voided", "sales"),
        row_count=2,
    )
    data.update(over)
    return ExportSpec(**data)


def _sale_line(**over) -> SaleLineResponse:
    data = dict(
        id=uuid.uuid4(),
        product_id=uuid.uuid4(),
        pack_id=None,
        variant_id=None,
        product_name="Cola",
        product_sku="SKU1",
        product_barcode=None,
        product_unit="piece",
        variant_name=None,
        selling_unit_name=None,
        selling_unit_multiplier=None,
        unit_price=D("100.000"),
        unit_cost=D("60.000"),
        quantity=D("2"),
        line_discount=D("0.000"),
        line_total=D("200.000"),
    )
    data.update(over)
    return SaleLineResponse(**data)


def _sale_payload(**over) -> SaleResponse:
    data = dict(
        id=uuid.uuid4(),
        invoice_number="INV-000123",
        client_request_id="req-1",
        customer_id=None,
        status="completed",
        subtotal=D("500.000"),
        discount=D("10.000"),
        total=D("490.000"),
        paid=D("490.000"),
        change=D("0.000"),
        debt=D("0.000"),
        payment_method="cash",
        device_id="POS-1",
        sale_date=datetime(2026, 1, 5, 10, 30),
        lines=[_sale_line()],
        payments=[
            SalePaymentResponse(
                id=uuid.uuid4(), method="cash", amount=D("490.000")
            )
        ],
    )
    data.update(over)
    return SaleResponse(**data)


def _purchase_payload(**over) -> PurchaseResponse:
    line = PurchaseLineResponse(
        id=uuid.uuid4(),
        product_id=uuid.uuid4(),
        product_name="Cement",
        product_sku="C01",
        product_unit="bag",
        purchase_unit_name=None,
        quantity=D("5"),
        unit_cost=D("50.000"),
        base_qty_equivalent=D("5"),
        line_total=D("250.000"),
    )
    data = dict(
        id=uuid.uuid4(),
        invoice_number="PUR-0001",
        status="received",
        supplier_id=uuid.uuid4(),
        supplier_name="BuildMart",
        user_id=uuid.uuid4(),
        subtotal=D("250.000"),
        discount=D("0.000"),
        total=D("250.000"),
        paid=D("0.000"),
        purchase_date=datetime(2026, 1, 6, 8, 0),
        lines=[line],
    )
    data.update(over)
    return PurchaseResponse(**data)


# ── 1. cell() ─────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        (None, ""),
        (True, "true"),
        (False, "false"),
        (D("10.000"), "10.000"),
        (D("-3.50"), "-3.50"),
        (date(2026, 3, 4), "2026-03-04"),
        (datetime(2026, 3, 4, 5, 6, 7, tzinfo=timezone.utc), "2026-03-04T05:06:07Z"),
        (datetime(2026, 3, 4, 5, 6, 7), "2026-03-04T05:06:07"),
        (
            datetime(2026, 3, 4, 5, 6, 7, tzinfo=timezone(timedelta(hours=2))),
            "2026-03-04T05:06:07+02:00",
        ),
        (1.5, "1.5"),
        (7, "7"),
        ("abc", "abc"),
    ],
)
def test_cell_serialization(value, expected):
    assert cell(value) == expected


def test_contract_constants():
    assert EXPORT_ROW_LIMIT == 50000
    assert ROW_LEVEL_REPORTS == ("products", "slow-moving", "voided", "sales")


# ── 2. build_spec / pdf_blocks structure ──────────────────────────────────


def test_financial_spec_structure():
    payload = _fin(
        gross_sales=D("100.000"),
        net_sales=D("100.000"),
        invoice_count=1,
        device_breakdown=[
            DeviceBreakdownRow(
                device_id="POS-1",
                invoice_count=1,
                net_sales=D("100.000"),
                share_pct=D("100.00"),
            )
        ],
    )
    spec = build_spec("financial", payload, locale="en")
    assert spec.landscape is False
    assert spec.row_count == 2  # main row + device row
    assert spec.title == label("report_financial", "en")
    assert spec.store_name == settings.STORE_NAME
    assert len(spec.blocks) == 2
    assert len(spec.blocks[0].headers) == 30
    assert spec.blocks[0].rows[0][0] == "2026-01-01 - 2026-01-31"
    assert spec.blocks[0].rows[0][8] == "100.000"  # net_sales
    assert spec.blocks[1].headers[0] == label("col_device", "en")

    sections = pdf_blocks("financial", payload, "en")
    assert len(sections) == 5  # sales / cost+profit / payment / debt / device
    assert all(section.totals is None for section in sections)
    assert sections[-1].headers[0] == label("col_device", "en")


@pytest.mark.parametrize(
    ("report", "expected"),
    [
        ("financial", False),
        ("products", True),
        ("categories", False),
        ("daily", False),
        ("hourly", False),
        ("peak-hours", False),
        ("slow-moving", True),
        ("voided", True),
        ("sales", True),
        ("suppliers", False),
    ],
)
def test_landscape_orientation_set(report, expected):
    spec = build_spec(report, _payload(report), locale="en")
    assert spec.landscape is expected
    assert spec.title == label(
        f"report_{report.replace('-', '_')}", "en"
    )


def test_totals_rules_match_csv_contract():
    products = build_spec("products", _payload("products"), locale="en")
    totals = products.blocks[0].totals
    assert totals is not None
    assert totals[0] == label("label_total", "en")
    # deliberate empty cells (no server aggregate) — same as the CSV
    for index in (1, 2, 5, 6, 8, 13):
        assert totals[index] == ""
    assert totals[7] == "930.000"  # net_sales

    for report in ("slow-moving", "voided"):
        spec = build_spec(report, _payload(report), locale="en")
        assert spec.blocks[0].totals is None

    sales = build_spec("sales", _payload("sales"), locale="en")
    sales_totals = sales.blocks[0].totals
    assert sales_totals is not None
    assert sales_totals[1:6] == [""] * 5
    assert sales_totals[6] == "200.000"  # subtotal

    hourly = build_spec("hourly", _payload("hourly"), locale="en")
    assert hourly.blocks[0].totals[2] == ""  # no gross aggregate


def test_build_spec_unknown_report():
    with pytest.raises(KeyError):
        build_spec("nope", _fin(), locale="en")


# ── 3. meta lines (default omission) ──────────────────────────────────────


def test_meta_lines_default_omission():
    filters = ExportFilters(
        date_from=_EPOCH,
        date_to=_END,
        status="completed",
        sort="net_revenue",
    )
    lines = filters.meta_lines("en")
    assert len(lines) == 1
    assert lines[0].startswith(label("label_period", "en"))

    rich = ExportFilters(
        status="void",
        payment_method="cash",
        device_id="POS-1",
        user_id="user-1",
        days=30,
        threshold=D("5.000"),
        lookback_days=7,
    ).meta_lines("en")
    text = " | ".join(rich)
    assert label("filter_status", "en") in text
    assert label("status_void", "en") in text
    assert label("filter_payment", "en") in text
    assert label("label_cash", "en") in text
    assert "POS-1" in text
    assert "user-1" in text
    assert "30" in text and "7" in text
    assert "5.000" in text


# ── 4. XLSX writer ────────────────────────────────────────────────────────


def test_xlsx_structure_arabic_row_level():
    spec = _spec(report="products", locale="ar")
    data = render_xlsx(spec, generated_at=datetime(2026, 2, 3, 4, 5, 6))
    ws = load_workbook(io.BytesIO(data)).active

    assert ws["A1"].value == "Store X — " + spec.title
    assert ws["A2"].value == (
        "Period: 2026-01-01 - 2026-01-31 | generated_at: 2026-02-03T04:05:06"
    )
    assert any(r.min_row == 1 for r in ws.merged_cells.ranges)  # merged title
    assert ws.cell(row=4, column=1).value == "Product"
    assert str(ws.freeze_panes) == "A5"
    assert ws.auto_filter.ref is not None
    assert ws.auto_filter.ref.startswith("A4:")
    assert ws.sheet_view.rightToLeft is True  # ar
    assert ws.page_setup.orientation == "landscape"
    assert ws.print_title_rows in ("4:4", "$4:$4")  # openpyxl normalises
    assert ws.title == spec.title  # sheet title sanitized/truncated

    money = ws.cell(row=5, column=2)
    assert money.value == 10 and money.number_format == "0.000"
    pct = ws.cell(row=5, column=3)
    assert pct.value == 12.5 and pct.number_format == '0.00"%"'
    # data rows then totals row
    assert ws.cell(row=6, column=1).value == "Gadget"
    assert ws.cell(row=7, column=1).value == "Total"


def test_xlsx_english_financial_multi_block():
    payload = _fin(
        device_breakdown=[
            DeviceBreakdownRow(
                device_id="POS-1",
                invoice_count=1,
                net_sales=D("100.000"),
                share_pct=D("100.00"),
            )
        ],
    )
    spec = build_spec("financial", payload, locale="en")
    data = render_xlsx(spec, generated_at=datetime(2026, 2, 3, 4, 5, 6))
    ws = load_workbook(io.BytesIO(data)).active

    assert ws.sheet_view.rightToLeft is not True  # en
    assert ws.page_setup.orientation == "portrait"
    assert ws.auto_filter.ref is None  # not row-level
    assert ws.cell(row=4, column=1).value == label("label_period", "en")
    # second block header below a blank separator row
    assert ws.cell(row=7, column=1).value == label("col_device", "en")
    assert ws.cell(row=8, column=1).value == "POS-1"


def test_xlsx_formula_injection_guard():
    block = ExportBlock(
        headers=["=HEAD(E1)", "Plain"],
        rows=[
            [
                "=cmd|' /C calc'!A1",
                "+1+2",
                "-SUM(A1)",
                "@user",
                "\tTAB",
                "-12.5",
                "-3",
                "normal",
            ]
        ],
        kinds=["text"] * 8,
    )
    spec = _spec(report="voided", locale="en", blocks=[block], row_count=1)
    ws = load_workbook(io.BytesIO(render_xlsx(spec))).active

    assert ws.cell(row=4, column=1).value == "'=HEAD(E1)"  # header guarded
    assert ws.cell(row=5, column=1).value == "'=cmd|' /C calc'!A1"
    assert ws.cell(row=5, column=2).value == "'+1+2"
    assert ws.cell(row=5, column=3).value == "'-SUM(A1)"
    assert ws.cell(row=5, column=4).value == "'@user"
    assert ws.cell(row=5, column=5).value == "'\tTAB"
    # numeric strings are typed as numbers — never guarded, never formulas
    assert ws.cell(row=5, column=6).value == -12.5
    assert isinstance(ws.cell(row=5, column=6).value, float)
    assert ws.cell(row=5, column=7).value == -3
    assert ws.cell(row=5, column=8).value == "normal"


def test_xlsx_write_only_above_threshold():
    rows = [[f"P{i}", str(i), f"{i}.50"] for i in range(5001)]
    block = ExportBlock(
        headers=["Product", "Qty", "Money"],
        rows=rows,
        kinds=["text", "money", "money"],
    )
    spec = _spec(
        report="products", locale="en", blocks=[block], row_count=len(rows)
    )
    ws = load_workbook(io.BytesIO(render_xlsx(spec))).active

    assert str(ws.freeze_panes) == "A5"
    assert ws.cell(row=4, column=1).value == "Product"
    assert ws.cell(row=5, column=1).value == "P0"
    assert ws.cell(row=5005, column=1).value == "P5000"
    assert ws.auto_filter.ref is not None
    assert ws.auto_filter.ref.startswith("A4:")


# ── 5. sanitize_filename ──────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        (
            "reports_financial_2026-01-01_2026-01-31_2026-01-01-120000.xlsx",
            "reports_financial_2026-01-01_2026-01-31_2026-01-01-120000.xlsx",
        ),
        ("a/b\\c.xlsx", "abc.xlsx"),
        ("we?ird*name.pdf", "weirdname.pdf"),
        ('in"va<lid>.txt', "invalid.txt"),
        ("CON.xlsx", "_CON.xlsx"),
        ("con.pdf", "_con.pdf"),
        ("...", "export"),
        ("../../etc/passwd", "etcpasswd"),
        ("اسم-عربي.pdf", "-.pdf"),  # non-ASCII dropped, hyphen kept
    ],
)
def test_sanitize_filename(raw, expected):
    assert sanitize_filename(raw) == expected


def test_sanitize_filename_truncates_keeping_extension():
    long = "a" * 200 + ".xlsx"
    out = sanitize_filename(long)
    assert len(out) == 120
    assert out.endswith(".xlsx")
    assert sanitize_filename("x" * 50, max_length=10) == "x" * 10


# ── 6. PDF renderers ──────────────────────────────────────────────────────


def _report_input(**over) -> ReportTableInput:
    data = dict(
        title="Products",
        store_name="Store X",
        meta_lines=["Period: 2026-01-01 - 2026-01-31"],
        blocks=[ReportTableBlock(headers=["A", "B"], rows=[["1", "2"]])],
        landscape=False,
        rtl=False,
        locale="en",
        generated_at=f"{label('generated', 'en')}: 2026-02-03T04:05:06",
        empty_message="",
    )
    data.update(over)
    return ReportTableInput(**data)


def test_report_pdf_geometry_and_fonts():
    for landscape, width, height in (
        (False, 595.28, 841.89),
        (True, 841.89, 595.28),
    ):
        raw = render_report_pdf(_report_input(landscape=landscape), compress=False)
        assert raw[:5] == b"%PDF-"
        assert b"/FontFile2" in raw  # embedded TTF subset (G7)
        w, h = _media_box(raw)
        assert w == pytest.approx(width, abs=0.01)
        assert h == pytest.approx(height, abs=0.01)


def test_report_pdf_english_text_content():
    raw = render_report_pdf(_report_input(), compress=False)
    text = _pdf_text(raw)
    assert "Products" in text
    assert "Store X" in text
    assert "Period: 2026-01-01 - 2026-01-31" in text
    assert label("generated", "en") in text
    assert "2026-02-03T04:05:06" in text


def test_report_pdf_arabic_shaped_title():
    title_ar = label("report_financial", "ar")
    raw = render_report_pdf(
        _report_input(title=title_ar, locale="ar", rtl=True), compress=False
    )
    text = _pdf_text(raw)
    shaped = shape_text(title_ar)
    assert shaped in text  # shaped + reordered form is what got drawn
    if shaped != title_ar:
        assert title_ar not in text  # raw unshaped sequence absent


def test_report_pdf_empty_message():
    raw = render_report_pdf(
        _report_input(
            blocks=[ReportTableBlock(headers=["A"], rows=[])],
            empty_message=label("no_data", "en"),
        ),
        compress=False,
    )
    text = _pdf_text(raw)
    assert label("no_data", "en") in text
    assert "Products" in text  # header still rendered


def test_invoice_geometry_80mm_and_a4():
    data = build_sale_document(_sale_payload(), locale="en")
    raw_80 = render_invoice(data, "80mm")
    w, h = _media_box(raw_80)
    assert w == pytest.approx(80 * 2.8346456693, abs=0.01)
    assert h > 50
    assert b"/FontFile2" in raw_80

    raw_a4 = render_invoice(data, "A4")
    w, h = _media_box(raw_a4)
    assert w == pytest.approx(595.28, abs=0.01)
    assert h == pytest.approx(841.89, abs=0.01)


def test_a4_rtl_reverses_items_table():
    sale = _sale_payload()
    story_en = a4_flowables(build_sale_document(sale, locale="en"))
    story_ar = a4_flowables(build_sale_document(sale, locale="ar"))
    # §15.7 A1 — a customer sale invoice drops the SKU column (7 cells).
    customer_headers = [k for k in _ITEM_HEADERS if k != "col_sku"]
    table_en = next(
        f for f in story_en if isinstance(f, Table) and len(f._cellvalues[0]) == 7
    )
    table_ar = next(
        f for f in story_ar if isinstance(f, Table) and len(f._cellvalues[0]) == 7
    )

    header_en = table_en._cellvalues[0]
    header_ar = table_ar._cellvalues[0]
    assert len(header_en) == 7
    # RTL row = reversed localized headers (shape applied by the template)
    expected_en = [shape_text(label(k, "en")) for k in customer_headers]
    expected_ar = list(
        reversed([shape_text(label(k, "ar")) for k in customer_headers])
    )
    assert [p.text for p in header_en] == expected_en
    assert [p.text for p in header_ar] == expected_ar


def test_a4_return_document_keeps_the_sku_column():
    """Internal documents are NOT customer receipts — 8 columns stay."""
    ret = ReturnResponse(
        id=uuid.uuid4(),
        return_number="RET-0001",
        sale_id=uuid.uuid4(),
        invoice_number="INV-000123",
        customer_id=None,
        user_id=uuid.uuid4(),
        reason="damaged",
        subtotal=D("100.000"),
        discount=D("0.000"),
        total=D("100.000"),
        device_id="POS-1",
        return_date=datetime(2026, 1, 7, 9, 0),
        lines=[
            ReturnLineResponse(
                id=uuid.uuid4(),
                product_id=uuid.uuid4(),
                product_name="Cola",
                product_sku="SKU9",
                product_unit="piece",
                unit_price=D("100.000"),
                unit_cost=D("60.000"),
                quantity=D("1"),
                line_discount=D("0.000"),
                line_total=D("100.000"),
            )
        ],
    )
    data = build_return_document(ret, locale="en")
    assert data.customer_facing is False
    assert data.lines[0].sku == "SKU9"
    story = a4_flowables(data)
    table = next(f for f in story if isinstance(f, Table) and len(f._cellvalues[0]) in (7, 8))
    assert len(table._cellvalues[0]) == 8
    assert "SKU9" in [p.text for p in table._cellvalues[1]]


# ── 7. DocumentData builders ──────────────────────────────────────────────


def test_sale_document_pack_line_shapes():
    pack_id = uuid.uuid4()
    sale = _sale_payload(
        lines=[
            _sale_line(),  # product line
            _sale_line(
                product_id=None,
                pack_id=pack_id,
                product_name="Combo",
                product_unit="pack",
                quantity=D("1"),
                line_total=D("300.000"),
            ),  # pack summary
            _sale_line(pack_id=pack_id, quantity=D("1"), line_total=D("0.000")),
        ]  # pack component
    )
    data = build_sale_document(sale, locale="en")

    assert [line.kind for line in data.lines] == [
        "product",
        "pack_summary",
        "pack_component",
    ]
    assert data.lines[0].show_money is True
    assert data.lines[1].show_money is True
    assert data.lines[1].name.endswith(label("pack_marker", "en"))
    assert data.lines[2].show_money is False  # component money suppressed
    assert data.lines[0].line_total == format_money(D("200.000"))


def test_sale_document_selling_unit_base_qty():
    sale = _sale_payload(
        lines=[
            _sale_line(
                selling_unit_name="Box",
                selling_unit_multiplier=D("12"),
                quantity=D("2"),
            )
        ]
    )
    data = build_sale_document(sale, locale="en")
    line = data.lines[0]
    assert line.unit_label == "Box"
    assert line.base_qty == format_qty(D("24"))  # 2 × 12


def test_sale_document_totals_and_variant():
    sale = _sale_payload(
        lines=[
            _sale_line(variant_name="2L", line_discount=D("5.000")),
        ]
    )
    data = build_sale_document(sale, locale="en")
    assert data.lines[0].variant == "2L"
    assert data.lines[0].name == "Cola (2L)"

    totals = data.totals
    assert totals is not None
    assert totals.subtotal == format_money(D("500.000"))
    assert totals.total == format_money(D("490.000"))
    assert totals.line_discounts_sum == format_money(D("5.000"))
    assert totals.invoice_discount == format_money(D("10.000"))
    assert totals.debt is None  # debt 0 → omitted
    assert totals.payment_method == label("label_cash", "en")
    assert len(data.payments) == 1
    assert data.payments[0].method_label == label("label_cash", "en")


def test_sale_document_void_and_header():
    sale = _sale_payload(
        status="void",
        voided_at=datetime(2026, 1, 5, 11, 0),
        void_reason="duplicate",
    )
    data = build_sale_document(sale, locale="ar")
    header = data.header
    assert header.document_number == "INV-000123"
    assert header.document_title == label("doc_invoice", "ar")
    assert header.is_void is True
    assert header.voided_at == format_datetime(datetime(2026, 1, 5, 11, 0))
    assert header.void_reason == "duplicate"
    assert header.status_label in (label("status_void", "ar"), "void")


def test_sale_document_customer_blocks():
    # §15.7 A3 — an anonymous cash sale prints NO customer row at all:
    # the localized "Cash customer" placeholder must not pose as a person.
    cash = build_sale_document(_sale_payload(), locale="en")
    assert cash.customer is None
    assert cash.customer_facing is True

    named = build_sale_document(
        _sale_payload(customer_id=uuid.uuid4(), customer_name="Bob"), locale="en"
    )
    assert named.customer is not None and named.customer.name == "Bob"

    unknown = build_sale_document(
        _sale_payload(customer_id=uuid.uuid4(), customer_name=None), locale="en"
    )
    assert unknown.customer is None  # known id, unknown name �� omit (��7.2)

    # §15.7 A4/A5 — cashier and device stay in the sale + audit trail but
    # are presentation-stripped from the customer document.
    data = build_sale_document(_sale_payload(cashier_name="Admin"), locale="en")
    assert data.cashier_name is None
    assert data.header.device_id is None
    assert data.store.name == settings.STORE_NAME
    # A1/A2 — identifiers are gone from the customer line contract too.
    assert all(line.sku is None and line.barcode is None for line in data.lines)


def test_internal_documents_keep_cashier_device_and_identifiers():
    """Returns/purchases are internal — the §15.7 policy must not leak."""
    ret = ReturnResponse(
        id=uuid.uuid4(),
        return_number="RET-0001",
        sale_id=uuid.uuid4(),
        invoice_number="INV-000123",
        customer_id=None,
        user_id=uuid.uuid4(),
        reason="damaged",
        subtotal=D("100.000"),
        discount=D("0.000"),
        total=D("100.000"),
        device_id="POS-1",
        return_date=datetime(2026, 1, 7, 9, 0),
        lines=[
            ReturnLineResponse(
                id=uuid.uuid4(),
                product_id=uuid.uuid4(),
                product_name="Cola",
                product_sku="SKU9",
                product_unit="piece",
                unit_price=D("100.000"),
                unit_cost=D("60.000"),
                quantity=D("1"),
                line_discount=D("0.000"),
                line_total=D("100.000"),
            )
        ],
    )
    data = build_return_document(
        ret, locale="en", names=DocumentNames(cashier="Admin")
    )
    assert data.customer_facing is False
    assert data.cashier_name == "Admin"
    assert data.header.device_id == "POS-1"
    assert data.lines[0].sku == "SKU9"
    # A6 is sale-only: internal documents keep the single combined stamp.
    assert data.header.occurred_date is None
    assert data.header.occurred_time is None
    # the anonymous placeholder is still what an internal document prints
    assert data.customer is not None
    assert data.customer.name == label("cash_customer", "en")


def test_sale_document_discount_consistency():
    good = _sale_payload(lines=[_sale_line(line_discount=D("0.000"))])
    assert line_discounts_consistency(
        build_sale_document(good, locale="en"), good
    ) is True

    bad = _sale_payload(lines=[_sale_line(line_discount=D("10.000"))])
    assert line_discounts_consistency(
        build_sale_document(bad, locale="en"), bad
    ) is False


def test_return_document_builder():
    ret = ReturnResponse(
        id=uuid.uuid4(),
        return_number="RET-0001",
        sale_id=uuid.uuid4(),
        invoice_number="INV-000123",
        customer_id=uuid.uuid4(),
        user_id=uuid.uuid4(),
        reason="damaged",
        subtotal=D("100.000"),
        discount=D("0.000"),
        total=D("100.000"),
        device_id="POS-1",
        return_date=datetime(2026, 1, 7, 9, 0),
        lines=[
            ReturnLineResponse(
                id=uuid.uuid4(),
                product_id=uuid.uuid4(),
                product_name="Cola",
                product_unit="piece",
                unit_price=D("100.000"),
                unit_cost=D("60.000"),
                quantity=D("1"),
                line_discount=D("0.000"),
                line_total=D("100.000"),
            )
        ],
    )
    data = build_return_document(
        ret, locale="en", names=DocumentNames(customer="Ali", cashier="Admin")
    )
    assert data.header.document_number == "RET-0001"
    assert data.header.document_title == label("doc_return", "en")
    assert data.header.source_invoice == "INV-000123"
    assert data.header.void_reason == "damaged"  # return reason display
    assert data.customer is not None and data.customer.name == "Ali"
    assert data.cashier_name == "Admin"
    assert data.totals is not None
    assert data.totals.total == format_money(D("100.000"))
    assert data.totals.paid is None  # returns carry no payment block
    assert data.supplier is None


def test_purchase_document_without_variant_name():
    """Regression: PurchaseLineResponse has no ``variant_name`` attribute."""
    purchase = _purchase_payload()
    data = build_purchase_document(
        purchase, locale="ar", names=DocumentNames(cashier="Admin")
    )
    assert data.lines[0].kind == "product"
    assert data.lines[0].name == "Cement"  # no AttributeError, no suffix
    assert data.lines[0].unit_label == "bag"
    assert data.lines[0].base_qty == format_qty(D("5"))
    assert data.supplier is not None and data.supplier.name == "BuildMart"
    assert data.header.supplier_name == "BuildMart"
    assert data.header.document_title == label("doc_purchase", "ar")
    assert data.header.status_label in (
        label("purchase_status_received", "ar"),
        "received",
    )
    assert data.totals is not None
    assert data.totals.invoice_discount is None  # discount 0 → omitted
    assert data.totals.paid == format_money(D("0.000"))

    # the raw helper tolerates line objects without the attribute at all
    assert _line_name(SimpleNamespace(product_name="X"), locale="en") == "X"


def test_shape_text_rules():
    assert shape_text("فاتورة") != "فاتورة"  # reshaped + reordered
    assert shape_text("INV-001 12.50") == "INV-001 12.50"  # latin untouched
    assert shape_text("") == ""
    assert is_rtl("ar") and not is_rtl("fr") and not is_rtl("en")
