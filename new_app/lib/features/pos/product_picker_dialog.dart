// Quick product picker (Phase 17 §18).
//
// Keyboard-first product selection for the POS: a searchable window listing
// name / barcode / SKU / selling price / stock, driven entirely from the
// keyboard. It reuses the POS catalog provider ([posSearchProvider]) — the
// same debounced, paginated service the workspace search uses — so there is
// no duplicate loading logic, no new endpoint and no second product query.
//
// The dialog only RESOLVES a product: it returns the chosen [ProductModel]
// and the caller (PosScreen) adds it through the canonical `_addProduct`
// path, which runs the full decision tree (variant / selling-unit pickers,
// stock guard, wholesale / promotion, merge-increment). One add path, one
// set of business rules.
//
// Interaction:
//   Arrow Down / Arrow Up  → move the highlighted row
//   Enter                  → add the highlighted product to the cart
//   Escape                 → close without adding (POS Escape stays safe)
//   Text                   → live search by name / barcode / SKU
//   Auto-focus on open     → the cashier can start typing immediately

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../products/models.dart';
import 'pos_providers.dart';

/// Opens the quick product picker. Returns the product the cashier chose,
/// or null when the window was dismissed without a choice.
Future<ProductModel?> showProductPickerDialog(BuildContext context) {
  return showDialog<ProductModel?>(
    context: context,
    builder: (_) => const ProductPickerDialog(),
  );
}

/// Dedicated, searchable product-selection window.
class ProductPickerDialog extends ConsumerStatefulWidget {
  const ProductPickerDialog({super.key});

  @override
  ConsumerState<ProductPickerDialog> createState() =>
      _ProductPickerDialogState();
}

class _ProductPickerDialogState extends ConsumerState<ProductPickerDialog> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  /// Row keys by product id — the arrow keys scroll the highlighted row into
  /// view, which needs the row's own context.
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};

  /// Highlighted row. -1 = nothing highlighted (empty result set).
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    // Fresh, complete catalog + cleared query on every open: the cashier
    // must never see a stale search, and the window covers the whole
    // catalog rather than the workspace's current page.
    Future.microtask(() {
      ref.read(posSearchProvider.notifier).setQuery('');
      ref.read(posSearchProvider.notifier).load();
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
    _selectedIndex = 0;
    _rowKeys.clear();
    ref.read(posSearchProvider.notifier).setQuery(value);
  }

  /// Rows of the current result set (never stale across a query change).
  List<ProductModel> get _items => ref.read(posSearchProvider).items;

  void _moveDown() {
    final items = _items;
    if (items.isEmpty) return;
    setState(() {
      _selectedIndex = _selectedIndex < 0
          ? 0
          : (_selectedIndex + 1) % items.length;
    });
    _revealSelected();
  }

  void _moveUp() {
    final items = _items;
    if (items.isEmpty) return;
    setState(() {
      _selectedIndex = _selectedIndex < 0
          ? items.length - 1
          : (_selectedIndex - 1) % items.length;
    });
    _revealSelected();
  }

  /// Scrolls the highlighted row into view after the frame that builds it —
  /// works for long, scrollable result lists.
  void _revealSelected() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final items = _items;
      if (!mounted || _selectedIndex < 0 || _selectedIndex >= items.length) {
        return;
      }
      final ctx = _rowKeys[items[_selectedIndex].id]?.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 120),
        );
      }
    });
  }

  /// Adds the highlighted product and closes. No highlighted row / no rows
  /// at all → nothing is added (Enter is simply inert).
  void _addSelected() {
    final items = _items;
    if (_selectedIndex < 0 || _selectedIndex >= items.length) return;
    Navigator.pop(context, items[_selectedIndex]);
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
    final state = ref.watch(posSearchProvider);

    // Keep the highlight valid whenever the result set changes (debounced
    // load, cleared search, error). An out-of-range index must never be
    // reachable by Enter.
    if (state.items.isEmpty) {
      _selectedIndex = -1;
    } else if (_selectedIndex < 0 || _selectedIndex >= state.items.length) {
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
                Expanded(child: _results(loc, theme, state)),
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

  Widget _results(String loc, ThemeData theme, PosSearchState state) {
    if (state.loading && state.items.isEmpty) {
      return const Center(
        key: Key('product-picker-loading'),
        child: CircularProgressIndicator(),
      );
    }
    if (state.error != null && state.items.isEmpty) {
      return Center(
        child: Text(
          state.error!,
          textAlign: TextAlign.center,
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (state.items.isEmpty) {
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
      itemCount: state.items.length,
      itemBuilder: (context, index) {
        final product = state.items[index];
        final key = _rowKeys.putIfAbsent(product.id, GlobalKey.new);
        final price = double.tryParse(product.price);
        final priceText = price == null
            ? product.price
            : (price == price.roundToDouble()
                ? price.toInt().toString()
                : price.toStringAsFixed(2));
        final out = (double.tryParse(product.quantity) ?? 0) <= 0;
        return ListTile(
          key: key,
          selected: index == _selectedIndex,
          selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.10),
          onTap: () => Navigator.pop(context, product),
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
                priceText,
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
      },
    );
  }
}
