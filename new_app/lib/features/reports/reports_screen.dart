// Reports screen (Phase 14) — tabs R1–R9 + R13, with R15 shown inside the
// financial tab (§8).
//
// RBAC: `report_financial` to view (§10 — same scope as the backend), and
// the CSV export button only renders with `export_data`. The shell
// provides the Scaffold/AppBar — this is content only.
//
// The date range + preset + device filter is shared by every ranged tab
// (§8 common parameters); peak-hours and slow-moving carry their own
// window parameters instead (§11).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../pos/pos_providers.dart';
import 'report_csv.dart';
import 'report_export.dart';
import 'report_export_dialog.dart';
import 'report_tabs.dart';
import 'reports_providers.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// Tab id → localized label key (§14 report names).
  static const List<(String, String)> _tabs = <(String, String)>[
    ('financial', 'report_financial'),
    ('products', 'report_products'),
    ('categories', 'report_categories'),
    ('daily', 'report_daily'),
    ('hourly', 'report_hourly'),
    ('peak', 'report_peak_hours'),
    ('slow', 'report_slow_moving'),
    ('voided', 'report_voided'),
    ('sales', 'report_sales'),
    ('suppliers', 'report_suppliers'),
  ];

  /// Report slug per tab index (§14 names, `peak-hours` / `slow-moving`).
  static const List<String> _reportSlugs = <String>[
    'financial',
    'products',
    'categories',
    'daily',
    'hourly',
    'peak-hours',
    'slow-moving',
    'voided',
    'sales',
    'suppliers',
  ];

  bool _exporting = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
    // The export button gates on the CURRENT tab (§12.1) — build reads
    // the index once, so it must be told when the tab actually changes.
    var lastIndex = _tabController.index;
    _tabController.addListener(() {
      if (mounted && _tabController.index != lastIndex) {
        lastIndex = _tabController.index;
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
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

  /// Phase 15 unified export: format dialog first (CSV / XLSX / PDF),
  /// then the matching flow. Cancel is neutral — no toast (§16.2).
  /// Gated by `export_data` (§10).
  Future<void> _export() async {
    if (_exporting || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final format = await showReportExportDialog(context, loc);
    if (format == null || !mounted) return; // user cancelled
    setState(() => _exporting = true);
    try {
      if (format == 'csv') {
        await _exportCsv(loc);
      } else {
        await _exportFile(loc, format);
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// §12.2 CSV (frozen Phase 14 path): build the CSV from the loaded
  /// payload (or a fresh page walk of the same endpoint for row-level
  /// reports), then the save dialog.
  Future<void> _exportCsv(String loc) async {
    final filter = ref.read(reportFilterProvider);
    final dio = ref.read(apiClientProvider).dio;
    final idx = _tabController.index;
    switch (idx) {
      case 0:
        final data = ref.read(financialProvider).data;
        if (data == null) return;
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'financial',
          dateFrom: data.dateFrom,
          dateTo: data.dateTo,
          build: () async => financialCsv(data, loc),
        );
      case 1:
        final sort = ref.read(productsProvider.notifier).sort;
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'products',
          dateFrom: reportDateParam(filter.dateFrom),
          dateTo: reportDateParam(filter.dateTo),
          build: () async =>
              productsCsv(await fetchAllProducts(dio, filter, sort: sort), loc),
        );
      case 2:
        final data = ref.read(categoriesProvider).data;
        if (data == null) return;
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'categories',
          dateFrom: data.dateFrom,
          dateTo: data.dateTo,
          build: () async => categoriesCsv(data, loc),
        );
      case 3:
        final data = ref.read(dailyProvider).data;
        if (data == null) return;
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'daily',
          dateFrom: data.dateFrom,
          dateTo: data.dateTo,
          build: () async => dailyCsv(data, loc),
        );
      case 4:
        final data = ref.read(hourlyProvider).data;
        if (data == null) return;
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'hourly',
          dateFrom: data.dateFrom,
          dateTo: data.dateTo,
          build: () async => hourlyCsv(data, loc),
        );
      case 5:
        final data = ref.read(peakProvider).data;
        if (data == null) return;
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'peak-hours',
          dateFrom: data.dateFrom,
          dateTo: data.dateTo,
          build: () async => peakCsv(data, loc),
        );
      case 6:
        final c = ref.read(slowMovingProvider.notifier);
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);
        final windowFrom = today.subtract(
          Duration(days: c.days <= 1 ? 0 : c.days - 1),
        );
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'slow-moving',
          dateFrom: reportDateParam(windowFrom),
          dateTo: reportDateParam(today),
          build: () async => slowMovingCsv(
            await fetchAllSlowMoving(dio, days: c.days, threshold: c.threshold),
            loc,
          ),
        );
      case 7:
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'voided',
          dateFrom: reportDateParam(filter.dateFrom),
          dateTo: reportDateParam(filter.dateTo),
          build: () async => voidedCsv(await fetchAllVoided(dio, filter), loc),
        );
      case 8:
        final c = ref.read(salesProvider.notifier);
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'sales',
          dateFrom: reportDateParam(filter.dateFrom),
          dateTo: reportDateParam(filter.dateTo),
          build: () async => salesCsv(
            await fetchAllSales(
              dio,
              filter,
              status: c.status,
              paymentMethod: c.paymentMethod,
            ),
            loc,
          ),
        );
      case 9:
        final data = ref.read(suppliersReportProvider).data;
        if (data == null) return;
        await exportReportCsv(
          context: context,
          loc: loc,
          reportSlug: 'suppliers',
          dateFrom: data.dateFrom,
          dateTo: data.dateTo,
          build: () async => suppliersCsv(data, loc),
        );
    }
  }

  /// Phase 15 backend export (§12.1): the server renders the SAME payload
  /// the screen shows to XLSX/PDF bytes — one request, no page walk.
  Future<void> _exportFile(String loc, String format) async {
    final dio = ref.read(apiClientProvider).dio;
    final reportSlug = _reportSlugs[_tabController.index];
    final body = _exportBody(_tabController.index);
    String? deviceId;
    try {
      deviceId = await ref.read(posDeviceIdProvider.future);
    } catch (_) {
      deviceId = null; // header is optional — export still proceeds
    }
    if (!mounted) return;
    await exportReportFile(
      context: context,
      dio: dio,
      loc: loc,
      reportSlug: reportSlug,
      format: format,
      body: body,
      deviceId: deviceId,
    );
  }

  /// `ExportRequest` fields for tab [idx] — mirrors exactly the query
  /// params the tab's GET sends (D12: export = what you see). `report`,
  /// `format` and `locale` are added by [exportReportFile].
  Map<String, dynamic> _exportBody(int idx) {
    final filter = ref.read(reportFilterProvider);
    switch (idx) {
      case 1:
        return {
          ...filter.rangeParams(),
          'sort': ref.read(productsProvider.notifier).sort,
        };
      case 5:
        // Peak-hours uses its lookback window, not the shared range (§11).
        return <String, dynamic>{
          'lookback_days': ref.read(peakProvider.notifier).lookbackDays,
          if (filter.deviceId?.isNotEmpty == true) 'device_id': filter.deviceId,
        };
      case 6:
        final c = ref.read(slowMovingProvider.notifier);
        return <String, dynamic>{'days': c.days, 'threshold': c.threshold};
      case 8:
        final c = ref.read(salesProvider.notifier);
        return <String, dynamic>{
          ...filter.rangeParams(),
          'status': c.status,
          if (c.paymentMethod != null && c.paymentMethod!.isNotEmpty)
            'payment_method': c.paymentMethod,
        };
      default:
        return filter.rangeParams();
    }
  }

  bool _exportReady() {
    switch (_tabController.index) {
      case 0:
        return ref.read(financialProvider).data != null;
      case 2:
        return ref.read(categoriesProvider).data != null;
      case 3:
        return ref.read(dailyProvider).data != null;
      case 4:
        return ref.read(hourlyProvider).data != null;
      case 5:
        return ref.read(peakProvider).data != null;
      case 9:
        return ref.read(suppliersReportProvider).data != null;
      default:
        // Row-level reports page fresh during export (§12.2).
        return true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('report_financial'));
    final canExport = ref.watch(hasPermissionProvider('export_data'));
    // Export readiness (§12.1): _exportReady() only READS the tab data, so
    // the build must depend on it — otherwise the button stays stale
    // (enabled/disabled from the moment the screen first builds).
    ref.watch(financialProvider.select((s) => s.data != null));
    ref.watch(categoriesProvider.select((s) => s.data != null));
    ref.watch(dailyProvider.select((s) => s.data != null));
    ref.watch(hourlyProvider.select((s) => s.data != null));
    ref.watch(peakProvider.select((s) => s.data != null));
    ref.watch(suppliersReportProvider.select((s) => s.data != null));

    if (!canView) {
      return Center(
        key: const Key('reports-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    return Padding(
      key: const Key('reports-screen'),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                AppStrings.t('reports', loc),
                key: const Key('reports-title'),
                style: theme.textTheme.headlineSmall,
              ),
              const Spacer(),
              if (canExport) ...[
                OutlinedButton.icon(
                  key: const Key('reports-export'),
                  onPressed: (_exporting || !_exportReady()) ? null : _export,
                  icon: _exporting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download_outlined, size: 18),
                  label: Text(AppStrings.t('export_title', loc)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 8),
          _buildFilterCard(theme, loc),
          const SizedBox(height: 4),
          TabBar(
            key: const Key('reports-tabbar'),
            controller: _tabController,
            isScrollable: true,
            tabs: [
              for (final (id, labelKey) in _tabs)
                Tab(
                  key: Key('reports-tab-$id'),
                  text: AppStrings.t(labelKey, loc),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                FinancialTab(),
                ProductsTab(),
                CategoriesTab(),
                DailyTab(),
                HourlyTab(),
                PeakTab(),
                SlowMovingTab(),
                VoidedTab(),
                SalesTab(),
                SuppliersTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Shared period/device filters as one responsive card: the controls
  /// wrap onto extra rows on narrow windows instead of overflowing, and
  /// the date texts force LTR so `yyyy-MM-dd` never mirrors under RTL.
  ///
  /// Visual hierarchy (Fix Round 2): the preset is the *active* filter,
  /// so it carries a primary-tinted surface + accent border; the date
  /// pickers and device field stay neutral; the clear action is a subtle
  /// error tint.
  Widget _buildFilterCard(ThemeData theme, String loc) {
    final filter = ref.watch(reportFilterProvider);
    final notifier = ref.read(reportFilterProvider.notifier);
    final hasFilters = filter.preset != 'today' || filter.deviceId != null;

    return Card(
      key: const Key('reports-filter-card'),
      margin: EdgeInsets.zero,
      elevation: 0,
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(
              width: 170,
              child: DropdownButtonFormField<String>(
                // ValueKey: the field is rebuilt when the preset changes so an
                // external reset (clear filters) updates the displayed item
                // (`initialValue` alone only seeds the first build).
                key: ValueKey<String>('reports-preset-${filter.preset}'),
                initialValue: filter.preset,
                isExpanded: true,
                decoration: InputDecoration(
                  labelText: AppStrings.t('label_period', loc),
                  isDense: true,
                  filled: true,
                  fillColor: Color.alphaBlend(
                    theme.colorScheme.primary.withValues(alpha: 0.08),
                    theme.colorScheme.surfaceContainerLow,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary.withValues(alpha: 0.7),
                      width: 1.2,
                    ),
                  ),
                  border: const OutlineInputBorder(),
                ),
                items: [
                  for (final preset in kReportPresets)
                    DropdownMenuItem(
                      value: preset,
                      child: Text(
                        AppStrings.t(reportPresetKey(preset), loc),
                        key: Key('reports-preset-item-$preset'),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) notifier.setPreset(value);
                },
              ),
            ),
            OutlinedButton(
              key: const Key('reports-date-from'),
              onPressed: () => _pickDate(from: true),
              child: Text(
                reportDateParam(filter.dateFrom),
                textDirection: TextDirection.ltr,
              ),
            ),
            OutlinedButton(
              key: const Key('reports-date-to'),
              onPressed: () => _pickDate(from: false),
              child: Text(
                reportDateParam(filter.dateTo),
                textDirection: TextDirection.ltr,
              ),
            ),
            SizedBox(
              width: 170,
              child: TextFormField(
                key: ValueKey<String>(
                  'reports-device-${filter.deviceId ?? ''}',
                ),
                initialValue: filter.deviceId ?? '',
                decoration: InputDecoration(
                  labelText: AppStrings.t('filter_device', loc),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onFieldSubmitted: (value) => notifier.setDevice(value),
              ),
            ),
            if (hasFilters)
              IconButton(
                key: const Key('reports-clear'),
                tooltip: AppStrings.t('clear', loc),
                onPressed: notifier.reset,
                color: theme.colorScheme.error,
                icon: const Icon(Icons.filter_alt_off_outlined, size: 20),
              ),
          ],
        ),
      ),
    );
  }
}
