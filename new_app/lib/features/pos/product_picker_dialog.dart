// Quick product picker (Phase 17 §18).
//
// Keyboard-first selection for the POS: a searchable window listing
// name / barcode / SKU / selling price / stock for catalog products, plus
// the SALEABLE packs the main catalog already shows (localized "Pack"
// badge, selling price, component summary). It reuses the POS catalog
// providers — [posSearchProvider] for products and [posCatalogPacksProvider]
// for packs (the same debounced, paginated services the workspace catalog
// uses) — so there is no duplicate loading logic, no new endpoint and no
// second debounce: the pack list mirrors the SETTLED catalog query.
//
// The dialog only RESOLVES a choice: it returns a [ProductPickerSelection]
// carrying either the chosen [ProductModel] or [PackModel] and the caller
// (PosScreen) adds it through the canonical path — `_addProduct` for a
// product, `_addCatalogPack` for a pack (availability pre-flight + ONE
// charged pack line with `pack_id`). One add path per kind, one set of
// business rules; a pack never becomes a fake product.
//
// Interaction:
//   Arrow Down / Arrow Up  → move the highlighted row (products + packs)
//   Enter                  → add the highlighted row to the cart
//   Escape                 → close without adding (POS Escape stays safe)
//   Text                   → live search by name / barcode / SKU
//   Auto-focus on open     → the cashier can start typing immediately

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../packs/pack_models.dart';
import '../products/models.dart';
import 'pack_picker_dialog.dart' show packComponentLabel;
import 'pos_providers.dart';

/// What the cashier picked: exactly one of [product] / [pack] is set.
///
/// The dialog never adds anything to the cart itself — the caller routes a
/// product through its existing add path and a pack through the canonical
/// pack flow, so pack pricing / availability / backend validation are the
/// ones already in force everywhere else.
class ProductPickerSelection {
  final ProductModel? product;
  final PackModel? pack;

  const ProductPickerSelection.product(ProductModel this.product)
      : pack = null;
  const ProductPickerSelection.pack(PackModel this.pack) : product = null;

  bool get isPack => pack != null;
}

/// Opens the quick picker. Returns the chosen product or pack, or null when
/// the window was dismissed without a choice.
Future<ProductPickerSelection?> showProductPickerDialog(
  BuildContext context,
) {
  return showDialog<ProductPickerSelection?>(
    context: context,
    builder: (_) => const ProductPickerDialog(),
  );
}

/// Dedicated, searchable selection window (products + saleable packs).
class ProductPickerDialog extends ConsumerStatefulWidget {
  const ProductPickerDialog({super.key});

  @override
  ConsumerState<ProductPickerDialog> createState() =>
      _ProductPickerDialogState();
}

/// One rendered row of the combined result list.
class _PickerRow {
  final ProductModel? product;
  final PackModel? pack;

  const _PickerRow.product(ProductModel this.product) : pack = null;
  const _PickerRow.pack(PackModel this.pack) : product = null;

  /// Stable row identity across BOTH lists (products and packs are separate
  /// id spaces, so the kind is part of the key).
  String get rowKey => pack != null
      ? 'pack:${pack!.id}'
      : 'product:${product!.id}';

  ProductPickerSelection get selection => pack != null
      ? ProductPickerSelection.pack(pack!)
      : ProductPickerSelection.product(product!);
}

class _ProductPickerDialogState extends ConsumerState<ProductPickerDialog> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Row keys by [_PickerRow.rowKey] — the arrow keys scroll the highlighted
  /// row into view, which needs the row's own context.
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};

  /// Highlighted row. -1 = nothing highlighted (empty result set).
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Fresh search + complete lists on every open: the cashier must never
    // see a stale search, and the window covers the whole catalog rather
    // than the workspace's current page.
    Future.microtask(() {
      ref.read(posSearchProvider.notifier).setQuery('');
      ref.read(posSearchProvider.notifier).load();
      // Packs mirror the settled catalog query; resetting it here starts a
      // fresh load only when the term actually changed (or nothing has been
      // loaded yet) — never one request per keystroke.
      final packs = ref.read(posCatalogPacksProvider.notifier);
      packs.syncQuery('');
      final packState = ref.read(posCatalogPacksProvider);
      if (packState.items.isEmpty && !packState.loading) packs.load();
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    // A new query is a new result set: the first match becomes the
    // highlighted row (the documented "auto-select first match" rule).
    // The packs follow the settled query through [posCatalogPacksProvider]'s
    // listener on [posSearchProvider] — one debounce for both lists.
    _selectedIndex = 0;
    _rowKeys.clear();
    ref.read(posSearchProvider.notifier).setQuery(value);
  }

  /// Rows of the current combined result set (never stale across a query
  /// change). Products first, packs after — the catalog's own order.
  List<_PickerRow> get _rows {
    final products = ref.read(posSearchProvider).items;
    final packs = ref.read(posCatalogPacksProvider).items;
    return <_PickerRow>[
      for (final product in products) _PickerRow.product(product),
      for (final pack in packs) _PickerRow.pack(pack),
    ];
  }

  void _moveDown() {
    final rows = _rows;
    if (rows.isEmpty) return;
    setState(() {
      _selectedIndex =
          _selectedIndex < 0 ? 0 : (_selectedIndex + 1) % rows.length;
    });
    _revealSelected();
  }

  void _moveUp() {
    final rows = _rows;
    if (rows.isEmpty) return;
    setState(() {
      _selectedIndex = _selectedIndex < 0
          ? rows.length - 1
          : (_selectedIndex - 1) % rows.length;
    });
    _revealSelected();
  }

  /// Scrolls the highlighted row into view after the frame that builds it —
  /// works for long, scrollable result lists.
  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final rows = _rows;
      if (!mounted || _selectedIndex < 0 || _selectedIndex >= rows.length) {
        return;
      }
      final ctx = _rowKeys[rows[_selectedIndex].rowKey]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 120),
        );
      }
    });
  }

  /// Adds the highlighted row and closes. No highlighted row / no rows at
  /// all → nothing is added (Enter is simply inert).
  void _addSelected() {
    final rows = _rows;
    if (_selectedIndex < 0 || _selectedIndex >= rows.length) return;
    Navigator.pop(context, rows[_selectedIndex].selection);
  }

  /// Arrow keys move the highlight, Enter adds, Escape closes. The dialog's
  /// own route scope owns these keys, so the POS page bindings never see
  /// them while the window is open.
  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveDown();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveUp();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _addSelected();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final productState = ref.watch(posSearchProvider);
    final packState = ref.watch(posCatalogPacksProvider);

    final rows = <_PickerRow>[
      for (final product in productState.items) _PickerRow.product(product),
      for (final pack in packState.items) _PickerRow.pack(pack),
    ];

    // Keep the highlight valid whenever the combined result set changes
    // (debounced load, cleared search, error, late pack rows). An
    // out-of-range index must never be reachable by Enter.
    if (rows.isEmpty) {
      _selectedIndex = -1;
    } else if (_selectedIndex < 0 || _selectedIndex >= rows.length) {
      _selectedIndex = 0;
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): _moveDown,
        const SingleActivator(LogicalKeyboardKey.arrowUp): _moveUp,
        const SingleActivator(LogicalKeyboardKey.enter): _addSelected,
        const SingleActivator(LogicalKeyboardKey.numpadEnter): _addSelected,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.pop(context),
      },
      // No autofocus here: the search field owns the opening focus (the
      // cashier types immediately). This node only sits above it so the
      // arrow / Enter / Escape keys bubbling out of the field land here.
      child: Focus(
        onKeyEvent: _onKeyEvent,
        child: AlertDialog(
          key: const Key('product-picker-dialog'),
          title: Text(AppStrings.t('select_product', loc)),
          content: SizedBox(
            width: 520,
            height: 420,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  key: const Key('product-picker-search'),
                  controller: _search,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    hintText: AppStrings.t('search_products', loc),
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                  ),
                  onChanged: _onChanged,
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: _results(
                    loc,
                    theme,
                    rows,
                    productState,
                    packState,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const Key('product-picker-cancel'),
              onPressed: () => Navigator.pop(context),
              child: Text(AppStrings.t('cancel', loc)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _results(
    String loc,
    ThemeData theme,
    List<_PickerRow> rows,
    PosSearchState productState,
    PosCatalogPacksState packState,
  ) {
    if ((productState.loading || packState.loading) && rows.isEmpty) {
      return const Center(
        key: Key('product-picker-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (rows.isEmpty &&
        (productState.error != null || packState.error != null)) {
      // A failed pack fetch never hides working products (the provider keeps
      // its rows and the panel above lists products first): only an empty
      // combined set surfaces the failure, with a localized message.
      return Center(
        child: Text(
          productState.error ??
              AppStrings.t('network_error_retry', loc),
          key: const Key('product-picker-error'),
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (rows.isEmpty) {
      return Center(
        key: const Key('product-picker-empty'),
        child: Text(
          AppStrings.t('no_products_found', loc),
          textAlign: TextAlign.center,
        ),
      );
    }
    return ListView.builder(
      key: const Key('product-picker-list'),
      controller: _scroll,
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[index];
        final key = _rowKeys.putIfAbsent(row.rowKey, GlobalKey.new);
        return row.pack != null
            ? _packTile(context, theme, loc, row.pack!, index, key)
            : _productTile(context, theme, row.product!, index, key);
      },
    );
  }

  /// The existing product row — appearance and behavior unchanged.
  Widget _productTile(
    BuildContext context,
    ThemeData theme,
    ProductModel product,
    int index,
    GlobalKey key,
  ) {
    final out = (double.tryParse(product.quantity) ?? 0) <= 0;
    return ListTile(
      key: key,
      selected: index == _selectedIndex,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.10),
      onTap: () =>
          Navigator.pop(context, ProductPickerSelection.product(product)),
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(
        product.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        [
          if ((product.barcode ?? '').isNotEmpty) product.barcode!,
          if ((product.sku ?? '').isNotEmpty) product.sku!,
        ].join('  •  '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            _priceText(product.price),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          Text(
            '${product.quantity} ${product.unit}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: out ? theme.colorScheme.error : null,
              fontWeight: out ? FontWeight.w700 : null,
            ),
          ),
        ],
      ),
    );
  }

  /// A saleable pack: same row shape as a product, told apart by the
  /// localized badge and a component summary instead of a stock count.
  Widget _packTile(
    BuildContext context,
    ThemeData theme,
    String loc,
    PackModel pack,
    int index,
    GlobalKey key,
  ) {
    final summary = _packComponentsSummary(pack, loc);
    final subtitle = [
      if ((pack.barcode ?? '').isNotEmpty) pack.barcode!,
      if (summary.isNotEmpty) summary,
    ].join('  •  ');
    return ListTile(
      key: key,
      selected: index == _selectedIndex,
      selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.10),
      onTap: () =>
          Navigator.pop(context, ProductPickerSelection.pack(pack)),
      leading: const Icon(Icons.inventory_2_outlined),
      title: Row(
        children: [
          Expanded(
            child: Text(
              pack.name,
              key: Key('product-picker-pack-name-${pack.id}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          _packBadge(loc, theme, pack),
        ],
      ),
      subtitle: subtitle.isEmpty
          ? null
          : Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
      trailing: Text(
        _priceText(pack.price),
        style: theme.textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  /// The ONE localized pack label (ar/fr/en) — identical to the badge the
  /// main POS catalog draws on a pack tile.
  Widget _packBadge(String loc, ThemeData theme, PackModel pack) {
    return Container(
      key: Key('product-picker-pack-badge-${pack.id}'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        AppStrings.t('pack', loc),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelSmall?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onTertiaryContainer,
        ),
      ),
    );
  }

  /// Component names from the pack's list row ("Bread · Milk +2"), or the
  /// component count when the response carries no component rows.
  String _packComponentsSummary(PackModel pack, String loc) {
    final labels = <String>[];
    for (final component in pack.components) {
      final label = packComponentLabel(
        productName: component.productName,
        unitName: component.sellingUnitName,
        unitQuantity: component.unitQuantity,
        sellingUnitId: component.sellingUnitId,
        multiplierText: component.sellingUnitMultiplier,
      );
      if (!labels.contains(label)) labels.add(label);
    }
    if (labels.isEmpty) {
      return pack.componentsCount <= 0
          ? ''
          : '${pack.componentsCount} ${AppStrings.t('components', loc)}';
    }
    return '${labels.take(3).join(' · ')}'
        '${labels.length > 3 ? ' +${labels.length - 3}' : ''}';
  }

  /// Money as the catalog shows it: whole amounts without decimals, other
  /// amounts with two — never a binary-float artefact.
  String _priceText(String raw) {
    final price = double.tryParse(raw);
    if (price == null) return raw;
    return price == price.roundToDouble()
        ? price.toInt().toString()
        : price.toStringAsFixed(2);
  }
}
