// Phase 14 dashboard model — mirror of `DashboardResponse`
// (`backend/app/schemas/report.py` §7).
//
// Money arrives as decimal STRINGs; the client never recomputes KPIs
// (§7: "a KPI that can be stale is worse than a KPI that costs 100 ms" —
// every value is computed server-side on each request).

/// Tolerant field reader: JSON numbers and strings both become String.
String? _str(Object? value) => value?.toString();

class DashboardRecentSale {
  final String saleId;
  final String invoiceNumber;
  final String saleDate;
  final String total;
  final String paymentMethod;
  final String? customerName;

  const DashboardRecentSale({
    required this.saleId,
    required this.invoiceNumber,
    required this.saleDate,
    required this.total,
    required this.paymentMethod,
    this.customerName,
  });

  factory DashboardRecentSale.fromJson(Map<String, dynamic> json) {
    return DashboardRecentSale(
      saleId: _str(json['sale_id']) ?? '',
      invoiceNumber: _str(json['invoice_number']) ?? '',
      saleDate: _str(json['sale_date']) ?? '',
      total: _str(json['total']) ?? '0',
      paymentMethod: _str(json['payment_method']) ?? '',
      customerName: _str(json['customer_name']),
    );
  }
}

class DashboardTopProduct {
  final String itemId;
  final String kind;
  final String name;
  final String netRevenue;
  final String qtySold;
  final String grossProfit;

  const DashboardTopProduct({
    required this.itemId,
    required this.kind,
    required this.name,
    required this.netRevenue,
    required this.qtySold,
    required this.grossProfit,
  });

  factory DashboardTopProduct.fromJson(Map<String, dynamic> json) {
    return DashboardTopProduct(
      itemId: _str(json['item_id']) ?? '',
      kind: _str(json['kind']) ?? 'product',
      name: _str(json['name']) ?? '',
      netRevenue: _str(json['net_revenue']) ?? '0',
      qtySold: _str(json['qty_sold']) ?? '0',
      grossProfit: _str(json['gross_profit']) ?? '0',
    );
  }
}

class DashboardReport {
  final String dateFrom;
  final String dateTo;
  final String todaySales;
  final int todayInvoices;
  final String todayNetProfit;
  final String todayExpenses;
  final int totalProducts;
  final int totalCustomers;
  final String stockValue;
  final int lowStockCount;
  final int customersWithDebt;
  final String totalDebt;
  final List<DashboardRecentSale> recentSales;
  final List<DashboardTopProduct> topProducts;

  const DashboardReport({
    required this.dateFrom,
    required this.dateTo,
    required this.todaySales,
    required this.todayInvoices,
    required this.todayNetProfit,
    required this.todayExpenses,
    required this.totalProducts,
    required this.totalCustomers,
    required this.stockValue,
    required this.lowStockCount,
    required this.customersWithDebt,
    required this.totalDebt,
    required this.recentSales,
    required this.topProducts,
  });

  factory DashboardReport.fromJson(Map<String, dynamic> json) {
    return DashboardReport(
      dateFrom: _str(json['date_from']) ?? '',
      dateTo: _str(json['date_to']) ?? '',
      todaySales: _str(json['today_sales']) ?? '0',
      todayInvoices: (json['today_invoices'] as num?)?.toInt() ?? 0,
      todayNetProfit: _str(json['today_net_profit']) ?? '0',
      todayExpenses: _str(json['today_expenses']) ?? '0',
      totalProducts: (json['total_products'] as num?)?.toInt() ?? 0,
      totalCustomers: (json['total_customers'] as num?)?.toInt() ?? 0,
      stockValue: _str(json['stock_value']) ?? '0',
      lowStockCount: (json['low_stock_count'] as num?)?.toInt() ?? 0,
      customersWithDebt: (json['customers_with_debt'] as num?)?.toInt() ?? 0,
      totalDebt: _str(json['total_debt']) ?? '0',
      recentSales: [
        for (final row in (json['recent_sales'] as List? ?? const []))
          DashboardRecentSale.fromJson(row as Map<String, dynamic>),
      ],
      topProducts: [
        for (final row in (json['top_products'] as List? ?? const []))
          DashboardTopProduct.fromJson(row as Map<String, dynamic>),
      ],
    );
  }
}
