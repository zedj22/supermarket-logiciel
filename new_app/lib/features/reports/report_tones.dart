// Semantic color system for the Reports UI (Phase 14, Human QA
// Fix Round 2).
//
// One centralized mapping: widgets never hardcode hues — they ask for a
// [ReportMetricTone] and resolve it through the active [ThemeData], so
// Light / Dark / Grey each get brightness-appropriate accents that stay
// readable on their surfaces. Sales maps to the theme's primary blue
// (the app's revenue accent); every other tone carries a fixed semantic
// hue with light/dark variants (800-level on light, 300-level on dark).
import 'package:flutter/material.dart';

/// Semantic categories for report metrics.
enum ReportMetricTone {
  /// Sales / revenue — primary blue (resolved to `colorScheme.primary`).
  sales,

  /// Net profit — green (sign feedback handled separately).
  profit,

  /// Expenses — red.
  expense,

  /// Returns — orange.
  returnValue,

  /// Debt / outstanding receivables — orange-red (amber family).
  debt,

  /// COGS / cost — gold-amber.
  cost,

  /// Inventory / stock value — purple.
  inventory,

  /// Invoice / document counts — cyan.
  documents,
}

// Light-theme accents (800-level; contrast ≈ 4.5:1 on white where
// practical, ≥ 3:1 for large bold numbers).
const Map<ReportMetricTone, Color> _lightTones =
    <ReportMetricTone, Color>{
  ReportMetricTone.profit: Color(0xFF2E7D32),
  ReportMetricTone.expense: Color(0xFFC62828),
  ReportMetricTone.returnValue: Color(0xFFEF6C00),
  ReportMetricTone.debt: Color(0xFFD84315),
  ReportMetricTone.cost: Color(0xFF9C6400),
  ReportMetricTone.inventory: Color(0xFF6A1B9A),
  ReportMetricTone.documents: Color(0xFF00838F),
};

// Dark/Grey-theme accents (300-level; readable on #1E1E1E / #2A2A2A).
const Map<ReportMetricTone, Color> _darkTones =
    <ReportMetricTone, Color>{
  ReportMetricTone.profit: Color(0xFF66BB6A),
  ReportMetricTone.expense: Color(0xFFEF5350),
  ReportMetricTone.returnValue: Color(0xFFFFB74D),
  ReportMetricTone.debt: Color(0xFFFF8A65),
  ReportMetricTone.cost: Color(0xFFFFD54F),
  ReportMetricTone.inventory: Color(0xFFCE93D8),
  ReportMetricTone.documents: Color(0xFF4DD0E1),
};

/// Resolves [tone] to a color through the active theme: `sales` is the
/// theme's primary blue; the rest pick their brightness variant.
Color resolveReportTone(ReportMetricTone tone, ThemeData theme) {
  if (tone == ReportMetricTone.sales) return theme.colorScheme.primary;
  final map =
      theme.brightness == Brightness.light ? _lightTones : _darkTones;
  return map[tone]!;
}

/// One restrained icon per tone (no icon flood: only toned elements
/// render an icon).
IconData reportToneIcon(ReportMetricTone tone) {
  switch (tone) {
    case ReportMetricTone.sales:
      return Icons.point_of_sale_outlined;
    case ReportMetricTone.profit:
      return Icons.trending_up;
    case ReportMetricTone.expense:
      return Icons.receipt_long_outlined;
    case ReportMetricTone.returnValue:
      return Icons.assignment_return_outlined;
    case ReportMetricTone.debt:
      return Icons.request_quote_outlined;
    case ReportMetricTone.cost:
      return Icons.shopping_bag_outlined;
    case ReportMetricTone.inventory:
      return Icons.warehouse_outlined;
    case ReportMetricTone.documents:
      return Icons.receipt_outlined;
  }
}

/// KPI label → semantic tone (`null` = neutral, no accent). Central so
/// the financial tab and the dashboard stay consistent without passing
/// tones at every call site.
ReportMetricTone? reportKpiTone(String labelKey) {
  switch (labelKey) {
    // Sales / revenue family (blue).
    case 'kpi_gross_sales':
    case 'kpi_sales_after_discounts':
    case 'kpi_net_sales':
    case 'kpi_paid_cash':
    case 'kpi_paid_card':
    case 'kpi_paid_partial':
    case 'kpi_collected':
    case 'kpi_change':
    case 'kpi_today_sales':
    case 'kpi_recent_sales':
    case 'kpi_top_products':
      return ReportMetricTone.sales;
    // Profit family (green).
    case 'kpi_gross_profit':
    case 'kpi_net_profit':
    case 'kpi_margin':
    case 'kpi_today_profit':
      return ReportMetricTone.profit;
    // Expenses (red).
    case 'kpi_expenses':
    case 'kpi_expenses_drawer':
    case 'kpi_expenses_external':
    case 'kpi_today_expenses':
      return ReportMetricTone.expense;
    // Returns (orange).
    case 'kpi_returns_count':
    case 'kpi_returns_total':
      return ReportMetricTone.returnValue;
    // Debt / receivables (orange-red).
    case 'kpi_outstanding_debt':
    case 'kpi_debt_collected':
    case 'kpi_debt_created':
    case 'kpi_ar_outstanding':
    case 'kpi_customers_with_debt':
    case 'kpi_total_debt':
    case 'kpi_supplier_payable':
    case 'kpi_suppliers_with_balance':
      return ReportMetricTone.debt;
    // Costs / purchases (gold-amber).
    case 'kpi_cogs':
    case 'kpi_cogs_net':
    case 'kpi_returns_cost':
    case 'kpi_purchases_total':
    case 'kpi_supplier_paid':
      return ReportMetricTone.cost;
    // Inventory / stock (purple).
    case 'kpi_stock_value':
    case 'kpi_low_stock':
    case 'kpi_total_products':
      return ReportMetricTone.inventory;
    // Invoice / document counts (cyan).
    case 'kpi_invoices':
    case 'kpi_items_sold':
      return ReportMetricTone.documents;
    default:
      return null;
  }
}

/// Table column label → semantic tone (`null` = neutral). Only genuinely
/// meaningful columns are toned — profit columns go green (sign-aware),
/// return columns orange; everything else stays neutral so tables never
/// turn into a rainbow.
ReportMetricTone? reportColumnTone(String labelKey) {
  switch (labelKey) {
    case 'col_gross_profit':
    case 'col_net_profit':
    case 'col_margin':
      return ReportMetricTone.profit;
    case 'col_returns_qty':
    case 'col_returns_amount':
      return ReportMetricTone.returnValue;
    default:
      return null;
  }
}

/// `-1200`, `-12.5%`, `-0` → true. Sign check only; the string is never
/// reformatted (money stays server-owned).
bool isNegativeValue(String raw) => raw.trim().startsWith('-');

/// Sign-aware text color for a money/percent value:
/// negatives → expense red, positive profit → profit green, otherwise
/// the tone's accent (or `null` to keep the default text color).
Color? reportValueColor(
  String raw,
  ReportMetricTone? tone,
  ThemeData theme,
) {
  if (isNegativeValue(raw)) {
    return resolveReportTone(ReportMetricTone.expense, theme);
  }
  if (tone == null) return null;
  if (tone == ReportMetricTone.profit) {
    return resolveReportTone(ReportMetricTone.profit, theme);
  }
  if (tone == ReportMetricTone.expense) {
    // Expenses: the icon/accent carries the red — keep the number
    // neutral so a screen of red numbers does not look like errors.
    return null;
  }
  // Return/debt/cost columns read better in their semantic hue; sales
  // columns stay neutral (blue numbers everywhere would fight the
  // profit greens).
  if (tone == ReportMetricTone.sales) return null;
  return resolveReportTone(tone, theme);
}
