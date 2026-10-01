// Phase 14 client-side CSV contract (§12.2).
//
// The CSV is built entirely on the client from the exact payload the
// screen shows. Gates covered here: RFC 4180 quoting, CRLF + trailing
// CRLF, UTF-8 BOM, localized headers with RAW values (no locale number
// formatting, no `%` in cells, ISO dates verbatim), the final `total`
// row per report type (omitted for voided/slow-moving — no totals
// payload), the hourly `sales_total` totals cell staying empty (no
// server aggregate → no client math), and the §12.2 filename format.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/reports/report_csv.dart';
import 'package:supermarket_pos/features/reports/report_models.dart';

FinancialReport _financial({String dateFrom = '2026-09-01', String dateTo = '2026-09-30'}) {
  return FinancialReport.fromJson(<String, dynamic>{
    'date_from': dateFrom,
    'date_to': dateTo,
    'gross_sales': '1234.567',
    'line_discounts': '10.000',
    'invoice_discounts': '5.000',
    'discounts_total': '15.000',
    'sales_after_discounts': '1219.567',
    'returns_count': 2,
    'returns_total': '20.000',
    'net_sales': '1199.567',
    'invoice_count': 7,
    'items_sold': '42',
    'cogs': '600.000',
    'returns_cost': '10.000',
    'cogs_net': '590.000',
    'expenses_total': '100.000',
    'expenses_drawer': '60.000',
    'expenses_external': '40.000',
    'gross_profit': '609.567',
    'net_profit': '509.567',
    'profit_margin_pct': '42.48',
    'paid_cash': '700.000',
    'paid_card': '300.000',
    'paid_partial': '199.567',
    'collected_total': '1199.567',
    'debt_created': '0.000',
    'change_total': '0.000',
    'outstanding_debt': '0.000',
    'debt_collected': '0.000',
    'ar_outstanding': '0.000',
    'customers_with_debt': 0,
    'device_breakdown': [
      {
        'device_id': null,
        'invoice_count': 7,
        'net_sales': '1199.567',
        'share_pct': '100.00',
      },
      {
        'device_id': 'POS-1',
        'invoice_count': 3,
        'net_sales': '400.000',
        'share_pct': '33.34',
      },
    ],
  });
}

ProductReportPage _products() => ProductReportPage.fromJson(<String, dynamic>{
      'date_from': '2026-09-01',
      'date_to': '2026-09-30',
      'sort': 'net_revenue',
      'items': [
        {
          'item_id': 'p1',
          'kind': 'product',
          'name': 'Widget, "big"',
          'sku': 'W-1',
          'category': null,
          'qty_sold': '3',
          'gross': '30.000',
          'line_discounts': '0.000',
          'invoice_discount_share': '0.000',
          'net_revenue': '30.000',
          'return_qty': '0',
          'return_amount': '0.000',
          'cogs': '18.000',
          'return_cost': '0.000',
          'gross_profit': '12.000',
          'margin_pct': '40.00',
        },
      ],
      'total': 1,
      'page': 1,
      'page_size': 100,
      'pages': 1,
      'totals': {
        'items_sold': '3',
        'gross_sales': '30.000',
        'discounts_total': '0.000',
        'sales_after_discounts': '30.000',
        'returns_count': 0,
        'returns_total': '0.000',
        'net_sales': '30.000',
        'cogs': '18.000',
        'returns_cost': '0.000',
        'cogs_net': '18.000',
        'gross_profit': '12.000',
        'expenses_total': '0.000',
        'net_profit': '12.000',
        'invoice_count': 1,
      },
    });

HourlyReportPage _hourly() => HourlyReportPage.fromJson(<String, dynamic>{
      'date_from': '2026-09-01',
      'date_to': '2026-09-01',
      'items': [
        {
          'hour': '2026-09-01T09:00:00Z',
          'net_sales': '100.000',
          'sales_total': '105.000',
          'returns_total': '0.000',
          'invoice_count': 2,
        },
      ],
      'totals': {
        'net_sales': '100.000',
        'returns_total': '0.000',
        'invoice_count': 2,
        'items_sold': '4',
      },
    });

SalesDetailPage _sales() => SalesDetailPage.fromJson(<String, dynamic>{
      'date_from': '2026-09-01',
      'date_to': '2026-09-01',
      'status': 'all',
      'items': [
        {
          'sale_id': 's1',
          'invoice_number': 'INV-0001',
          'sale_date': '2026-09-01T10:00:00Z',
          'status': 'completed',
          'customer_name': 'Ali',
          'user_name': 'Admin',
          'payment_method': 'cash',
          'subtotal': '100.000',
          'discounts': '5.000',
          'total': '95.000',
          'paid': '100.000',
          'change': '5.000',
          'device_id': null,
        },
      ],
      'total': 1,
      'page': 1,
      'page_size': 100,
      'pages': 1,
      'totals': {
        'count': 1,
        'subtotal': '100.000',
        'discounts': '5.000',
        'total': '95.000',
        'paid': '100.000',
        'change': '5.000',
      },
    });

VoidedReportPage _voided() => VoidedReportPage.fromJson(<String, dynamic>{
      'date_from': '2026-09-01',
      'date_to': '2026-09-01',
      'items': [
        {
          'sale_id': 's2',
          'invoice_number': 'INV-0002',
          'sale_date': '2026-09-01T11:00:00Z',
          'voided_at': '2026-09-01T12:00:00Z',
          'total': '50.000',
          'payment_method': 'cash',
          'void_reason': 'wrong item',
          'voided_by_name': 'Admin',
          'device_id': 'POS-2',
          'line_count': 3,
        },
      ],
      'total': 1,
      'page': 1,
      'page_size': 100,
      'pages': 1,
    });

SlowMovingPage _slow() => SlowMovingPage.fromJson(<String, dynamic>{
      'days': 30,
      'threshold': 0,
      'items': [
        {
          'product_id': 'p9',
          'name': 'Dust Collector',
          'sku': 'D-9',
          'category': 'Tools',
          'quantity': '5',
          'low_stock_threshold': '2',
          'stock_value': '250.000',
          'last_sale_date': null,
        },
      ],
      'total': 1,
      'page': 1,
      'page_size': 100,
      'pages': 1,
    });

List<String> _lines(String csv) =>
    csv.split('\r\n').sublist(0, csv.split('\r\n').length - 1);

void main() {
  group('CSV primitives (§12.2)', () {
    test('csvField quotes delimiters, quotes and newlines (RFC 4180)', () {
      expect(csvField('plain'), 'plain');
      expect(csvField('10.000'), '10.000');
      expect(csvField('a,b'), '"a,b"');
      expect(csvField('say "hi"'), '"say ""hi"""');
      expect(csvField('line1\nline2'), '"line1\nline2"');
      expect(csvField('line1\r\nline2'), '"line1\r\nline2"');
    });

    test('buildCsv joins with CRLF and ends with CRLF', () {
      final csv = buildCsv([
        ['a', 'b'],
        ['c', 'd'],
      ]);
      expect(csv, 'a,b\r\nc,d\r\n');
      expect(csv.endsWith('\r\n'), isTrue);
      expect(csv.contains('\n\n'), isFalse);
    });

    test('csvBytes prefixes the UTF-8 BOM (Excel on Windows)', () {
      final bytes = csvBytes('x,y\r\n');
      expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
      expect(String.fromCharCodes(bytes.sublist(3)), 'x,y\r\n');
    });

    test('filename format reports_<report>_<from>_<to>_<stamp>.csv', () {
      expect(
        reportCsvFilename(
          report: 'financial',
          dateFrom: '2026-09-01',
          dateTo: '2026-09-30',
          now: DateTime(2026, 9, 30, 14, 5, 6),
        ),
        'reports_financial_2026-09-01_2026-09-30_2026-09-30-140506.csv',
      );
      expect(
        reportCsvFilename(
          report: 'peak-hours',
          dateFrom: '2026-09-01',
          dateTo: '2026-09-30',
          now: DateTime(2026, 1, 2, 3, 4, 5),
        ),
        'reports_peak-hours_2026-09-01_2026-09-30_2026-01-02-030405.csv',
      );
    });
  });

  group('financial CSV (R1 + R15 device block)', () {
    test('header + totals row keep raw decimal strings, no % or separators',
        () {
      final lines = _lines(financialCsv(_financial(), 'en'));
      expect(lines, hasLength(6)); // header, totals, blank, dev header, 2 rows
      final header = lines[0].split(',');
      final totals = lines[1].split(',');
      expect(header, hasLength(totals.length));
      expect(header.first, AppStrings.t('label_period', 'en'));
      // Period cell carries the ISO range verbatim (§6 / §12.2).
      expect(totals.first, '2026-09-01 - 2026-09-30');
      // Raw money strings, no locale formatting, no % in cells.
      expect(lines[1], contains('1234.567'));
      expect(lines[1], contains('42.48'));
      expect(lines[1], isNot(contains('%')));
      // The raw value must survive untouched (no thousand separators).
      expect(totals[1], '1234.567');
    });

    test('device block has own header after a blank separator line', () {
      final lines = _lines(financialCsv(_financial(), 'en'));
      expect(lines[2], '');
      expect(lines[3].split(','),
          [AppStrings.t('col_device', 'en'), AppStrings.t('col_count', 'en'),
           AppStrings.t('col_net_revenue', 'en'), AppStrings.t('col_share', 'en')]);
      expect(lines[4], contains(AppStrings.t('label_unknown_device', 'en')));
      expect(lines[4], contains('100.00'));
      expect(lines[5], contains('POS-1'));
    });

    test('Arabic headers are localized (no key leaks, no RTL shaping)',
        () {
      final lines = _lines(financialCsv(_financial(), 'ar'));
      expect(lines[0].split(',').first, AppStrings.t('label_period', 'ar'));
      expect(lines[0].split(',').first, isNot('label_period'));
      expect(lines[0].split(',').first, isNot(AppStrings.t('label_period', 'en')));
      // Money cells stay ASCII/raw even in the RTL locale (§12.2).
      expect(lines[1], contains('1234.567'));
    });
  });

  group('§5.8 row reports (products / categories)', () {
    test('products CSV: quoted names, uncategorized label, totals row', () {
      final lines = _lines(productsCsv(_products(), 'en'));
      expect(lines, hasLength(3)); // header, row, totals
      expect(lines[0], contains(AppStrings.t('col_product', 'en')));
      // RFC 4180: comma + embedded quotes are escaped as one field.
      expect(lines[1], contains('"Widget, ""big"""'));
      expect(lines[1], contains(AppStrings.t('label_uncategorized', 'en')));
      // Totals row: label_total, blanks where §5 has no aggregate, then
      // items_sold / gross / … verbatim.
      final totals = lines[2].split(',');
      expect(totals[0], AppStrings.t('label_total', 'en'));
      expect(totals[1], '');
      expect(totals[2], '');
      expect(totals[3], '3');
      expect(totals[4], '30.000');
      expect(totals.last, ''); // margin has no aggregate
    });

    test('categories CSV totals row aligns with its 12 columns', () {
      final page = CategoryReportPage.fromJson(<String, dynamic>{
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
        'items': [
          {
            'category_id': null,
            'category': null,
            'qty_sold': '1',
            'gross': '10.000',
            'line_discounts': '0.000',
            'invoice_discount_share': '0.000',
            'net_revenue': '10.000',
            'return_qty': '0',
            'return_amount': '0.000',
            'cogs': '6.000',
            'return_cost': '0.000',
            'gross_profit': '4.000',
            'margin_pct': '40.00',
          },
        ],
        'totals': {
          'items_sold': '1',
          'gross_sales': '10.000',
          'net_sales': '10.000',
          'cogs': '6.000',
          'returns_cost': '0.000',
          'gross_profit': '4.000',
        },
      });
      final lines = _lines(categoriesCsv(page, 'en'));
      expect(lines, hasLength(3));
      expect(lines[1].split(',').first,
          AppStrings.t('label_uncategorized', 'en'));
      expect(lines[2].split(',').length, 12);
      expect(lines[2].split(',')[0], AppStrings.t('label_total', 'en'));
      expect(lines[2].split(',')[1], '1'); // items_sold
      expect(lines[2].split(',')[5], '10.000'); // net_sales
    });
  });

  group('time buckets (daily / hourly / peak)', () {
    test('hourly totals row leaves sales_total empty (no client math)', () {
      final lines = _lines(hourlyCsv(_hourly(), 'en'));
      expect(lines, hasLength(3));
      final totals = lines[2].split(',');
      expect(totals[0], AppStrings.t('label_total', 'en'));
      expect(totals[1], '100.000'); // net_sales aggregate exists
      expect(totals[2], ''); // sales_total: payload has no aggregate
      expect(totals[3], '0.000');
      expect(totals[4], '2');
      // Row values stay raw: ISO hour verbatim.
      expect(lines[1], contains('2026-09-01T09:00:00Z'));
      expect(lines[1], contains('105.000'));
    });

    test('daily CSV echoes ISO dates verbatim + totals row', () {
      final page = DailyReportPage.fromJson(<String, dynamic>{
        'date_from': '2026-09-01',
        'date_to': '2026-09-02',
        'items': [
          {
            'date': '2026-09-01',
            'net_sales': '100.000',
            'cogs_net': '60.000',
            'gross_profit': '40.000',
            'expenses': '10.000',
            'net_profit': '30.000',
            'invoice_count': 2,
            'items_sold': '5',
            'returns_total': '0.000',
          },
        ],
        'totals': {
          'net_sales': '100.000',
          'cogs_net': '60.000',
          'gross_profit': '40.000',
          'expenses_total': '10.000',
          'net_profit': '30.000',
          'invoice_count': 2,
          'items_sold': '5',
          'returns_total': '0.000',
        },
      });
      final lines = _lines(dailyCsv(page, 'en'));
      expect(lines, hasLength(3));
      expect(lines[1].split(',')[0], '2026-09-01');
      expect(lines[2].split(',')[0], AppStrings.t('label_total', 'en'));
      expect(lines[2].split(',')[6], '2');
    });

    test('peak CSV has one row per hour bucket + totals row', () {
      final report = PeakHoursReport.fromJson(<String, dynamic>{
        'lookback_days': 30,
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
        'items': [
          {'hour': 9, 'net_sales': '80.000', 'invoice_count': 3,
           'items_sold': '9'},
        ],
        'totals': {
          'net_sales': '80.000',
          'invoice_count': 3,
          'items_sold': '9',
        },
      });
      final lines = _lines(peakCsv(report, 'en'));
      expect(lines, hasLength(3));
      expect(lines[1].split(',')[0], '9');
      expect(lines[2].split(',')[0], AppStrings.t('label_total', 'en'));
    });
  });

  group('detail lists (voided / slow-moving / sales)', () {
    test('voided CSV has NO totals row (no totals payload)', () {
      final lines = _lines(voidedCsv(_voided(), 'en'));
      expect(lines, hasLength(2)); // header + 1 row
      expect(lines[1], isNot(contains(AppStrings.t('label_total', 'en'))));
      expect(lines[1], contains(AppStrings.t('label_cash', 'en')));
      expect(lines[1], contains('wrong item'));
      expect(lines[1], contains('POS-2'));
    });

    test('slow-moving CSV has NO totals row', () {
      final lines = _lines(slowMovingCsv(_slow(), 'en'));
      expect(lines, hasLength(2));
      expect(lines[1], contains('Dust Collector'));
      expect(lines[1], contains('250.000'));
      expect(lines.last, isNot(startsWith(AppStrings.t('label_total', 'en'))));
    });

    test('sales CSV includes localized status/method + totals row', () {
      final lines = _lines(salesCsv(_sales(), 'en'));
      expect(lines, hasLength(3));
      expect(lines[1], contains(AppStrings.t('status_completed', 'en')));
      expect(lines[1], contains(AppStrings.t('label_cash', 'en')));
      expect(lines[1], contains(AppStrings.t('label_unknown_device', 'en')));
      expect(lines[1], contains('5.000')); // change field mapped verbatim
      final totals = lines[2].split(',');
      expect(totals[0], AppStrings.t('label_total', 'en'));
      expect(totals[6], '100.000'); // subtotal
      expect(totals[8], '95.000'); // total
      expect(totals[10], '5.000'); // change
    });

    test('supplier report CSV: period range + the four §5.6 figures', () {
      final report = SupplierReport.fromJson(<String, dynamic>{
        'date_from': '2026-09-01',
        'date_to': '2026-09-30',
        'supplier_payable': '1500.000',
        'purchases_total': '2000.000',
        'supplier_paid': '500.000',
        'suppliers_with_balance': 3,
      });
      final lines = _lines(suppliersCsv(report, 'en'));
      expect(lines, hasLength(2));
      expect(lines[0].split(',').first, AppStrings.t('label_period', 'en'));
      final totals = lines[1].split(',');
      expect(totals[0], '2026-09-01 - 2026-09-30');
      expect(totals[1], '1500.000');
      expect(totals[4], '3');
    });
  });
}
