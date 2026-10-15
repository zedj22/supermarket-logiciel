// Client-side CSV builder for Phase 14 exports (§12.2).
//
// Contract (§12.2):
//   * Data source = the exact payload the screen shows (or a fresh page
//     walk of the SAME endpoint for row-level reports).
//   * UTF-8 **with BOM**, **CRLF** line endings, RFC 4180 quoting (`"`
//     doubling), comma delimiter.
//   * Localized header row (keys from §14); values stay RAW: dot-decimal
//     numbers verbatim from the server, ISO 8601 dates verbatim — no
//     thousand separators, no locale formatting inside cells.
//   * Final row labelled `total` for aggregate reports; omitted for pure
//     detail lists without a totals row (voided, slow-moving).
//   * Filename `reports_<report>_<dateFrom>_<dateTo>_<yyyy-MM-dd-HHmmss>.csv`
//     (ASCII only). No comment header block (breaks parsers).
//   * Arabic/RTL: CSV is a data format → no RTL shaping (§12.2).
import 'dart:convert';

import 'package:intl/intl.dart';

import '../../core/strings.dart';
import 'report_models.dart';

/// §12.2 row cap (50 000 rows = 500 pages of 100).
const int kExportRowLimit = 50000;

/// RFC 4180 field escaping: quote when the value contains a delimiter,
/// quote, CR or LF; double every embedded quote.
String csvField(String value) {
  final needsQuotes = value.contains('"') ||
      value.contains(',') ||
      value.contains('\n') ||
      value.contains('\r');
  if (!needsQuotes) return value;
  return '"${value.replaceAll('"', '""')}"';
}

/// Builds the CSV text: rows joined with CRLF, trailing CRLF at EOF.
String buildCsv(List<List<String>> rows) {
  final buffer = StringBuffer();
  for (final row in rows) {
    buffer.write(row.map(csvField).join(','));
    buffer.write('\r\n');
  }
  return buffer.toString();
}

/// UTF-8 bytes prefixed with the BOM (Excel on Windows needs it).
List<int> csvBytes(String csv) =>
    <int>[0xEF, 0xBB, 0xBF, ...utf8.encode(csv)];

/// `reports_<report>_<from>_<to>_<yyyy-MM-dd-HHmmss>.csv` (§12.2, ASCII).
String reportCsvFilename({
  required String report,
  required String dateFrom,
  required String dateTo,
  required DateTime now,
}) {
  final stamp = DateFormat('yyyy-MM-dd-HHmmss').format(now);
  return 'reports_${report}_${dateFrom}_${dateTo}_$stamp.csv';
}

String _t(String key, String loc) => AppStrings.t(key, loc);

// ---------------------------------------------------------------------------
// R1 — financial (single aggregate object)
// ---------------------------------------------------------------------------

/// Financial CSV: header row + the single totals row, then a second
/// block for the §8 R15 device breakdown (own header, blank separator
/// line keeps the file parseable as two tables).
String financialCsv(FinancialReport r, String loc) {
  final rows = <List<String>>[
    [
      _t('label_period', loc),
      _t('kpi_gross_sales', loc),
      _t('kpi_line_discounts', loc),
      _t('kpi_invoice_discounts', loc),
      _t('kpi_discounts_total', loc),
      _t('kpi_sales_after_discounts', loc),
      _t('kpi_returns_count', loc),
      _t('kpi_returns_total', loc),
      _t('kpi_net_sales', loc),
      _t('kpi_invoices', loc),
      _t('kpi_items_sold', loc),
      _t('kpi_cogs', loc),
      _t('kpi_returns_cost', loc),
      _t('kpi_cogs_net', loc),
      _t('kpi_expenses', loc),
      _t('kpi_expenses_drawer', loc),
      _t('kpi_expenses_external', loc),
      _t('kpi_gross_profit', loc),
      _t('kpi_net_profit', loc),
      _t('kpi_margin', loc),
      _t('kpi_paid_cash', loc),
      _t('kpi_paid_card', loc),
      _t('kpi_paid_partial', loc),
      _t('kpi_collected', loc),
      _t('kpi_debt_created', loc),
      _t('kpi_change', loc),
      _t('kpi_outstanding_debt', loc),
      _t('kpi_debt_collected', loc),
      _t('kpi_ar_outstanding', loc),
      _t('kpi_customers_with_debt', loc),
    ],
    [
      // Col 0 is the range this totals row covers (the header says
      // "Period"; §6 dates echoed verbatim, ISO 8601).
      '${r.dateFrom} - ${r.dateTo}',
      r.grossSales,
      r.lineDiscounts,
      r.invoiceDiscounts,
      r.discountsTotal,
      r.salesAfterDiscounts,
      '${r.returnsCount}',
      r.returnsTotal,
      r.netSales,
      '${r.invoiceCount}',
      r.itemsSold,
      r.cogs,
      r.returnsCost,
      r.cogsNet,
      r.expensesTotal,
      r.expensesDrawer,
      r.expensesExternal,
      r.grossProfit,
      r.netProfit,
      r.profitMarginPct,
      r.paidCash,
      r.paidCard,
      r.paidPartial,
      r.collectedTotal,
      r.debtCreated,
      r.changeTotal,
      r.outstandingDebt,
      r.debtCollected,
      r.arOutstanding,
      '${r.customersWithDebt}',
    ],
    const <String>[''],
    [
      _t('col_device', loc),
      _t('col_count', loc),
      _t('col_net_revenue', loc),
      _t('col_share', loc),
    ],
    for (final d in r.deviceBreakdown)
      [
        d.deviceId == null || d.deviceId!.isEmpty
            ? _t('label_unknown_device', loc)
            : d.deviceId!,
        '${d.invoiceCount}',
        d.netSales,
        d.sharePct,
      ],
  ];
  return buildCsv(rows);
}

// ---------------------------------------------------------------------------
// R2 / R3 — §5.8 rows
// ---------------------------------------------------------------------------

List<String> _productTotalsRow(ReportTotals t, String loc) => <String>[
      _t('label_total', loc),
      '',
      '',
      t.itemsSold,
      t.grossSales,
      // No server aggregate exists for the split line/invoice discounts or
      // return quantity (§5 gives the combined figure only) — cells stay
      // empty rather than showing a computed (screen-side) money value.
      '',
      '',
      t.netSales,
      '',
      t.returnsTotal,
      t.cogs,
      t.returnsCost,
      t.grossProfit,
      '',
    ];

/// Product performance CSV (§8 R2 = §5.8 columns + category).
String productsCsv(ProductReportPage page, String loc) {
  final rows = <List<String>>[
    [
      _t('col_product', loc),
      _t('col_sku', loc),
      _t('col_category', loc),
      _t('col_qty', loc),
      _t('col_gross', loc),
      _t('col_line_discounts', loc),
      _t('col_invoice_discount', loc),
      _t('col_net_revenue', loc),
      _t('col_returns_qty', loc),
      _t('col_returns_amount', loc),
      _t('col_cogs', loc),
      _t('kpi_returns_cost', loc),
      _t('col_gross_profit', loc),
      _t('col_margin', loc),
    ],
    for (final row in page.items)
      [
        row.name,
        row.sku ?? '',
        (row.category == null || row.category!.isEmpty)
            ? _t('label_uncategorized', loc)
            : row.category!,
        row.qtySold,
        row.gross,
        row.lineDiscounts,
        row.invoiceDiscountShare,
        row.netRevenue,
        row.returnQty,
        row.returnAmount,
        row.cogs,
        row.returnCost,
        row.grossProfit,
        row.marginPct,
      ],
    _productTotalsRow(page.totals, loc),
  ];
  return buildCsv(rows);
}

/// Category analysis CSV (§8 R3).
String categoriesCsv(CategoryReportPage page, String loc) {
  final rows = <List<String>>[
    [
      _t('col_category', loc),
      _t('col_qty', loc),
      _t('col_gross', loc),
      _t('col_line_discounts', loc),
      _t('col_invoice_discount', loc),
      _t('col_net_revenue', loc),
      _t('col_returns_qty', loc),
      _t('col_returns_amount', loc),
      _t('col_cogs', loc),
      _t('kpi_returns_cost', loc),
      _t('col_gross_profit', loc),
      _t('col_margin', loc),
    ],
    for (final row in page.items)
      [
        (row.category == null || row.category!.isEmpty)
            ? _t('label_uncategorized', loc)
            : row.category!,
        row.qtySold,
        row.gross,
        row.lineDiscounts,
        row.invoiceDiscountShare,
        row.netRevenue,
        row.returnQty,
        row.returnAmount,
        row.cogs,
        row.returnCost,
        row.grossProfit,
        row.marginPct,
      ],
    <String>[
      _t('label_total', loc),
      page.totals.itemsSold,
      page.totals.grossSales,
      '',
      '',
      page.totals.netSales,
      '',
      page.totals.returnsTotal,
      page.totals.cogs,
      page.totals.returnsCost,
      page.totals.grossProfit,
      '',
    ],
  ];
  return buildCsv(rows);
}

// ---------------------------------------------------------------------------
// R4 / R5 / R6 — time buckets
// ---------------------------------------------------------------------------

/// Daily timeline CSV (§8 R4).
String dailyCsv(DailyReportPage page, String loc) {
  final rows = <List<String>>[
    [
      _t('col_date', loc),
      _t('kpi_net_sales', loc),
      _t('col_cogs', loc),
      _t('col_gross_profit', loc),
      _t('col_expenses', loc),
      _t('col_net_profit', loc),
      _t('kpi_invoices', loc),
      _t('kpi_items_sold', loc),
      _t('kpi_returns_total', loc),
    ],
    for (final row in page.items)
      [
        row.date,
        row.netSales,
        row.cogsNet,
        row.grossProfit,
        row.expenses,
        row.netProfit,
        '${row.invoiceCount}',
        row.itemsSold,
        row.returnsTotal,
      ],
    <String>[
      _t('label_total', loc),
      page.totals.netSales,
      page.totals.cogsNet,
      page.totals.grossProfit,
      page.totals.expensesTotal,
      page.totals.netProfit,
      '${page.totals.invoiceCount}',
      page.totals.itemsSold,
      page.totals.returnsTotal,
    ],
  ];
  return buildCsv(rows);
}

/// Hourly timeline CSV (§8 R5). The payload has no aggregate for the
/// `sales_total` column (§5.1 reports the discounted figures), so that
/// cell in the totals row stays empty instead of being computed here.
String hourlyCsv(HourlyReportPage page, String loc) {
  final rows = <List<String>>[
    [
      _t('col_hour', loc),
      _t('kpi_net_sales', loc),
      _t('col_gross', loc),
      _t('kpi_returns_total', loc),
      _t('kpi_invoices', loc),
    ],
    for (final row in page.items)
      [
        row.hour,
        row.netSales,
        row.salesTotal,
        row.returnsTotal,
        '${row.invoiceCount}',
      ],
    <String>[
      _t('label_total', loc),
      page.totals.netSales,
      '',
      page.totals.returnsTotal,
      '${page.totals.invoiceCount}',
    ],
  ];
  return buildCsv(rows);
}

/// Peak hours CSV (§8 R6, exactly 24 rows).
String peakCsv(PeakHoursReport report, String loc) {
  final rows = <List<String>>[
    [
      _t('col_hour', loc),
      _t('kpi_net_sales', loc),
      _t('kpi_invoices', loc),
      _t('kpi_items_sold', loc),
    ],
    for (final row in report.items)
      [
        '${row.hour}',
        row.netSales,
        '${row.invoiceCount}',
        row.itemsSold,
      ],
    <String>[
      _t('label_total', loc),
      report.totals.netSales,
      '${report.totals.invoiceCount}',
      report.totals.itemsSold,
    ],
  ];
  return buildCsv(rows);
}

// ---------------------------------------------------------------------------
// R7 / R8 / R9 — detail lists
// ---------------------------------------------------------------------------

/// Slow-moving stock CSV (§8 R7) — no totals row (no totals payload).
String slowMovingCsv(SlowMovingPage page, String loc) {
  final rows = <List<String>>[
    [
      _t('col_product', loc),
      _t('col_sku', loc),
      _t('col_category', loc),
      _t('col_qty', loc),
      _t('col_stock_value', loc),
      _t('col_last_sale', loc),
    ],
    for (final row in page.items)
      [
        row.name,
        row.sku ?? '',
        row.category ?? '',
        row.quantity,
        row.stockValue,
        row.lastSaleDate ?? '',
      ],
  ];
  return buildCsv(rows);
}

/// Voided invoices CSV (§8 R8) — no totals row (no totals payload).
String voidedCsv(VoidedReportPage page, String loc) {
  final rows = <List<String>>[
    [
      _t('col_invoice', loc),
      _t('col_date', loc),
      _t('col_voided_at', loc),
      _t('col_total', loc),
      _t('col_method', loc),
      _t('col_void_reason', loc),
      _t('col_user', loc),
      _t('col_device', loc),
      _t('col_count', loc),
    ],
    for (final row in page.items)
      [
        row.invoiceNumber,
        row.saleDate,
        row.voidedAt ?? '',
        row.total,
        row.paymentMethod.isEmpty
            ? ''
            : _t('label_${row.paymentMethod}', loc),
        row.voidReason ?? '',
        row.voidedByName ?? '',
        (row.deviceId == null || row.deviceId!.isEmpty)
            ? _t('label_unknown_device', loc)
            : row.deviceId!,
        '${row.lineCount}',
      ],
  ];
  return buildCsv(rows);
}

/// Sales detail CSV (§8 R9) — totals row included because the screen
/// shows one (§12.2 conditional rule).
String salesCsv(SalesDetailPage page, String loc) {
  final rows = <List<String>>[
    [
      _t('col_invoice', loc),
      _t('col_date', loc),
      _t('filter_status', loc),
      _t('col_customer', loc),
      _t('col_user', loc),
      _t('col_method', loc),
      _t('col_subtotal', loc),
      _t('kpi_discounts_total', loc),
      _t('col_total', loc),
      _t('col_paid', loc),
      _t('col_change', loc),
      _t('col_device', loc),
    ],
    for (final row in page.items)
      [
        row.invoiceNumber,
        row.saleDate,
        _t('status_${row.status}', loc),
        row.customerName ?? '',
        row.userName ?? '',
        row.paymentMethod.isEmpty
            ? ''
            : _t('label_${row.paymentMethod}', loc),
        row.subtotal,
        row.discounts,
        row.total,
        row.paid,
        row.changeAmount,
        (row.deviceId == null || row.deviceId!.isEmpty)
            ? _t('label_unknown_device', loc)
            : row.deviceId!,
      ],
    <String>[
      _t('label_total', loc),
      '',
      '',
      '',
      '',
      '',
      page.totals.subtotal,
      page.totals.discounts,
      page.totals.total,
      page.totals.paid,
      page.totals.changeAmount,
      '',
    ],
  ];
  return buildCsv(rows);
}

// ---------------------------------------------------------------------------
// R13 — supplier payables (single aggregate object)
// ---------------------------------------------------------------------------

/// Supplier report CSV (§8 R13) — header + totals row, like financial.
String suppliersCsv(SupplierReport report, String loc) {
  final rows = <List<String>>[
    [
      _t('label_period', loc),
      _t('kpi_supplier_payable', loc),
      _t('kpi_purchases_total', loc),
      _t('kpi_supplier_paid', loc),
      _t('kpi_suppliers_with_balance', loc),
    ],
    <String>[
      '${report.dateFrom} - ${report.dateTo}',
      report.supplierPayable,
      report.purchasesTotal,
      report.supplierPaid,
      '${report.suppliersWithBalance}',
    ],
  ];
  return buildCsv(rows);
}

// ---------------------------------------------------------------------------
// Loyalty report (Loyalty Phase F)
// ---------------------------------------------------------------------------

/// Loyalty CSV: four blocks (sales context + period activity, current
/// balances, events breakdown, full ledger). Raw values verbatim — no
/// screen-side computation (§12.2).
String loyaltyCsv(LoyaltyReport r, String loc) {
  final rows = <List<String>>[
    [
      _t('label_period', loc),
      _t('kpi_gross_sales', loc),
      _t('kpi_sales_after_discounts', loc),
      _t('kpi_invoices', loc),
      _t('loyalty_points_earned', loc),
      _t('loyalty_cashback_earned', loc),
      _t('loyalty_settlement_points', loc),
      _t('loyalty_points_redeemed', loc),
      _t('loyalty_redemption_value', loc),
      _t('loyalty_points_reversed', loc),
      _t('loyalty_cashback_reversed', loc),
      _t('loyalty_points_restored', loc),
      _t('loyalty_restored_value', loc),
      _t('loyalty_shortfall_points', loc),
      _t('loyalty_shortfall_cashback', loc),
      _t('loyalty_adjustment_points', loc),
      _t('loyalty_adjustment_cashback', loc),
    ],
    <String>[
      '${r.dateFrom} - ${r.dateTo}',
      r.salesGross,
      r.salesAfterDiscounts,
      '${r.invoiceCount}',
      r.pointsEarned,
      r.cashbackEarned,
      r.settlementPoints,
      r.pointsRedeemed,
      r.redemptionValue,
      r.pointsReversed,
      r.cashbackReversed,
      r.pointsRestored,
      r.restoredValue,
      r.shortfallPoints,
      r.shortfallCashback,
      r.adjustmentPoints,
      r.adjustmentCashback,
    ],
    const <String>[''],
    [
      _t('loyalty_report_balances', loc),
      _t('loyalty_outstanding_points', loc),
      _t('loyalty_outstanding_cashback', loc),
      _t('loyalty_accounts_with_balance', loc),
    ],
    <String>[
      '',
      r.outstandingPoints,
      r.outstandingCashback,
      '${r.accountsWithBalance}',
    ],
    const <String>[''],
    [
      _t('col_event', loc),
      _t('col_count', loc),
      _t('col_points', loc),
      _t('col_cashback', loc),
    ],
    for (final e in r.events)
      [
        _t('loyalty_event_${e.eventType}', loc),
        '${e.entries}',
        e.pointsDelta,
        e.cashbackDelta,
      ],
    const <String>[''],
    [
      _t('col_date', loc),
      _t('col_customer', loc),
      _t('col_invoice', loc),
      _t('col_event', loc),
      _t('col_points', loc),
      _t('col_cashback', loc),
      _t('col_points_balance', loc),
      _t('col_cashback_balance', loc),
      _t('note', loc),
    ],
    for (final row in r.items)
      [
        row.createdAt,
        row.customerName ?? '',
        row.invoiceNumber ?? '',
        _t('loyalty_event_${row.eventType}', loc),
        row.pointsDelta,
        row.cashbackDelta,
        row.balanceAfterPoints,
        row.balanceAfterCashback,
        row.note ?? '',
      ],
  ];
  return buildCsv(rows);
}
