// Phase 14 (Reports + Dashboard) localization coverage across ar/fr/en.
//
// Contract (§14): every Phase 14 key × 3 locales resolves to a real
// translation (never the raw key — `AppStrings.t` falls back to the key
// itself, which would render `report_invalid_range` literally on screen),
// the three maps are actually localized, and every dynamic key family the
// reports UI composes (`status_*`, `label_*`, `preset_*`, sort labels)
// also resolves for every enum value the code can produce.
import 'package:flutter_test/flutter_test.dart';
import 'package:supermarket_pos/core/strings.dart';
import 'package:supermarket_pos/features/reports/report_models.dart';
import 'package:supermarket_pos/features/reports/reports_providers.dart';

const _locales = ['ar', 'fr', 'en'];

/// Keys introduced by Phase 14 — the block appended to each locale map
/// after `category_other` (tab names, KPI labels, filters/presets, table
/// headers, states, export, status/payment labels, 422 error codes).
const _phase14Keys = [
  // Report tab names / device filter
  'report_financial',
  'report_products',
  'report_categories',
  'report_daily',
  'report_hourly',
  'report_peak_hours',
  'report_slow_moving',
  'report_voided',
  'report_sales',
  'report_suppliers',
  'report_device',
  // KPI labels (§5 / §7)
  'kpi_gross_sales',
  'kpi_line_discounts',
  'kpi_invoice_discounts',
  'kpi_discounts_total',
  'kpi_sales_after_discounts',
  'kpi_net_sales',
  'kpi_returns_count',
  'kpi_returns_total',
  'kpi_invoices',
  'kpi_items_sold',
  'kpi_cogs',
  'kpi_returns_cost',
  'kpi_cogs_net',
  'kpi_expenses',
  'kpi_expenses_drawer',
  'kpi_expenses_external',
  'kpi_gross_profit',
  'kpi_net_profit',
  'kpi_margin',
  'kpi_paid_cash',
  'kpi_paid_card',
  'kpi_paid_partial',
  'kpi_collected',
  'kpi_debt_created',
  'kpi_change',
  'kpi_outstanding_debt',
  'kpi_debt_collected',
  'kpi_ar_outstanding',
  'kpi_customers_with_debt',
  'kpi_total_debt',
  'kpi_stock_value',
  'kpi_low_stock',
  'kpi_today_sales',
  'kpi_today_profit',
  'kpi_today_expenses',
  'kpi_total_products',
  'kpi_total_customers',
  'kpi_recent_sales',
  'kpi_top_products',
  'kpi_supplier_payable',
  'kpi_purchases_total',
  'kpi_supplier_paid',
  'kpi_suppliers_with_balance',
  // Filters / presets
  'filter_from',
  'filter_to',
  'filter_device',
  'filter_status',
  'filter_payment',
  'preset_today',
  'preset_yesterday',
  'preset_last_7_days',
  'preset_this_month',
  'preset_last_month',
  'preset_last_3_months',
  'preset_last_6_months',
  'preset_custom',
  'filter_sort',
  'filter_lookback',
  'filter_threshold',
  'filter_all_devices',
  // Table headers
  'col_invoice',
  'col_date',
  'col_time',
  'col_customer',
  'col_user',
  'col_device',
  'col_method',
  'col_subtotal',
  'col_line_discounts',
  'col_invoice_discount',
  'col_total',
  'col_paid',
  'col_change',
  'col_qty',
  'col_gross',
  'col_net_revenue',
  'col_returns_qty',
  'col_returns_amount',
  'col_cogs',
  'col_gross_profit',
  'col_margin',
  'col_expenses',
  'col_net_profit',
  'col_category',
  'col_product',
  'col_sku',
  'col_stock',
  'col_stock_value',
  'col_last_sale',
  'col_voided_at',
  'col_void_reason',
  'col_hour',
  'col_share',
  'col_count',
  // Totals / states / misc
  'label_total',
  'label_unknown_device',
  'label_uncategorized',
  'state_no_data',
  'state_loading',
  'state_error',
  'label_today',
  'label_period',
  'label_as_of',
  'label_snapshot',
  'label_documents',
  'label_percent',
  // Export (§12.2)
  'export_csv',
  'export_xlsx',
  'export_pdf',
  'export_row_limit',
  'export_failed',
  'export_permission',
  'export_started',
  'export_done',
  'export_report_name',
  // Status / payment labels
  'status_completed',
  'status_all',
  'label_cash',
  'label_card',
  'label_partial',
  'label_credit',
  // Report errors (422 codes, §11)
  'report_invalid_range',
  'report_range_too_wide',
  'report_sort_invalid',
];

/// Existing keys the Phase 14 screens reuse (must not regress).
const _reusedKeys = [
  'dashboard',
  'reports',
  'permission_denied',
  'network_error_retry',
  'api_error_retry',
  'validation_error',
  'session_expired_login',
  'refresh',
  'retry',
  'all',
  'clear',
  'status_void',
];

void main() {
  group('Phase 14 report strings', () {
  test('exactly 135 Phase 14 keys are under test (405 entries)', () {
    expect(_phase14Keys, hasLength(135));
    expect(_phase14Keys.toSet(), hasLength(135), reason: 'duplicate key');
    });

    for (final locale in _locales) {
      test('every Phase 14 key exists and is non-empty in "$locale"', () {
        for (final key in _phase14Keys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing/empty: $key@$locale');
          expect(
            value,
            isNot(key),
            reason: 'untranslated fallback for $key@$locale',
          );
        }
      });

      test('reused keys still resolve in "$locale"', () {
        for (final key in _reusedKeys) {
          final value = AppStrings.t(key, locale);
          expect(value, isNotEmpty, reason: 'missing: $key@$locale');
          expect(value, isNot(key), reason: 'raw key: $key@$locale');
        }
      });
    }

    test('Arabic and English Phase 14 translations differ', () {
      var translated = 0;
      for (final key in _phase14Keys) {
        if (AppStrings.t(key, 'ar') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase14Keys.length ~/ 2));
    });

    test('French and English Phase 14 translations differ', () {
      var translated = 0;
      for (final key in _phase14Keys) {
        if (AppStrings.t(key, 'fr') != AppStrings.t(key, 'en')) {
          translated++;
        }
      }
      expect(translated, greaterThan(_phase14Keys.length ~/ 2));
    });

    test('every sales status has a localized label (sales filter + CSV)', () {
      for (final locale in _locales) {
        for (final status in kSalesStatuses) {
          final key = reportStatusKey(status);
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: 'missing status label $key@$locale',
          );
        }
      }
    });

    test('every payment method has a localized label (tabs + CSV)', () {
      for (final locale in _locales) {
        for (final method in kSalesPaymentMethods) {
          final key = reportPaymentMethodKey(method);
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: 'missing payment label $key@$locale',
          );
        }
      }
    });

    test('every preset has a localized label', () {
      for (final locale in _locales) {
        for (final preset in kReportPresets) {
          final key = reportPresetKey(preset);
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: 'missing preset label $key@$locale',
          );
        }
      }
    });

    test('every sort option maps to an existing column label', () {
      for (final locale in _locales) {
        for (final sort in kReportSorts) {
          final key = reportSortKey(sort);
          expect(
            AppStrings.t(key, locale),
            isNot(key),
            reason: 'missing sort label $key@$locale',
          );
        }
      }
    });

    test('device label falls back to the localized unknown-device text', () {
      for (final locale in _locales) {
        expect(
          reportDeviceLabel(null, locale),
          AppStrings.t('label_unknown_device', locale),
        );
        expect(reportDeviceLabel('', locale), isNot(''));
        expect(reportDeviceLabel('POS-1', locale), 'POS-1');
      }
    });
  });
}
