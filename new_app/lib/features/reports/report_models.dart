// Phase 14 report models — hand-written mirrors of
// `backend/app/schemas/report.py` (§11 responses).
//
// Money always arrives as a decimal STRING (Phase 0 money rule): the
// backend computes every figure with Decimal SQL per §5 and Flutter only
// renders what the API returned — no screen ever recomputes a total
// (§8 note: "Reports screens are the only place that assembles these;
// no screen may compute money").
//
// EXCEPTION — the profit PERCENTAGE of a product / category row: money
// totals are never touched, but the displayed percentage is derived here
// from the returned money strings (markup on cost, `core/money.dart` +
// `core/markup_percent.dart`) because the backend's `margin_pct` is a
// different metric (gross profit / net revenue). See
// `ProductReportRow.marginPct`.
//
// Dates: `date` fields arrive as `YYYY-MM-DD`, timestamps as ISO 8601.
// Both are kept as the raw string so CSV export can echo them verbatim
// (§12.2: ISO 8601 inside CSV, locale-independent).

import '../../core/markup_percent.dart';
import '../../core/money.dart';
import '../../core/strings.dart';

/// Tolerant field reader: JSON numbers and strings both become String,
/// `null` stays `null`.
String? _str(Object? value) => value?.toString();

/// Net cost behind a §5.8 row: `cogs - return_cost`, in thousandths.
/// `null` when either side is unparsable — then no percentage is shown.
int? _netCostMilli(String cogs, String returnCost) {
  final cost = moneyToMilli(cogs);
  final returned = moneyToMilli(returnCost);
  if (cost == null || returned == null) return null;
  return cost - returned;
}

/// Money string that MAY be negative (`gross_profit` on a losing row) in
/// thousandths. `moneyToMilli` itself rejects the sign, so it is peeled
/// off first — still exact integer math, never a `double`.
int? _signedMilli(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final negative = value.startsWith('-');
  final milli = moneyToMilli(negative ? value.substring(1) : value);
  if (milli == null) return null;
  return negative ? -milli : milli;
}

class DeviceBreakdownRow {
  /// §8 R15 — `null` → the client renders `label_unknown_device`.
  final String? deviceId;
  final int invoiceCount;
  final String netSales;
  final String sharePct;

  const DeviceBreakdownRow({
    required this.deviceId,
    required this.invoiceCount,
    required this.netSales,
    required this.sharePct,
  });

  factory DeviceBreakdownRow.fromJson(Map<String, dynamic> json) {
    return DeviceBreakdownRow(
      deviceId: _str(json['device_id']),
      invoiceCount: (json['invoice_count'] as num?)?.toInt() ?? 0,
      netSales: _str(json['net_sales']) ?? '0',
      sharePct: _str(json['share_pct']) ?? '0',
    );
  }
}

/// `GET /reports/financial` — §5.1–§5.5 blocks + §8 R15 breakdown.
class FinancialReport {
  final String dateFrom;
  final String dateTo;
  final String? deviceId;

  // §5.1 sales block
  final String grossSales;
  final String lineDiscounts;
  final String invoiceDiscounts;
  final String discountsTotal;
  final String salesAfterDiscounts;
  final int returnsCount;
  final String returnsTotal;
  final String netSales;
  final int invoiceCount;
  final String itemsSold;

  // §5.2 cost block
  final String cogs;
  final String returnsCost;
  final String cogsNet;

  // §5.3 profit block
  final String expensesTotal;
  final String expensesDrawer;
  final String expensesExternal;
  final String grossProfit;
  final String netProfit;
  final String profitMarginPct;

  // §5.4 payment split
  final String paidCash;
  final String paidCard;
  final String paidPartial;
  final String collectedTotal;
  final String debtCreated;
  final String changeTotal;

  // §5.5 debt block
  final String outstandingDebt;
  final String debtCollected;
  final String arOutstanding;
  final int customersWithDebt;

  // §8 R15
  final List<DeviceBreakdownRow> deviceBreakdown;

  const FinancialReport({
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
    required this.grossSales,
    required this.lineDiscounts,
    required this.invoiceDiscounts,
    required this.discountsTotal,
    required this.salesAfterDiscounts,
    required this.returnsCount,
    required this.returnsTotal,
    required this.netSales,
    required this.invoiceCount,
    required this.itemsSold,
    required this.cogs,
    required this.returnsCost,
    required this.cogsNet,
    required this.expensesTotal,
    required this.expensesDrawer,
    required this.expensesExternal,
    required this.grossProfit,
    required this.netProfit,
    required this.profitMarginPct,
    required this.paidCash,
    required this.paidCard,
    required this.paidPartial,
    required this.collectedTotal,
    required this.debtCreated,
    required this.changeTotal,
    required this.outstandingDebt,
    required this.debtCollected,
    required this.arOutstanding,
    required this.customersWithDebt,
    required this.deviceBreakdown,
  });

  factory FinancialReport.fromJson(Map<String, dynamic> json) {
    return FinancialReport(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      deviceId: _str(json['device_id']),
      grossSales: _str(json['gross_sales']) ?? '0',
      lineDiscounts: _str(json['line_discounts']) ?? '0',
      invoiceDiscounts: _str(json['invoice_discounts']) ?? '0',
      discountsTotal: _str(json['discounts_total']) ?? '0',
      salesAfterDiscounts: _str(json['sales_after_discounts']) ?? '0',
      returnsCount: (json['returns_count'] as num?)?.toInt() ?? 0,
      returnsTotal: _str(json['returns_total']) ?? '0',
      netSales: _str(json['net_sales']) ?? '0',
      invoiceCount: (json['invoice_count'] as num?)?.toInt() ?? 0,
      itemsSold: _str(json['items_sold']) ?? '0',
      cogs: _str(json['cogs']) ?? '0',
      returnsCost: _str(json['returns_cost']) ?? '0',
      cogsNet: _str(json['cogs_net']) ?? '0',
      expensesTotal: _str(json['expenses_total']) ?? '0',
      expensesDrawer: _str(json['expenses_drawer']) ?? '0',
      expensesExternal: _str(json['expenses_external']) ?? '0',
      grossProfit: _str(json['gross_profit']) ?? '0',
      netProfit: _str(json['net_profit']) ?? '0',
      profitMarginPct: _str(json['profit_margin_pct']) ?? '0',
      paidCash: _str(json['paid_cash']) ?? '0',
      paidCard: _str(json['paid_card']) ?? '0',
      paidPartial: _str(json['paid_partial']) ?? '0',
      collectedTotal: _str(json['collected_total']) ?? '0',
      debtCreated: _str(json['debt_created']) ?? '0',
      changeTotal: _str(json['change_total']) ?? '0',
      outstandingDebt: _str(json['outstanding_debt']) ?? '0',
      debtCollected: _str(json['debt_collected']) ?? '0',
      arOutstanding: _str(json['ar_outstanding']) ?? '0',
      customersWithDebt: (json['customers_with_debt'] as num?)?.toInt() ?? 0,
      deviceBreakdown: [
        for (final row in (json['device_breakdown'] as List? ?? const []))
          DeviceBreakdownRow.fromJson(row as Map<String, dynamic>),
      ],
    );
  }
}

/// Totals row of §5.8 reports (also the CSV `total` row source).
class ReportTotals {
  final String grossSales;
  final String discountsTotal;
  final String salesAfterDiscounts;
  final int returnsCount;
  final String returnsTotal;
  final String netSales;
  final String cogs;
  final String returnsCost;
  final String cogsNet;
  final String grossProfit;
  final String expensesTotal;
  final String netProfit;
  final int invoiceCount;
  final String itemsSold;

  const ReportTotals({
    required this.grossSales,
    required this.discountsTotal,
    required this.salesAfterDiscounts,
    required this.returnsCount,
    required this.returnsTotal,
    required this.netSales,
    required this.cogs,
    required this.returnsCost,
    required this.cogsNet,
    required this.grossProfit,
    required this.expensesTotal,
    required this.netProfit,
    required this.invoiceCount,
    required this.itemsSold,
  });

  factory ReportTotals.fromJson(Map<String, dynamic> json) {
    return ReportTotals(
      grossSales: _str(json['gross_sales']) ?? '0',
      discountsTotal: _str(json['discounts_total']) ?? '0',
      salesAfterDiscounts: _str(json['sales_after_discounts']) ?? '0',
      returnsCount: (json['returns_count'] as num?)?.toInt() ?? 0,
      returnsTotal: _str(json['returns_total']) ?? '0',
      netSales: _str(json['net_sales']) ?? '0',
      cogs: _str(json['cogs']) ?? '0',
      returnsCost: _str(json['returns_cost']) ?? '0',
      cogsNet: _str(json['cogs_net']) ?? '0',
      grossProfit: _str(json['gross_profit']) ?? '0',
      expensesTotal: _str(json['expenses_total']) ?? '0',
      netProfit: _str(json['net_profit']) ?? '0',
      invoiceCount: (json['invoice_count'] as num?)?.toInt() ?? 0,
      itemsSold: _str(json['items_sold']) ?? '0',
    );
  }

  static const ReportTotals empty = ReportTotals(
    grossSales: '0',
    discountsTotal: '0',
    salesAfterDiscounts: '0',
    returnsCount: 0,
    returnsTotal: '0',
    netSales: '0',
    cogs: '0',
    returnsCost: '0',
    cogsNet: '0',
    grossProfit: '0',
    expensesTotal: '0',
    netProfit: '0',
    invoiceCount: 0,
    itemsSold: '0',
  );
}

/// §5.8 row — `kind` is `product` | `pack` | `component`.
class ProductReportRow {
  final String itemId;
  final String kind;
  final String name;
  final String? sku;
  final String? categoryId;
  final String? category;
  final String qtySold;
  final String gross;
  final String lineDiscounts;
  final String invoiceDiscountShare;
  final String netRevenue;
  final String returnQty;
  final String returnAmount;
  final String cogs;
  final String returnCost;
  final String grossProfit;

  /// Markup ON COST — `gross_profit / (cogs - return_cost) * 100`,
  /// rendered `NN.NN%` by the shared `core/markup_percent.dart` helper.
  ///
  /// Derived in the model from the money strings above (money totals are
  /// NOT recomputed — only this percentage is). The backend also returns
  /// `margin_pct`, which is gross profit / net revenue; it is a different
  /// metric, kept on the wire for API compatibility and never displayed.
  ///
  /// `null` when the net cost is missing, unparsable or not strictly
  /// positive — never divide by zero, never print a meaningless percentage.
  final String? marginPct;

  const ProductReportRow({
    required this.itemId,
    required this.kind,
    required this.name,
    this.sku,
    this.categoryId,
    this.category,
    required this.qtySold,
    required this.gross,
    required this.lineDiscounts,
    required this.invoiceDiscountShare,
    required this.netRevenue,
    required this.returnQty,
    required this.returnAmount,
    required this.cogs,
    required this.returnCost,
    required this.grossProfit,
    required this.marginPct,
  });

  factory ProductReportRow.fromJson(Map<String, dynamic> json) {
    final grossProfit = _str(json['gross_profit']) ?? '0';
    final cogs = _str(json['cogs']) ?? '0';
    final returnCost = _str(json['return_cost']) ?? '0';
    return ProductReportRow(
      itemId: _str(json['item_id']) ?? '',
      kind: _str(json['kind']) ?? 'product',
      name: _str(json['name']) ?? '',
      sku: _str(json['sku']),
      categoryId: _str(json['category_id']),
      category: _str(json['category']),
      qtySold: _str(json['qty_sold']) ?? '0',
      gross: _str(json['gross']) ?? '0',
      lineDiscounts: _str(json['line_discounts']) ?? '0',
      invoiceDiscountShare: _str(json['invoice_discount_share']) ?? '0',
      netRevenue: _str(json['net_revenue']) ?? '0',
      returnQty: _str(json['return_qty']) ?? '0',
      returnAmount: _str(json['return_amount']) ?? '0',
      cogs: cogs,
      returnCost: returnCost,
      grossProfit: grossProfit,
      marginPct: markupPercent(
        profitMilli: _signedMilli(grossProfit),
        costMilli: _netCostMilli(cogs, returnCost),
      ),
    );
  }
}

/// `GET /reports/products` — paginated (§8 R2).
class ProductReportPage {
  final String dateFrom;
  final String dateTo;
  final String? deviceId;
  final String sort;
  final List<ProductReportRow> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;
  final ReportTotals totals;

  const ProductReportPage({
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
    required this.sort,
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.pages,
    required this.totals,
  });

  factory ProductReportPage.fromJson(Map<String, dynamic> json) {
    return ProductReportPage(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      deviceId: _str(json['device_id']),
      sort: _str(json['sort']) ?? 'net_revenue',
      items: [
        for (final row in (json['items'] as List? ?? const []))
          ProductReportRow.fromJson(row as Map<String, dynamic>),
      ],
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 0,
      pages: (json['pages'] as num?)?.toInt() ?? 1,
      totals: json['totals'] is Map<String, dynamic>
          ? ReportTotals.fromJson(json['totals'] as Map<String, dynamic>)
          : ReportTotals.empty,
    );
  }
}

/// §5.8 row aggregated by category (`null` → `label_uncategorized`).
class CategoryReportRow {
  final String? categoryId;
  final String? category;
  final String qtySold;
  final String gross;
  final String lineDiscounts;
  final String invoiceDiscountShare;
  final String netRevenue;
  final String returnQty;
  final String returnAmount;
  final String cogs;
  final String returnCost;
  final String grossProfit;

  /// See [ProductReportRow.marginPct] — same markup-on-cost derivation,
  /// same rules (money totals untouched, `null` without a positive net
  /// cost, backend `margin_pct` never displayed).
  final String? marginPct;

  const CategoryReportRow({
    this.categoryId,
    this.category,
    required this.qtySold,
    required this.gross,
    required this.lineDiscounts,
    required this.invoiceDiscountShare,
    required this.netRevenue,
    required this.returnQty,
    required this.returnAmount,
    required this.cogs,
    required this.returnCost,
    required this.grossProfit,
    required this.marginPct,
  });

  factory CategoryReportRow.fromJson(Map<String, dynamic> json) {
    final grossProfit = _str(json['gross_profit']) ?? '0';
    final cogs = _str(json['cogs']) ?? '0';
    final returnCost = _str(json['return_cost']) ?? '0';
    return CategoryReportRow(
      categoryId: _str(json['category_id']),
      category: _str(json['category']),
      qtySold: _str(json['qty_sold']) ?? '0',
      gross: _str(json['gross']) ?? '0',
      lineDiscounts: _str(json['line_discounts']) ?? '0',
      invoiceDiscountShare: _str(json['invoice_discount_share']) ?? '0',
      netRevenue: _str(json['net_revenue']) ?? '0',
      returnQty: _str(json['return_qty']) ?? '0',
      returnAmount: _str(json['return_amount']) ?? '0',
      cogs: cogs,
      returnCost: returnCost,
      grossProfit: grossProfit,
      marginPct: markupPercent(
        profitMilli: _signedMilli(grossProfit),
        costMilli: _netCostMilli(cogs, returnCost),
      ),
    );
  }
}

/// `GET /reports/categories` — ≤500 rows, no pagination (§8 R3).
class CategoryReportPage {
  final String dateFrom;
  final String dateTo;
  final String? deviceId;
  final List<CategoryReportRow> items;
  final ReportTotals totals;

  const CategoryReportPage({
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
    required this.items,
    required this.totals,
  });

  factory CategoryReportPage.fromJson(Map<String, dynamic> json) {
    return CategoryReportPage(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      deviceId: _str(json['device_id']),
      items: [
        for (final row in (json['items'] as List? ?? const []))
          CategoryReportRow.fromJson(row as Map<String, dynamic>),
      ],
      totals: json['totals'] is Map<String, dynamic>
          ? ReportTotals.fromJson(json['totals'] as Map<String, dynamic>)
          : ReportTotals.empty,
    );
  }
}

/// §8 R4 row — one business day (UTC bucket, A1).
class DailyReportRow {
  final String date;
  final String netSales;
  final String cogsNet;
  final String grossProfit;
  final String expenses;
  final String netProfit;
  final int invoiceCount;
  final String itemsSold;
  final String returnsTotal;

  const DailyReportRow({
    required this.date,
    required this.netSales,
    required this.cogsNet,
    required this.grossProfit,
    required this.expenses,
    required this.netProfit,
    required this.invoiceCount,
    required this.itemsSold,
    required this.returnsTotal,
  });

  factory DailyReportRow.fromJson(Map<String, dynamic> json) {
    return DailyReportRow(
      date: _str(json['date']) ?? '',
      netSales: _str(json['net_sales']) ?? '0',
      cogsNet: _str(json['cogs_net']) ?? '0',
      grossProfit: _str(json['gross_profit']) ?? '0',
      expenses: _str(json['expenses']) ?? '0',
      netProfit: _str(json['net_profit']) ?? '0',
      invoiceCount: (json['invoice_count'] as num?)?.toInt() ?? 0,
      itemsSold: _str(json['items_sold']) ?? '0',
      returnsTotal: _str(json['returns_total']) ?? '0',
    );
  }
}

/// `GET /reports/daily` — ≤400 rows (§6).
class DailyReportPage {
  final String dateFrom;
  final String dateTo;
  final String? deviceId;
  final List<DailyReportRow> items;
  final ReportTotals totals;

  const DailyReportPage({
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
    required this.items,
    required this.totals,
  });

  factory DailyReportPage.fromJson(Map<String, dynamic> json) {
    return DailyReportPage(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      deviceId: _str(json['device_id']),
      items: [
        for (final row in (json['items'] as List? ?? const []))
          DailyReportRow.fromJson(row as Map<String, dynamic>),
      ],
      totals: json['totals'] is Map<String, dynamic>
          ? ReportTotals.fromJson(json['totals'] as Map<String, dynamic>)
          : ReportTotals.empty,
    );
  }
}

/// §8 R5 row — one hour bucket (ISO hour, UTC, A1).
class HourlyReportRow {
  final String hour;
  final String netSales;
  final String salesTotal;
  final String returnsTotal;
  final int invoiceCount;

  const HourlyReportRow({
    required this.hour,
    required this.netSales,
    required this.salesTotal,
    required this.returnsTotal,
    required this.invoiceCount,
  });

  factory HourlyReportRow.fromJson(Map<String, dynamic> json) {
    return HourlyReportRow(
      hour: _str(json['hour']) ?? '',
      netSales: _str(json['net_sales']) ?? '0',
      salesTotal: _str(json['sales_total']) ?? '0',
      returnsTotal: _str(json['returns_total']) ?? '0',
      invoiceCount: (json['invoice_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `GET /reports/hourly` — ≤31 days → ≤744 rows (§6).
class HourlyReportPage {
  final String dateFrom;
  final String dateTo;
  final String? deviceId;
  final List<HourlyReportRow> items;
  final ReportTotals totals;

  const HourlyReportPage({
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
    required this.items,
    required this.totals,
  });

  factory HourlyReportPage.fromJson(Map<String, dynamic> json) {
    return HourlyReportPage(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      deviceId: _str(json['device_id']),
      items: [
        for (final row in (json['items'] as List? ?? const []))
          HourlyReportRow.fromJson(row as Map<String, dynamic>),
      ],
      totals: json['totals'] is Map<String, dynamic>
          ? ReportTotals.fromJson(json['totals'] as Map<String, dynamic>)
          : ReportTotals.empty,
    );
  }
}

/// §8 R6 row — hour 0–23 aggregated over the lookback window.
class PeakHourRow {
  final int hour;
  final String netSales;
  final int invoiceCount;
  final String itemsSold;

  const PeakHourRow({
    required this.hour,
    required this.netSales,
    required this.invoiceCount,
    required this.itemsSold,
  });

  factory PeakHourRow.fromJson(Map<String, dynamic> json) {
    return PeakHourRow(
      hour: (json['hour'] as num?)?.toInt() ?? 0,
      netSales: _str(json['net_sales']) ?? '0',
      invoiceCount: (json['invoice_count'] as num?)?.toInt() ?? 0,
      itemsSold: _str(json['items_sold']) ?? '0',
    );
  }
}

/// `GET /reports/peak-hours` — exactly 24 rows (§8 R6).
class PeakHoursReport {
  final int lookbackDays;
  final String dateFrom;
  final String dateTo;
  final List<PeakHourRow> items;
  final ReportTotals totals;

  const PeakHoursReport({
    required this.lookbackDays,
    required this.dateFrom,
    required this.dateTo,
    required this.items,
    required this.totals,
  });

  factory PeakHoursReport.fromJson(Map<String, dynamic> json) {
    return PeakHoursReport(
      lookbackDays: (json['lookback_days'] as num?)?.toInt() ?? 0,
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      items: [
        for (final row in (json['items'] as List? ?? const []))
          PeakHourRow.fromJson(row as Map<String, dynamic>),
      ],
      totals: json['totals'] is Map<String, dynamic>
          ? ReportTotals.fromJson(json['totals'] as Map<String, dynamic>)
          : ReportTotals.empty,
    );
  }
}

/// §8 R7 row — active product with no sales in the window.
class SlowMovingRow {
  final String productId;
  final String name;
  final String? sku;
  final String? category;
  final String quantity;
  final String lowStockThreshold;
  final String stockValue;
  final String? lastSaleDate;

  const SlowMovingRow({
    required this.productId,
    required this.name,
    this.sku,
    this.category,
    required this.quantity,
    required this.lowStockThreshold,
    required this.stockValue,
    this.lastSaleDate,
  });

  factory SlowMovingRow.fromJson(Map<String, dynamic> json) {
    return SlowMovingRow(
      productId: _str(json['product_id']) ?? '',
      name: _str(json['name']) ?? '',
      sku: _str(json['sku']),
      category: _str(json['category']),
      quantity: _str(json['quantity']) ?? '0',
      lowStockThreshold: _str(json['low_stock_threshold']) ?? '0',
      stockValue: _str(json['stock_value']) ?? '0',
      lastSaleDate: _str(json['last_sale_date']),
    );
  }
}

/// `GET /reports/slow-moving` — paginated (§8 R7).
class SlowMovingPage {
  final int days;
  final String threshold;
  final List<SlowMovingRow> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  const SlowMovingPage({
    required this.days,
    required this.threshold,
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.pages,
  });

  factory SlowMovingPage.fromJson(Map<String, dynamic> json) {
    return SlowMovingPage(
      days: (json['days'] as num?)?.toInt() ?? 0,
      threshold: _str(json['threshold']) ?? '0',
      items: [
        for (final row in (json['items'] as List? ?? const []))
          SlowMovingRow.fromJson(row as Map<String, dynamic>),
      ],
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 0,
      pages: (json['pages'] as num?)?.toInt() ?? 1,
    );
  }
}

/// §8 R8 row — voided invoices filtered by `voided_at` (§5.9 / D14).
class VoidedSaleRow {
  final String saleId;
  final String invoiceNumber;
  final String saleDate;
  final String? voidedAt;
  final String total;
  final String paymentMethod;
  final String? voidReason;
  final String? voidedBy;
  final String? voidedByName;
  final String? deviceId;
  final int lineCount;

  const VoidedSaleRow({
    required this.saleId,
    required this.invoiceNumber,
    required this.saleDate,
    this.voidedAt,
    required this.total,
    required this.paymentMethod,
    this.voidReason,
    this.voidedBy,
    this.voidedByName,
    this.deviceId,
    required this.lineCount,
  });

  factory VoidedSaleRow.fromJson(Map<String, dynamic> json) {
    return VoidedSaleRow(
      saleId: _str(json['sale_id']) ?? '',
      invoiceNumber: _str(json['invoice_number']) ?? '',
      saleDate: _str(json['sale_date']) ?? '',
      voidedAt: _str(json['voided_at']),
      total: _str(json['total']) ?? '0',
      paymentMethod: _str(json['payment_method']) ?? '',
      voidReason: _str(json['void_reason']),
      voidedBy: _str(json['voided_by']),
      voidedByName: _str(json['voided_by_name']),
      deviceId: _str(json['device_id']),
      lineCount: (json['line_count'] as num?)?.toInt() ?? 0,
    );
  }
}

/// `GET /reports/voided` — paginated (§8 R8).
class VoidedReportPage {
  final String dateFrom;
  final String dateTo;
  final String? deviceId;
  final List<VoidedSaleRow> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  const VoidedReportPage({
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.pages,
  });

  factory VoidedReportPage.fromJson(Map<String, dynamic> json) {
    return VoidedReportPage(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      deviceId: _str(json['device_id']),
      items: [
        for (final row in (json['items'] as List? ?? const []))
          VoidedSaleRow.fromJson(row as Map<String, dynamic>),
      ],
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 0,
      pages: (json['pages'] as num?)?.toInt() ?? 1,
    );
  }
}

/// §8 R9 row — sales detail (report table + export row source).
class SalesDetailRow {
  final String saleId;
  final String invoiceNumber;
  final String saleDate;
  final String status;
  final String? customerId;
  final String? customerName;
  final String? userName;
  final String paymentMethod;
  final String subtotal;
  final String discounts;
  final String total;
  final String paid;

  /// JSON field name is `change` (Dart keyword → [changeAmount]).
  final String changeAmount;
  final String? deviceId;

  const SalesDetailRow({
    required this.saleId,
    required this.invoiceNumber,
    required this.saleDate,
    required this.status,
    this.customerId,
    this.customerName,
    this.userName,
    required this.paymentMethod,
    required this.subtotal,
    required this.discounts,
    required this.total,
    required this.paid,
    required this.changeAmount,
    this.deviceId,
  });

  factory SalesDetailRow.fromJson(Map<String, dynamic> json) {
    return SalesDetailRow(
      saleId: _str(json['sale_id']) ?? '',
      invoiceNumber: _str(json['invoice_number']) ?? '',
      saleDate: _str(json['sale_date']) ?? '',
      status: _str(json['status']) ?? '',
      customerId: _str(json['customer_id']),
      customerName: _str(json['customer_name']),
      userName: _str(json['user_name']),
      paymentMethod: _str(json['payment_method']) ?? '',
      subtotal: _str(json['subtotal']) ?? '0',
      discounts: _str(json['discounts']) ?? '0',
      total: _str(json['total']) ?? '0',
      paid: _str(json['paid']) ?? '0',
      changeAmount: _str(json['change']) ?? '0',
      deviceId: _str(json['device_id']),
    );
  }
}

class SalesDetailTotals {
  final int count;
  final String subtotal;
  final String discounts;
  final String total;
  final String paid;
  final String changeAmount;

  const SalesDetailTotals({
    required this.count,
    required this.subtotal,
    required this.discounts,
    required this.total,
    required this.paid,
    required this.changeAmount,
  });

  factory SalesDetailTotals.fromJson(Map<String, dynamic> json) {
    return SalesDetailTotals(
      count: (json['count'] as num?)?.toInt() ?? 0,
      subtotal: _str(json['subtotal']) ?? '0',
      discounts: _str(json['discounts']) ?? '0',
      total: _str(json['total']) ?? '0',
      paid: _str(json['paid']) ?? '0',
      changeAmount: _str(json['change']) ?? '0',
    );
  }

  static const SalesDetailTotals empty = SalesDetailTotals(
    count: 0,
    subtotal: '0',
    discounts: '0',
    total: '0',
    paid: '0',
    changeAmount: '0',
  );
}

/// `GET /reports/sales` — paginated (§8 R9).
class SalesDetailPage {
  final String dateFrom;
  final String dateTo;
  final String status;
  final List<SalesDetailRow> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;
  final SalesDetailTotals totals;

  const SalesDetailPage({
    required this.dateFrom,
    required this.dateTo,
    required this.status,
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.pages,
    required this.totals,
  });

  factory SalesDetailPage.fromJson(Map<String, dynamic> json) {
    return SalesDetailPage(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      status: _str(json['status']) ?? 'completed',
      items: [
        for (final row in (json['items'] as List? ?? const []))
          SalesDetailRow.fromJson(row as Map<String, dynamic>),
      ],
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 0,
      pages: (json['pages'] as num?)?.toInt() ?? 1,
      totals: json['totals'] is Map<String, dynamic>
          ? SalesDetailTotals.fromJson(json['totals'] as Map<String, dynamic>)
          : SalesDetailTotals.empty,
    );
  }
}

/// `GET /reports/suppliers` — §5.6 compact object (§8 R13).
class SupplierReport {
  final String dateFrom;
  final String dateTo;
  final String supplierPayable;
  final String purchasesTotal;
  final String supplierPaid;
  final int suppliersWithBalance;

  const SupplierReport({
    required this.dateFrom,
    required this.dateTo,
    required this.supplierPayable,
    required this.purchasesTotal,
    required this.supplierPaid,
    required this.suppliersWithBalance,
  });

  factory SupplierReport.fromJson(Map<String, dynamic> json) {
    return SupplierReport(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      supplierPayable: _str(json['supplier_payable']) ?? '0',
      purchasesTotal: _str(json['purchases_total']) ?? '0',
      supplierPaid: _str(json['supplier_paid']) ?? '0',
      suppliersWithBalance:
          (json['suppliers_with_balance'] as num?)?.toInt() ?? 0,
    );
  }
}

// ---------------------------------------------------------------------------
// Loyalty report (Loyalty Phase F)
// ---------------------------------------------------------------------------

/// One row per ledger event type in the window (signed net deltas).
class LoyaltyEventTotals {
  final String eventType;
  final int entries;
  final String pointsDelta;
  final String cashbackDelta;

  const LoyaltyEventTotals({
    required this.eventType,
    required this.entries,
    required this.pointsDelta,
    required this.cashbackDelta,
  });

  factory LoyaltyEventTotals.fromJson(Map<String, dynamic> json) {
    return LoyaltyEventTotals(
      eventType: _str(json['event_type']) ?? '',
      entries: (json['entries'] as num?)?.toInt() ?? 0,
      pointsDelta: _str(json['points_delta']) ?? '0',
      cashbackDelta: _str(json['cashback_delta']) ?? '0',
    );
  }
}

/// One ledger entry with its transaction reference (invoice).
class LoyaltyLedgerRow {
  final String entryId;
  final String createdAt;
  final String customerId;
  final String? customerName;
  final String eventType;
  final String pointsDelta;
  final String cashbackDelta;
  final String balanceAfterPoints;
  final String balanceAfterCashback;
  final String? invoiceNumber;
  final String? saleId;
  final String? returnId;
  final String? note;

  const LoyaltyLedgerRow({
    required this.entryId,
    required this.createdAt,
    required this.customerId,
    this.customerName,
    required this.eventType,
    required this.pointsDelta,
    required this.cashbackDelta,
    required this.balanceAfterPoints,
    required this.balanceAfterCashback,
    this.invoiceNumber,
    this.saleId,
    this.returnId,
    this.note,
  });

  factory LoyaltyLedgerRow.fromJson(Map<String, dynamic> json) {
    return LoyaltyLedgerRow(
      entryId: _str(json['entry_id']) ?? '',
      createdAt: _str(json['created_at']) ?? '',
      customerId: _str(json['customer_id']) ?? '',
      customerName: _str(json['customer_name']),
      eventType: _str(json['event_type']) ?? '',
      pointsDelta: _str(json['points_delta']) ?? '0',
      cashbackDelta: _str(json['cashback_delta']) ?? '0',
      balanceAfterPoints: _str(json['balance_after_points']) ?? '0',
      balanceAfterCashback: _str(json['balance_after_cashback']) ?? '0',
      invoiceNumber: _str(json['invoice_number']),
      saleId: _str(json['sale_id']),
      returnId: _str(json['return_id']),
      note: _str(json['note']),
    );
  }
}

/// `GET /reports/loyalty` — window activity + balance snapshot + paginated
/// ledger (Loyalty Phase F). Sales figures keep §5.1 semantics; rewards
/// are reported beside sales, never inside them.
class LoyaltyReport {
  final String dateFrom;
  final String dateTo;
  final String? deviceId;

  // Sales context (§5.1 semantics).
  final String salesGross;
  final String salesAfterDiscounts;
  final int invoiceCount;

  // Period activity (ledger, window-bounded).
  final String pointsEarned;
  final String cashbackEarned;
  final int earnEntries;
  final String settlementPoints;
  final String pointsRedeemed;
  final String redemptionValue;
  final int redeemEntries;
  final String pointsReversed;
  final String cashbackReversed;
  final int reversalEntries;
  final String pointsRestored;
  final String restoredValue;
  final int restoreEntries;
  final String shortfallPoints;
  final String shortfallCashback;
  final String adjustmentPoints;
  final String adjustmentCashback;

  // Current balances (snapshot, not a window total).
  final String outstandingPoints;
  final String outstandingCashback;
  final int accountsWithBalance;

  final List<LoyaltyEventTotals> events;
  final List<LoyaltyLedgerRow> items;
  final int total;
  final int page;
  final int pageSize;
  final int pages;

  const LoyaltyReport({
    required this.dateFrom,
    required this.dateTo,
    this.deviceId,
    required this.salesGross,
    required this.salesAfterDiscounts,
    required this.invoiceCount,
    required this.pointsEarned,
    required this.cashbackEarned,
    required this.earnEntries,
    required this.settlementPoints,
    required this.pointsRedeemed,
    required this.redemptionValue,
    required this.redeemEntries,
    required this.pointsReversed,
    required this.cashbackReversed,
    required this.reversalEntries,
    required this.pointsRestored,
    required this.restoredValue,
    required this.restoreEntries,
    required this.shortfallPoints,
    required this.shortfallCashback,
    required this.adjustmentPoints,
    required this.adjustmentCashback,
    required this.outstandingPoints,
    required this.outstandingCashback,
    required this.accountsWithBalance,
    required this.events,
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.pages,
  });

  factory LoyaltyReport.fromJson(Map<String, dynamic> json) {
    return LoyaltyReport(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      deviceId: _str(json['device_id']),
      salesGross: _str(json['sales_gross']) ?? '0',
      salesAfterDiscounts: _str(json['sales_after_discounts']) ?? '0',
      invoiceCount: (json['invoice_count'] as num?)?.toInt() ?? 0,
      pointsEarned: _str(json['points_earned']) ?? '0',
      cashbackEarned: _str(json['cashback_earned']) ?? '0',
      earnEntries: (json['earn_entries'] as num?)?.toInt() ?? 0,
      settlementPoints: _str(json['settlement_points']) ?? '0',
      pointsRedeemed: _str(json['points_redeemed']) ?? '0',
      redemptionValue: _str(json['redemption_value']) ?? '0',
      redeemEntries: (json['redeem_entries'] as num?)?.toInt() ?? 0,
      pointsReversed: _str(json['points_reversed']) ?? '0',
      cashbackReversed: _str(json['cashback_reversed']) ?? '0',
      reversalEntries: (json['reversal_entries'] as num?)?.toInt() ?? 0,
      pointsRestored: _str(json['points_restored']) ?? '0',
      restoredValue: _str(json['restored_value']) ?? '0',
      restoreEntries: (json['restore_entries'] as num?)?.toInt() ?? 0,
      shortfallPoints: _str(json['shortfall_points']) ?? '0',
      shortfallCashback: _str(json['shortfall_cashback']) ?? '0',
      adjustmentPoints: _str(json['adjustment_points']) ?? '0',
      adjustmentCashback: _str(json['adjustment_cashback']) ?? '0',
      outstandingPoints: _str(json['outstanding_points']) ?? '0',
      outstandingCashback: _str(json['outstanding_cashback']) ?? '0',
      accountsWithBalance:
          (json['accounts_with_balance'] as num?)?.toInt() ?? 0,
      events: [
        for (final row in (json['events'] as List? ?? const []))
          LoyaltyEventTotals.fromJson(row as Map<String, dynamic>),
      ],
      items: [
        for (final row in (json['items'] as List? ?? const []))
          LoyaltyLedgerRow.fromJson(row as Map<String, dynamic>),
      ],
      total: (json['total'] as num?)?.toInt() ?? 0,
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageSize: (json['page_size'] as num?)?.toInt() ?? 0,
      pages: (json['pages'] as num?)?.toInt() ?? 1,
    );
  }
}

/// Localization key for a payment method code (`label_<code>`).
String reportPaymentMethodKey(String method) => 'label_$method';

/// Localization key for a sale status (`status_completed` / `status_void`).
String reportStatusKey(String status) => 'status_$status';

/// R15 device label — `null`/blank → `label_unknown_device`.
String reportDeviceLabel(String? deviceId, String loc) {
  if (deviceId == null || deviceId.isEmpty) {
    return AppStrings.t('label_unknown_device', loc);
  }
  return deviceId;
}
