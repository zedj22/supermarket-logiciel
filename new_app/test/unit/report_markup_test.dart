// Product / category report percentage — markup ON COST, derived in the
// model from the returned money strings.
//
//   markup = gross_profit / (cogs - return_cost) * 100
//
// The backend also sends `margin_pct` = gross_profit / net revenue. That
// accounting figure is kept on the wire for API compatibility and is
// NEVER displayed: the report column now means the same thing as the
// product list, the product form and the pack estimate.
//
// Money totals themselves are never recomputed here — only this
// percentage is derived, and only from values the API returned.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/features/reports/report_models.dart';

Map<String, dynamic> _productRow({
  String cogs = '2000.000',
  String returnCost = '0.000',
  String grossProfit = '2000.000',
  String marginPct = '50.00',
}) =>
    <String, dynamic>{
      'item_id': 'p1',
      'kind': 'product',
      'name': 'Widget',
      'sku': 'W-1',
      'qty_sold': '1',
      'gross': '4000.000',
      'line_discounts': '0.000',
      'invoice_discount_share': '0.000',
      'net_revenue': '4000.000',
      'return_qty': '0',
      'return_amount': '0.000',
      'cogs': cogs,
      'return_cost': returnCost,
      'gross_profit': grossProfit,
      'margin_pct': marginPct, // backend metric — must be ignored
    };

Map<String, dynamic> _categoryRow({
  String cogs = '2000.000',
  String returnCost = '0.000',
  String grossProfit = '2000.000',
  String marginPct = '50.00',
}) =>
    <String, dynamic>{
      'category_id': null,
      'category': null,
      'qty_sold': '1',
      'gross': '4000.000',
      'line_discounts': '0.000',
      'invoice_discount_share': '0.000',
      'net_revenue': '4000.000',
      'return_qty': '0',
      'return_amount': '0.000',
      'cogs': cogs,
      'return_cost': returnCost,
      'gross_profit': grossProfit,
      'margin_pct': marginPct,
    };

void main() {
  group('ProductReportRow — markup on cost', () {
    test('cost 2 000 / profit 2 000 → 100%', () {
      expect(ProductReportRow.fromJson(_productRow()).marginPct, '100.00%');
    });

    test('cost 2 000 / profit 1 000 → 50%', () {
      expect(
        ProductReportRow.fromJson(
          _productRow(grossProfit: '1000.000', marginPct: '25.00'),
        ).marginPct,
        '50.00%',
      );
    });

    test('cost 2 000 / profit 500 → 25%', () {
      expect(
        ProductReportRow.fromJson(
          _productRow(grossProfit: '500.000', marginPct: '12.50'),
        ).marginPct,
        '25.00%',
      );
    });

    test('the backend `margin_pct` (profit / revenue) is never displayed',
        () {
      // Fixture: revenue 4 000, cost 2 000 → backend says 50% on revenue,
      // the app shows 100% on cost. For a discounted row the two diverge
      // even more (12 / 18 = 66.66% vs the backend's 40.00).
      expect(
        ProductReportRow.fromJson(
          _productRow(cogs: '18.000', grossProfit: '12.000', marginPct: '40.00'),
        ).marginPct,
        '66.66%',
      );
    });

    test('net cost subtracts returns from cogs', () {
      // cogs 2 000 - return_cost 500 = 1 500 net, profit 500 → 33.33%.
      expect(
        ProductReportRow.fromJson(
          _productRow(cogs: '2000.000', returnCost: '500.000',
              grossProfit: '500.000'),
        ).marginPct,
        '33.33%',
      );
    });

    test('zero or missing cost never divides by zero', () {
      expect(
        ProductReportRow.fromJson(
          _productRow(cogs: '0.000', grossProfit: '4000.000'),
        ).marginPct,
        isNull,
      );
      expect(
        ProductReportRow.fromJson(
          _productRow(cogs: '0.000', returnCost: '0.000', grossProfit: '0.000'),
        ).marginPct,
        isNull,
      );
      // A net cost of zero after returns (cost fully returned).
      expect(
        ProductReportRow.fromJson(
          _productRow(cogs: '1000.000', returnCost: '1000.000',
              grossProfit: '0.000'),
        ).marginPct,
        isNull,
      );
    });

    test('a losing row keeps a negative markup', () {
      expect(
        ProductReportRow.fromJson(
          _productRow(grossProfit: '-500.000', marginPct: '-25.00'),
        ).marginPct,
        '-25.00%',
      );
    });

    test('absolute money figures stay verbatim (no totals recomputed)', () {
      final row = ProductReportRow.fromJson(
        _productRow(cogs: '18.000', grossProfit: '12.000', marginPct: '40.00'),
      );
      expect(row.cogs, '18.000');
      expect(row.returnCost, '0.000');
      expect(row.grossProfit, '12.000');
      expect(row.netRevenue, '4000.000');
    });
  });

  group('CategoryReportRow — the same markup derivation', () {
    test('cost 2 000 / profit 2 000 → 100%', () {
      expect(CategoryReportRow.fromJson(_categoryRow()).marginPct, '100.00%');
    });

    test('cost 6 / profit 4 → 66.66%, backend 40.00 ignored', () {
      expect(
        CategoryReportRow.fromJson(
          _categoryRow(cogs: '6.000', grossProfit: '4.000', marginPct: '40.00'),
        ).marginPct,
        '66.66%',
      );
    });

    test('zero cost hides the percentage', () {
      expect(
        CategoryReportRow.fromJson(
          _categoryRow(cogs: '0.000', grossProfit: '4000.000'),
        ).marginPct,
        isNull,
      );
    });
  });

  group('FinancialReport — net margin on sales stays untouched', () {
    test('profit_margin_pct is passed through verbatim (accounting KPI)', () {
      final report = FinancialReport.fromJson(<String, dynamic>{
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
        'net_sales': '1000.000',
        'net_profit': '400.000',
        'profit_margin_pct': '40.00',
        'device_breakdown': const [],
      });
      // net_profit / net_sales = 40% of REVENUE — deliberately NOT turned
      // into markup on cost (that would be 66.67% and would misstate the
      // P&L-style KPI).
      expect(report.profitMarginPct, '40.00');
      expect(report.netProfit, '400.000');
      expect(report.netSales, '1000.000');
    });
  });
}
