// Stock / Inventory screen (Phase 7 final): modern desktop ERP layout.
//
// Base-unit adjustments only (no unit selector — Phase 6 units stay in Products).
// Responsive breakpoints (full window width):
//   WIDE   >= 1200 : KPI cards + table + detail side panel
//   MEDIUM 800–1199: KPI cards + table + stacked detail
//   NARROW < 800   : compact KPI cards, stacked toolbar, cards + detail
// Layout never relies on ClipRect; breakpoints use MediaQuery so RTL works.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/strings.dart';
import '../../core/widgets/status_chip.dart';
import '../../core/widgets/table_header.dart';
import '../../l10n/locale_provider.dart';
import '../../theme/app_theme.dart';
import '../auth/permission_helpers.dart';
import 'adjust_dialog.dart';
import 'inventory_models.dart';
import 'inventory_providers.dart';

enum StockLayoutMode { wide, medium, narrow }

StockLayoutMode stockLayoutModeFor(double width) {
  if (width >= 1200) return StockLayoutMode.wide;
  if (width >= 800) return StockLayoutMode.medium;
  return StockLayoutMode.narrow;
}

/// The three stock states map onto the shared status tones, so every pill
/// in the app gets the same brightness-aware tinted fill and foreground
/// (§17.4 — no screen invents its own "green means fine" recipe). `null` is
/// the archived state, which has no colour of its own.
StatusTone stockTone(ProductStockStatus? status) => switch (status) {
      ProductStockStatus.active => StatusTone.success,
      ProductStockStatus.low => StatusTone.warning,
      ProductStockStatus.out => StatusTone.error,
      null => StatusTone.neutral,
    };

/// Localized label for a movement type (never hardcoded in widgets).
String movementTypeLabel(String type, String loc) {
  switch (type) {
    case 'sale':
      return AppStrings.t('movement_sale', loc);
    case 'sale_void':
      return AppStrings.t('movement_sale', loc);
    case 'purchase':
      return AppStrings.t('movement_purchase', loc);
    case 'purchase_delete':
      return AppStrings.t('movement_purchase', loc);
    case 'return':
      return AppStrings.t('movement_return', loc);
    case 'adjustment':
      return AppStrings.t('movement_adjustment', loc);
    case 'package_receive':
      return AppStrings.t('movement_package_receive', loc);
    case 'package_break':
      return AppStrings.t('movement_package_break', loc);
    case 'pack_component':
      return AppStrings.t('movement_adjustment', loc);
    default:
      return type;
  }
}

/// Stock delta direction for journal color semantics (visual only).
enum MovementDirection { increase, decrease, set }

/// Parse a signed `quantity_change` string into a display direction.
/// Positive → increase (green), negative → decrease (red), zero/unknown → set (info).
MovementDirection movementDirectionFromQuantityChange(String quantityChange) {
  final value = double.tryParse(quantityChange.trim());
  if (value == null) return MovementDirection.set;
  if (value > 0) return MovementDirection.increase;
  if (value < 0) return MovementDirection.decrease;
  return MovementDirection.set;
}

/// Semantic color for the quantity delta itself (green / red / info-blue).
Color movementQuantityColor(String quantityChange) {
  switch (movementDirectionFromQuantityChange(quantityChange)) {
    case MovementDirection.increase:
      return AppColors.success;
    case MovementDirection.decrease:
      return AppColors.error;
    case MovementDirection.set:
      return AppColors.info;
  }
}

/// Ensure positive deltas keep a visible `+` sign (e.g. `5.000` → `+5.000`).
/// Negative / zero / unparseable values are returned unchanged.
String formatSignedQuantityChange(String quantityChange) {
  final raw = quantityChange.trim();
  final value = double.tryParse(raw);
  if (value == null || value <= 0) return raw;
  return raw.startsWith('+') ? raw : '+$raw';
}

/// Badge / icon color for a movement type.
/// Uses type defaults where direction is fixed; otherwise falls back to
/// the quantity_change sign (adjustment increase/decrease/set, ambiguous rows).
Color movementTypeColor(String type, {String? quantityChange}) {
  final direction = quantityChange == null
      ? null
      : movementDirectionFromQuantityChange(quantityChange);

  Color byDirection() {
    switch (direction) {
      case MovementDirection.increase:
        return AppColors.success;
      case MovementDirection.decrease:
        return AppColors.error;
      case MovementDirection.set:
        return AppColors.info;
      case null:
        return AppColors.info;
    }
  }

  switch (type) {
    case 'sale':
      return direction == MovementDirection.increase
          ? AppColors.success
          : AppColors.error;
    case 'sale_void':
      return direction == MovementDirection.decrease
          ? AppColors.error
          : AppColors.success;
    case 'purchase':
    case 'package_receive':
      return direction == MovementDirection.decrease
          ? AppColors.error
          : AppColors.success;
    case 'return':
      if (direction == MovementDirection.increase) return AppColors.success;
      if (direction == MovementDirection.set) return AppColors.info;
      return AppColors.error;
    case 'package_break':
      return byDirection();
    case 'adjustment':
    case 'pack_component':
      return byDirection();
    default:
      return byDirection();
  }
}

/// Compact surface decoration shared by KPI / toolbar / table / detail cards.
BoxDecoration stockCardDecoration(ThemeData theme) {
  final cs = theme.colorScheme;
  return BoxDecoration(
    color: cs.surface,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.7)),
    boxShadow: [
      BoxShadow(
        color: cs.shadow.withValues(alpha: 0.04),
        blurRadius: 6,
        offset: const Offset(0, 1),
      ),
    ],
  );
}

class StockScreen extends ConsumerStatefulWidget {
  const StockScreen({super.key});

  @override
  ConsumerState<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends ConsumerState<StockScreen>
    with SingleTickerProviderStateMixin {
  final _searchController = TextEditingController();
  late final TabController _tabController;

  InventoryItemModel? _selected;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    Future.microtask(() {
      ref.read(inventoryProvider.notifier).load();
      ref.read(movementsProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _openAdjust(InventoryItemModel item) async {
    final result = await showAdjustDialog(context, product: item);
    if (result != null && mounted) {
      final selected = _selected;
      if (selected != null && selected.productId == item.productId) {
        await ref
            .read(productStockDetailProvider.notifier)
            .load(item.productId);
      }
      ref.read(movementsProvider.notifier).refresh();
      ref.read(inventoryProvider.notifier).load();
    }
  }

  Future<void> _openDetail(InventoryItemModel item) async {
    setState(() => _selected = item);
    await ref.read(productStockDetailProvider.notifier).load(item.productId);
  }

  void _clearDetail() {
    setState(() => _selected = null);
    ref.read(productStockDetailProvider.notifier).clear();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;

    final canView = ref.watch(hasPermissionProvider('inventory_view'));
    if (!canView) {
      return Center(
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
          key: const Key('stock-permission-denied'),
        ),
      );
    }

    final canAdjust = ref.watch(hasPermissionProvider('inventory_adjust'));
    final state = ref.watch(inventoryProvider);
    final mode = stockLayoutModeFor(MediaQuery.sizeOf(context).width);
    final gap = mode == StockLayoutMode.narrow ? 8.0 : 12.0;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        mode == StockLayoutMode.narrow ? 12 : 16,
        16,
        mode == StockLayoutMode.narrow ? 12 : 16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(theme, loc, mode, canAdjust),
          SizedBox(height: gap),
          if (mode != StockLayoutMode.narrow) ...[
            _buildKpiRow(theme, loc, mode, state),
            SizedBox(height: gap),
          ],
          _buildToolbar(theme, loc, mode, state),
          SizedBox(height: gap),
          if (mode == StockLayoutMode.narrow)
            _buildCompactKpis(theme, loc, state),
          if (mode == StockLayoutMode.narrow) SizedBox(height: gap),
          TabBar(
            controller: _tabController,
            tabs: [
              Tab(
                text: AppStrings.t('inventory', loc),
                key: const Key('stock-tab-list'),
              ),
              Tab(
                text: AppStrings.t('movement_history', loc),
                key: const Key('stock-tab-movements'),
              ),
            ],
          ),
          SizedBox(height: gap),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildInventoryTab(theme, loc, mode, state, canAdjust),
                _buildMovementsTab(theme, loc, mode),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────
  Widget _buildHeader(
    ThemeData theme,
    String loc,
    StockLayoutMode mode,
    bool canAdjust,
  ) {
    final cs = theme.colorScheme;
    final selected = _selected;

    return Row(
      children: [
        if (mode != StockLayoutMode.narrow) ...[
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: cs.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(Icons.warehouse_outlined, color: cs.primary),
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppStrings.t('inventory', loc),
                key: const Key('stock-title'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                AppStrings.t('inventory_subtitle', loc),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurface.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
        IconButton(
          key: const Key('stock-refresh'),
          tooltip: AppStrings.t('refresh', loc),
          icon: const Icon(Icons.refresh),
          onPressed: () => ref.read(inventoryProvider.notifier).refresh(),
        ),
        if (canAdjust && selected != null) ...[
          const SizedBox(width: 4),
          FilledButton.icon(
            key: const Key('stock-header-adjust'),
            onPressed: () => _openAdjust(selected),
            icon: const Icon(Icons.tune, size: 18),
            label: Text(AppStrings.t('adjust_stock', loc)),
          ),
        ],
      ],
    );
  }

  // ── KPI cards (wide / medium) ─────────────────────────────────────
  Widget _buildKpiRow(
    ThemeData theme,
    String loc,
    StockLayoutMode mode,
    InventoryState state,
  ) {
    final lowCount = state.items.where((i) => i.isLowStock).length;
    final outCount = state.items.where((i) => i.isOutStock).length;
    final cards = [
      _kpiCard(
        theme,
        key: const Key('kpi-total-value'),
        label: AppStrings.t('total_stock_value', loc),
        value: state.totalStockValue,
        color: theme.colorScheme.primary,
        icon: Icons.account_balance_wallet_outlined,
      ),
      _kpiCard(
        theme,
        key: const Key('kpi-product-count'),
        label: AppStrings.t('products', loc),
        value: '${state.total}',
        color: AppColors.info,
        icon: Icons.inventory_2_outlined,
      ),
      _kpiCard(
        theme,
        key: const Key('kpi-low-stock'),
        label: AppStrings.t('low_stock', loc),
        value: '$lowCount',
        color: AppColors.warning,
        icon: Icons.warning_amber_outlined,
      ),
      _kpiCard(
        theme,
        key: const Key('kpi-out-stock'),
        label: AppStrings.t('out_of_stock', loc),
        value: '$outCount',
        color: AppColors.error,
        icon: Icons.remove_shopping_cart_outlined,
      ),
    ];

    if (mode == StockLayoutMode.narrow) {
      return GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 2.4,
        children: cards,
      );
    }

    return Row(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(width: 10),
          Expanded(child: cards[i]),
        ],
      ],
    );
  }

  Widget _kpiCard(
    ThemeData theme, {
    required Key key,
    required String label,
    required String value,
    required Color color,
    required IconData icon,
  }) {
    final cs = theme.colorScheme;
    return Container(
      key: key,
      height: 88,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: stockCardDecoration(theme),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCompactKpis(
    ThemeData theme,
    String loc,
    InventoryState state,
  ) {
    final lowCount = state.items.where((i) => i.isLowStock).length;
    final outCount = state.items.where((i) => i.isOutStock).length;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        _miniChip(
          theme,
          key: const Key('kpi-total-value'),
          label: AppStrings.t('total_stock_value', loc),
          value: state.totalStockValue,
          color: theme.colorScheme.primary,
        ),
        _miniChip(
          theme,
          key: const Key('kpi-product-count'),
          label: AppStrings.t('products', loc),
          value: '${state.total}',
          color: AppColors.info,
        ),
        _miniChip(
          theme,
          key: const Key('kpi-low-stock'),
          label: AppStrings.t('low_stock', loc),
          value: '$lowCount',
          color: AppColors.warning,
        ),
        _miniChip(
          theme,
          key: const Key('kpi-out-stock'),
          label: AppStrings.t('out_of_stock', loc),
          value: '$outCount',
          color: AppColors.error,
        ),
      ],
    );
  }

  Widget _miniChip(
    ThemeData theme, {
    required Key key,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: theme.textTheme.labelSmall,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(width: 6),
          Text(
            value,
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // ── Toolbar (one rounded container) ───────────────────────────────
  Widget _buildToolbar(
    ThemeData theme,
    String loc,
    StockLayoutMode mode,
    InventoryState state,
  ) {
    final cs = theme.colorScheme;

    final search = TextField(
      key: const Key('stock-search'),
      controller: _searchController,
      style: theme.textTheme.bodyMedium,
      decoration: InputDecoration(
        prefixIcon: const Icon(Icons.search, size: 20),
        hintText: AppStrings.t('search', loc),
        isDense: true,
        filled: true,
        fillColor: cs.surfaceContainerHighest.withValues(alpha: 0.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      ),
      onChanged: (v) => ref.read(inventoryProvider.notifier).setSearch(v),
    );

    final statusFilter = DropdownButtonFormField<String>(
      key: const Key('stock-status-filter'),
      initialValue: state.query.status,
      decoration: InputDecoration(
        labelText: AppStrings.t('status', loc),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
      ),
      items: [
        DropdownMenuItem(
            value: 'active', child: Text(AppStrings.t('active', loc))),
        DropdownMenuItem(
            value: 'archived', child: Text(AppStrings.t('archived', loc))),
        DropdownMenuItem(
            value: 'all', child: Text(AppStrings.t('all', loc))),
      ],
      onChanged: (v) {
        if (v != null) ref.read(inventoryProvider.notifier).setStatus(v);
      },
    );

    final lowStockFilter = FilterChip(
      key: const Key('stock-low-filter'),
      label: Text(AppStrings.t('low_stock_only', loc)),
      selected: state.query.lowStockOnly,
      onSelected: (v) =>
          ref.read(inventoryProvider.notifier).setLowStockOnly(v),
    );

    final refreshBtn = IconButton(
      key: const Key('stock-toolbar-refresh'),
      tooltip: AppStrings.t('refresh', loc),
      icon: const Icon(Icons.refresh, size: 20),
      onPressed: () => ref.read(inventoryProvider.notifier).refresh(),
    );

    if (mode == StockLayoutMode.narrow) {
      return Column(
        children: [
          search,
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [statusFilter, lowStockFilter, refreshBtn],
          ),
        ],
      );
    }

    return Container(
      key: const Key('stock-toolbar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: stockCardDecoration(theme),
      child: Row(
        children: [
          Expanded(flex: 3, child: search),
          const SizedBox(width: 10),
          SizedBox(width: 150, child: statusFilter),
          const SizedBox(width: 10),
          lowStockFilter,
          const SizedBox(width: 4),
          refreshBtn,
        ],
      ),
    );
  }

  // ── Inventory list tab ────────────────────────────────────────────
  Widget _buildInventoryTab(
    ThemeData theme,
    String loc,
    StockLayoutMode mode,
    InventoryState state,
    bool canAdjust,
  ) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(key: Key('stock-loading')),
      );
    }
    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(state.error!, key: const Key('stock-error')),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () =>
                  ref.read(inventoryProvider.notifier).refresh(),
              child: Text(AppStrings.t('retry', loc)),
            ),
          ],
        ),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warehouse_outlined,
                size: 48, color: theme.colorScheme.outline),
            const SizedBox(height: 8),
            Text(
              AppStrings.t('no_data', loc),
              key: const Key('stock-empty'),
              style: theme.textTheme.bodyLarge,
            ),
          ],
        ),
      );
    }

    final items = state.items;
    final showDetailPanel =
        mode == StockLayoutMode.wide && _selected != null;

    final list = mode == StockLayoutMode.narrow
        ? _buildItemCards(theme, loc, items, canAdjust)
        : _buildItemTable(theme, loc, mode, items, canAdjust);

    if (showDetailPanel) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: list),
          const SizedBox(width: 12),
          SizedBox(
            width: 340,
            child: _buildDetailPanel(theme, loc, canAdjust, mode),
          ),
        ],
      );
    }

    return Column(
      children: [
        Expanded(child: list),
        if (_selected != null && mode != StockLayoutMode.wide) ...[
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240),
            child: _buildDetailPanel(theme, loc, canAdjust, mode),
          ),
        ],
        _buildPagination(theme, loc, state),
      ],
    );
  }

  Widget _buildItemTable(
    ThemeData theme,
    String loc,
    StockLayoutMode mode,
    List<InventoryItemModel> items,
    bool canAdjust,
  ) {
    final wide = mode == StockLayoutMode.wide;
    final cs = theme.colorScheme;

    return Container(
      key: const Key('stock-list'),
      decoration: stockCardDecoration(theme),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Header row — pinned above the scrolling body (§17.2).
          TableHeaderRow(
            testKey: const Key('stock-table-header'),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              Expanded(flex: 3, child: _th(theme, AppStrings.t('name', loc))),
              if (wide)
                Expanded(
                    flex: 2,
                    child: _th(theme, AppStrings.t('category', loc))),
              SizedBox(
                  width: 90,
                  child: _th(theme, AppStrings.t('quantity', loc),
                      numeric: true)),
              SizedBox(
                  width: 100,
                  child: _th(theme, AppStrings.t('avg_cost', loc),
                      numeric: true)),
              SizedBox(
                  width: 110,
                  child: _th(theme, AppStrings.t('stock_value', loc),
                      numeric: true)),
              SizedBox(
                  width: 76,
                  child: _th(theme, AppStrings.t('status', loc),
                      numeric: true)),
              SizedBox(
                  width: 48,
                  child: _th(theme, AppStrings.t('actions', loc),
                      numeric: true)),
            ],
          ),
          Expanded(
            child: ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                thickness: 0.5,
                color: cs.outlineVariant.withValues(alpha: 0.5),
              ),
              itemBuilder: (context, index) {
                final item = items[index];
                final selected = _selected?.productId == item.productId;
                final status = item.isOutStock
                    ? ProductStockStatus.out
                    : item.isLowStock
                        ? ProductStockStatus.low
                        : ProductStockStatus.active;
                final statusColor = switch (status) {
                  ProductStockStatus.active => AppColors.success,
                  ProductStockStatus.low => AppColors.warning,
                  ProductStockStatus.out => AppColors.error,
                };
                final statusLabel = switch (status) {
                  ProductStockStatus.active => AppStrings.t('in_stock', loc),
                  ProductStockStatus.low => AppStrings.t('low_stock', loc),
                  ProductStockStatus.out => AppStrings.t('out_of_stock', loc),
                };

                return InkWell(
                  key: Key('stock-item-${item.productId}'),
                  onTap: () => _openDetail(item),
                  hoverColor: cs.primary.withValues(alpha: 0.04),
                  child: Container(
                    color: selected
                        ? cs.primary.withValues(alpha: 0.08)
                        : null,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                item.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (item.barcode != null)
                                Text(
                                  item.barcode!,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: cs.onSurface.withValues(alpha: 0.7),
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                        if (wide)
                          Expanded(
                            flex: 2,
                            child: Text(
                              item.categoryName ??
                                  AppStrings.t('no_category', loc),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: cs.outline),
                            ),
                          ),
                        SizedBox(
                          width: 90,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                item.quantity,
                                textAlign: TextAlign.end,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  color: statusColor,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                AppStrings.unitLabel(item.unit, loc),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: cs.onSurface.withValues(alpha: 0.7),
                                  fontSize: 11.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                        SizedBox(
                          width: 100,
                          child: Text(
                            item.avgCost,
                            textAlign: TextAlign.end,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        SizedBox(
                          width: 110,
                          child: Text(
                            item.stockValue,
                            textAlign: TextAlign.end,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 76,
                          child: Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: StatusChip(
                              label: statusLabel,
                              tone: stockTone(status),
                              dense: true,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 48,
                          child: canAdjust
                              ? IconButton(
                                  key: Key('stock-adjust-${item.productId}'),
                                  tooltip: AppStrings.t('adjust_stock', loc),
                                  icon: const Icon(Icons.tune, size: 18),
                                  onPressed: () => _openAdjust(item),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _buildPagination(theme, loc, ref.watch(inventoryProvider)),
          ),
        ],
      ),
    );
  }

  Widget _th(ThemeData theme, String label, {bool numeric = false}) {
    return Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: numeric ? TextAlign.end : TextAlign.start,
      style: AppTheme.tableHeader(theme),
    );
  }

  Widget _buildItemCards(
    ThemeData theme,
    String loc,
    List<InventoryItemModel> items,
    bool canAdjust,
  ) {
    final cs = theme.colorScheme;
    return ListView.builder(
      key: const Key('stock-cards'),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final selected = _selected?.productId == item.productId;
        final status = item.isOutStock
            ? ProductStockStatus.out
            : item.isLowStock
                ? ProductStockStatus.low
                : ProductStockStatus.active;
        final statusColor = switch (status) {
          ProductStockStatus.active => AppColors.success,
          ProductStockStatus.low => AppColors.warning,
          ProductStockStatus.out => AppColors.error,
        };
        final statusLabel = switch (status) {
          ProductStockStatus.active => AppStrings.t('in_stock', loc),
          ProductStockStatus.low => AppStrings.t('low_stock', loc),
          ProductStockStatus.out => AppStrings.t('out_of_stock', loc),
        };

        return Container(
          key: Key('stock-card-${item.productId}'),
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.all(12),
          decoration: stockCardDecoration(theme).copyWith(
            border: Border.all(
              color: selected
                  ? cs.primary.withValues(alpha: 0.45)
                  : cs.outlineVariant.withValues(alpha: 0.7),
            ),
          ),
          child: InkWell(
            onTap: () => _openDetail(item),
            borderRadius: BorderRadius.circular(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    StatusChip(
                      label: statusLabel,
                      tone: stockTone(status),
                      dense: true,
                    ),
                    if (canAdjust) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        key: Key('stock-adjust-${item.productId}'),
                        tooltip: AppStrings.t('adjust_stock', loc),
                        icon: const Icon(Icons.tune, size: 18),
                        onPressed: () => _openAdjust(item),
                      ),
                    ],
                  ],
                ),
                if (item.barcode != null)
                  Text(
                    item.barcode!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.7),
                      fontSize: 12,
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _cardStat(
                        theme,
                        AppStrings.t('quantity', loc),
                        '${item.quantity} '
                        '${AppStrings.unitLabel(item.unit, loc)}',
                        color: statusColor,
                      ),
                    ),
                    Expanded(
                      child: _cardStat(
                        theme,
                        AppStrings.t('avg_cost', loc),
                        item.avgCost,
                      ),
                    ),
                    Expanded(
                      child: _cardStat(
                        theme,
                        AppStrings.t('stock_value', loc),
                        item.stockValue,
                        emphasize: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _cardStat(
    ThemeData theme,
    String label,
    String value, {
    Color? color,
    bool emphasize = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
          ),
        ),
        Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildPagination(
    ThemeData theme,
    String loc,
    InventoryState state,
  ) {
    if (state.pages <= 1) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left, size: 20),
            onPressed: state.query.page > 1
                ? () => ref
                    .read(inventoryProvider.notifier)
                    .setPage(state.query.page - 1)
                : null,
          ),
          Text(
            '${state.query.page} / ${state.pages}',
            style: theme.textTheme.bodySmall,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, size: 20),
            onPressed: state.query.page < state.pages
                ? () => ref
                    .read(inventoryProvider.notifier)
                    .setPage(state.query.page + 1)
                : null,
          ),
        ],
      ),
    );
  }

  // ── Detail panel (modern inspector card) ──────────────────────────
  Widget _buildDetailPanel(
    ThemeData theme,
    String loc,
    bool canAdjust,
    StockLayoutMode mode,
  ) {
    final detailAsync = ref.watch(productStockDetailProvider);
    final selected = _selected;
    if (selected == null) return const SizedBox.shrink();
    final cs = theme.colorScheme;

    return Container(
      key: const Key('stock-detail-panel'),
      padding: const EdgeInsets.all(14),
      decoration: stockCardDecoration(theme),
      child: detailAsync.when(
        loading: () => const SizedBox(
          height: 120,
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Text('${AppStrings.t('error', loc)}: $e'),
        data: (detail) {
          if (detail == null) return const SizedBox.shrink();
          final status = detail.isArchived
              ? null
              : (double.tryParse(detail.quantity) ?? 0) <= 0
                  ? ProductStockStatus.out
                  : (double.tryParse(detail.quantity) ?? 0) <=
                          (double.tryParse(detail.lowStockThreshold) ?? 5)
                      ? ProductStockStatus.low
                      : ProductStockStatus.active;
          final statusColor = switch (status) {
            ProductStockStatus.active => AppColors.success,
            ProductStockStatus.low => AppColors.warning,
            ProductStockStatus.out => AppColors.error,
            null => cs.outline,
          };
          final statusLabel = status == null
              ? AppStrings.t('archived', loc)
              : switch (status) {
                  ProductStockStatus.active => AppStrings.t('in_stock', loc),
                  ProductStockStatus.low => AppStrings.t('low_stock', loc),
                  ProductStockStatus.out => AppStrings.t('out_of_stock', loc),
                };

          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        detail.name,
                        key: const Key('detail-name'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    if (mode != StockLayoutMode.narrow)
                      IconButton(
                        key: const Key('detail-close'),
                        tooltip: AppStrings.t('cancel', loc),
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: _clearDetail,
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                if (detail.barcode != null)
                  Text(
                    detail.barcode!,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline),
                  ),
                const SizedBox(height: 10),
                StatusChip(
                  label: statusLabel,
                  tone: stockTone(status),
                  leading: StatusDot(color: statusColor),
                ),
                const SizedBox(height: 12),
                Text(
                  AppStrings.t('stock_quantity', loc),
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: cs.onSurface.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${detail.quantity} '
                  '${AppStrings.unitLabel(detail.unit, loc)}',
                  key: const Key('detail-quantity'),
                  textDirection: TextDirection.ltr,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: statusColor,
                  ),
                ),
                const SizedBox(height: 12),
                _detailRow(theme, loc, 'avg_cost', detail.avgCost),
                _detailRow(theme, loc, 'cost', detail.cost),
                _detailRow(theme, loc, 'stock_value', detail.stockValue),
                const SizedBox(height: 12),
                if (canAdjust)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      key: const Key('detail-adjust'),
                      onPressed: () => _openAdjust(selected),
                      icon: const Icon(Icons.tune, size: 18),
                      label: Text(AppStrings.t('adjust_stock', loc)),
                    ),
                  ),
                const SizedBox(height: 14),
                Text(
                  AppStrings.t('recent_movements', loc),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                if (detail.recentMovements.isEmpty)
                  Text(
                    AppStrings.t('no_movements', loc),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: cs.outline),
                  )
                else
                  ...detail.recentMovements.take(8).map(
                        (m) => _movementTile(theme, loc, m),
                      ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _detailRow(ThemeData theme, String loc, String key, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              AppStrings.t(key, loc),
              style: theme.textTheme.bodySmall,
            ),
          ),
          Text(
            value,
            textDirection: TextDirection.ltr,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _movementTile(
    ThemeData theme,
    String loc,
    InventoryMovementModel m,
  ) {
    final badgeColor = movementTypeColor(
      m.movementType,
      quantityChange: m.quantityChange,
    );
    final qtyColor = movementQuantityColor(m.quantityChange);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration:
                BoxDecoration(color: badgeColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  movementTypeLabel(m.movementType, loc),
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w600),
                ),
                if (m.reason != null && m.reason!.isNotEmpty)
                  Text(
                    m.reason!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.outline),
                  ),
              ],
            ),
          ),
          Text(
            formatSignedQuantityChange(m.quantityChange),
            key: Key('movement-qty-${m.id}'),
            textDirection: TextDirection.ltr,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: qtyColor, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  // ── Movements tab ─────────────────────────────────────────────────
  Widget _buildMovementsTab(
    ThemeData theme,
    String loc,
    StockLayoutMode mode,
  ) {
    final movState = ref.watch(movementsProvider);
    final cs = theme.colorScheme;

    final typeFilter = DropdownButton<String?>(
      key: const Key('movement-type-filter'),
      value: movState.query.movementType,
      hint: Text(AppStrings.t('movement_type', loc)),
      isExpanded: mode != StockLayoutMode.narrow,
      underline: const SizedBox.shrink(),
      items: [
        DropdownMenuItem<String?>(
          value: null,
          child: Text(AppStrings.t('all', loc)),
        ),
        for (final t in const [
          'sale',
          'purchase',
          'return',
          'adjustment',
          'package_receive',
          'package_break',
        ])
          DropdownMenuItem<String?>(
            value: t,
            child: Text(movementTypeLabel(t, loc)),
          ),
      ],
      onChanged: (v) =>
          ref.read(movementsProvider.notifier).setMovementType(v),
    );

    final header = Container(
      key: const Key('movements-toolbar'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: stockCardDecoration(theme),
      child: Row(
        children: [
          Expanded(child: typeFilter),
          IconButton(
            key: const Key('movements-refresh'),
            tooltip: AppStrings.t('refresh', loc),
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => ref.read(movementsProvider.notifier).refresh(),
          ),
        ],
      ),
    );

    if (movState.loading && movState.items.isEmpty) {
      return Column(
        children: [
          header,
          const SizedBox(height: 8),
          const Expanded(
            child: Center(
              child: CircularProgressIndicator(
                key: Key('movements-loading'),
              ),
            ),
          ),
        ],
      );
    }
    if (movState.error != null && movState.items.isEmpty) {
      return Column(
        children: [
          header,
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: Text(movState.error!,
                  key: const Key('movements-error')),
            ),
          ),
        ],
      );
    }
    if (movState.items.isEmpty) {
      return Column(
        children: [
          header,
          const SizedBox(height: 8),
          Expanded(
            child: Center(
              child: Text(
                AppStrings.t('no_movements', loc),
                key: const Key('movements-empty'),
              ),
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        header,
        const SizedBox(height: 8),
        Expanded(
          child: ListView.separated(
            key: const Key('movements-list'),
            itemCount: movState.items.length,
            separatorBuilder: (_, _) => Divider(
              height: 1,
              thickness: 0.5,
              color: cs.outlineVariant.withValues(alpha: 0.5),
            ),
            itemBuilder: (context, index) {
              final m = movState.items[index];
              final badgeColor = movementTypeColor(
                m.movementType,
                quantityChange: m.quantityChange,
              );
              final qtyColor = movementQuantityColor(m.quantityChange);
              return Container(
                key: Key('movement-${m.id}'),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        switch (m.movementType) {
                          'sale' || 'sale_void' => Icons.point_of_sale,
                          'purchase' || 'package_receive' =>
                            Icons.local_shipping,
                          'return' => Icons.undo,
                          'package_break' => Icons.inventory_2,
                          _ => Icons.tune,
                        },
                        size: 16,
                        color: badgeColor,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  [
                                    if (m.productName != null) m.productName!,
                                    if (m.variantName != null)
                                      '(${m.variantName!})',
                                  ].join(' '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.bodyMedium
                                      ?.copyWith(fontWeight: FontWeight.w600),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: badgeColor.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  movementTypeLabel(m.movementType, loc),
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: badgeColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            [
                              if (m.reason != null && m.reason!.isNotEmpty)
                                m.reason!,
                              if (m.userName != null)
                                '${AppStrings.t('performed_by', loc)}: '
                                    '${m.userName!}',
                              if (m.unitCost != null)
                                '${AppStrings.t('unit_cost', loc)}: '
                                    '${m.unitCost}',
                            ].join(' · '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall
                                ?.copyWith(color: cs.outline),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          formatSignedQuantityChange(m.quantityChange),
                          key: Key('movement-qty-${m.id}'),
                          textDirection: TextDirection.ltr,
                          style: theme.textTheme.titleSmall?.copyWith(
                            color: qtyColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (m.avgCostAfter != null)
                          Text(
                            'PMP: ${m.avgCostAfter}',
                            textDirection: TextDirection.ltr,
                            style: theme.textTheme.labelSmall
                                ?.copyWith(color: cs.outline),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        if (movState.pages > 1)
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.chevron_left, size: 20),
                onPressed: movState.query.page > 1
                    ? () => ref
                        .read(movementsProvider.notifier)
                        .setPage(movState.query.page - 1)
                    : null,
              ),
              Text(
                '${movState.query.page} / ${movState.pages}',
                style: theme.textTheme.bodySmall,
              ),
              IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                onPressed: movState.query.page < movState.pages
                    ? () => ref
                        .read(movementsProvider.notifier)
                        .setPage(movState.query.page + 1)
                    : null,
              ),
            ],
          ),
      ],
    );
  }
}

/// Stock status enum (local to stock screen — mirrors products screen).
enum ProductStockStatus { active, low, out }
