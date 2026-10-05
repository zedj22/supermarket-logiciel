// Purchases screen (Phase 11): purchase history with status / supplier
// / search filters. Tapping a row opens the detail dialog (historical
// lines, status badge, receive/cancel/draft-delete actions per
// permission).
//
// RBAC: viewing requires purchase_view (whole screen); the New button
// is hidden without purchase_create; lifecycle actions are gated
// inside the detail dialog (purchase_create for receive/edit,
// purchase_delete for cancel/delete). The server enforces every route
// regardless of this UI gating.
//
// Responsive: PurchasesLayoutMode {wide ≥1200, medium ≥800, narrow}
// (stock/products convention) — narrow renders compact tiles, medium
// and wide render table-like rows with progressively more columns.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../core/widgets/table_header.dart';
import '../../l10n/locale_provider.dart';
import '../../theme/app_theme.dart';
import '../auth/permission_helpers.dart';
import 'purchase_detail_dialog.dart';
import 'purchase_form_dialog.dart';
import 'purchase_models.dart';
import 'purchase_pickers.dart';
import 'purchases_providers.dart';

enum PurchasesLayoutMode { wide, medium, narrow }

PurchasesLayoutMode purchasesLayoutModeFor(double width) {
  if (width >= 1200) return PurchasesLayoutMode.wide;
  if (width >= 800) return PurchasesLayoutMode.medium;
  return PurchasesLayoutMode.narrow;
}

String _timestampOf(DateTime? value) {
  if (value == null) return '';
  final m = value.month.toString().padLeft(2, '0');
  final d = value.day.toString().padLeft(2, '0');
  final h = value.hour.toString().padLeft(2, '0');
  final min = value.minute.toString().padLeft(2, '0');
  final s = value.second.toString().padLeft(2, '0');
  return '${value.year}-$m-$d $h:$min:$s';
}

class PurchasesScreen extends ConsumerStatefulWidget {
  const PurchasesScreen({super.key});

  @override
  ConsumerState<PurchasesScreen> createState() => _PurchasesScreenState();
}

class _PurchasesScreenState extends ConsumerState<PurchasesScreen> {
  String? _filterSupplierName;

  @override
  void initState() {
    super.initState();
    // Refresh on every visit (provider state itself is kept alive).
    Future.microtask(() {
      if (!mounted) return;
      ref.read(purchasesProvider.notifier).load();
    });
  }

  Future<void> _add() async {
    await showPurchaseFormDialog(context);
    // The notifier refreshes on success; a dismissed dialog changes
    // nothing — but re-sync anyway in case a lifecycle action ran.
    if (!mounted) return;
    ref.read(purchasesProvider.notifier).refresh();
  }

  Future<void> _pickSupplierFilter() async {
    final supplier = await showPurchaseSupplierPicker(context);
    if (supplier == null || !mounted) return;
    setState(() => _filterSupplierName = supplier.name);
    ref.read(purchasesProvider.notifier).setSupplierFilter(supplier.id);
  }

  void _clearSupplierFilter() {
    setState(() => _filterSupplierName = null);
    ref.read(purchasesProvider.notifier).setSupplierFilter(null);
  }

  Future<void> _openDetail(String purchaseId) async {
    await showPurchaseDetailDialog(context, purchaseId: purchaseId);
    if (!mounted) return;
    ref.read(purchasesProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final canView = ref.watch(hasPermissionProvider('purchase_view'));
    final canCreate = ref.watch(hasPermissionProvider('purchase_create'));

    if (!canView) {
      return Center(
        key: const Key('purchases-denied'),
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final state = ref.watch(purchasesProvider);
    final query = state.query;
    final mode = purchasesLayoutModeFor(MediaQuery.sizeOf(context).width);

    return Padding(
      key: const Key('purchases-screen'),
      padding:
          EdgeInsets.all(mode == PurchasesLayoutMode.narrow ? 12 : 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                AppStrings.t('purchases', loc),
                key: const Key('purchases-title'),
                style: theme.textTheme.headlineSmall,
              ),
              SizedBox(
                width: 240,
                child: TextField(
                  key: const Key('purchases-search'),
                  decoration: InputDecoration(
                    hintText: AppStrings.t('search', loc),
                    isDense: true,
                    prefixIcon: const Icon(Icons.search, size: 18),
                    border: const OutlineInputBorder(),
                  ),
                  inputFormatters: [LengthLimitingTextInputFormatter(200)],
                  onChanged: (value) =>
                      ref.read(purchasesProvider.notifier).setSearch(value),
                ),
              ),
              // QA fix round: intrinsic width — a fixed 180px width let
              // the dense outlined control's internal Row overflow by
              // 21px in English ("Status" + value + suffix icon). The
              // header is a Wrap, so locale-driven width is safe.
              DropdownButtonFormField<String>(
                key: const Key('purchases-status-filter'),
                initialValue: query.status,
                decoration: InputDecoration(
                  labelText: AppStrings.t('status', loc),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Text(AppStrings.t('all', loc)),
                  ),
                  for (final status in const [
                    PurchaseStatusValue.draft,
                    PurchaseStatusValue.received,
                    PurchaseStatusValue.cancelled,
                  ])
                    DropdownMenuItem<String>(
                      value: status,
                      child: Text(
                        AppStrings.t('purchase_status_$status', loc),
                      ),
                    ),
                ],
                onChanged: (value) => ref
                    .read(purchasesProvider.notifier)
                    .setStatus(value ?? ''),
              ),
              if (_filterSupplierName == null)
                OutlinedButton.icon(
                  key: const Key('purchases-supplier-filter'),
                  onPressed: _pickSupplierFilter,
                  icon: const Icon(Icons.factory_outlined, size: 18),
                  label: Text(AppStrings.t('supplier', loc)),
                )
              else
                Chip(
                  key: const Key('purchases-supplier-filter-active'),
                  avatar: const Icon(Icons.factory_outlined, size: 16),
                  label: Text(_filterSupplierName!),
                  deleteIcon: const Icon(Icons.close, size: 16),
                  onDeleted: _clearSupplierFilter,
                ),
              if (canCreate)
                ElevatedButton.icon(
                  key: const Key('purchases-add-button'),
                  onPressed: _add,
                  icon: const Icon(Icons.add),
                  label: Text(AppStrings.t('add_purchase', loc)),
                ),
            ],
          ),
          if (state.error != null) ...[
            const SizedBox(height: 12),
            Material(
              key: const Key('purchases-error'),
              color: theme.colorScheme.errorContainer,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        state.error!,
                        style: TextStyle(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      key: const Key('purchases-retry'),
                      onPressed: () =>
                          ref.read(purchasesProvider.notifier).refresh(),
                      child: Text(AppStrings.t('retry', loc)),
                    ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            '${AppStrings.t('total', loc)}: ${state.total}',
            key: const Key('purchases-total'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Expanded(child: _buildBody(theme, loc, state, mode)),
          if (state.pages > 1) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('purchases-prev'),
                  onPressed: query.page > 1 && !state.loading
                      ? () =>
                          ref.read(purchasesProvider.notifier).setPage(
                                query.page - 1,
                              )
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Text(
                  '${query.page} / ${state.pages}',
                  key: const Key('purchases-page'),
                ),
                IconButton(
                  key: const Key('purchases-next'),
                  onPressed: query.page < state.pages && !state.loading
                      ? () =>
                          ref.read(purchasesProvider.notifier).setPage(
                                query.page + 1,
                              )
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBody(
    ThemeData theme,
    String loc,
    PurchasesState state,
    PurchasesLayoutMode mode,
  ) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        key: Key('purchases-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        key: const Key('purchases-empty'),
        child: Text(AppStrings.t('no_purchases', loc)),
      );
    }
    if (mode == PurchasesLayoutMode.narrow) {
      return ListView.builder(
        key: const Key('purchases-list'),
        itemCount: state.items.length,
        itemBuilder: (context, index) => _tile(state.items[index], index, loc),
      );
    }
    final wide = mode == PurchasesLayoutMode.wide;
    return Column(
      children: [
        _headerRow(theme, loc, wide: wide),
        const SizedBox(height: 4),
        Expanded(
          child: ListView.builder(
            key: const Key('purchases-list'),
            itemCount: state.items.length,
            itemBuilder: (context, index) =>
                _row(theme, state.items[index], index, loc, wide: wide),
          ),
        ),
      ],
    );
  }

  Color _statusColor(BuildContext context, String status) {
    final scheme = Theme.of(context).colorScheme;
    switch (status) {
      case PurchaseStatusValue.received:
        return scheme.primary;
      case PurchaseStatusValue.cancelled:
        return scheme.error;
      default:
        return scheme.tertiary;
    }
  }

  Widget _statusBadge(BuildContext context, String status, String loc) {
    final color = _statusColor(context, status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        AppStrings.t('purchase_status_$status', loc),
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _tile(PurchaseModel purchase, int index, String loc) {
    final theme = Theme.of(context);
    return ListTile(
      key: Key('purchase-tile-$index'),
      onTap: () => _openDetail(purchase.id),
      title: Text(
        purchase.invoiceNumber,
        key: Key('purchase-invoice-$index'),
      ),
      subtitle: Text(
        [
          purchase.supplierName ?? '',
          AppStrings.t('purchase_status_${purchase.status}', loc),
          if (purchase.purchaseDate != null)
            _timestampOf(purchase.purchaseDate),
        ].where((part) => part.isNotEmpty).join(' · '),
        key: Key('purchase-meta-$index'),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            formatMoney(purchase.total),
            key: Key('purchase-total-$index'),
            style: theme.textTheme.titleMedium,
          ),
          if (purchase.unpaidMilli > 0)
            Text(
              '${AppStrings.t('remaining', loc)}: '
              '${formatMoney(purchase.unpaid)}',
              key: Key('purchase-remaining-$index'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerRow(ThemeData theme, String loc, {required bool wide}) {
    final style = AppTheme.tableHeader(theme);
    return TableHeaderRow(
      testKey: const Key('purchases-table-header'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      children: [
        Expanded(
          flex: 3,
          child: Text(
            AppStrings.t('invoice_number', loc),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Expanded(
          flex: 3,
          child: Text(
            AppStrings.t('supplier', loc),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            AppStrings.t('status', loc),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            AppStrings.t('total', loc),
            style: style,
            textAlign: TextAlign.end,
          ),
        ),
        Expanded(
          flex: 2,
          child: Text(
            AppStrings.t('remaining', loc),
            style: style,
            textAlign: TextAlign.end,
          ),
        ),
        if (wide)
          Expanded(
            flex: 3,
            child: Text(
              AppStrings.t('date', loc),
              style: style,
              textAlign: TextAlign.end,
            ),
          ),
      ],
    );
  }

  Widget _row(
    ThemeData theme,
    PurchaseModel purchase,
    int index,
    String loc, {
    required bool wide,
  }) {
    return InkWell(
      key: Key('purchase-row-$index'),
      onTap: () => _openDetail(purchase.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Text(
                purchase.invoiceNumber,
                key: Key('purchase-invoice-$index'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                purchase.supplierName ?? '',
                key: Key('purchase-supplier-$index'),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 2,
              child: _statusBadge(context, purchase.status, loc),
            ),
            Expanded(
              flex: 2,
              child: Text(
                formatMoney(purchase.total),
                key: Key('purchase-total-$index'),
                textAlign: TextAlign.end,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                purchase.unpaidMilli > 0
                    ? formatMoney(purchase.unpaid)
                    : '—',
                key: Key('purchase-remaining-$index'),
                textAlign: TextAlign.end,
                style: purchase.unpaidMilli > 0
                    ? TextStyle(color: theme.colorScheme.error)
                    : null,
              ),
            ),
            if (wide)
              Expanded(
                flex: 3,
                child: Text(
                  _timestampOf(purchase.purchaseDate),
                  key: Key('purchase-date-$index'),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
