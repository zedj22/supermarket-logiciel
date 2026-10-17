// The ten Phase 14 report tabs (§8): R1 financial (+ R15 device
// breakdown), R2 products, R3 categories, R4 daily, R5 hourly, R6 peak,
// R7 slow-moving, R8 voided, R9 sales detail, R13 suppliers.
//
// Every tab loads its own controller on first build (initState) and is
// kept alive across tab switches (AutomaticKeepAliveClientMixin) so a
// preset change only refreshes tabs that were already opened. All money
// renders through `formatMoney` (trailing-zero trim) — never computed.
// Charts are plain widgets per G24 (see `ReportBarChart`).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../core/widgets/h_scroll_view.dart';
import '../../core/widgets/section_header.dart';
import '../../l10n/locale_provider.dart';
import '../clients/customer_models.dart';
import 'report_models.dart';
import 'report_tones.dart';
import 'report_widgets.dart';
import 'reports_providers.dart';

String _m(String raw) => formatMoney(raw);

String _pct(String raw) => '${formatMoney(raw)}%';

/// Localized enum label with a graceful raw fallback (never a `label_*`
/// key leaking to the screen when the server sends an unknown code).
String _enumLabel(String key, String raw, String loc) {
  final value = AppStrings.t(key, loc);
  return value == key ? raw : value;
}

String _methodLabel(String method, String loc) =>
    method.isEmpty ? '' : _enumLabel('label_$method', method, loc);

String _statusLabel(String status, String loc) =>
    _enumLabel('status_$status', status, loc);

double _num(String raw) => double.tryParse(raw) ?? 0.0;

/// Section header: small semantic icon chip + title + a subtle accent
/// line that fills the remaining width (visual hierarchy — the header
/// separates sections without dominating them). [tone] resolves through
/// the active theme; [icon] overrides the tone's default glyph.
Widget _sectionTitle(
  ThemeData theme,
  String loc,
  String titleKey, {
  ReportMetricTone? tone,
  IconData? icon,
}) {
  final accent =
      tone == null ? theme.colorScheme.primary : resolveReportTone(tone, theme);
  // One shared implementation (lib/core/widgets/section_header.dart) so the
  // reports, dashboard and devices section breaks read identically.
  return SectionHeader(
    title: AppStrings.t(titleKey, loc),
    titleKey: titleKey,
    accent: accent,
    icon: icon ?? (tone == null ? null : reportToneIcon(tone)),
  );
}

/// Responsive KPI grid: the number of columns grows with the available
/// width (1 → 5) so cards always fill the row instead of hugging their
/// labels, and every card in a row shares the same cell width.
Widget _tiles(List<Widget> children) => LayoutBuilder(
      builder: (context, constraints) {
        const spacing = 10.0;
        // Guard against an unbounded parent (ListView keeps this finite,
        // but a fallback keeps the grid safe wherever else it lands).
        final width =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 600.0;
        final columns = width >= 1200
            ? 5
            : width >= 960
                ? 4
                : width >= 680
                    ? 3
                    : width >= 420
                        ? 2
                        : 1;
        final cell = columns == 1
            ? width
            : (width - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final child in children) SizedBox(width: cell, child: child),
          ],
        );
      },
    );

ReportKpiTile _tile(String labelKey, String value) => ReportKpiTile(
      labelKey: labelKey,
      value: value,
      testKey: 'kpi-$labelKey',
    );

// ---------------------------------------------------------------------------
// R1 — Financial / P&L (+ R15 device breakdown)
// ---------------------------------------------------------------------------

class FinancialTab extends ConsumerStatefulWidget {
  const FinancialTab({super.key});

  @override
  ConsumerState<FinancialTab> createState() => _FinancialTabState();
}

class _FinancialTabState extends ConsumerState<FinancialTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(financialProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(financialProvider);
    final r = state.data;

    return ReportStateView<FinancialReport>(
      state: state,
      isEmpty: false,
      emptyKey: 'state_no_data',
      loc: loc,
      onRetry: () => ref.read(financialProvider.notifier).load(),
      child: r == null
          ? const SizedBox.shrink()
          : ListView(
              key: const Key('financial-content'),
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                _sectionTitle(theme, loc, 'sales',
                    tone: ReportMetricTone.sales),
                _tiles([
                  _tile('kpi_gross_sales', _m(r.grossSales)),
                  _tile('kpi_line_discounts', _m(r.lineDiscounts)),
                  _tile('kpi_invoice_discounts', _m(r.invoiceDiscounts)),
                  _tile('kpi_discounts_total', _m(r.discountsTotal)),
                  _tile(
                      'kpi_sales_after_discounts', _m(r.salesAfterDiscounts)),
                  _tile('kpi_returns_count', '${r.returnsCount}'),
                  _tile('kpi_returns_total', _m(r.returnsTotal)),
                  _tile('kpi_net_sales', _m(r.netSales)),
                  _tile('kpi_invoices', '${r.invoiceCount}'),
                  _tile('kpi_items_sold', _m(r.itemsSold)),
                ]),
                _sectionTitle(theme, loc, 'kpi_cogs',
                    tone: ReportMetricTone.cost),
                _tiles([
                  _tile('kpi_cogs', _m(r.cogs)),
                  _tile('kpi_returns_cost', _m(r.returnsCost)),
                  _tile('kpi_cogs_net', _m(r.cogsNet)),
                ]),
                _sectionTitle(theme, loc, 'kpi_net_profit',
                    tone: ReportMetricTone.profit),
                _tiles([
                  _tile('kpi_expenses', _m(r.expensesTotal)),
                  _tile('kpi_expenses_drawer', _m(r.expensesDrawer)),
                  _tile('kpi_expenses_external', _m(r.expensesExternal)),
                  _tile('kpi_gross_profit', _m(r.grossProfit)),
                  _tile('kpi_net_profit', _m(r.netProfit)),
                  _tile('kpi_margin', _pct(r.profitMarginPct)),
                ]),
                _sectionTitle(theme, loc, 'payment_method',
                    tone: ReportMetricTone.documents),
                _tiles([
                  _tile('kpi_paid_cash', _m(r.paidCash)),
                  _tile('kpi_paid_card', _m(r.paidCard)),
                  _tile('kpi_paid_partial', _m(r.paidPartial)),
                  _tile('kpi_collected', _m(r.collectedTotal)),
                  _tile('kpi_debt_created', _m(r.debtCreated)),
                  _tile('kpi_change', _m(r.changeTotal)),
                ]),
                _sectionTitle(theme, loc, 'debts',
                    tone: ReportMetricTone.debt),
                _tiles([
                  _tile('kpi_outstanding_debt', _m(r.outstandingDebt)),
                  _tile('kpi_debt_collected', _m(r.debtCollected)),
                  _tile('kpi_ar_outstanding', _m(r.arOutstanding)),
                  _tile('kpi_customers_with_debt', '${r.customersWithDebt}'),
                ]),
                // §8 R15 — device breakdown (grouping, not an endpoint).
                _sectionTitle(
                  theme,
                  loc,
                  'report_device',
                  tone: ReportMetricTone.documents,
                  icon: Icons.devices_outlined,
                ),
                if (r.deviceBreakdown.isEmpty)
                  Text(AppStrings.t('state_no_data', loc))
                else
                  SizedBox(
                    // Bounded so this table pins its heading and scrolls
                    // its own rows instead of taking over the tab (§17.2).
                    height: (44 + r.deviceBreakdown.length * 41)
                        .clamp(120, 360)
                        .toDouble(),
                    child: ReportTable(
                      key: const Key('financial-devices'),
                      rowKeyPrefix: 'device-row',
                      loc: loc,
                      columns: const [
                        ReportColumn('col_device'),
                        ReportColumn('col_count', numeric: true),
                        ReportColumn('col_net_revenue', numeric: true),
                        ReportColumn('col_share', numeric: true),
                      ],
                      rows: [
                        for (final d in r.deviceBreakdown)
                          [
                            reportDeviceLabel(d.deviceId, loc),
                            '${d.invoiceCount}',
                            _m(d.netSales),
                            _pct(d.sharePct),
                          ],
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// R2 — Product performance
// ---------------------------------------------------------------------------

class ProductsTab extends ConsumerStatefulWidget {
  const ProductsTab({super.key});

  @override
  ConsumerState<ProductsTab> createState() => _ProductsTabState();
}

class _ProductsTabState extends ConsumerState<ProductsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(productsProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(productsProvider);
    final controller = ref.read(productsProvider.notifier);
    final page = state.data;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<String>(
                key: ValueKey<String>('reports-sort-${controller.sort}'),
                initialValue: controller.sort,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: AppStrings.t('filter_sort', loc),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final sort in kReportSorts)
                    DropdownMenuItem(
                      value: sort,
                      child: Text(
                        AppStrings.t(reportSortKey(sort), loc),
                        key: Key('reports-sort-item-$sort'),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) controller.setSort(value);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ReportStateView<ProductReportPage>(
            state: state,
            isEmpty: page?.items.isEmpty ?? false,
            emptyKey: 'state_no_data',
            loc: loc,
            emptyTone: ReportMetricTone.inventory,
            emptyIcon: Icons.warehouse_outlined,
            onRetry: () => ref.read(productsProvider.notifier).load(),
            child: page == null
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      Expanded(
                        child: ReportTable(
                          key: const Key('products-table'),
                          loc: loc,
                          columns: const [
                            ReportColumn('col_product'),
                            ReportColumn('col_sku'),
                            ReportColumn('col_category'),
                            ReportColumn('col_qty', numeric: true),
                            ReportColumn('col_gross', numeric: true),
                            ReportColumn('col_line_discounts', numeric: true),
                            ReportColumn('col_invoice_discount',
                                numeric: true),
                            ReportColumn('col_net_revenue', numeric: true),
                            ReportColumn('col_returns_qty', numeric: true),
                            ReportColumn('col_returns_amount',
                                numeric: true),
                            ReportColumn('col_cogs', numeric: true),
                            ReportColumn('kpi_returns_cost', numeric: true),
                            ReportColumn('col_gross_profit', numeric: true),
                            ReportColumn('col_margin', numeric: true),
                          ],
                          rows: [
                            for (final row in page.items)
                              [
                                row.name,
                                row.sku ?? '',
                                (row.category == null ||
                                        row.category!.isEmpty)
                                    ? AppStrings.t('label_uncategorized', loc)
                                    : row.category!,
                                _m(row.qtySold),
                                _m(row.gross),
                                _m(row.lineDiscounts),
                                _m(row.invoiceDiscountShare),
                                _m(row.netRevenue),
                                _m(row.returnQty),
                                _m(row.returnAmount),
                                _m(row.cogs),
                                _m(row.returnCost),
                                _m(row.grossProfit),
                                _pct(row.marginPct),
                              ],
                          ],
                          totalsRow: [
                            AppStrings.t('label_total', loc),
                            '',
                            '',
                            _m(page.totals.itemsSold),
                            _m(page.totals.grossSales),
                            '',
                            '',
                            _m(page.totals.netSales),
                            '',
                            _m(page.totals.returnsTotal),
                            _m(page.totals.cogs),
                            _m(page.totals.returnsCost),
                            _m(page.totals.grossProfit),
                            '',
                          ],
                        ),
                      ),
                      if (page.pages > 1)
                        ReportPagination(
                          page: page.page,
                          pages: page.pages,
                          total: page.total,
                          loading: state.loading,
                          onPrev: () =>
                              ref.read(productsProvider.notifier).setPage(
                                    page.page - 1,
                                  ),
                          onNext: () =>
                              ref.read(productsProvider.notifier).setPage(
                                    page.page + 1,
                                  ),
                          loc: loc,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// R3 — Category analysis
// ---------------------------------------------------------------------------

class CategoriesTab extends ConsumerStatefulWidget {
  const CategoriesTab({super.key});

  @override
  ConsumerState<CategoriesTab> createState() => _CategoriesTabState();
}

class _CategoriesTabState extends ConsumerState<CategoriesTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(categoriesProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(categoriesProvider);
    final page = state.data;

    return ReportStateView<CategoryReportPage>(
      state: state,
      isEmpty: page?.items.isEmpty ?? false,
      emptyKey: 'state_no_data',
      loc: loc,
      onRetry: () => ref.read(categoriesProvider.notifier).load(),
      child: page == null
          ? const SizedBox.shrink()
          : ReportTable(
              key: const Key('categories-table'),
              loc: loc,
              columns: const [
                ReportColumn('col_category'),
                ReportColumn('col_qty', numeric: true),
                ReportColumn('col_gross', numeric: true),
                ReportColumn('col_line_discounts', numeric: true),
                ReportColumn('col_invoice_discount', numeric: true),
                ReportColumn('col_net_revenue', numeric: true),
                ReportColumn('col_returns_qty', numeric: true),
                ReportColumn('col_returns_amount', numeric: true),
                ReportColumn('col_cogs', numeric: true),
                ReportColumn('kpi_returns_cost', numeric: true),
                ReportColumn('col_gross_profit', numeric: true),
                ReportColumn('col_margin', numeric: true),
              ],
              rows: [
                for (final row in page.items)
                  [
                    (row.category == null || row.category!.isEmpty)
                        ? AppStrings.t('label_uncategorized', loc)
                        : row.category!,
                    _m(row.qtySold),
                    _m(row.gross),
                    _m(row.lineDiscounts),
                    _m(row.invoiceDiscountShare),
                    _m(row.netRevenue),
                    _m(row.returnQty),
                    _m(row.returnAmount),
                    _m(row.cogs),
                    _m(row.returnCost),
                    _m(row.grossProfit),
                    _pct(row.marginPct),
                  ],
              ],
              totalsRow: [
                AppStrings.t('label_total', loc),
                _m(page.totals.itemsSold),
                _m(page.totals.grossSales),
                '',
                '',
                _m(page.totals.netSales),
                '',
                _m(page.totals.returnsTotal),
                _m(page.totals.cogs),
                _m(page.totals.returnsCost),
                _m(page.totals.grossProfit),
                '',
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// R4 — Daily timeline (table + plain bar chart, G24)
// ---------------------------------------------------------------------------

class DailyTab extends ConsumerStatefulWidget {
  const DailyTab({super.key});

  @override
  ConsumerState<DailyTab> createState() => _DailyTabState();
}

class _DailyTabState extends ConsumerState<DailyTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(dailyProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(dailyProvider);
    final page = state.data;

    return ReportStateView<DailyReportPage>(
      state: state,
      isEmpty: page?.items.isEmpty ?? false,
      emptyKey: 'state_no_data',
      loc: loc,
      emptyTone: ReportMetricTone.sales,
      emptyIcon: Icons.point_of_sale_outlined,
      onRetry: () => ref.read(dailyProvider.notifier).load(),
      child: page == null
          ? const SizedBox.shrink()
          : ListView(
              key: const Key('daily-content'),
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                if (page.items.length <= 48) ...[
                  // Bar chart of the server's net_sales series (§8 R4).
                  SizedBox(
                    height: 200,
                    child: ReportBarChart(
                      bars: [
                        for (final row in page.items)
                          ReportBar(
                            label: row.date.length >= 10
                                ? row.date.substring(5)
                                : row.date,
                            value: _num(row.netSales),
                            caption: page.items.length <= 14
                                ? _m(row.netSales)
                                : null,
                          ),
                      ],
                      barKeyPrefix: 'daily-bar',
                      tone: ReportMetricTone.sales,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  height: 360,
                  child: ReportTable(
                    key: const Key('daily-table'),
                    loc: loc,
                    columns: const [
                      ReportColumn('col_date'),
                      ReportColumn('kpi_net_sales', numeric: true),
                      ReportColumn('col_cogs', numeric: true),
                      ReportColumn('col_gross_profit', numeric: true),
                      ReportColumn('col_expenses', numeric: true),
                      ReportColumn('col_net_profit', numeric: true),
                      ReportColumn('kpi_invoices', numeric: true),
                      ReportColumn('kpi_items_sold', numeric: true),
                      ReportColumn('kpi_returns_total', numeric: true),
                    ],
                    rows: [
                      for (final row in page.items)
                        [
                          row.date,
                          _m(row.netSales),
                          _m(row.cogsNet),
                          _m(row.grossProfit),
                          _m(row.expenses),
                          _m(row.netProfit),
                          '${row.invoiceCount}',
                          _m(row.itemsSold),
                          _m(row.returnsTotal),
                        ],
                    ],
                    totalsRow: [
                      AppStrings.t('label_total', loc),
                      _m(page.totals.netSales),
                      _m(page.totals.cogsNet),
                      _m(page.totals.grossProfit),
                      _m(page.totals.expensesTotal),
                      _m(page.totals.netProfit),
                      '${page.totals.invoiceCount}',
                      _m(page.totals.itemsSold),
                      _m(page.totals.returnsTotal),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// R5 — Hourly timeline (table + plain bar chart, G24)
// ---------------------------------------------------------------------------

class HourlyTab extends ConsumerStatefulWidget {
  const HourlyTab({super.key});

  @override
  ConsumerState<HourlyTab> createState() => _HourlyTabState();
}

class _HourlyTabState extends ConsumerState<HourlyTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(hourlyProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(hourlyProvider);
    final page = state.data;

    return ReportStateView<HourlyReportPage>(
      state: state,
      isEmpty: page?.items.isEmpty ?? false,
      emptyKey: 'state_no_data',
      loc: loc,
      emptyTone: ReportMetricTone.sales,
      emptyIcon: Icons.point_of_sale_outlined,
      onRetry: () => ref.read(hourlyProvider.notifier).load(),
      child: page == null
          ? const SizedBox.shrink()
          : ListView(
              key: const Key('hourly-content'),
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                if (page.items.length <= 48) ...[
                  SizedBox(
                    height: 200,
                    child: ReportBarChart(
                      bars: [
                        for (final row in page.items)
                          ReportBar(
                            label: reportHourLabel(row.hour).length >= 16
                                ? reportHourLabel(row.hour).substring(11)
                                : reportHourLabel(row.hour),
                            value: _num(row.netSales),
                            caption: page.items.length <= 14
                                ? _m(row.netSales)
                                : null,
                          ),
                      ],
                      barKeyPrefix: 'hourly-bar',
                      tone: ReportMetricTone.sales,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                SizedBox(
                  height: 360,
                  child: ReportTable(
                    key: const Key('hourly-table'),
                    loc: loc,
                    columns: const [
                      ReportColumn('col_hour'),
                      ReportColumn('kpi_net_sales', numeric: true),
                      ReportColumn('col_gross', numeric: true),
                      ReportColumn('kpi_returns_total', numeric: true),
                      ReportColumn('kpi_invoices', numeric: true),
                    ],
                    rows: [
                      for (final row in page.items)
                        [
                          reportHourLabel(row.hour),
                          _m(row.netSales),
                          _m(row.salesTotal),
                          _m(row.returnsTotal),
                          '${row.invoiceCount}',
                        ],
                    ],
                    totalsRow: [
                      AppStrings.t('label_total', loc),
                      _m(page.totals.netSales),
                      '',
                      _m(page.totals.returnsTotal),
                      '${page.totals.invoiceCount}',
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// R6 — Peak hours (24-row chart + table)
// ---------------------------------------------------------------------------

class PeakTab extends ConsumerStatefulWidget {
  const PeakTab({super.key});

  @override
  ConsumerState<PeakTab> createState() => _PeakTabState();
}

class _PeakTabState extends ConsumerState<PeakTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(peakProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(peakProvider);
    final controller = ref.read(peakProvider.notifier);
    final report = state.data;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 200,
              child: TextFormField(
                key: const Key('reports-lookback'),
                initialValue: '${controller.lookbackDays}',
                decoration: InputDecoration(
                  labelText: AppStrings.t('filter_lookback', loc),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                inputFormatters: [LengthLimitingTextInputFormatter(3)],
                onFieldSubmitted: (value) {
                  final parsed = int.tryParse(value.trim());
                  if (parsed != null) controller.setLookback(parsed);
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ReportStateView<PeakHoursReport>(
            state: state,
            isEmpty: report?.items.isEmpty ?? false,
            emptyKey: 'state_no_data',
            loc: loc,
            emptyTone: ReportMetricTone.sales,
            emptyIcon: Icons.point_of_sale_outlined,
            onRetry: () => ref.read(peakProvider.notifier).load(),
            child: report == null
                ? const SizedBox.shrink()
                : ListView(
                    key: const Key('peak-content'),
                    padding: const EdgeInsets.only(top: 8, bottom: 24),
                    children: [
                      SizedBox(
                        height: 200,
                        child: ReportBarChart(
                          bars: [
                            for (final row in report.items)
                              ReportBar(
                                label: reportPeakHourLabel(row.hour),
                                value: _num(row.netSales),
                              ),
                          ],
                          barKeyPrefix: 'peak-bar',
                          tone: ReportMetricTone.documents,
                        ),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        height: 420,
                        child: ReportTable(
                          key: const Key('peak-table'),
                          loc: loc,
                          columns: const [
                            ReportColumn('col_hour'),
                            ReportColumn('kpi_net_sales', numeric: true),
                            ReportColumn('kpi_invoices', numeric: true),
                            ReportColumn('kpi_items_sold', numeric: true),
                          ],
                          rows: [
                            for (final row in report.items)
                              [
                                '${row.hour}',
                                _m(row.netSales),
                                '${row.invoiceCount}',
                                _m(row.itemsSold),
                              ],
                          ],
                          totalsRow: [
                            AppStrings.t('label_total', loc),
                            _m(report.totals.netSales),
                            '${report.totals.invoiceCount}',
                            _m(report.totals.itemsSold),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// R7 — Slow-moving stock
// ---------------------------------------------------------------------------

class SlowMovingTab extends ConsumerStatefulWidget {
  const SlowMovingTab({super.key});

  @override
  ConsumerState<SlowMovingTab> createState() => _SlowMovingTabState();
}

class _SlowMovingTabState extends ConsumerState<SlowMovingTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(slowMovingProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(slowMovingProvider);
    final controller = ref.read(slowMovingProvider.notifier);
    final page = state.data;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Two fixed-width inputs: fine on a wide window, 1px (and worse
        // in English) over the edge on a narrow one. HScrollView keeps
        // every control reachable instead of clipping the second field.
        HScrollView(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 170,
                child: TextFormField(
                  key: const Key('reports-slow-days'),
                  initialValue: '${controller.days}',
                  decoration: InputDecoration(
                    labelText: AppStrings.t('filter_lookback', loc),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(3)],
                  onFieldSubmitted: (value) {
                    final parsed = int.tryParse(value.trim());
                    if (parsed != null) controller.setDays(parsed);
                  },
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 170,
                child: TextFormField(
                  key: const Key('reports-slow-threshold'),
                  initialValue: '${controller.threshold}',
                  decoration: InputDecoration(
                    labelText: AppStrings.t('filter_threshold', loc),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(4)],
                  onFieldSubmitted: (value) {
                    final parsed = int.tryParse(value.trim());
                    if (parsed != null) controller.setThreshold(parsed);
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ReportStateView<SlowMovingPage>(
            state: state,
            isEmpty: page?.items.isEmpty ?? false,
            emptyKey: 'state_no_data',
            loc: loc,
            emptyTone: ReportMetricTone.inventory,
            emptyIcon: Icons.warehouse_outlined,
            onRetry: () => ref.read(slowMovingProvider.notifier).load(),
            child: page == null
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      Expanded(
                        child: ReportTable(
                          key: const Key('slow-table'),
                          loc: loc,
                          columns: const [
                            ReportColumn('col_product'),
                            ReportColumn('col_sku'),
                            ReportColumn('col_category'),
                            ReportColumn('col_qty', numeric: true),
                            ReportColumn('col_stock_value', numeric: true),
                            ReportColumn('col_last_sale'),
                          ],
                          rows: [
                            for (final row in page.items)
                              [
                                row.name,
                                row.sku ?? '',
                                row.category ?? '',
                                _m(row.quantity),
                                _m(row.stockValue),
                                row.lastSaleDate == null
                                    ? ''
                                    : reportDateTimeLabel(row.lastSaleDate!),
                              ],
                          ],
                        ),
                      ),
                      if (page.pages > 1)
                        ReportPagination(
                          page: page.page,
                          pages: page.pages,
                          total: page.total,
                          loading: state.loading,
                          onPrev: () =>
                              ref.read(slowMovingProvider.notifier).setPage(
                                    page.page - 1,
                                  ),
                          onNext: () =>
                              ref.read(slowMovingProvider.notifier).setPage(
                                    page.page + 1,
                                  ),
                          loc: loc,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// R8 — Voided invoices
// ---------------------------------------------------------------------------

class VoidedTab extends ConsumerStatefulWidget {
  const VoidedTab({super.key});

  @override
  ConsumerState<VoidedTab> createState() => _VoidedTabState();
}

class _VoidedTabState extends ConsumerState<VoidedTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(voidedProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(voidedProvider);
    final page = state.data;

    return ReportStateView<VoidedReportPage>(
      state: state,
      isEmpty: page?.items.isEmpty ?? false,
      emptyKey: 'state_no_data',
      loc: loc,
      onRetry: () => ref.read(voidedProvider.notifier).load(),
      child: page == null
          ? const SizedBox.shrink()
          : Column(
              children: [
                Expanded(
                  child: ReportTable(
                    key: const Key('voided-table'),
                    loc: loc,
                    columns: const [
                      ReportColumn('col_invoice'),
                      ReportColumn('col_date'),
                      ReportColumn('col_voided_at'),
                      ReportColumn('col_total', numeric: true),
                      ReportColumn('col_method'),
                      ReportColumn('col_void_reason'),
                      ReportColumn('col_user'),
                      ReportColumn('col_device'),
                      ReportColumn('col_count', numeric: true),
                    ],
                    rows: [
                      for (final row in page.items)
                        [
                          row.invoiceNumber,
                          row.saleDate,
                          row.voidedAt == null
                              ? ''
                              : reportDateTimeLabel(row.voidedAt!),
                          _m(row.total),
                          _methodLabel(row.paymentMethod, loc),
                          row.voidReason ?? '',
                          row.voidedByName ?? '',
                          reportDeviceLabel(row.deviceId, loc),
                          '${row.lineCount}',
                        ],
                    ],
                  ),
                ),
                if (page.pages > 1)
                  ReportPagination(
                    page: page.page,
                    pages: page.pages,
                    total: page.total,
                    loading: state.loading,
                    onPrev: () =>
                        ref.read(voidedProvider.notifier).setPage(
                              page.page - 1,
                            ),
                    onNext: () =>
                        ref.read(voidedProvider.notifier).setPage(
                              page.page + 1,
                            ),
                    loc: loc,
                  ),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// R9 — Sales detail
// ---------------------------------------------------------------------------

class SalesTab extends ConsumerStatefulWidget {
  const SalesTab({super.key});

  @override
  ConsumerState<SalesTab> createState() => _SalesTabState();
}

class _SalesTabState extends ConsumerState<SalesTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(salesProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(salesProvider);
    final controller = ref.read(salesProvider.notifier);
    final page = state.data;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 392px of fixed filters: scrolls instead of overflowing (41px
        // over at 600 wide, 141px in English at 500).
        HScrollView(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  key: ValueKey<String>('reports-status-${controller.status}'),
                  initialValue: controller.status,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('filter_status', loc),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    for (final status in kSalesStatuses)
                      DropdownMenuItem<String>(
                        value: status,
                        child: Text(
                          status == 'all'
                              ? AppStrings.t('all', loc)
                              : AppStrings.t(reportStatusKey(status), loc),
                          key: Key('reports-status-item-$status'),
                        ),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) controller.setStatus(value);
                  },
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                width: 190,
                child: DropdownButtonFormField<String>(
                  key: ValueKey<String>(
                    'reports-payment-${controller.paymentMethod ?? 'all'}',
                  ),
                  initialValue: controller.paymentMethod ?? '',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: AppStrings.t('filter_payment', loc),
                    isDense: true,
                    border: const OutlineInputBorder(),
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      value: '',
                      child: Text(
                        AppStrings.t('all', loc),
                        key: const Key('reports-payment-item-all'),
                      ),
                    ),
                    for (final method in kSalesPaymentMethods)
                      DropdownMenuItem<String>(
                        value: method,
                        child: Text(
                          AppStrings.t(reportPaymentMethodKey(method), loc),
                          key: Key('reports-payment-item-$method'),
                        ),
                      ),
                  ],
                  onChanged: (value) => controller.setPaymentMethod(value),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ReportStateView<SalesDetailPage>(
            state: state,
            isEmpty: page?.items.isEmpty ?? false,
            emptyKey: 'state_no_data',
            loc: loc,
            emptyTone: ReportMetricTone.sales,
            emptyIcon: Icons.point_of_sale_outlined,
            onRetry: () => ref.read(salesProvider.notifier).load(),
            child: page == null
                ? const SizedBox.shrink()
                : Column(
                    children: [
                      Expanded(
                        child: ReportTable(
                          key: const Key('sales-table'),
                          loc: loc,
                          columns: const [
                            ReportColumn('col_invoice'),
                            ReportColumn('col_date'),
                            ReportColumn('filter_status'),
                            ReportColumn('col_customer'),
                            ReportColumn('col_user'),
                            ReportColumn('col_method'),
                            ReportColumn('col_subtotal', numeric: true),
                            ReportColumn('kpi_discounts_total',
                                numeric: true),
                            ReportColumn('col_total', numeric: true),
                            ReportColumn('col_paid', numeric: true),
                            ReportColumn('col_change', numeric: true),
                            ReportColumn('col_device'),
                          ],
                          rows: [
                            for (final row in page.items)
                              [
                                row.invoiceNumber,
                                reportDateTimeLabel(row.saleDate),
                                _statusLabel(row.status, loc),
                                row.customerName ?? '',
                                row.userName ?? '',
                                _methodLabel(row.paymentMethod, loc),
                                _m(row.subtotal),
                                _m(row.discounts),
                                _m(row.total),
                                _m(row.paid),
                                _m(row.changeAmount),
                                reportDeviceLabel(row.deviceId, loc),
                              ],
                          ],
                          totalsRow: [
                            AppStrings.t('label_total', loc),
                            '',
                            '',
                            '',
                            '',
                            '',
                            _m(page.totals.subtotal),
                            _m(page.totals.discounts),
                            _m(page.totals.total),
                            _m(page.totals.paid),
                            _m(page.totals.changeAmount),
                            '',
                          ],
                        ),
                      ),
                      if (page.pages > 1)
                        ReportPagination(
                          page: page.page,
                          pages: page.pages,
                          total: page.total,
                          loading: state.loading,
                          onPrev: () =>
                              ref.read(salesProvider.notifier).setPage(
                                    page.page - 1,
                                  ),
                          onNext: () =>
                              ref.read(salesProvider.notifier).setPage(
                                    page.page + 1,
                                  ),
                          loc: loc,
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// R13 — Supplier payables
// ---------------------------------------------------------------------------

class SuppliersTab extends ConsumerStatefulWidget {
  const SuppliersTab({super.key});

  @override
  ConsumerState<SuppliersTab> createState() => _SuppliersTabState();
}

class _SuppliersTabState extends ConsumerState<SuppliersTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(suppliersReportProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(suppliersReportProvider);
    final report = state.data;

    return ReportStateView<SupplierReport>(
      state: state,
      isEmpty: false,
      emptyKey: 'state_no_data',
      loc: loc,
      emptyTone: ReportMetricTone.cost,
      emptyIcon: Icons.shopping_bag_outlined,
      onRetry: () => ref.read(suppliersReportProvider.notifier).load(),
      child: report == null
          ? const SizedBox.shrink()
          : ListView(
              key: const Key('suppliers-content'),
              padding: const EdgeInsets.only(top: 8, bottom: 24),
              children: [
                _sectionTitle(
                  theme,
                  loc,
                  'label_period',
                  icon: Icons.date_range_outlined,
                ),
                Text(
                  '${report.dateFrom} → ${report.dateTo}',
                  key: const Key('suppliers-range'),
                ),
                const SizedBox(height: 12),
                _tiles([
                  _tile('kpi_supplier_payable', _m(report.supplierPayable)),
                  _tile('kpi_purchases_total', _m(report.purchasesTotal)),
                  _tile('kpi_supplier_paid', _m(report.supplierPaid)),
                  _tile(
                    'kpi_suppliers_with_balance',
                    '${report.suppliersWithBalance}',
                  ),
                ]),
              ],
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Loyalty — period activity + balance snapshot + ledger (Loyalty Phase F)
// ---------------------------------------------------------------------------

class LoyaltyTab extends ConsumerStatefulWidget {
  const LoyaltyTab({super.key});

  @override
  ConsumerState<LoyaltyTab> createState() => _LoyaltyTabState();
}

class _LoyaltyTabState extends ConsumerState<LoyaltyTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      ref.read(loyaltyProvider.notifier).load();
    });
  }

  /// Localized ledger event label (`loyalty_event_<code>`) with a raw
  /// fallback — same contract as `_enumLabel`.
  String _eventLabel(String raw, String loc) =>
      _enumLabel('loyalty_event_$raw', raw, loc);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final state = ref.watch(loyaltyProvider);
    final r = state.data;

    return ReportStateView<LoyaltyReport>(
      state: state,
      isEmpty: false,
      emptyKey: 'state_no_data',
      loc: loc,
      onRetry: () => ref.read(loyaltyProvider.notifier).load(),
      child: r == null
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Summary scrolls; the ledger table below owns the rest of
                // the viewport (ReportTable needs bounded height).
                Expanded(
                  flex: 2,
                  child: ListView(
                    key: const Key('loyalty-content'),
                    padding: const EdgeInsets.only(top: 8),
                    children: [
                      _sectionTitle(
                        theme,
                        loc,
                        'label_period',
                        icon: Icons.date_range_outlined,
                      ),
                      Text(
                        '${r.dateFrom} → ${r.dateTo}',
                        key: const Key('loyalty-range'),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        AppStrings.t('loyalty_report_snapshot', loc),
                        key: const Key('loyalty-snapshot-note'),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),

                      // Sales context (§5.1 semantics — rewards reported
                      // beside, never inside sales totals).
                      _sectionTitle(theme, loc, 'sales',
                          tone: ReportMetricTone.sales),
                      _tiles([
                        _tile('kpi_gross_sales', _m(r.salesGross)),
                        _tile(
                            'kpi_sales_after_discounts', _m(r.salesAfterDiscounts)),
                        _tile('kpi_invoices', '${r.invoiceCount}'),
                      ]),
                      const SizedBox(height: 12),

                      // Period activity (ledger, window-bounded).
                      _sectionTitle(theme, loc, 'loyalty_report_activity',
                          tone: ReportMetricTone.profit),
                      _tiles([
                        _tile('loyalty_points_earned', _m(r.pointsEarned)),
                        _tile('loyalty_cashback_earned', _m(r.cashbackEarned)),
                        _tile(
                            'loyalty_settlement_points', _m(r.settlementPoints)),
                        _tile('loyalty_points_redeemed', _m(r.pointsRedeemed)),
                        _tile(
                            'loyalty_redemption_value', _m(r.redemptionValue)),
                        _tile('loyalty_points_reversed', _m(r.pointsReversed)),
                        _tile('loyalty_cashback_reversed',
                            _m(r.cashbackReversed)),
                        _tile(
                            'loyalty_points_restored', _m(r.pointsRestored)),
                        _tile('loyalty_restored_value', _m(r.restoredValue)),
                        _tile('loyalty_shortfall_points', _m(r.shortfallPoints)),
                        _tile(
                            'loyalty_shortfall_cashback', _m(r.shortfallCashback)),
                        _tile(
                            'loyalty_adjustment_points', _m(r.adjustmentPoints)),
                        _tile('loyalty_adjustment_cashback',
                            _m(r.adjustmentCashback)),
                      ]),
                      const SizedBox(height: 12),

                      // Current balances (snapshot — not a window total).
                      _sectionTitle(theme, loc, 'loyalty_report_balances',
                          tone: ReportMetricTone.debt),
                      _tiles([
                        _tile(
                            'loyalty_outstanding_points', _m(r.outstandingPoints)),
                        _tile('loyalty_outstanding_cashback',
                            _m(r.outstandingCashback)),
                        _tile(
                          'loyalty_accounts_with_balance',
                          '${r.accountsWithBalance}',
                        ),
                      ]),
                      const SizedBox(height: 12),

                      // Events breakdown (raw ledger event types in the
                      // window — includes restorations posted as
                      // adjustments; the headline adjustment tiles above
                      // count admin adjustments only).
                      if (r.events.isNotEmpty) ...[
                        ReportTable(
                          key: const Key('loyalty-events-table'),
                          loc: loc,
                          columns: const [
                            ReportColumn('col_event'),
                            ReportColumn('col_count', numeric: true),
                            ReportColumn('col_points', numeric: true),
                            ReportColumn('col_cashback', numeric: true),
                          ],
                          rows: [
                            for (final e in r.events)
                              [
                                _eventLabel(e.eventType, loc),
                                '${e.entries}',
                                _m(e.pointsDelta),
                                _m(e.cashbackDelta),
                              ],
                          ],
                        ),
                        const SizedBox(height: 12),
                      ],
                    ],
                  ),
                ),

                // Ledger history (paginated detail).
                _sectionTitle(
                  theme,
                  loc,
                  'loyalty_report_ledger',
                  icon: Icons.history_outlined,
                ),
                Expanded(
                  flex: 3,
                  child: Column(
                    children: [
                      Expanded(
                        child: ReportTable(
                          key: const Key('loyalty-ledger-table'),
                          loc: loc,
                          columns: const [
                            ReportColumn('col_date'),
                            ReportColumn('col_customer'),
                            ReportColumn('col_invoice'),
                            ReportColumn('col_event'),
                            ReportColumn('col_points', numeric: true),
                            ReportColumn('col_cashback', numeric: true),
                            ReportColumn('col_points_balance', numeric: true),
                            ReportColumn('col_cashback_balance', numeric: true),
                            ReportColumn('note'),
                          ],
                          rows: [
                            for (final row in r.items)
                              [
                                reportDateTimeLabel(row.createdAt),
                                row.customerName ?? '',
                                row.invoiceNumber ?? '',
                                _eventLabel(row.eventType, loc),
                                _m(row.pointsDelta),
                                _m(row.cashbackDelta),
                                _m(row.balanceAfterPoints),
                                _m(row.balanceAfterCashback),
                                row.note ?? '',
                              ],
                          ],
                        ),
                      ),
                      if (r.pages > 1)
                        ReportPagination(
                          page: r.page,
                          pages: r.pages,
                          total: r.total,
                          loading: state.loading,
                          onPrev: () =>
                              ref.read(loyaltyProvider.notifier).setPage(
                                    r.page - 1,
                                  ),
                          onNext: () =>
                              ref.read(loyaltyProvider.notifier).setPage(
                                    r.page + 1,
                                  ),
                          loc: loc,
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}
