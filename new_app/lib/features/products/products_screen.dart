// Products screen (Phase 5, final color & visual polish): modern desktop
// POS/ERP workspace — semantic color system, category pills, status badges,
// stock-aware quantity colors, richer rows/cards, unified toolbar, and
// workspace-owned empty/loading/error/pagination states.
//
// Responsive breakpoints (full window width):
//   WIDE   >= 1200 : full table, all permitted columns, single-row toolbar
//   MEDIUM 800–1199: wrapping toolbar, reduced columns
//   NARROW < 800   : adaptive product cards, stacked controls
// Layout never relies on ClipRect; breakpoints use MediaQuery so RTL works.
// Colors come from ThemeData / AppColors (theme-aware, not hardcoded-only).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/colors.dart';
import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/shortcuts.dart';
import '../../core/strings.dart';
import '../../core/widgets/table_header.dart';
import '../../l10n/locale_provider.dart';
import '../../theme/app_theme.dart';
import '../auth/permission_helpers.dart';
import '../clients/customer_models.dart';
import 'categories_dialog.dart';
import 'label_print_dialog.dart';
import 'models.dart';
import 'product_form_dialog.dart';
import 'products_providers.dart';

enum ProductsLayoutMode { wide, medium, narrow }

ProductsLayoutMode productsLayoutModeFor(double width) {
  if (width >= 1200) return ProductsLayoutMode.wide;
  if (width >= 800) return ProductsLayoutMode.medium;
  return ProductsLayoutMode.narrow;
}

/// Stock/status semantic for a product row.
enum ProductStockStatus { active, low, out, archived }

/// Derive stock status from quantity vs low-stock threshold (archived wins).
ProductStockStatus productStockStatus(ProductModel product) {
  if (product.isArchived) return ProductStockStatus.archived;
  final qty = double.tryParse(product.quantity) ?? 0;
  final threshold = double.tryParse(product.lowStockThreshold) ?? 5;
  if (qty <= 0) return ProductStockStatus.out;
  if (qty <= threshold) return ProductStockStatus.low;
  return ProductStockStatus.active;
}

/// Theme-aware semantic color for a stock status.
Color productStatusColor(ThemeData theme, ProductStockStatus status) {
  switch (status) {
    case ProductStockStatus.active:
      return AppColors.success;
    case ProductStockStatus.low:
      return AppColors.warning;
    case ProductStockStatus.out:
      return AppColors.error;
    case ProductStockStatus.archived:
      return theme.colorScheme.onSurface.withValues(alpha: 0.6);
  }
}

/// Localized label for a stock status (never hardcoded in widgets).
String productStatusLabel(ProductStockStatus status, String loc) {
  switch (status) {
    case ProductStockStatus.active:
      return AppStrings.t('active', loc);
    case ProductStockStatus.low:
      return AppStrings.t('low_stock', loc);
    case ProductStockStatus.out:
      return AppStrings.t('out_of_stock', loc);
    case ProductStockStatus.archived:
      return AppStrings.t('archived', loc);
  }
}

/// Phase 17 — profit and margin for one product row (display only).
///
/// Returns `(profit, margin)`: profit is `price - cost` in exact
/// thousandths (`100.000 - 60.000` → `'40.000'`), margin is
/// `profit / price` rendered `NN.NN%`. Margin is null when the price is 0
/// — never divide by zero, the same rule the pack form applies to its
/// estimated margin. Nothing here is persisted or sent anywhere.
(String?, String?) productProfitMargin(ProductModel product) {
  final priceMilli = moneyToMilli(product.price);
  final costMilli = moneyToMilli(product.cost);
  if (priceMilli == null || costMilli == null) return (null, null);
  final value = priceMilli - costMilli;
  if (priceMilli == 0) return (milliToMoney(value), null);
  // hundredths of a percent, so 40.000 / 100.000 reads "40.00%".
  final hundredths = (value * 10000) ~/ priceMilli;
  final negative = hundredths < 0;
  final abs = hundredths.abs();
  final margin = '${negative ? '-' : ''}'
      '${abs ~/ 100}.${(abs % 100).toString().padLeft(2, '0')}%';
  return (milliToMoney(value), margin);
}

/// Deterministic subdued category color from identity/name (no DB change).
/// The palette itself lives with the other centralized tokens in
/// `lib/core/colors.dart` — this alias keeps the screen's vocabulary.
Color categoryPillColor(String identity) => AppColors.categoryIdentity(identity);

/// Horizontal flex weights so the product column dominates without leaving
/// intrinsic-width gaps. Actions stay compact (fixed width).
class _Col {
  final String label;
  final int flex;
  final bool numeric;
  final double fixedWidth; // 0 = flex

  const _Col(
    this.label, {
    required this.flex,
    this.numeric = false,
    this.fixedWidth = 0,
  });
}

class ProductsScreen extends ConsumerStatefulWidget {
  const ProductsScreen({super.key});

  @override
  ConsumerState<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends ConsumerState<ProductsScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  /// Barcode / price-label selection mode (§ labels). Selection SURVIVES
  /// paging — [_labelSelected] is keyed by product id, not by page.
  bool _labelMode = false;
  final Map<String, ProductModel> _labelSelected = {};

  /// Phase 17 §18 — page-level hooks for the shell's F4 / Ctrl+F / F5.
  late final PageShortcuts _pageShortcuts;

  @override
  void initState() {
    super.initState();
    _pageShortcuts = PageShortcuts(
      focusSearch: () {
        if (!mounted) return;
        _searchFocusNode.requestFocus();
      },
      refresh: () {
        if (!mounted) return;
        ref.read(productsProvider.notifier).refresh();
      },
    );
    PageShortcutsRegistry.current = _pageShortcuts;
    Future.microtask(() {
      ref.read(productsProvider.notifier).load();
      ref.read(categoriesProvider.notifier).load(status: 'active');
    });
  }

  @override
  void dispose() {
    if (identical(PageShortcutsRegistry.current, _pageShortcuts)) {
      PageShortcutsRegistry.current = null;
    }
    _searchFocusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;

    final canView = ref.watch(hasPermissionProvider('product_view'));
    if (!canView) {
      return Center(
        child: Text(
          AppStrings.t('permission_denied', loc),
          style: theme.textTheme.bodyLarge,
        ),
      );
    }

    final canCreate = ref.watch(hasPermissionProvider('product_create'));
    final canUpdate = ref.watch(hasPermissionProvider('product_update'));
    final canArchive = ref.watch(hasPermissionProvider('product_archive'));
    final canManageCategories =
        ref.watch(hasPermissionProvider('category_manage'));

    final state = ref.watch(productsProvider);
    final categories = ref.watch(categoriesProvider).activeItems;

    // Full content width after nav rail + padding — never intrinsic-sized.
    final tight = productsLayoutModeFor(MediaQuery.sizeOf(context).width) ==
        ProductsLayoutMode.narrow;
    final gap = tight ? 8.0 : 12.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, tight ? 12 : 16, 16, tight ? 12 : 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final mode =
              productsLayoutModeFor(MediaQuery.sizeOf(context).width);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHeader(theme, loc, mode, canCreate, canManageCategories),
              SizedBox(height: gap),
              _buildToolbar(theme, loc, mode, state, categories),
              SizedBox(height: gap),
              Expanded(child: _buildWorkspace(theme, loc, mode, state,
                  canCreate: canCreate,
                  canUpdate: canUpdate,
                  canArchive: canArchive)),
            ],
          );
        },
      ),
    );
  }

  // ── A. Page header (compact, purposeful) ──────────────────────
  Widget _buildHeader(
    ThemeData theme,
    String loc,
    ProductsLayoutMode mode,
    bool canCreate,
    bool canManageCategories,
  ) {
    final iconBox = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.28),
        ),
      ),
      child: Icon(
        Icons.inventory_2_outlined,
        size: 22,
        color: theme.colorScheme.primary,
      ),
    );

    final titleBlock = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (mode != ProductsLayoutMode.narrow) ...[
          iconBox,
          const SizedBox(width: 12),
        ],
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AppStrings.t('products', loc),
                key: const Key('products-header-title'),
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontSize: mode == ProductsLayoutMode.narrow ? 22 : 26,
                ),
              ),
              if (mode != ProductsLayoutMode.narrow) ...[
                const SizedBox(height: 2),
                Text(
                  AppStrings.t('products_subtitle', loc),
                  key: const Key('products-header-subtitle'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    final secondary = canManageCategories
        ? OutlinedButton.icon(
            key: const Key('products-manage-categories-button'),
            onPressed: () => showCategoriesDialog(context),
            icon: Icon(
              Icons.category_outlined,
              size: mode == ProductsLayoutMode.narrow ? 16 : 18,
            ),
            label: Text(
              mode == ProductsLayoutMode.narrow
                  ? AppStrings.t('categories', loc)
                  : AppStrings.t('manage_categories', loc),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.colorScheme.onSurface,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.symmetric(
                horizontal: mode == ProductsLayoutMode.narrow ? 10 : 16,
                vertical: mode == ProductsLayoutMode.narrow ? 8 : 10,
              ),
              side: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.45),
              ),
            ),
          )
        : null;
    final primary = canCreate
        ? FilledButton.icon(
            key: const Key('products-add-button'),
            onPressed: () => showProductFormDialog(context),
            icon: Icon(
              Icons.add,
              size: mode == ProductsLayoutMode.narrow ? 16 : 18,
            ),
            label: Text(AppStrings.t('add_product', loc)),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.primary,
              foregroundColor: theme.colorScheme.onPrimary,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.symmetric(
                horizontal: mode == ProductsLayoutMode.narrow ? 12 : 18,
                vertical: mode == ProductsLayoutMode.narrow ? 8 : 12,
              ),
            ),
          )
        : null;

    final actionChildren = _labelMode
        ? <Widget>[
            _labelActions(theme, loc, mode),
          ]
        : <Widget>[
            OutlinedButton.icon(
              key: const Key('products-print-labels'),
              onPressed: _enterLabelMode,
              icon: Icon(
                Icons.local_print_shop_outlined,
                size: mode == ProductsLayoutMode.narrow ? 16 : 18,
              ),
              label: Text(AppStrings.t('print_labels', loc)),
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.onSurface,
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.symmetric(
                  horizontal: mode == ProductsLayoutMode.narrow ? 10 : 16,
                  vertical: mode == ProductsLayoutMode.narrow ? 8 : 10,
                ),
                side: BorderSide(
                  color: theme.colorScheme.outline.withValues(alpha: 0.45),
                ),
              ),
            ),
            if (secondary != null) const SizedBox(width: 8),
            ?secondary,
            if (primary != null) ...[
              if (secondary != null) const SizedBox(width: 8),
              primary,
            ],
          ];

    if (mode == ProductsLayoutMode.wide && actionChildren.isNotEmpty) {
      return SizedBox(
        height: 72,
        child: Row(
          children: [
            Expanded(child: titleBlock),
            const SizedBox(width: 12),
            for (final a in actionChildren) a,
          ],
        ),
      );
    }

    // Medium/narrow: title + actions share a wrapping row so short
    // viewports (e.g. 600×500) keep enough height for the product list.
    final actions = actionChildren.isEmpty
        ? null
        : Wrap(
            spacing: 8,
            runSpacing: 6,
            alignment: WrapAlignment.end,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: actionChildren,
          );

    if (mode == ProductsLayoutMode.narrow) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Row(
          children: [
            Expanded(child: titleBlock),
            if (actions != null) ...[
              const SizedBox(width: 8),
              Flexible(child: actions),
            ],
          ],
        ),
      );
    }

    // Medium: stack title above wrapping actions (no Row overflow).
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          titleBlock,
          if (actions != null) ...[
            const SizedBox(height: 8),
            Align(alignment: AlignmentDirectional.centerStart, child: actions),
          ],
        ],
      ),
    );
  }

  // ── Barcode / price-label selection mode ─────────────────────
  void _enterLabelMode() {
    setState(() {
      _labelMode = true;
      _labelSelected.clear();
    });
  }

  void _exitLabelMode() {
    setState(() {
      _labelMode = false;
      _labelSelected.clear();
    });
  }

  void _toggleLabel(ProductModel product) {
    setState(() {
      if (_labelSelected.containsKey(product.id)) {
        _labelSelected.remove(product.id);
      } else {
        _labelSelected[product.id] = product;
      }
    });
  }

  /// Tristate for the header checkbox over the CURRENT page only:
  /// all selected → true, none → false, mixed → null (§ selection mode).
  bool? _pageSelectionState(List<ProductModel> items) {
    if (items.isEmpty) return false;
    final count = items.where((p) => _labelSelected.containsKey(p.id)).length;
    if (count == 0) return false;
    if (count == items.length) return true;
    return null;
  }

  void _toggleAllOnPage(List<ProductModel> items) {
    final clear = _pageSelectionState(items) == true;
    setState(() {
      for (final product in items) {
        if (clear) {
          _labelSelected.remove(product.id);
        } else {
          _labelSelected[product.id] = product;
        }
      }
    });
  }

  Future<void> _openLabelDialog() async {
    final printed = await showLabelPrintDialog(
      context,
      products: List<ProductModel>.of(_labelSelected.values),
    );
    // A confirmed print exits selection mode (§16.2 — no success toast).
    if (printed == true && mounted) _exitLabelMode();
  }

  Widget _labelActions(ThemeData theme, String loc, ProductsLayoutMode mode) {
    final compact = mode == ProductsLayoutMode.narrow;
    final padding = EdgeInsets.symmetric(
      horizontal: compact ? 10 : 16,
      vertical: compact ? 8 : 10,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          key: const Key('products-label-count'),
          '${_labelSelected.length} ${AppStrings.t('labels_selected', loc)}',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(width: 10),
        OutlinedButton(
          key: const Key('products-label-cancel'),
          onPressed: _exitLabelMode,
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.onSurface,
            visualDensity: VisualDensity.compact,
            padding: padding,
            side: BorderSide(
              color: theme.colorScheme.outline.withValues(alpha: 0.45),
            ),
          ),
          child: Text(AppStrings.t('cancel', loc)),
        ),
        const SizedBox(width: 8),
        FilledButton.icon(
          key: const Key('products-print-action'),
          onPressed: _labelSelected.isEmpty ? null : _openLabelDialog,
          icon: Icon(
            Icons.local_print_shop_outlined,
            size: compact ? 16 : 18,
          ),
          label: Text(AppStrings.t('print', loc)),
          style: FilledButton.styleFrom(
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 12 : 18,
              vertical: compact ? 8 : 12,
            ),
          ),
        ),
      ],
    );
  }

  // ── B. Unified filter/search toolbar ─────────────────────────
  Widget _buildToolbar(
    ThemeData theme,
    String loc,
    ProductsLayoutMode mode,
    ProductsState state,
    List<CategoryModel> categories,
  ) {
    final cs = theme.colorScheme;
    final fieldBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(8),
      borderSide: BorderSide(color: cs.outline.withValues(alpha: 0.35)),
    );

    final searchField = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 140),
      child: TextField(
        key: const Key('products-search-field'),
        controller: _searchController,
        focusNode: _searchFocusNode,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          hintText: AppStrings.t('search', loc),
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurface.withValues(alpha: 0.6),
          ),
          prefixIcon: Icon(
            Icons.search,
            size: 20,
            color: cs.onSurface.withValues(alpha: 0.55),
          ),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, _) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                key: const Key('products-search-clear'),
                tooltip: AppStrings.t('clear', loc),
                icon: const Icon(Icons.close, size: 18),
                onPressed: () {
                  _searchController.clear();
                  ref.read(productsProvider.notifier).setSearch('');
                },
              );
            },
          ),
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          border: fieldBorder,
          enabledBorder: fieldBorder,
          focusedBorder: fieldBorder.copyWith(
            borderSide: BorderSide(color: cs.primary, width: 1.5),
          ),
          filled: true,
          fillColor: cs.surface,
        ),
        onChanged: (value) =>
            ref.read(productsProvider.notifier).setSearch(value),
      ),
    );

    Widget filterDropdown<T>({
      required Key key,
      required T value,
      required List<DropdownMenuItem<T>> items,
      required void Function(T?) onChanged,
      IconData? icon,
      double minWidth = 120,
      double maxWidth = 170,
    }) {
      final selected = value != null;
      final narrow = mode == ProductsLayoutMode.narrow;
      final minW = narrow ? minWidth.clamp(80.0, 110.0) : minWidth;
      final maxW = narrow ? maxWidth.clamp(100.0, 130.0) : maxWidth;
      return ConstrainedBox(
        constraints: BoxConstraints(minWidth: minW, maxWidth: maxW),
        child: DropdownButtonFormField<T>(
          key: key,
          initialValue: value,
          items: items,
          onChanged: onChanged,
          isDense: true,
          isExpanded: true,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: narrow ? 13 : null,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
          icon: const Icon(Icons.arrow_drop_down, size: 22),
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: icon == null
                ? null
                : Icon(
                    icon,
                    size: 16,
                    color: cs.onSurface.withValues(alpha: 0.55),
                  ),
            contentPadding: EdgeInsets.symmetric(
              horizontal: narrow ? 8 : 10,
              vertical: narrow ? 6 : 10,
            ),
            border: fieldBorder,
            enabledBorder: fieldBorder,
            focusedBorder: fieldBorder.copyWith(
              borderSide: BorderSide(color: cs.primary, width: 1.5),
            ),
            filled: true,
            fillColor: cs.surface,
          ),
        ),
      );
    }

    final status = filterDropdown<String>(
      key: const Key('products-status-filter'),
      value: state.query.status,
      icon: Icons.tune,
      items: [
        DropdownMenuItem(
          value: 'active',
          child: Text(
            AppStrings.t('active', loc),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownMenuItem(
          value: 'archived',
          child: Text(
            AppStrings.t('archived', loc),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownMenuItem(
          value: 'all',
          child: Text(
            AppStrings.t('all', loc),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      onChanged: (v) {
        if (v != null) ref.read(productsProvider.notifier).setStatus(v);
      },
    );

    final category = filterDropdown<String?>(
      key: const Key('products-category-filter'),
      value: state.query.categoryId,
      icon: Icons.category_outlined,
      items: [
        DropdownMenuItem<String?>(
          value: null,
          child: Text(
            AppStrings.t('all', loc),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        for (final c in categories)
          DropdownMenuItem<String?>(
            value: c.id,
            child: Text(c.name, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) => ref.read(productsProvider.notifier).setCategory(v),
    );

    // Sort is supported server-side (ProductQuery.sortBy/sortOrder).
    String sortValue = '${state.query.sortBy}:${state.query.sortOrder}';
    final sort = filterDropdown<String>(
      key: const Key('products-sort-filter'),
      value: ['name:asc', 'name:desc', 'price:asc', 'price:desc', 'quantity:asc']
              .contains(sortValue)
          ? sortValue
          : 'name:asc',
      icon: Icons.sort_rounded,
      minWidth: 130,
      maxWidth: 180,
      items: [
        DropdownMenuItem(
          value: 'name:asc',
          child: Text(
            '${AppStrings.t('sort_name', loc)} ↑',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownMenuItem(
          value: 'name:desc',
          child: Text(
            '${AppStrings.t('sort_name', loc)} ↓',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownMenuItem(
          value: 'price:asc',
          child: Text(
            '${AppStrings.t('sort_price', loc)} ↑',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownMenuItem(
          value: 'price:desc',
          child: Text(
            '${AppStrings.t('sort_price', loc)} ↓',
            overflow: TextOverflow.ellipsis,
          ),
        ),
        DropdownMenuItem(
          value: 'quantity:asc',
          child: Text(
            '${AppStrings.t('sort_quantity', loc)} ↑',
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
      onChanged: (v) {
        if (v == null) return;
        final parts = v.split(':');
        ref
            .read(productsProvider.notifier)
            .setSort(parts[0], parts[1]);
      },
    );

    final refresh = IconButton(
      key: const Key('products-refresh-button'),
      tooltip: AppStrings.t('refresh', loc),
      onPressed: () => ref.read(productsProvider.notifier).refresh(),
      icon: const Icon(Icons.refresh),
      visualDensity: VisualDensity.compact,
      style: IconButton.styleFrom(
        foregroundColor: cs.primary,
        backgroundColor: cs.primary.withValues(alpha: 0.10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );

    final controls = <Widget>[
      status,
      category,
      if (mode == ProductsLayoutMode.wide) sort,
      refresh,
    ];

    // One unified surface so toolbar belongs to the workspace below.
    // Medium/narrow: Wrap cannot host Expanded — search uses a flexible
    // SizedBox sized from the toolbar width via LayoutBuilder.
    return Material(
      key: const Key('products-toolbar'),
      color: cs.surfaceContainerHighest.withValues(alpha: 0.65),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: cs.outline.withValues(alpha: 0.22)),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: mode == ProductsLayoutMode.narrow ? 8 : 10,
        ),
        child: mode == ProductsLayoutMode.wide
            ? Row(
                children: [
                  Expanded(flex: 3, child: searchField),
                  const SizedBox(width: 10),
                  for (var i = 0; i < controls.length; i++) ...[
                    if (i > 0) const SizedBox(width: 10),
                    controls[i],
                  ],
                ],
              )
            : LayoutBuilder(
                builder: (context, cons) {
                  final available = cons.maxWidth;
                  final searchWidth = mode == ProductsLayoutMode.medium
                      ? (available - 360).clamp(160.0, double.infinity)
                      : available.clamp(160.0, 240.0);
                  return Wrap(
                    spacing: mode == ProductsLayoutMode.narrow ? 8 : 10,
                    runSpacing: mode == ProductsLayoutMode.narrow ? 8 : 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(width: searchWidth, child: searchField),
                      ...controls,
                    ],
                  );
                },
              ),
      ),
    );
  }

  // ── C. Product workspace (fills remaining width + height) ────
  Widget _buildWorkspace(
    ThemeData theme,
    String loc,
    ProductsLayoutMode mode,
    ProductsState state, {
    required bool canCreate,
    required bool canUpdate,
    required bool canArchive,
  }) {
    final cs = theme.colorScheme;
    return Material(
      key: const Key('products-workspace'),
      color: cs.surfaceContainerLow.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(12),
      elevation: 0,
      child: Container(
        width: double.infinity,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: cs.outline.withValues(alpha: 0.25)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.18),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) =>
                    FadeTransition(opacity: animation, child: child),
                child: _buildBody(
                  theme,
                  loc,
                  mode,
                  state,
                  canCreate: canCreate,
                  canUpdate: canUpdate,
                  canArchive: canArchive,
                ),
              ),
            ),
            if (state.items.isNotEmpty && state.error == null)
              _buildFooter(theme, loc, state),
          ],
        ),
      ),
    );
  }

  // ── Body states (inside workspace) ───────────────────────────
  Widget _buildBody(
    ThemeData theme,
    String loc,
    ProductsLayoutMode mode,
    ProductsState state, {
    required bool canCreate,
    required bool canUpdate,
    required bool canArchive,
  }) {
    if (state.loading && state.items.isEmpty) {
      return Center(
        key: const Key('products-loading'),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 14),
            Text(
              AppStrings.t('loading', loc),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      );
    }
    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppColors.error.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.error_outline,
                  size: 40,
                  color: AppColors.error,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                state.error!,
                key: const Key('products-error'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                key: const Key('products-retry'),
                onPressed: () => ref.read(productsProvider.notifier).refresh(),
                icon: const Icon(Icons.refresh, size: 18),
                label: Text(AppStrings.t('retry', loc)),
              ),
            ],
          ),
        ),
      );
    }
    if (state.items.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(
                  Icons.inventory_2_outlined,
                  size: 48,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: 14),
              Text(
                AppStrings.t('no_products', loc),
                key: const Key('products-empty'),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                AppStrings.t('no_products_hint', loc),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              if (canCreate) ...[
                const SizedBox(height: 16),
                FilledButton.icon(
                  key: const Key('products-empty-add'),
                  onPressed: () => showProductFormDialog(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: Text(AppStrings.t('add_product', loc)),
                ),
              ],
            ],
          ),
        ),
      );
    }
    if (mode == ProductsLayoutMode.narrow) {
      return _buildCardList(
        theme,
        loc,
        state.items,
        canUpdate: canUpdate,
        canArchive: canArchive,
      );
    }
    return _buildTable(
      theme,
      loc,
      state.items,
      mode: mode,
      canUpdate: canUpdate,
      canArchive: canArchive,
    );
  }

  // ── D. Full-width dense table (wide / medium) ────────────────
  Widget _buildTable(
    ThemeData theme,
    String loc,
    List<ProductModel> items, {
    required ProductsLayoutMode mode,
    required bool canUpdate,
    required bool canArchive,
  }) {
    final cs = theme.colorScheme;
    final showCost = canUpdate;
    final showUnit = mode == ProductsLayoutMode.wide;
    final showCategory = mode == ProductsLayoutMode.wide;
    // Profit / margin / wholesale are wide-screen columns. Three extra
    // figures at 800–1199px squeeze the name cell under 50px — below the
    // thumbnail — so the medium table keeps the columns it always had.
    final showFinancials =
        canUpdate && mode == ProductsLayoutMode.wide;
    final showStatus = true;
    final showActions = canUpdate || canArchive;

    final cols = <_Col>[
      _Col(AppStrings.t('name', loc), flex: 24),
      _Col(AppStrings.t('barcode', loc), flex: 13),
      if (showCategory) _Col(AppStrings.t('category', loc), flex: 11),
      _Col(AppStrings.t('price', loc), flex: 10, numeric: true),
      if (showCost) _Col(AppStrings.t('cost', loc), flex: 10, numeric: true),
      // Phase 17 pricing — gated exactly like cost: both need `product_update`.
      if (showFinancials)
        _Col(AppStrings.t('profit', loc), flex: 10, numeric: true),
      if (showFinancials)
        _Col(AppStrings.t('margin', loc), flex: 15, numeric: true),
      if (showFinancials)
        _Col(AppStrings.t('wholesale_price', loc), flex: 16, numeric: true),
      _Col(AppStrings.t('quantity', loc), flex: 10, numeric: true),
      if (showUnit) _Col(AppStrings.t('unit', loc), flex: 8),
      if (showStatus)
        _Col(AppStrings.t('status', loc), flex: 0, fixedWidth: 112),
      if (showActions)
        _Col(AppStrings.t('actions', loc), flex: 0, fixedWidth: 96),
    ];

    Widget cell(int index, Widget child, {bool header = false}) {
      final col = cols[index];
      final inner = Padding(
        // 10px horizontally, 5px vertically: a two-line product name must
        // not touch the row divider, and a cell must not read as a wall of
        // text. At 1280 the twelve columns are tight enough that the extra
        // 4px per column is the difference between a figure on one line and
        // a figure split in two.
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: DefaultTextStyle(
          style: header ? tableHeaderStyle(context) : theme.textTheme.bodyMedium!,
          child: col.fixedWidth > 0
              ? SizedBox(width: col.fixedWidth, child: child)
              : Align(
                  alignment: col.numeric
                      ? AlignmentDirectional.centerEnd
                      : AlignmentDirectional.centerStart,
                  child: child,
                ),
        ),
      );
      if (col.fixedWidth > 0) return inner;
      return Expanded(flex: col.flex, child: inner);
    }

    List<Widget> headerCells() => [
          for (var i = 0; i < cols.length; i++)
            if (i == 0 && _labelMode)
              // Label mode: tristate select-all over the CURRENT page —
              // the selection itself survives paging (§ selection mode).
              cell(
                i,
                Checkbox(
                  key: const Key('products-label-check-all'),
                  tristate: true,
                  value: _pageSelectionState(items),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  onChanged: (_) => _toggleAllOnPage(items),
                ),
                header: true,
              )
            else
              cell(i, Text(cols[i].label, overflow: TextOverflow.ellipsis),
                  header: true),
        ];

    List<Widget> dataCells(ProductModel product) {
      final status = productStockStatus(product);
      final cells = <Widget>[
        // 0 — product
        cell(
          0,
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_labelMode) ...[
                Checkbox(
                  key: Key('product-label-check-${product.id}'),
                  value: _labelSelected.containsKey(product.id),
                  onChanged: (_) => _toggleLabel(product),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
              _thumbnail(product, size: 40),
              const SizedBox(width: 10),
              Flexible(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      overflow: TextOverflow.ellipsis,
                      // A name may take a second line; nothing else in the
                      // row does, so a figure never reads as two values.
                      maxLines: 2,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (!showCategory &&
                        (product.categoryName?.isNotEmpty ?? false)) ...[
                      const SizedBox(height: 2),
                      _CategoryPill(
                        label: product.categoryName!,
                        color: categoryPillColor(
                          product.categoryId ?? product.categoryName!,
                        ),
                        fontSize: 11.5,
                        compact: true,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        cell(
          1,
          Text(
            product.barcode ?? '—',
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontFamily: 'monospace',
              fontSize: 13,
              color: cs.onSurface.withValues(alpha: 0.78),
            ),
          ),
        ),
      ];
      var i = 2;
      if (showCategory) {
        final name = product.categoryName;
        cells.add(
          cell(
            i++,
            name == null || name.isEmpty
                ? Text(
                    AppStrings.t('no_category', loc),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: cs.onSurface.withValues(alpha: 0.7),
                    ),
                  )
                : _CategoryPill(
                    label: name,
                    color: categoryPillColor(product.categoryId ?? name),
                  ),
          ),
        );
      }
      cells.add(
        cell(
          i++,
          _fitEnd(numericText(
            formatGrouped(product.price),
            // Tabular figures so prices line up down the column.
            style: AppTheme.numeric(theme, size: 15).copyWith(
              fontWeight: FontWeight.w700,
            ),
          )),
        ),
      );
      if (showCost) {
        cells.add(
          cell(
            i++,
            _fitEnd(numericText(
              formatGrouped(product.cost),
              style: AppTheme.numeric(theme, size: 14).copyWith(
                fontWeight: FontWeight.w500,
                color: cs.onSurface.withValues(alpha: 0.75),
              ),
            )),
          ),
        );
        // Phase 17 pricing — profit / margin / wholesale columns.
        if (showFinancials) {
          final (profit, margin) = productProfitMargin(product);
          cells.add(
            cell(
              i++,
              _fitEnd(numericText(
                profit == null ? '—' : formatGrouped(profit),
                key: Key('product-profit-${product.id}'),
                style: AppTheme.numeric(theme, size: 14).copyWith(
                  fontWeight: FontWeight.w600,
                  color: (profit?.startsWith('-') ?? false)
                      ? AppColors.error
                      : cs.primary,
                ),
              )),
            ),
          );
          cells.add(
            cell(
              i++,
              _fitEnd(numericText(
                margin ?? '—',
                key: Key('product-margin-${product.id}'),
                style: AppTheme.numeric(theme, size: 14).copyWith(
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface.withValues(alpha: 0.8),
                ),
              )),
            ),
          );
          final wholesale = product.wholesalePrice;
          cells.add(
            cell(
              i++,
              _fitEnd(numericText(
                wholesale == null ? '—' : formatGrouped(wholesale),
                key: Key('product-wholesale-${product.id}'),
                style: AppTheme.numeric(theme, size: 14).copyWith(
                  fontWeight: FontWeight.w500,
                  color: wholesale == null
                      ? cs.onSurface.withValues(alpha: 0.6)
                      : cs.onSurface.withValues(alpha: 0.8),
                ),
              )),
            ),
          );
        }
      }
      final qtyColor = switch (status) {
        ProductStockStatus.out => AppColors.error,
        ProductStockStatus.low => AppColors.warning,
        _ => cs.onSurface,
      };
      cells.add(
        cell(
          i++,
          _fitEnd(numericText(
            formatGrouped(product.quantity),
            key: Key('product-qty-${product.id}'),
            style: AppTheme.numeric(theme, size: 15).copyWith(
              fontWeight: status == ProductStockStatus.active
                  ? FontWeight.w600
                  : FontWeight.w700,
              color: qtyColor,
            ),
          )),
        ),
      );
      if (showUnit) {
        cells.add(
          cell(
            i++,
            FittedBox(
              fit: BoxFit.scaleDown,
              child: _UnitPill(label: product.unit, loc: loc),
            ),
          ),
        );
      }
      if (showStatus) {
        cells.add(
          cell(
            i++,
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: _StatusBadge(status: status, loc: loc),
              ),
            ),
          ),
        );
      }
      if (showActions) {
        cells.add(
          cell(
            i,
            _rowActions(
              product,
              loc: loc,
              canUpdate: canUpdate,
              canArchive: canArchive,
            ),
          ),
        );
      }
      return cells;
    }

    return Column(
      key: const Key('products-table'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TableHeaderRow(
          testKey: const Key('products-table-header'),
          children: headerCells(),
        ),
        Expanded(
          child: ListView.separated(
            key: const Key('products-table-body'),
            itemCount: items.length,
            separatorBuilder: (_, _) => Container(
              height: 1,
              color: cs.outline.withValues(alpha: 0.10),
            ),
            itemBuilder: (context, index) {
              final product = items[index];
              return _HoverRow(
                key: ValueKey('product-row-${product.id}'),
                minHeight: 56,
                hoverColor: cs.primary.withValues(alpha: 0.07),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: dataCells(product),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  // ── Adaptive cards (narrow < 800) ────────────────────────────
  Widget _buildCardList(
    ThemeData theme,
    String loc,
    List<ProductModel> items, {
    required bool canUpdate,
    required bool canArchive,
  }) {
    final cs = theme.colorScheme;
    return ListView.builder(
      key: const Key('products-cards'),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final product = items[index];
        final status = productStockStatus(product);
        final qtyColor = switch (status) {
          ProductStockStatus.out => AppColors.error,
          ProductStockStatus.low => AppColors.warning,
          _ => cs.onSurface,
        };
        return Card(
          key: ValueKey('product-card-${product.id}'),
          margin: const EdgeInsets.only(bottom: 10),
          elevation: 0,
          color: cs.surfaceContainerHighest.withValues(alpha: 0.55),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: cs.outline.withValues(alpha: 0.18)),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_labelMode) ...[
                      Checkbox(
                        key: Key('product-label-check-${product.id}'),
                        value: _labelSelected.containsKey(product.id),
                        onChanged: (_) => _toggleLabel(product),
                        materialTapTargetSize:
                            MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                      const SizedBox(width: 8),
                    ],
                    _thumbnail(product, size: 44),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  product.name,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 6),
                              _StatusBadge(status: status, loc: loc),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            product.barcode ?? '—',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFamily: 'monospace',
                              color: cs.onSurface.withValues(alpha: 0.75),
                            ),
                          ),
                          const SizedBox(height: 6),
                          if (product.categoryName != null &&
                              product.categoryName!.isNotEmpty)
                            _CategoryPill(
                              label: product.categoryName!,
                              color: categoryPillColor(
                                product.categoryId ?? product.categoryName!,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: cs.surface.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: cs.outline.withValues(alpha: 0.12),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _metricBlock(
                          theme,
                          AppStrings.t('price', loc),
                          formatGrouped(product.price),
                          color: cs.onSurface,
                          strong: true,
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 28,
                        color: cs.outline.withValues(alpha: 0.18),
                      ),
                      Expanded(
                          child: _metricBlock(
                            theme,
                            AppStrings.t('quantity', loc),
                            formatGrouped(product.quantity),
                            color: qtyColor,
                            strong: true,
                          ),
                      ),
                      if (canUpdate) ...[
                        Container(
                          width: 1,
                          height: 28,
                          color: cs.outline.withValues(alpha: 0.18),
                        ),
                        Expanded(
                          child: _metricBlock(
                            theme,
                            AppStrings.t('cost', loc),
                            formatGrouped(product.cost),
                            color: cs.onSurface.withValues(alpha: 0.72),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _UnitPill(label: product.unit, loc: loc),
                    const Spacer(),
                    if (canUpdate || canArchive)
                      _rowActions(
                        product,
                        loc: loc,
                        canUpdate: canUpdate,
                        canArchive: canArchive,
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

  Widget _metricBlock(
    ThemeData theme,
    String label,
    String value, {
    required Color color,
    bool strong = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: 13,
            color: theme.colorScheme.onSurface.withValues(alpha: 0.72),
          ),
        ),
        const SizedBox(height: 2),
        numericText(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontSize: strong ? 15 : 14,
            fontWeight: strong ? FontWeight.w700 : FontWeight.w500,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _rowActions(
    ProductModel product, {
    required String loc,
    required bool canUpdate,
    required bool canArchive,
  }) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canUpdate)
          IconButton(
            key: Key('product-edit-${product.id}'),
            tooltip: AppStrings.t('edit', loc),
            icon: const Icon(Icons.edit_outlined, size: 18),
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              foregroundColor: theme.colorScheme.primary,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: 0.10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => showProductFormDialog(context, product: product),
          ),
        if (canArchive)
          IconButton(
            key: Key('product-archive-${product.id}'),
            tooltip: AppStrings.t('delete', loc),
            icon: const Icon(Icons.archive_outlined, size: 18),
            visualDensity: VisualDensity.compact,
            style: IconButton.styleFrom(
              foregroundColor: AppColors.error,
              backgroundColor: AppColors.error.withValues(alpha: 0.10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () => _confirmArchive(product),
          ),
      ],
    );
  }

  // ── D. Pagination footer (inside workspace) ──────────────────
  Widget _buildFooter(ThemeData theme, String loc, ProductsState state) {
    final cs = theme.colorScheme;
    const pageSizeOptions = [20, 40, 60, 100];
    final currentSize = pageSizeOptions.contains(state.query.pageSize)
        ? state.query.pageSize
        : 40;

    Widget pageButton({
      required Widget child,
      required bool selected,
      VoidCallback? onPressed,
      Key? key,
      String? tooltip,
    }) {
      final shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
      );
      if (selected) {
        return Tooltip(
          message: tooltip ?? '',
          child: Container(
            key: key,
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: cs.primary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: DefaultTextStyle(
              style: TextStyle(
                color: cs.onPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
              child: child,
            ),
          ),
        );
      }
      return IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: child,
        visualDensity: VisualDensity.compact,
        style: IconButton.styleFrom(
          foregroundColor: cs.onSurface.withValues(alpha: 0.75),
          backgroundColor: cs.surface,
          shape: shape,
          side: BorderSide(color: cs.outline.withValues(alpha: 0.25)),
        ),
      );
    }

    return Container(
      key: const Key('products-footer'),
      height: MediaQuery.sizeOf(context).width < 800 ? 44 : 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest.withValues(alpha: 0.45),
        border: Border(
          top: BorderSide(color: cs.outline.withValues(alpha: 0.2)),
        ),
      ),
      child: Row(
        children: [
          Flexible(
            child: Text(
              '${AppStrings.t('total', loc)}: ${state.total}',
              key: const Key('products-total'),
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: cs.onSurface.withValues(alpha: 0.75),
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (MediaQuery.sizeOf(context).width >= 800) ...[
            Tooltip(
              message: AppStrings.t('page_size', loc),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  key: const Key('products-page-size'),
                  value: currentSize,
                  isDense: true,
                  items: [
                    for (final size in pageSizeOptions)
                      DropdownMenuItem(
                        value: size,
                        child: Text(
                          '$size',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      ref.read(productsProvider.notifier).setPageSize(v);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          pageButton(
            key: const Key('products-prev-page'),
            selected: false,
            tooltip: AppStrings.t('prev', loc),
            onPressed: state.query.page > 1
                ? () => ref
                    .read(productsProvider.notifier)
                    .setPage(state.query.page - 1)
                : null,
            child: const Icon(Icons.chevron_left, size: 18),
          ),
          const SizedBox(width: 6),
          Text(
            '${state.query.page} / ${state.pages}',
            key: const Key('products-page-indicator'),
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 6),
          pageButton(
            key: const Key('products-next-page'),
            selected: false,
            tooltip: AppStrings.t('next', loc),
            onPressed: state.query.page < state.pages
                ? () => ref
                    .read(productsProvider.notifier)
                    .setPage(state.query.page + 1)
                : null,
            child: const Icon(Icons.chevron_right, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _thumbnail(ProductModel product, {double size = 40}) {
    final path = product.imagePath;
    final radius = BorderRadius.circular(8);
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.file(
          File(path),
          width: size,
          height: size,
          fit: BoxFit.cover,
          cacheWidth: (size * 2).round(),
        ),
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.95),
        border: Border.all(
          color: Theme.of(context)
              .colorScheme
              .outline
              .withValues(alpha: 0.15),
        ),
      ),
      child: Icon(
        Icons.inventory_2_outlined,
        size: size * 0.55,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4),
      ),
    );
  }

  void _confirmArchive(ProductModel product) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppStrings.t('delete', loc)),
        content: Text(AppStrings.t('archive_product_confirm', loc)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          TextButton(
            key: const Key('confirm-archive-product'),
            onPressed: () async {
              Navigator.pop(ctx);
              final error = await ref
                  .read(productsProvider.notifier)
                  .archiveProduct(product.id);
              if (error != null && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(error),
                    backgroundColor: Theme.of(context).colorScheme.error,
                  ),
                );
              } else if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(AppStrings.t('product_archived', loc)),
                  ),
                );
              }
            },
            child: Text(AppStrings.t('confirm', loc)),
          ),
        ],
      ),
    );
  }
}

/// Lightweight row with subtle hover feedback (no per-row animation packages).
class _HoverRow extends StatefulWidget {
  final Widget child;
  final double minHeight;
  final Color hoverColor;

  const _HoverRow({
    super.key,
    required this.child,
    this.minHeight = 56,
    required this.hoverColor,
  });

  @override
  State<_HoverRow> createState() => _HoverRowState();
}

class _HoverRowState extends State<_HoverRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        color: _hovered ? widget.hoverColor : Colors.transparent,
        constraints: BoxConstraints(minHeight: widget.minHeight),
        child: widget.child,
      ),
    );
  }
}

/// Semantic status badge: color tint + indicator + localized text.
class _StatusBadge extends StatelessWidget {
  final ProductStockStatus status;
  final String loc;

  const _StatusBadge({required this.status, required this.loc});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = productStatusColor(theme, status);
    final label = productStatusLabel(status, loc);
    return Container(
      key: Key('product-status-${status.name}'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

/// Deterministic category pill (subtle tinted background + border).
class _CategoryPill extends StatelessWidget {
  final String label;
  final Color color;
  final double fontSize;
  final bool compact;

  const _CategoryPill({
    required this.label,
    required this.color,
    this.fontSize = 12.5,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    // Foreground must stay legible on the 14% wash in every theme: the
    // helper darkens/lightens the same category hue until it clears
    // WCAG AA against the composited background (see AppColors).
    final foreground = AppColors.categoryPillForeground(
      color,
      Theme.of(context).brightness,
    );
    return Container(
      key: Key('product-category-pill-$label'),
      padding: compact
          ? const EdgeInsets.symmetric(horizontal: 6, vertical: 1)
          : const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        label,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w600,
          color: foreground,
        ),
      ),
    );
  }
}

/// A table figure that must never break across two lines: when the column
/// is tight it shrinks a hair instead of splitting "20.00%" mid-value.
Widget _fitEnd(Widget child) => FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerEnd,
      child: child,
    );

/// Compact unit pill / readable text.
class _UnitPill extends StatelessWidget {
  final String label;
  final String loc;

  const _UnitPill({required this.label, required this.loc});

  @override
  Widget build(BuildContext context) {
    // Units are backend enum values (piece/kg/…) — localized via unitLabel.
    final text = AppStrings.unitLabel(label, loc);
    final theme = Theme.of(context);
    return Container(
      key: Key('product-unit-$label'),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.2),
        ),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodySmall?.copyWith(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
        ),
      ),
    );
  }
}
