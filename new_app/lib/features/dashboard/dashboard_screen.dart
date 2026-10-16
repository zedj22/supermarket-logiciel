// Dashboard screen (Phase 14) — §7 KPI cards, recent sales, top products.
//
// RBAC: `report_financial` (§10 — the rail entry AND this content are
// gated; a cashier landing on `/` sees the localized permission message,
// never money). The shell provides the Scaffold/AppBar.
//
// Charts are plain widgets per G24; bars only scale already-computed
// server values for display height (no money math, §7/§8).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/numeric_text.dart';
import '../../core/strings.dart';
import '../../core/widgets/page_title.dart';
import '../../core/widgets/section_header.dart';
import '../../l10n/locale_provider.dart';
import '../auth/permission_helpers.dart';
import '../clients/customer_models.dart';
import '../reports/report_widgets.dart';
import '../reports/reports_providers.dart';
import 'dashboard_models.dart';
import 'dashboard_providers.dart';

class DashboardScreen extends ConsumerStatefulWidget {
  const DashboardScreen({super.key});

  @override
  ConsumerState<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends ConsumerState<DashboardScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      if (!mounted) return;
      final canView = ref.read(hasPermissionProvider('report_financial'));
      if (canView) ref.read(dashboardProvider.notifier).load();
    });
  }

  Future<void> _pickDate({required bool from}) async {
    final notifier = ref.read(reportFilterProvider.notifier);
    final current = ref.read(reportFilterProvider);
    final picked = await showDatePicker(
      context: context,
      initialDate: from ? current.dateFrom : current.dateTo,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    if (from) {
      notifier.setDateFrom(picked);
    } else {
      notifier.setDateTo(picked);
    }
  }

  String _methodLabel(String method, String loc) {
    if (method.isEmpty) return '';
    final key = 'label_$method';
    final value = AppStrings.t(key, loc);
    return value == key ? method : value;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('report_financial'));

    if (!canView) {
      return Center(
        key: const Key('dashboard-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final state = ref.watch(dashboardProvider);
    final data = state.data;

    return Padding(
      key: const Key('dashboard-screen'),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // One rung for the H1 across the app; actions fall under the
          // title on a narrow window instead of overflowing.
          PageTitle(
            title: AppStrings.t('dashboard', loc),
            titleKey: const Key('dashboard-title'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  key: const Key('dashboard-reports-link'),
                  onPressed: () => context.go('/reports'),
                  icon: const Icon(Icons.summarize_outlined, size: 18),
                  label: Text(AppStrings.t('reports', loc)),
                ),
                const SizedBox(width: 8),
                IconButton(
                  key: const Key('dashboard-refresh'),
                  tooltip: AppStrings.t('refresh', loc),
                  onPressed: () =>
                      ref.read(dashboardProvider.notifier).refresh(),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${AppStrings.t('label_as_of', loc)}: '
            '${reportDateParam(ref.watch(reportFilterProvider).dateFrom)}'
            ' → ${reportDateParam(ref.watch(reportFilterProvider).dateTo)}',
            key: const Key('dashboard-range'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          _buildPeriodBar(loc),
          const SizedBox(height: 12),
          Expanded(child: _buildBody(theme, loc, state, data)),
        ],
      ),
    );
  }

  Widget _buildPeriodBar(String loc) {
    final filter = ref.watch(reportFilterProvider);
    final notifier = ref.read(reportFilterProvider.notifier);
    final presetDropdown = SizedBox(
      width: 170,
      child: DropdownButtonFormField<String>(
        key: ValueKey<String>('dashboard-preset-${filter.preset}'),
        initialValue: filter.preset,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: AppStrings.t('label_period', loc),
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: [
          for (final preset in kReportPresets)
            DropdownMenuItem(
              value: preset,
              child: Text(
                AppStrings.t(reportPresetKey(preset), loc),
                key: Key('dashboard-preset-item-$preset'),
              ),
            ),
        ],
        onChanged: (value) {
          if (value != null) notifier.setPreset(value);
        },
      ),
    );
    final dateFrom = OutlinedButton(
      key: const Key('dashboard-date-from'),
      onPressed: () => _pickDate(from: true),
      child: Text(reportDateParam(filter.dateFrom)),
    );
    final dateTo = OutlinedButton(
      key: const Key('dashboard-date-to'),
      onPressed: () => _pickDate(from: false),
      child: Text(reportDateParam(filter.dateTo)),
    );

    // Wide windows keep the original single row; tighter windows wrap
    // the period controls instead of overflowing ("RenderFlex overflowed
    // by 29 pixels" at an 800px window).
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 740) {
          return Row(
            children: [
              presetDropdown,
              const SizedBox(width: 8),
              dateFrom,
              const SizedBox(width: 6),
              dateTo,
            ],
          );
        }
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [presetDropdown, dateFrom, dateTo],
        );
      },
    );
  }

  Widget _buildBody(
    ThemeData theme,
    String loc,
    DashboardState state,
    DashboardReport? data,
  ) {
    if (data == null && state.error == null) {
      return Center(
        key: const Key('dashboard-loading'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(key: Key('dashboard-spinner')),
            const SizedBox(height: 12),
            Text(AppStrings.t('state_loading', loc)),
          ],
        ),
      );
    }
    if (data == null) {
      return Center(
        key: const Key('dashboard-error'),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(state.error!, key: const Key('dashboard-error-message')),
            const SizedBox(height: 8),
            TextButton(
              key: const Key('dashboard-retry'),
              onPressed: () => ref.read(dashboardProvider.notifier).load(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }

    final errorBanner = state.error == null
        ? null
        : Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              state.error!,
              key: const Key('dashboard-error-message'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          );

    return ListView(
      key: const Key('dashboard-content'),
      children: [
        ?errorBanner,
        // KPIs read as three business blocks (today / stock / customers)
        // instead of one wall of ten equal tiles — the values and their
        // `kpi-*` keys are exactly the server snapshot as before.
        _kpiGroup(loc, 'kpi_group_today', [
          _kpi('kpi_today_sales', formatMoney(data.todaySales)),
          _kpi('kpi_invoices', '${data.todayInvoices}'),
          _kpi('kpi_today_profit', formatMoney(data.todayNetProfit)),
          _kpi('kpi_today_expenses', formatMoney(data.todayExpenses)),
        ]),
        _kpiGroup(loc, 'kpi_group_inventory', [
          _kpi('kpi_total_products', '${data.totalProducts}'),
          _kpi('kpi_stock_value', formatMoney(data.stockValue)),
          _kpi('kpi_low_stock', '${data.lowStockCount}'),
        ]),
        _kpiGroup(loc, 'kpi_group_customers', [
          _kpi('kpi_total_customers', '${data.totalCustomers}'),
          _kpi('kpi_customers_with_debt', '${data.customersWithDebt}'),
          _kpi('kpi_total_debt', formatMoney(data.totalDebt)),
        ]),
        KeyedSubtree(
          key: const Key('dashboard-recent-title'),
          child: SectionHeader(
            title: AppStrings.t('kpi_recent_sales', loc),
            titleKey: 'kpi_recent_sales',
          ),
        ),
        if (data.recentSales.isEmpty)
          Text(
            AppStrings.t('state_no_data', loc),
            key: const Key('dashboard-recent-empty'),
          )
        else
          Card(
            key: const Key('dashboard-recent'),
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < data.recentSales.length; i++)
                  _recentTile(theme, loc, data.recentSales[i], i),
              ],
            ),
          ),
        KeyedSubtree(
          key: const Key('dashboard-top-title'),
          child: SectionHeader(
            title: AppStrings.t('kpi_top_products', loc),
            titleKey: 'kpi_top_products',
          ),
        ),
        if (data.topProducts.isEmpty)
          Text(
            AppStrings.t('state_no_data', loc),
            key: const Key('dashboard-top-empty'),
          )
        else ...[
          SizedBox(
            height: 200,
            child: ReportBarChart(
              bars: [
                for (final p in data.topProducts)
                  ReportBar(
                    label: p.name,
                    value: double.tryParse(p.netRevenue) ?? 0.0,
                    caption: formatMoney(p.netRevenue),
                  ),
              ],
              barKeyPrefix: 'top-bar',
            ),
          ),
          Card(
            key: const Key('dashboard-top'),
            margin: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < data.topProducts.length; i++)
                  _topTile(theme, loc, data.topProducts[i], i),
              ],
            ),
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _kpi(String labelKey, String value) => ReportKpiTile(
        labelKey: labelKey,
        value: value,
        testKey: 'kpi-$labelKey',
      );

  /// A kicker + one row of KPI tiles. Same tiles, same keys — only the
  /// grouping (and therefore the reading order) is new.
  Widget _kpiGroup(String loc, String groupKey, List<Widget> tiles) =>
      Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              title: AppStrings.t(groupKey, loc),
              titleKey: groupKey,
              dense: true,
            ),
            Wrap(spacing: 10, runSpacing: 10, children: tiles),
          ],
        ),
      );

  Widget _recentTile(
    ThemeData theme,
    String loc,
    DashboardRecentSale sale,
    int index,
  ) {
    final meta = <String>[
      reportDateTimeLabel(sale.saleDate),
      _methodLabel(sale.paymentMethod, loc),
      if (sale.customerName != null && sale.customerName!.isNotEmpty)
        sale.customerName!,
    ];
    return ListTile(
      key: Key('dashboard-recent-$index'),
      title: Text(sale.invoiceNumber),
      subtitle: numericText(meta.join(' · '), key: Key('dashboard-recent-meta-$index')),
      trailing: numericText(
        formatMoney(sale.total),
        key: Key('dashboard-recent-total-$index'),
        style: theme.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _topTile(
    ThemeData theme,
    String loc,
    DashboardTopProduct product,
    int index,
  ) {
    return ListTile(
      key: Key('dashboard-top-$index'),
      title: Text(product.name, key: Key('dashboard-top-name-$index')),
      // Bidi: the Arabic KPI labels stay natural; each grouped value is
      // its own LTR isolate (a forced-LTR paragraph still reverses digits
      // after an Arabic label — W7).
      subtitle: Text(
        '${AppStrings.t('kpi_items_sold', loc)}: '
        '${bidiIsolateLtr(formatMoney(product.qtySold))}'
        ' · ${AppStrings.t('kpi_net_sales', loc)}: '
        '${bidiIsolateLtr(formatMoney(product.netRevenue))}',
        key: Key('dashboard-top-meta-$index'),
      ),
      trailing: numericText(
        formatMoney(product.grossProfit),
        key: Key('dashboard-top-profit-$index'),
        style: theme.textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    );
  }
}
