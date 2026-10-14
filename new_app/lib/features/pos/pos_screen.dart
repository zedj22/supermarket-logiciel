// POS / Checkout screen (Phase 8 Step 3).
//
// Responsive layout (full window width inside nav shell):
//   WIDE   >= 1100 : favorites/search sidebar + product grid + cart panel
//   MEDIUM 800–1099: products + cart side-by-side
//   NARROW < 800   : stacked search/products + cart (drawer cart toggle)
// Cart width (UX FIX #8): 480 (≥1400) / 440 (1100–1399) / 400 (800–1099)
// floors 420 wide & 380 medium; narrow keeps full-width drawer.
//
// Add-to-cart decision (no choice = no dialog):
//   empty successful variants/units → no choice → direct add (qty 1, price)
//   active choices                 → variant and/or selling-unit pickers
//   single variant                 → auto-select (no dialog)
//   API error on lookup            → NO direct add; localized error + retry;
//                                    product stays out of cart until lookup OK
//
// Catalog view: grid (default) | list — persisted in SharedPreferences
// (`pos_catalog_view_mode`). Toggle never reloads the product catalog.
//
// Keyboard: F1 POS / F2 Products / F3 (Ctrl+N) add product at the shell
// level, F4 (Ctrl+F) search, F5 refresh, Enter add/scan, F6 customer,
// F7 invoice discount, SPACE payment (legacy F8 removed), F9 hold,
// F10 held sales, F11 history, F12 clear (confirm), + add one unit /
// - remove one unit / * enter a new quantity for the last active cart
// line, Escape clears search (or hands focus back to the workspace) —
// never the cart. F1–F5/Ctrl+N live one level up in the nav shell so the
// map is the same on every screen (lib/core/app_shortcuts.dart); the local
// bindings below cover everything POS owns.
//
// `+`, `-`, `*` (UX FIX #12 / Phase 8 FIX #1–#3): claimed while the POS
// search field or a cart quantity field has focus (typing them there
// acts on the active line, never inserts the char); any other text field
// keeps normal typing. Quantity typing accepts expressions (`10*24` →
// 240); every mutation is parsed, stock-validated and applied through
// pos_quantity.dart (one shared rule).
//
// Add → focus (Phase 8 FIX #1): a successful add (new or merged line)
// makes that line active and moves the keyboard focus to its quantity
// field, so `+` keeps working without the mouse.
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/amount_entry.dart';
import '../../core/colors.dart';
import '../../core/keyboard.dart';
import '../../core/shortcuts.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../clients/clients_providers.dart';
import '../clients/customer_models.dart';
import '../packs/pack_models.dart';
import '../products/models.dart';
import '../products/quantity_dialog.dart';
import '../products/selling_unit_picker.dart';
import '../products/variant_picker.dart';
import '../returns/return_providers.dart';
import '../settings/settings_provider.dart';
import '../shell/shortcuts_help_dialog.dart';
import 'customer_picker_dialog.dart';
import 'holds_dialog.dart';
import 'invoice_discount_dialog.dart';
import 'pack_picker_dialog.dart';
import 'payment_dialog.dart';
import 'pos_error_message.dart';
import 'pos_layout.dart';
import 'pos_models.dart';
import 'pos_providers.dart';
import 'pos_quantity.dart';
import 'pos_qty_shortcuts.dart';
import 'pos_return_lines.dart';
import 'pos_toast.dart';
import 'price_override_dialog.dart';
import 'print_document.dart';
import 'print_preview_dialog.dart';
import 'print_service.dart';
import 'qty_multiplier_dialog.dart';
import 'sale_history_dialog.dart';

// Layout mode + adaptive cart panel width live in pos_layout.dart (the
// compact toast needs them too); re-exported so `import 'pos_screen.dart'`
// keeps providing them.
export 'pos_layout.dart';

/// Result of a POS add-decision lookup: success with items (may be empty)
/// OR failure with the original [error] object — failure is never treated
/// as empty, and the raw error is localized only when it is shown.
class _ChoicesLookup<T> {
  final List<T> items;
  final Object? error;

  const _ChoicesLookup.ok(this.items) : error = null;
  const _ChoicesLookup.fail(this.error) : items = const [];

  bool get failed => error != null;
}

class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final FocusNode _focusNode = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();

  /// Key of the cart line whose quantity field should take keyboard focus
  /// — set right after a successful add (Phase 8 FIX #1), consumed by the
  /// matching [_CartLineTile] and cleared again at the end of that frame.
  final ValueNotifier<String?> _qtyFocusRequest = ValueNotifier<String?>(null);
  bool _cartDrawerOpen = false;

  /// Last POS return-mode failure (localized message + raw backend
  /// detail) — shown inline in the return banner and as a toast. Kept
  /// out of the cart provider on purpose: checkout's `lastError` listener
  /// would otherwise double-toast it, and the return flow already has its
  /// own banner surface.
  PosApiError? _returnError;

  /// This screen's page-level shortcut hooks, published to the nav shell.
  late final PageShortcuts _pageShortcuts;

  @override
  void initState() {
    super.initState();
    // Phase 17 §18 — the shell's F4 / Ctrl+F / F5 act on the page that is
    // actually on screen. Register this screen's hooks; never touches the
    // cart, so a page-level refresh can never destroy a sale in progress.
    _pageShortcuts = PageShortcuts(
      focusSearch: _focusSearch,
      refresh: _refreshWorkspace,
    );
    PageShortcutsRegistry.current = _pageShortcuts;
    Future.microtask(() {
      ref.read(posSearchProvider.notifier).load();
      ref.read(favoritesProvider.notifier).load();
      ref.read(holdsProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    if (identical(PageShortcutsRegistry.current, _pageShortcuts)) {
      PageShortcutsRegistry.current = null;
    }
    _focusNode.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _qtyFocusRequest.dispose();
    super.dispose();
  }

  /// F4 / Ctrl+F — move the keyboard to the barcode/search field.
  void _focusSearch() {
    if (!mounted) return;
    _searchFocusNode.requestFocus();
  }

  /// F5 — reload the read-only POS lists. Deliberately never touches the
  /// cart: a refresh must not clear, merge or reset a sale in progress.
  void _refreshWorkspace() {
    if (!mounted) return;
    ref.read(posSearchProvider.notifier).load();
    ref.read(favoritesProvider.notifier).load();
    ref.read(holdsProvider.notifier).load();
  }

  /// Escape — the context-safe clear. With text in the search box it only
  /// empties the box; when the box is already empty it hands focus back to
  /// the POS workspace node (so SPACE / F-keys are reachable again).
  /// It never, under any circumstance, clears the cart — that stays behind
  /// F12 + its confirm dialog.
  void _handleEscape() {
    if (!mounted) return;
    if (_searchController.text.isNotEmpty) {
      _searchController.clear();
      ref.read(posSearchProvider.notifier).clear();
      ref.read(posSearchProvider.notifier).load();
      _searchFocusNode.requestFocus();
      return;
    }
    _focusNode.requestFocus();
  }

  /// Phase 8 FIX #1 — a successful add leaves the cart keyboard-first: the
  /// line just added (or the line it merged into) becomes ACTIVE and its
  /// quantity field takes focus, so the cashier can keep pressing `+`
  /// without reaching for the mouse.
  ///
  /// The request is dropped at the end of the frame when no tile claimed it
  /// (line off-screen, cart hidden) — focus is never stolen later by a
  /// stale request.
  void _requestQtyFocus(String key) {
    _qtyFocusRequest.value = key;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_qtyFocusRequest.value == key) _qtyFocusRequest.value = null;
    });
  }

  Future<void> _handleShortcut(LogicalKeyboardKey key) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final cart = ref.read(posCartProvider);
    final canDiscount = ref.read(hasPermissionProvider('pos_discount'));

    if (key == LogicalKeyboardKey.f6) {
      final customer = await showCustomerPickerDialog(context);
      if (customer != null) {
        ref.read(posCartProvider.notifier).setCustomer(customer);
      }
      if (mounted) _searchFocusNode.requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.f7) {
      if (cart.isEmpty) return;
      if (!canDiscount) {
        showPosToast(
          context,
          message: AppStrings.t('permission_discount', loc),
          kind: PosToastKind.warning,
        );
        return;
      }
      await showInvoiceDiscountDialog(context);
      if (mounted) _searchFocusNode.requestFocus();
      return;
    }
    // Phase 17 §18 — SPACE is the payment shortcut; the legacy F8 binding is
    // gone. The activator refuses the key while ANY other text field has
    // primary focus (search, dialogs, pickers — the cashier keeps typing),
    // so this branch runs with the POS workspace active or while a cart
    // quantity field is focused; the space character never reaches that
    // quantity field, so its value cannot be touched by the pay key. The
    // empty-cart toast comes from the same `_openPayment()` the PAY button
    // uses — one flow, one message.
    if (key == LogicalKeyboardKey.space) {
      await _openPayment();
      if (mounted) _searchFocusNode.requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.f9) {
      // Return mode owns the cart: saving it as a hold would silently
      // shelve the pending return (the hold restore is a SALE snapshot).
      if (cart.isEmpty || cart.returnMode) return;
      final err = await ref.read(posCartProvider.notifier).createHold();
      if (err != null && mounted) {
        showPosToast(context, message: err, kind: PosToastKind.error);
      } else if (mounted) {
        showPosToast(
          context,
          message: AppStrings.t('hold_saved', loc),
          kind: PosToastKind.success,
        );
        _searchController.clear();
        ref.read(posSearchProvider.notifier).clear();
        ref.read(posSearchProvider.notifier).load();
        ref.read(holdsProvider.notifier).load();
      }
      return;
    }
    if (key == LogicalKeyboardKey.f10) {
      await showHoldsDialog(context);
      if (mounted) _searchFocusNode.requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.f11) {
      await showSaleHistoryDialog(context);
      if (mounted) _searchFocusNode.requestFocus();
      return;
    }
    if (key == LogicalKeyboardKey.f12) {
      if (cart.isEmpty) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(AppStrings.t('clear_cart', loc)),
          content: Text(AppStrings.t('clear_cart_confirm', loc)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(AppStrings.t('cancel', loc)),
            ),
            ElevatedButton(
              key: const Key('clear-cart-confirm'),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(AppStrings.t('clear_cart', loc)),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        ref.read(posCartProvider.notifier).clearCart();
        _searchController.clear();
        ref.read(posSearchProvider.notifier).clear();
      }
      if (mounted) _searchFocusNode.requestFocus();
      return;
    }
  }

  /// One toast for every rejected quantity mutation: [isStockError]
  /// selects the stock key, otherwise the invalid-input key.
  /// (Single funnel — UX FIX #12, FIX #6.)
  void _showQtyError(String message, bool isStockError) {
    if (!mounted) return;
    showPosToast(
      context,
      message: message,
      kind: PosToastKind.error,
      key: Key(isStockError ? 'pos-qty-stock-error' : 'pos-qty-invalid'),
    );
  }

  /// `+` — add exactly one unit to the last active cart line.
  /// Parse + cross-line stock guard live in pos_quantity.dart (shared
  /// with the cart buttons, the qty field and the `*` dialog).
  void _incrementActiveLine() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final cart = ref.read(posCartProvider);
    final line = cart.lastActiveLine;
    if (line == null) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('cart_empty', loc),
        kind: PosToastKind.info,
        key: const Key('pos-qty-empty-cart'),
      );
      return;
    }
    applyLineQuantity(
      notifier: ref.read(posCartProvider.notifier),
      cart: cart,
      line: line,
      // Exact +1 (scaled math) — 2.7 → 3.7, never 3.6999999999999996.
      rawInput: posQuantityAdd(line.quantity, 1),
      loc: loc,
      onError: _showQtyError,
    );
  }

  /// `-` — remove exactly one unit from the last active cart line.
  ///
  /// Same rule as the cart line's decrease button: the step comes from the
  /// shared [_qtyStepText] (a quantity of 1 stays 1, silently — the button
  /// is disabled there) and is written through the SAME validating funnel
  /// ([applyLineQuantity]) as every other mutation path.
  void _decrementActiveLine() {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final cart = ref.read(posCartProvider);
    final line = cart.lastActiveLine;
    if (line == null) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('cart_empty', loc),
        kind: PosToastKind.info,
        key: const Key('pos-qty-empty-cart'),
      );
      return;
    }
    final text = _qtyStepText(line.quantity, -1);
    if (text == null) return; // minimum reached — button would be disabled
    applyLineQuantity(
      notifier: ref.read(posCartProvider.notifier),
      cart: cart,
      line: line,
      // Exact −1 (scaled math) — 3.7 → 2.7, never 2.6999999999999997.
      rawInput: text,
      loc: loc,
      onError: _showQtyError,
    );
  }

  /// `*` — open the quantity INPUT dialog for the last active line.
  ///
  /// The dialog returns the number the cashier typed; that value REPLACES
  /// the line quantity (24, `*`, 3 → 3 — it is never multiplied). Written
  /// through [applyLineQuantity], exactly like `+`, `-`, the cart buttons
  /// and the qty field, so the shared stock guard and totals stay intact.
  Future<void> _setActiveLineQuantity() async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final line = ref.read(posCartProvider).lastActiveLine;
    if (line == null) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('cart_empty', loc),
        kind: PosToastKind.info,
        key: const Key('pos-qty-empty-cart'),
      );
      return;
    }
    if (!mounted) return;
    final next = await showQuantityInputDialog(
      context,
      productName: line.name,
      currentQuantity: line.quantity,
      availableStock: line.availableStock,
      unitMultiplier: line.unitMultiplier,
    );
    if (next == null || !mounted) return;
    // The dialog validated with the single-line rule; the cart-wide rule
    // (other lines of the same stock bucket) is applied here — shared.
    applyLineQuantity(
      notifier: ref.read(posCartProvider.notifier),
      cart: ref.read(posCartProvider),
      line: line,
      rawInput: next,
      loc: loc,
      onError: _showQtyError,
    );
  }

  /// Cart qty field / line +/- buttons: the ONE validating mutation path
  /// for an existing line (expression parsing + stock guard + toast).
  bool _updateLineQty(String key, String rawInput) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final cart = ref.read(posCartProvider);
    CartLine? line;
    for (final candidate in cart.lines) {
      if (candidate.key == key) {
        line = candidate;
        break;
      }
    }
    if (line == null) return false;
    return applyLineQuantity(
      notifier: ref.read(posCartProvider.notifier),
      cart: cart,
      line: line,
      rawInput: rawInput,
      loc: loc,
      onError: _showQtyError,
    );
  }

  /// Enter in search: if barcode-shaped exact match, add; else load results.
  Future<void> _submitSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) return;
    final products = ref.read(posSearchProvider).items;
    ProductModel? exact;
    for (final p in products) {
      if (p.barcode == query || p.name == query || p.sku == query) {
        exact = p;
        break;
      }
    }
    if (exact == null && products.isNotEmpty) {
      exact = products.first;
    }
    if (exact != null) {
      await _addProduct(exact);
    } else {
      await ref.read(posSearchProvider.notifier).load();
    }
  }

  Future<void> _addProduct(ProductModel product) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (product.isArchived) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('archive_product_pos', loc),
        kind: PosToastKind.warning,
      );
      return;
    }
    // FIX #6/#7: base stock ≤ 0 → never open pickers, never mutate cart.
    if ((double.tryParse(product.quantity) ?? 0) <= 0) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('cannot_add_out_of_stock', loc),
        kind: PosToastKind.error,
        key: const Key('pos-out-of-stock-error'),
      );
      return;
    }

    // Fetch variants once — only for this product (minimal lookup).
    // Failure ≠ empty: never direct-add when the decision lookup failed.
    final variantLookup = await _fetchActiveVariants(product.id);
    if (variantLookup.error != null) {
      _showLookupError(product, variantLookup.error!);
      return;
    }
    final variants = variantLookup.items;
    VariantModel? variant;
    if (variants.length == 1) {
      // Single valid choice — no dialog.
      variant = variants.first;
    } else if (variants.length > 1) {
      if (!mounted) return;
      variant = await showVariantPicker(
        context,
        productId: product.id,
        productPrice: product.price,
        // Phase 18 — display only (a variant without its own price falls
        // back to the retail card, which may show the promotion price).
        productPromoPrice: product.promotion?.price,
      );
      // Restore barcode/search focus after dialog closes (keyboard-first).
      if (mounted) _searchFocusNode.requestFocus();
      if (variant == null) return; // cancelled
    }

    // FIX #8: selected variant with stock ≤ 0 → block before unit picker.
    if (variant != null && (double.tryParse(variant.quantity) ?? 0) <= 0) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t('cannot_add_out_of_stock', loc),
        kind: PosToastKind.error,
        key: const Key('pos-out-of-stock-error'),
      );
      return;
    }

    // Fetch selling units once for this product to decide dialog vs direct.
    final unitLookup = await _fetchActiveSellingUnits(product.id);
    if (unitLookup.error != null) {
      _showLookupError(product, unitLookup.error!);
      return;
    }
    final units = unitLookup.items;
    final price = variant?.price ?? product.price;
    final stock = variant?.quantity ?? product.quantity;
    final name = variant == null
        ? product.name
        : '${product.name} · ${variant.name}';
    // Phase 18 promotion — the gate mirrors the backend's
    // `line_uses_product_retail` (app/services/sale.py): a promotion may
    // only discount a line whose price comes from `products.price`. An
    // explicit variant price (or a custom selling unit below) is never
    // promoted. [promoPrice] is the SERVER-computed effective promo unit
    // price already attached to the product response.
    final promoPrice = price == product.price
        ? product.promotion?.price
        : null;

    if (units.isEmpty) {
      // Weight/length base product with no configured selling units — the
      // cashier must say HOW MUCH (kg/g/m or DA): show the entry dialog
      // instead of silently adding qty 1 (non-weight units keep the direct
      // add below; cancelling the dialog adds nothing).
      if (isAmountEntryUnit(product.unit)) {
        if (!mounted) return;
        final qty = await showQuantityDialog(
          context,
          unit: SellingUnitModel(
            id: kSellingUnitBaseKey,
            productId: product.id,
            name: product.unit,
            unitType: product.unit,
            multiplier: '1',
            isBaseUnit: true,
            sellingPrice: promoPrice ?? price,
            effectivePrice: promoPrice ?? price,
            availableBaseQty: stock,
            availableSellingQty: stock,
          ),
          productQuantity: stock,
          productUnit: product.unit,
          unitPrice: promoPrice ?? price,
        );
        // Restore barcode/search focus after dialog closes (keyboard-first).
        if (mounted) _searchFocusNode.requestFocus();
        if (qty == null) return; // cancelled — never force a qty-1 line
        _addCartLine(
          productId: product.id,
          variantId: variant?.id,
          name: name,
          variantName: variant?.name,
          unitName: product.unit,
          quantity: qty,
          // Phase 18 — the promotion price replaces retail on this line;
          // retailPrice below still stamps the ORIGINAL retail price.
          unitPrice: promoPrice ?? price,
          barcode: product.barcode,
          productUnit: product.unit,
          availableStock: stock,
          baseUnitPrice: price,
          // Phase 17 pricing — wholesale snapshot (see [_retailPriceOf]).
          retailPrice: _retailPriceOf(product, price),
          wholesalePrice: product.wholesalePrice,
          wholesaleMinQty: product.wholesaleMinQty,
          promotionPrice: promoPrice,
        );
        return;
      }
      // No selling-unit choice → direct add (qty 1, base unit, catalog price).
      _addCartLine(
        productId: product.id,
        variantId: variant?.id,
        name: name,
        variantName: variant?.name,
        unitName: product.unit,
        quantity: '1',
        // Phase 18 — the promotion price replaces retail on this line;
        // retailPrice below still stamps the ORIGINAL retail price.
        unitPrice: promoPrice ?? price,
        barcode: product.barcode,
        productUnit: product.unit,
        availableStock: stock,
        baseUnitPrice: price,
        // Phase 17 pricing — wholesale snapshot (see [_retailPriceOf]).
        retailPrice: _retailPriceOf(product, price),
        wholesalePrice: product.wholesalePrice,
        wholesaleMinQty: product.wholesaleMinQty,
        promotionPrice: promoPrice,
      );
      return;
    }

    // Selling-unit choices exist → picker (user decides unit + qty).
    // UX FIX #4: base unit is always an option inside the picker
    // (sellingUnitId = null on base selection).
    if (!mounted) return;
    final pick = await showSellingUnitPicker(
      context,
      productId: product.id,
      productQuantity: stock,
      productUnit: product.unit,
      productPrice: price,
      // Phase 18 — display only: the base-unit card shows the promo price
      // while the pick result keeps the RETAIL price (the promotion is
      // applied here, where the retail-branch gate can be evaluated).
      productPromoPrice: product.promotion?.price,
    );
    // Restore barcode/search focus after dialog closes (keyboard-first).
    if (mounted) _searchFocusNode.requestFocus();
    if (pick == null) return;
    // Phase 18 gate — promotion only when the BASE unit was chosen with no
    // explicit selling price and the line prices off `products.price`.
    final pickPromoPrice = pick.isBaseUnit &&
            !pick.hasExplicitPrice &&
            pick.unitPrice == product.price
        ? product.promotion?.price
        : null;
    _addCartLine(
      productId: product.id,
      variantId: variant?.id,
      sellingUnitId: pick.sellingUnitId,
      name: name,
      variantName: variant?.name,
      unitName: pick.isBaseUnit ? product.unit : pick.unitName,
      quantity: pick.quantity,
      unitPrice: pickPromoPrice ?? pick.unitPrice,
      barcode: product.barcode,
      productUnit: product.unit,
      availableStock: stock,
      // Informational snapshot — totals always use unitPrice above.
      baseUnitPrice: price,
      unitMultiplier: pick.isBaseUnit ? null : pick.unitMultiplier,
      // Phase 17 pricing — wholesale snapshot (see [_retailPriceOf]).
      // Wholesale belongs ONLY to the product's base unit: a custom selling
      // unit (Box/Carton/…) never gets the snapshot, so it can never become
      // wholesale-eligible however high the multiplier drives the quantity.
      retailPrice: pick.isBaseUnit
          ? _retailPriceOf(product, pick.unitPrice)
          : null,
      wholesalePrice: product.wholesalePrice,
      wholesaleMinQty: product.wholesaleMinQty,
      promotionPrice: pickPromoPrice,
    );
  }

  /// Pack flow (Phase 10): pick an active pack, pre-flight its component
  /// stock, then place ONE charged pack line in the cart. The component
  /// explosion and the inventory deduction happen on the backend at
  /// checkout — the cart only ever holds the pack itself.
  Future<void> _addPack() async {
    final PackPickResult? pick = await showPackPickerDialog(context);
    if (pick == null || !mounted) return;
    // Restore barcode/search focus after the dialog (keyboard-first).
    _searchFocusNode.requestFocus();
    _addCartLine(
      packId: pick.packId,
      name: pick.name,
      quantity: pick.quantity,
      unitPrice: pick.price,
      barcode: pick.barcode,
      productUnit: 'pack',
      unitName: 'pack',
      // Client-side guard: a pack can never be sold more often than its
      // components currently allow (backend re-checks at checkout).
      availableStock: pick.maxPackQuantity,
      componentsSummary: pick.componentsSummary,
    );
  }

  /// Product stays out of the cart until the required lookup succeeds.
  /// Localized headline + backend detail (UX FIX #12 — FIX #5).
  void _showLookupError(ProductModel product, Object error) {
    if (!mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final failure = posApiError(error, loc);
    showPosToast(
      context,
      message: failure.message,
      detail: failure.detail,
      messageKey: const Key('pos-lookup-error-message'),
      kind: PosToastKind.error,
      key: const Key('pos-lookup-error'),
      actionLabel: AppStrings.t('retry', loc),
      actionKey: const Key('pos-lookup-error-retry'),
      onAction: () => _addProduct(product),
    );
  }

  /// Minimal lookups for the add decision — never reloads the catalog list.
  /// [error] is null only on a successful HTTP response (items may be empty).
  Future<_ChoicesLookup<VariantModel>> _fetchActiveVariants(
    String productId,
  ) async {
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        '/api/v1/products/$productId/variants',
        queryParameters: {'page_size': 50},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => VariantModel.fromJson(e as Map<String, dynamic>))
          .where((v) => !v.isArchived)
          .toList();
      return _ChoicesLookup.ok(items);
    } catch (e) {
      return _ChoicesLookup.fail(e);
    }
  }

  Future<_ChoicesLookup<SellingUnitModel>> _fetchActiveSellingUnits(
    String productId,
  ) async {
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        '/api/v1/products/$productId/selling-units',
        queryParameters: {'include_archived': false},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => SellingUnitModel.fromJson(e as Map<String, dynamic>))
          .where((u) => !u.isArchived)
          .toList();
      return _ChoicesLookup.ok(items);
    } catch (e) {
      return _ChoicesLookup.fail(e);
    }
  }

  /// Phase 17/18 pricing — the retail price to stamp on a line, or null
  /// when the line must NEVER be wholesale- or promotion-priced.
  ///
  /// [linePrice] is the CATALOG price the line's price came from (the
  /// pre-promotion price passed by [_addProduct]). Wholesale/promotion may
  /// only touch a price that came from `products.price` — the precedence
  /// in `app/domain/wholesale.py` is explicit selling-unit price >
  /// explicit variant price > product retail price > pack price.
  /// Stamping the snapshot only when it equals [linePrice] keeps the
  /// invariant `CartLine.retailPrice` == the catalog price the line was
  /// priced from at construction (with Phase 18, `unitPrice` may be the
  /// PROMOTION price while `retailPrice` keeps the original retail), so
  /// re-pricing a quantity change can only switch retail → promotion →
  /// wholesale and can never rewrite a variant / selling-unit / pack price.
  ///
  /// Callers additionally pass null for a CUSTOM selling-unit line (see the
  /// picker call site): even when that unit falls back to the retail price,
  /// its multiplier is an inventory conversion, never a wholesale
  /// qualifier — the snapshot is reserved for the product's base unit.
  static String? _retailPriceOf(ProductModel product, String linePrice) =>
      linePrice == product.price ? product.price : null;

  void _addCartLine({
    String? productId,
    String? packId,
    String? variantId,
    String? sellingUnitId,
    required String name,
    String? variantName,
    String? unitName,
    required String quantity,
    required String unitPrice,
    String? barcode,
    String productUnit = 'piece',
    String? availableStock,
    String? baseUnitPrice,
    String? unitMultiplier,
    String? componentsSummary,
    // Phase 17 pricing — wholesale snapshot of the retail branch this line
    // was priced off (null everywhere wholesale must never apply: packs,
    // explicit variant / selling-unit prices). See CartLine.priceFor.
    String? retailPrice,
    String? wholesalePrice,
    String? wholesaleMinQty,
    // Phase 18 promotion — effective promo unit price snapshot (null when
    // the line is not promoted). Set together with retailPrice, which then
    // keeps the ORIGINAL retail price.
    String? promotionPrice,
  }) {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    // Merge + stock guard in one place (UX FIX #12 — FIX #6): adding a
    // product the cart already holds is checked against the merged qty.
    // Both outcomes share the same line key: a new line, or the existing
    // line the quantity was merged into.
    final line = CartLine(
      productId: productId,
      packId: packId,
      variantId: variantId,
      sellingUnitId: sellingUnitId,
      name: name,
      variantName: variantName,
      unitName: unitName,
      quantity: quantity,
      unitPrice: unitPrice,
      barcode: barcode,
      productUnit: productUnit,
      availableStock: availableStock,
      componentsSummary: componentsSummary,
      baseUnitPrice: baseUnitPrice,
      unitMultiplier: unitMultiplier,
      retailPrice: retailPrice,
      wholesalePrice: wholesalePrice,
      wholesaleMinQty: wholesaleMinQty,
      promotionPrice: promotionPrice,
    );
    final applied = applyAddingLine(
      notifier: ref.read(posCartProvider.notifier),
      cart: ref.read(posCartProvider),
      newLine: line,
      rawInput: quantity,
      loc: loc,
      onError: _showQtyError,
    );
    // Phase 8 FIX #1: focus the line that was actually written.
    if (applied && mounted) _requestQtyFocus(line.key);
  }

  Future<void> _pickCustomer() async {
    final customer = await showCustomerPickerDialog(context);
    if (!mounted) return;
    if (customer != null) {
      ref.read(posCartProvider.notifier).setCustomer(customer);
    }
  }

  Future<void> _openPayment() async {
    final cart = ref.read(posCartProvider);
    // Return mode: SPACE / PAY confirm the return, never open the payment
    // dialog — charging a customer mid-return would be a cash loss.
    if (cart.returnMode) {
      await _confirmReturn();
      return;
    }
    if (cart.isEmpty) {
      final loc = ref.read(localeProvider).flutterLocale.languageCode;
      showPosToast(
        context,
        message: AppStrings.t('cart_empty', loc),
        kind: PosToastKind.info,
      );
      return;
    }
    final result = await showPaymentDialog(context);
    if (result != null && mounted) {
      await _afterCheckoutSuccess(result);
    }
  }

  /// Enter / exit the POS return mode. Lines are never touched — the
  /// notifier's [PosCartNotifier.setReturnMode] only flips the flag — and
  /// any banner error from a previous attempt/session is dropped.
  void _setReturnMode(bool enabled) {
    ref.read(posCartProvider.notifier).setReturnMode(enabled);
    if (!mounted) return;
    setState(() => _returnError = null);
  }

  /// Confirm return mode → ONE `POST /api/v1/returns` with the cart as
  /// independent lines (server prices every line, GATE 5).
  ///
  /// Idempotency mirrors checkout: one `client_request_id` per attempt,
  /// reused on retry ([PosCartNotifier.beginReturnAttempt]); the cart is
  /// cleared ONLY after the server confirms — a failure keeps the cart,
  /// the mode and the same request id for a safe retry.
  Future<void> _confirmReturn() async {
    final cart = ref.read(posCartProvider);
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (cart.returnPending) return;
    if (cart.isEmpty) {
      showPosToast(
        context,
        message: AppStrings.t('cart_empty', loc),
        kind: PosToastKind.info,
      );
      return;
    }
    final built = buildPosReturnLines(cart.lines);
    final errorKey = built.errorKey;
    if (errorKey != null) {
      final error = PosApiError(AppStrings.t(errorKey, loc));
      setState(() => _returnError = error);
      showPosToast(
        context,
        message: error.message,
        kind: PosToastKind.warning,
        key: const Key('pos-return-validation-toast'),
      );
      return;
    }

    final notifier = ref.read(posCartProvider.notifier);
    final clientRequestId = notifier.beginReturnAttempt();
    setState(() => _returnError = null);

    String? deviceId;
    try {
      deviceId = await ref.read(posDeviceIdProvider.future);
    } catch (_) {
      deviceId = null;
    }
    final (result, error) = await ref.read(returnsApiProvider).create(
          payload: {
            'client_request_id': clientRequestId,
            'lines': [for (final line in built.lines) line.toJson()],
            // Optional audit field: the backend stores null exactly as it
            // stores an absent value, so no conditional entry is needed.
            'device_id': deviceId,
          },
        );
    if (!mounted) return;
    if (result == null) {
      // Keep cart + mode + client_request_id for a safe retry.
      notifier.failReturnAttempt();
      setState(() => _returnError = error);
      showPosToast(
        context,
        message: error?.message ?? AppStrings.t('api_error_retry', loc),
        detail: error?.detail,
        kind: PosToastKind.error,
        key: const Key('pos-return-error-toast'),
      );
      return;
    }
    // Server confirmed → clear the cart (also exits return mode) and
    // report the server-owned refund total.
    notifier.clearCart();
    setState(() => _returnError = null);
    showPosToast(
      context,
      message: AppStrings.t(
        result.idempotentReplay ? 'return_replay' : 'return_success',
        loc,
      ),
      detail: result.refundTotal,
      kind: PosToastKind.success,
      key: const Key('return-success-snackbar'),
    );
    // An already-open returns history list stays fresh (same pattern as
    // the AR refresh after a credit sale — only views that are alive).
    if (ref.exists(returnsProvider)) {
      ref.read(returnsProvider.notifier).refresh();
    }
  }

  /// Success flow after POST /sales 2xx.
  /// If price_overrides[] is non-empty, show a mandatory confirmation dialog
  /// (product name, client price, server price, explanation) before the
  /// success snackbar. Cart was already cleared by checkout success only —
  /// never because of the override itself. Same client_request_id is not
  /// regenerated (checkout already completed).
  Future<void> _afterCheckoutSuccess(CheckoutResult result) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (result.priceOverrides.isNotEmpty && mounted) {
      await showPriceOverrideDialog(context, result.priceOverrides);
    }
    if (!mounted) return;
    showPosToast(
      context,
      message: AppStrings.t('sale_completed', loc),
      detail: result.invoiceNumber,
      kind: PosToastKind.success,
      key: const Key('checkout-success-snackbar'),
    );
    _searchController.clear();
    ref.read(posSearchProvider.notifier).clear();
    ref.read(posSearchProvider.notifier).load();
    ref.read(favoritesProvider.notifier).load();
    _refreshArViewsIfIndebt(result);
    // §17.6 print hook runs last: the sale is committed, the cart is gone
    // and the success toast is up — printing can never undo any of that.
    await _maybeAutoPrint(result);
  }

  /// Post-sale print hook (POS workflow §9, Phase 17 §17.6).
  ///
  /// `ask_before_print` shows a "Print invoice?" dialog and prints only on
  /// yes; otherwise `auto_print_invoice` prints straight away; with both off
  /// (the fresh-install default) nothing happens and the cashier prints from
  /// the sale detail exactly as before.  Every failure is a localized toast —
  /// a completed sale is never reported as failed because of a printer.
  Future<void> _maybeAutoPrint(CheckoutResult result) async {
    final store = await loadStoreSettingsOnce(ref);
    if (!mounted || store == null) return;
    if (store.askBeforePrint) {
      if (!await _confirmPrintInvoice()) return;
    } else if (!store.autoPrintInvoice) {
      return;
    }
    await _printInvoice(result, paper: store.defaultPaper);
  }

  Future<bool> _confirmPrintInvoice() async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        key: const Key('ask-print-dialog'),
        title: Text(AppStrings.t('print', loc)),
        content: Text(AppStrings.t('ask_before_print_question', loc)),
        actions: [
          TextButton(
            key: const Key('ask-print-cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('ask-print-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.t('confirm', loc)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  /// Fetches the backend PDF for [paper] and hands it to the system print
  /// dialog.  Any failure — fetch or print — degrades to an error toast.
  Future<void> _printInvoice(CheckoutResult result, {required String paper}) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    String? deviceId;
    try {
      deviceId = await ref.read(posDeviceIdProvider.future);
    } catch (_) {
      deviceId = null;
    }
    if (!mounted) return;
    try {
      final doc = await fetchPrintDocument(
        ref.read(apiClientProvider).dio,
        documentType: 'sale',
        documentId: result.id,
        paper: paper,
        locale: loc,
        deviceId: deviceId,
      );
      if (!mounted) return;
      await ref.read(printServiceProvider).printPdf(
            doc.bytes,
            paper: doc.paper,
            filename: doc.filename,
          );
    } on PrintServiceException catch (e) {
      _autoPrintFailed(
        e.code != null ? AppStrings.t(e.code!, loc) : AppStrings.t('print_failed', loc),
      );
    } on DioException catch (e) {
      _autoPrintFailed(printFetchMessage(e, loc));
    } catch (_) {
      _autoPrintFailed(AppStrings.t('print_failed', loc));
    }
  }

  void _autoPrintFailed(String message) {
    if (!mounted) return;
    showPosToast(
      context,
      message: message,
      kind: PosToastKind.error,
      key: const Key('auto-print-failed-toast'),
    );
  }

  /// Fix Round 2 (debt balance bug): a credit sale raises the customer's
  /// aggregate outstanding balance (Phase 9: ledger entry +
  /// `customers.balance` move in the same transaction). Re-read every
  /// accounts-receivable view that is already alive so the list, the
  /// debtors list and the AR summary show it immediately instead of the
  /// pre-checkout snapshot. Nothing is fetched for screens never opened.
  void _refreshArViewsIfIndebt(CheckoutResult result) {
    final debtMilli = moneyToMilli(result.debt);
    if (debtMilli == null || debtMilli <= 0) return;
    if (ref.exists(customersProvider)) {
      ref.read(customersProvider.notifier).refresh();
    }
    if (ref.exists(debtorsProvider)) {
      ref.read(debtorsProvider.notifier).refresh();
    }
    if (ref.exists(debtSummaryProvider)) {
      ref.read(debtSummaryProvider.notifier).refresh();
    }
  }

  Future<void> _holdSale() async {
    final cart = ref.read(posCartProvider);
    // Return mode owns the cart (same rule as the F9 shortcut).
    if (cart.isEmpty || cart.returnMode) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final err = await ref.read(posCartProvider.notifier).createHold();
    if (!mounted) return;
    if (err != null) {
      showPosToast(context, message: err, kind: PosToastKind.error);
    } else {
      showPosToast(
        context,
        message: AppStrings.t('hold_saved', loc),
        kind: PosToastKind.success,
      );
      _searchController.clear();
      ref.read(posCartProvider.notifier).clearNotice();
      ref.read(posSearchProvider.notifier).clear();
      ref.read(posSearchProvider.notifier).load();
      ref.read(favoritesProvider.notifier).load();
      ref.read(holdsProvider.notifier).load();
    }
  }

  Future<void> _confirmClearCart() async {
    final cart = ref.read(posCartProvider);
    if (cart.isEmpty) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppStrings.t('clear_cart', loc)),
        content: Text(AppStrings.t('clear_cart_confirm', loc)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(AppStrings.t('cancel', loc)),
          ),
          ElevatedButton(
            key: const Key('clear-cart-confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(AppStrings.t('clear_cart', loc)),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(posCartProvider.notifier).clearCart();
      _searchController.clear();
      ref.read(posSearchProvider.notifier).clear();
    }
  }

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(localeProvider).flutterLocale.languageCode;
    final theme = Theme.of(context);
    final cart = ref.watch(posCartProvider);
    final search = ref.watch(posSearchProvider);
    final favorites = ref.watch(favoritesProvider);
    final viewMode = ref.watch(posCatalogViewModeProvider);
    final heldCount = ref.watch(holdsProvider).items.length;
    final layout = posLayoutModeFor(MediaQuery.sizeOf(context).width);
    final cartWidth =
        posCartWidthFor(MediaQuery.sizeOf(context).width);

    // Show notice toast once after hold restore etc.
    ref.listen(posCartProvider, (previous, next) {
      if (next.notice != null && next.notice != previous?.notice) {
        final message = AppStrings.t(next.notice!, loc);
        showPosToast(
          context,
          message: message,
          kind: PosToastKind.success,
          key: Key(next.notice!),
        );
        ref.read(posCartProvider.notifier).clearNotice();
      }
      if (next.lastError != null && next.lastError != previous?.lastError) {
        // `_message` already localized it (UX FIX #12 — FIX #5).
        final error = next.lastError!;
        showPosToast(
          context,
          message: error,
          kind: PosToastKind.error,
          key: const Key('pos-error-snackbar'),
        );
      }
    });

    final searchField = _SearchField(
      controller: _searchController,
      focusNode: _searchFocusNode,
      query: search.query,
      loading: search.loading,
      onChanged: (v) => ref.read(posSearchProvider.notifier).setQuery(v),
      onSubmitted: (_) => _submitSearch(),
    );

    final productCatalog = _ProductCatalog(
      products: search.items,
      loading: search.loading,
      loadingMore: search.loadingMore,
      hasMore: search.hasMore,
      loadMoreError: search.loadMoreError,
      onLoadMore: () => ref.read(posSearchProvider.notifier).loadMore(),
      error: search.error,
      favorites: favorites.items,
      viewMode: viewMode,
      onAdd: _addProduct,
      onToggleFavorite: (product, isFav) async {
        final err = await ref
            .read(favoritesProvider.notifier)
            .toggle(product.id, currentlyFavorited: isFav);
        if (err != null && context.mounted) {
          showPosToast(context, message: err, kind: PosToastKind.error);
        }
      },
    );

    final favoritesRow = _FavoritesRow(
      favorites: favorites.items,
      onTapFavorite: (f) async {
        // Resolve product by id then add
        final dio = ref.read(apiClientProvider).dio;
        try {
          final response = await dio.get('/api/v1/products/${f.productId}');
          final product =
              ProductModel.fromJson(response.data as Map<String, dynamic>);
          await _addProduct(product);
        } catch (_) {
          // fallback: add with known favorite fields
          _addCartLine(
            productId: f.productId,
            name: f.productName ?? f.productId,
            quantity: '1',
            unitPrice: f.price ?? '0',
            barcode: f.barcode,
          );
        }
      },
    );

    final cartPanel = _CartPanel(
      cart: cart,
      qtyFocusRequest: _qtyFocusRequest,
      onRemoveLine: (key) =>
          ref.read(posCartProvider.notifier).removeLine(key),
      // Single validating qty path (UX FIX #12 — FIX #6).
      onUpdateQty: _updateLineQty,
      // Tapping / focusing a line makes it the `+` / `*` target (FIX #2).
      onActivateLine: (key) =>
          ref.read(posCartProvider.notifier).setActiveLine(key),
      onUpdateLineDiscount: (key, d) =>
          ref.read(posCartProvider.notifier).updateLine(key, lineDiscount: d),
      onCustomer: _pickCustomer,
      onDiscount: () async {
        if (!ref.read(hasPermissionProvider('pos_discount'))) {
          showPosToast(
            context,
            message: AppStrings.t('permission_discount', loc),
            kind: PosToastKind.warning,
          );
          return;
        }
        await showInvoiceDiscountDialog(context);
      },
      onPayment: _openPayment,
      onHold: _holdSale,
      onHolds: () async {
        await showHoldsDialog(context);
        if (!mounted) return;
        // Refresh badge after dialog (restore/delete may have changed list).
        // Success snackbar is handled by the posCartProvider notice listener
        // (loadHold → notice 'hold_restored').
        ref.read(holdsProvider.notifier).load();
      },
      onHistory: () => showSaleHistoryDialog(context),
      onClear: _confirmClearCart,
      heldCount: heldCount,
      // POS return mode (cart → independent return).
      canReturn: ref.watch(hasPermissionProvider('pos_return')),
      onReturn: () => _setReturnMode(true),
      onCancelReturn: () => _setReturnMode(false),
      onConfirmReturn: _confirmReturn,
      returnError: _returnError?.message,
    );

        final workspace = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (layout == PosLayoutMode.wide) favoritesRow,
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 180),
                  child: searchField,
                ),
              ),
              const SizedBox(width: 8),
              // Phase 10 — packs / bundles picker (own dialog, own search).
              OutlinedButton.icon(
                key: const Key('pos-packs-button'),
                onPressed: _addPack,
                icon: const Icon(Icons.local_offer_outlined, size: 18),
                label: Text(
                  AppStrings.t('packs', loc),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: const Size(0, 38),
                  visualDensity: VisualDensity.compact,
                  side: BorderSide(
                    color: theme.colorScheme.outline.withValues(alpha: 0.5),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Phase 17 §18 — the keyboard map needs a discoverable entry
              // point next to the tools it describes.
              IconButton(
                key: const Key('pos-shortcuts-button'),
                tooltip: AppStrings.t('shortcuts_title', loc),
                onPressed: () => showShortcutsDialog(context),
                icon: const Icon(Icons.keyboard),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 38,
                  minHeight: 38,
                ),
              ),
              const SizedBox(width: 8),
              // FIX #3: full labels when workspace allows; icons+tooltip when tight.
              if (layout != PosLayoutMode.narrow &&
                  (MediaQuery.sizeOf(context).width - cartWidth) < 500)
                _ViewModeToggle(
                  mode: viewMode,
                  compact: true,
                  onChanged: (m) =>
                      ref.read(posCatalogViewModeProvider.notifier).setMode(m),
                )
              else
                ConstrainedBox(
                  // FIX #3: ≥190 when space allows; grow for full labels.
                  constraints: const BoxConstraints(minWidth: 190),
                  child: _ViewModeToggle(
                    mode: viewMode,
                    compact: false,
                    onChanged: (m) => ref
                        .read(posCatalogViewModeProvider.notifier)
                        .setMode(m),
                  ),
                ),
            ],
          ),
        ),
        Expanded(child: productCatalog),
      ],
    );

    Widget body;
    switch (layout) {
      case PosLayoutMode.wide:
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: workspace),
            const VerticalDivider(width: 1),
            SizedBox(width: cartWidth, child: cartPanel),
          ],
        );
      case PosLayoutMode.medium:
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: workspace),
            const VerticalDivider(width: 1),
            SizedBox(width: cartWidth, child: cartPanel),
          ],
        );
      case PosLayoutMode.narrow:
        // When the cart drawer is open it owns the full height so the
        // fixed cart chrome (totals + action buttons + pay) never overflows
        // on short viewports (600×500). Workspace returns when closed.
        body = _cartDrawerOpen
            ? Column(
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        IconButton(
                          key: const Key('toggle-cart'),
                          tooltip: AppStrings.t('cart_empty', loc),
                          onPressed: () =>
                              setState(() => _cartDrawerOpen = false),
                          icon: const Icon(Icons.close),
                        ),
                        Expanded(
                          child: Text(
                            '${AppStrings.t('total_label', loc)}: '
                            '${cart.totals.totalDisplay}',
                            style: theme.textTheme.titleMedium,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(child: cartPanel),
                ],
              )
            : Column(
                children: [
                  Expanded(child: workspace),
                  SizedBox(
                    height: 56,
                    child: Row(
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text(
                              '${AppStrings.t('total_label', loc)}: '
                              '${cart.totals.totalDisplay}',
                              style: theme.textTheme.titleMedium,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        IconButton(
                          key: const Key('toggle-cart'),
                          tooltip: AppStrings.t('pos', loc),
                          onPressed: () =>
                              setState(() => _cartDrawerOpen = true),
                          icon: const Icon(Icons.shopping_cart),
                        ),
                      ],
                    ),
                  ),
                ],
              );
    }

    // Global shortcuts — Escape never clears cart; F12 requires confirm.
    // F4 / Ctrl+F focus search; after dialogs close, search remains the
    // sensible default focus for barcode/keyboard-first cashier flow.
    // SPACE pays (Phase 17 §18, replaces legacy F8) but only when no text
    // field is consuming the space — TextFreeKeyActivator declines it
    // while an EditableText has primary focus, so typing is never stolen.
    // The one exception is a focused CART QUANTITY field (every add leaves
    // focus there, Phase 8 FIX #1): it hands SPACE to the payment shortcut
    // instead of inserting it, so the pay key can never corrupt a quantity
    // (see cartQtyFieldHasFocus). The search field and every dialog input
    // keep SPACE as ordinary text.
    // `+` / `-` / `*` act on the last active cart line: `+`, `-` and `*`
    // are also claimed while the search or a cart qty field is focused
    // (never inserted as text) — see PosQtyShortcutActivator. While a
    // dialog route is open its focus scope owns the keys, so none of them
    // reach this layer — including Escape, which therefore stays safe to
    // bind here (dialogs keep their own route-level dismiss).
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f4): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.f5): _refreshWorkspace,
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
        const SingleActivator(LogicalKeyboardKey.f6): () =>
            _handleShortcut(LogicalKeyboardKey.f6),
        const SingleActivator(LogicalKeyboardKey.f7): () =>
            _handleShortcut(LogicalKeyboardKey.f7),
        // SPACE replaces F8 (Phase 17 §18 — "SPACE replaces F8 for payment").
        // While a cart quantity field is focused the activator claims the
        // key anyway (allowWhileEditing) — the callback is IDENTICAL, only
        // the event precedence changes: handled key ⇒ the qty text input
        // never sees the space character.
        TextFreeKeyActivator(
          LogicalKeyboardKey.space,
          allowWhileEditing: cartQtyFieldHasFocus,
        ): () => _handleShortcut(LogicalKeyboardKey.space),
        const SingleActivator(LogicalKeyboardKey.f9): () =>
            _handleShortcut(LogicalKeyboardKey.f9),
        const SingleActivator(LogicalKeyboardKey.f10): () =>
            _handleShortcut(LogicalKeyboardKey.f10),
        const SingleActivator(LogicalKeyboardKey.f11): () =>
            _handleShortcut(LogicalKeyboardKey.f11),
        const SingleActivator(LogicalKeyboardKey.f12): () =>
            _handleShortcut(LogicalKeyboardKey.f12),
        const PosQtyShortcutActivator(PosQtyShortcutKind.increment): () =>
            _incrementActiveLine(),
        const PosQtyShortcutActivator(PosQtyShortcutKind.decrement): () =>
            _decrementActiveLine(),
        const PosQtyShortcutActivator(PosQtyShortcutKind.quantityEntry): () =>
            _setActiveLineQuantity(),
      },
      child: Focus(
        autofocus: true,
        focusNode: _focusNode,
        child: Scaffold(
          key: const Key('pos-screen'),
          body: body,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quantity step — ONE implementation of the cart's minimum rule
// ---------------------------------------------------------------------------

/// Exact step of [delta] units from the committed [quantity] (scaled ×1000
/// math), clamped to `[0, kPosQuantityMax]`.
///
/// Returns null when the step would take the quantity to zero or below:
/// that is the cart minimum, shared by the line +/- buttons (which disable
/// at 1) and by the global `+` / `-` shortcuts (which stay silent) — one
/// rule, so keyboard and mouse can never diverge.
String? _qtyStepText(String quantity, double delta) {
  final current = posScaled(quantity) ?? 0;
  final next = current + (delta * kPosQtyScale).round();
  if (next <= 0) return null;
  final maxScaled = (kPosQuantityMax * kPosQtyScale).toInt();
  return posScaledText(next > maxScaled ? maxScaled : next);
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String query;
  final bool loading;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.query,
    required this.loading,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('pos-search-field'),
          controller: controller,
          focusNode: focusNode,
          autofocus: true,
          decoration: InputDecoration(
            hintText: AppStrings.t('search_products', loc),
            prefixIcon: const Icon(Icons.search),
            suffixIcon: loading
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
        const SizedBox(height: 4),
        Text(
          AppStrings.t('scan_barcode_hint', loc),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      ],
    );
  }
}

class _ViewModeToggle extends StatelessWidget {
  final PosCatalogViewMode mode;
  final ValueChanged<PosCatalogViewMode> onChanged;
  final bool compact;

  const _ViewModeToggle({
    required this.mode,
    required this.onChanged,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final selectedColor = theme.colorScheme.primary;
    final onSelected = theme.colorScheme.onPrimary;

    Widget segment({
      required Key key,
      required PosCatalogViewMode value,
      required IconData icon,
      required String label,
    }) {
      final selected = mode == value;
      final content = Padding(
        padding: EdgeInsets.symmetric(
          horizontal: compact ? 10 : 10,
          vertical: 8,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: compact ? 18 : 18,
              color: selected ? onSelected : theme.colorScheme.outline,
            ),
            if (!compact) ...[
              const SizedBox(width: 4),
              Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontSize: 14,
                  color:
                      selected ? onSelected : theme.colorScheme.onSurface,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ],
        ),
      );
      return Material(
        key: key,
        color: selected ? selectedColor : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => onChanged(value),
          child: Tooltip(
            message: label,
            child: compact
                ? content
                : ConstrainedBox(
                    constraints: const BoxConstraints(minWidth: 90),
                    child: content,
                  ),
          ),
        ),
      );
    }

    return Container(
      key: const Key('pos-view-mode-toggle'),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(
            key: const Key('pos-view-mode-grid'),
            value: PosCatalogViewMode.grid,
            icon: Icons.grid_view,
            label: AppStrings.t('catalog_view_grid', loc),
          ),
          segment(
            key: const Key('pos-view-mode-list'),
            value: PosCatalogViewMode.list,
            icon: Icons.view_list,
            label: AppStrings.t('catalog_view_list', loc),
          ),
        ],
      ),
    );
  }
}

/// Returns a file-backed image when [imagePath] is a valid existing file;
/// otherwise null (caller uses text-first presentation — never a blank box).
Image? _tryProductImage(
  String? imagePath, {
  int? cacheWidth,
  required WidgetBuilder errorFallback,
}) {
  final path = imagePath?.trim();
  if (path == null || path.isEmpty) return null;
  final file = File(path);
  if (!file.existsSync()) return null;
  return Image.file(
    file,
    fit: BoxFit.cover,
    cacheWidth: cacheWidth,
    errorBuilder: (_, _, _) => Builder(builder: errorFallback),
  );
}

class _ProductCatalog extends StatelessWidget {
  final List<ProductModel> products;
  final bool loading;

  /// Next page is being appended (bottom spinner).
  final bool loadingMore;

  /// Server reported more pages than [products] currently holds.
  final bool hasMore;

  /// Append failed — rows stay on screen, footer shows the message.
  final String? loadMoreError;

  /// Ask the provider for the next page (no-op while loading / exhausted).
  final VoidCallback onLoadMore;

  final String? error;
  final List<FavoriteModel> favorites;
  final PosCatalogViewMode viewMode;
  final Future<void> Function(ProductModel) onAdd;
  final void Function(ProductModel, bool) onToggleFavorite;

  const _ProductCatalog({
    required this.products,
    required this.loading,
    required this.loadingMore,
    required this.hasMore,
    required this.loadMoreError,
    required this.onLoadMore,
    required this.error,
    required this.favorites,
    required this.viewMode,
    required this.onAdd,
    required this.onToggleFavorite,
  });

  bool _isFav(ProductModel product) =>
      favorites.any((f) => f.productId == product.id);

  Widget _favoriteButton(
    BuildContext context,
    ProductModel product,
    bool isFav,
  ) {
    return IconButton(
      visualDensity: VisualDensity.compact,
      icon: Icon(
        isFav ? Icons.star : Icons.star_border,
        size: 18,
        color: isFav ? AppColors.warning : null,
      ),
      onPressed: () => onToggleFavorite(product, isFav),
    );
  }

  Widget _stockLine(BuildContext context, ProductModel product) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final out = (double.tryParse(product.quantity) ?? 0) <= 0;
    if (out) {
      return Text(
        AppStrings.t('out_of_stock', loc),
        key: Key('pos-product-oos-${product.id}'),
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.error,
          fontWeight: FontWeight.w700,
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }
    return Text(
      '${AppStrings.t('stock_quantity', loc)}: '
      '${product.quantity} ${product.unit}',
      style: theme.textTheme.bodySmall,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// Catalog price, shared by the grid card and the list tile. With an
  /// active promotion it shows the Phase 18 treatment — retail struck
  /// through, effective promo price, percent badge (`~~200~~ 160 -20%`)
  /// — otherwise the plain retail price (keys unchanged).
  Widget _price(BuildContext context, ProductModel product) {
    final theme = Theme.of(context);
    final promo = product.promotion;
    final badge = promo == null ? '' : promo.discountBadgeFor(product.price);
    if (promo == null || badge.isEmpty) {
      return Text(
        product.price,
        key: Key('pos-product-price-${product.id}'),
        style: theme.textTheme.titleMedium?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.bold,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        // Regression fix: inside a narrow grid card this Row gets a TIGHT
        // width, and the three texts together can exceed it. The retail
        // price and the badge are secondary, so they yield (loose flex =
        // they keep their natural size while there is room, ellipsize only
        // when there is not); the effective promo price never yields.
        Flexible(
          child: Text(
            product.price,
            key: Key('pos-product-retail-price-${product.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.titleMedium?.copyWith(
              decoration: TextDecoration.lineThrough,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          promo.price,
          key: Key('pos-product-price-${product.id}'),
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            badge,
            key: Key('pos-product-promo-${product.id}'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.tertiary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }

  /// Dominant name treatment when no image is available (text-first card).
  Widget _heroName(BuildContext context, ProductModel product) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Text(
          product.name,
          key: Key('pos-product-name-${product.id}'),
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
            height: 1.15,
            color: theme.textTheme.titleLarge?.color ??
                theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }

  Widget _gridCard(BuildContext context, ProductModel product) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    final isFav = _isFav(product);
    final out = (double.tryParse(product.quantity) ?? 0) <= 0;
    final img = _tryProductImage(
      product.imagePath,
      cacheWidth: 200,
      errorFallback: (_) => _heroName(context, product),
    );

    return Card(
      key: Key('pos-product-${product.id}'),
      clipBehavior: Clip.antiAlias,
      elevation: out ? 0 : 1,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: out
              ? theme.colorScheme.error
              : theme.colorScheme.outline.withValues(alpha: 0.2),
          width: out ? 1.5 : 1,
        ),
      ),
      child: Opacity(
        opacity: out ? 0.55 : 1,
        child: InkWell(
          onTap: out ? null : () => onAdd(product),
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: img == null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (out)
                        Container(
                          key: Key('pos-product-oos-badge-${product.id}'),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            AppStrings.t('out_of_stock', loc),
                            style: TextStyle(
                              color: theme.colorScheme.onError,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        )
                      else
                        Align(
                          alignment: AlignmentDirectional.centerEnd,
                          child:
                              _favoriteButton(context, product, isFav),
                        ),
                      const SizedBox(height: 4),
                      Expanded(child: _heroName(context, product)),
                      const SizedBox(height: 4),
                      _price(context, product),
                      const SizedBox(height: 2),
                      _stockLine(context, product),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              product.name,
                              key: Key('pos-product-name-${product.id}'),
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!out)
                            _favoriteButton(context, product, isFav),
                        ],
                      ),
                      if (out) ...[
                        const SizedBox(height: 4),
                        Container(
                          key: Key('pos-product-oos-badge-${product.id}'),
                          alignment: Alignment.center,
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.error,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            AppStrings.t('out_of_stock', loc),
                            style: TextStyle(
                              color: theme.colorScheme.onError,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 6),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: SizedBox.expand(child: img),
                        ),
                      ),
                      const SizedBox(height: 6),
                      _price(context, product),
                      const SizedBox(height: 2),
                      _stockLine(context, product),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _listTile(BuildContext context, ProductModel product) {
    final theme = Theme.of(context);
    final loc = Localizations.localeOf(context).languageCode;
    final isFav = _isFav(product);
    final out = (double.tryParse(product.quantity) ?? 0) <= 0;
    final img = _tryProductImage(
      product.imagePath,
      cacheWidth: 72,
      errorFallback: (_) => const SizedBox.shrink(),
    );

    return Material(
      key: Key('pos-product-${product.id}'),
      color: out
          ? theme.colorScheme.error.withValues(alpha: 0.04)
          : Colors.transparent,
      child: InkWell(
        onTap: out ? null : () => onAdd(product),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Opacity(
            opacity: out ? 0.65 : 1,
            child: Row(
              children: [
                if (!out) _favoriteButton(context, product, isFav),
                if (img != null) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(width: 40, height: 40, child: img),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        product.name,
                        key: Key('pos-product-name-${product.id}'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      if (out)
                        Text(
                          AppStrings.t('out_of_stock', loc),
                          key: Key('pos-product-oos-${product.id}'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.error,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 1,
                        )
                      else
                        Text(
                          '${AppStrings.unitLabel(product.unit, loc)} · '
                          '${AppStrings.t('stock_quantity', loc)}: '
                          '${product.quantity}',
                          key: Key('pos-product-meta-${product.id}'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.outline,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                _price(context, product),
                const SizedBox(width: 4),
                IconButton(
                  key: Key('pos-product-add-${product.id}'),
                  tooltip: AppStrings.t('add_to_cart', loc),
                  visualDensity: VisualDensity.compact,
                  icon: Icon(
                    Icons.add_circle_outline,
                    size: 22,
                    color: out
                        ? theme.colorScheme.outline
                        : theme.colorScheme.primary,
                  ),
                  onPressed: out ? null : () => onAdd(product),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Near-the-end trigger: ask for the next page while the cashier scrolls.
  /// The provider no-ops when exhausted or already loading, so this can fire
  /// on every scroll tick near the bottom without issuing extra requests.
  bool _onScroll(ScrollNotification notification) {
    if (!hasMore) return false;
    if (notification.metrics.axis != Axis.vertical) return false;
    if (notification is! ScrollUpdateNotification &&
        notification is! ScrollEndNotification) {
      return false;
    }
    final metrics = notification.metrics;
    if (metrics.pixels >=
        metrics.maxScrollExtent - kPosCatalogLoadMoreThreshold) {
      onLoadMore();
    }
    return false;
  }

  bool get _hasFooter => loadingMore || loadMoreError != null;

  /// Bottom row: spinner while the next page appends, message on failure.
  Widget _footer(BuildContext context) {
    if (loadingMore) {
      return const Center(
        key: Key('pos-catalog-loading-more'),
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Center(
      key: const Key('pos-catalog-load-more-error'),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          loadMoreError!,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);

    if (loading && products.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (error != null) {
      return Center(
        child: Text(
          error!,
          key: const Key('pos-search-error'),
          style: TextStyle(color: theme.colorScheme.error),
        ),
      );
    }
    if (products.isEmpty) {
      return Center(
        child: Text(
          AppStrings.t('no_products_found', loc),
          key: const Key('pos-no-products'),
        ),
      );
    }

    // GridView/ListView.builder stay the scrollables: only the visible
    // window is ever built — never all loaded rows at once.
    final footerCount = _hasFooter ? 1 : 0;

    if (viewMode == PosCatalogViewMode.list) {
      return NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: ListView.separated(
          key: const Key('pos-product-list'),
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: products.length + footerCount,
          separatorBuilder: (_, index) =>
              index + 1 == products.length && footerCount > 0
                  ? const SizedBox(height: 0)
                  : const Divider(height: 1),
          itemBuilder: (context, index) {
            if (index >= products.length) return _footer(context);
            return _listTile(context, products[index]);
          },
        ),
      );
    }

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: GridView.builder(
        key: const Key('pos-product-grid'),
        padding: const EdgeInsets.all(12),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 200,
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.05,
        ),
        itemCount: products.length + footerCount,
        itemBuilder: (context, index) {
          if (index >= products.length) return _footer(context);
          return _gridCard(context, products[index]);
        },
      ),
    );
  }
}

class _FavoritesRow extends StatelessWidget {
  final List<FavoriteModel> favorites;
  final void Function(FavoriteModel) onTapFavorite;

  const _FavoritesRow({
    required this.favorites,
    required this.onTapFavorite,
  });

  @override
  Widget build(BuildContext context) {
    if (favorites.isEmpty) return const SizedBox.shrink();

    return SizedBox(
      height: 72,
      child: ListView.separated(
        key: const Key('pos-favorites-row'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: favorites.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final f = favorites[index];
          return ActionChip(
            key: Key('pos-favorite-${f.productId}'),
            avatar: const Icon(Icons.star, size: 16),
            label: Text(
              f.productName ?? f.productId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onPressed: () => onTapFavorite(f),
          );
        },
      ),
    );
  }
}

class _CartPanel extends StatelessWidget {
  final PosCartState cart;
  final void Function(String) onRemoveLine;

  /// Line key that should receive keyboard focus after an add
  /// (Phase 8 FIX #1) — consumed by the matching line tile.
  final ValueNotifier<String?> qtyFocusRequest;

  /// Returns true when the quantity was applied (false = rejected, a toast
  /// was already shown by the shared validation funnel).
  final bool Function(String key, String quantity) onUpdateQty;

  /// Marks a line as the `+` / `*` target (line tap or qty-field focus).
  final void Function(String key) onActivateLine;
  final void Function(String, String) onUpdateLineDiscount;
  final VoidCallback onCustomer;
  final VoidCallback onDiscount;
  final VoidCallback onPayment;
  final VoidCallback onHold;
  final VoidCallback onHolds;
  final VoidCallback onHistory;
  final VoidCallback onClear;
  final int heldCount;

  /// POS return mode — the footer Return button (permission-gated) enters
  /// the mode; the banner + totals-panel Confirm/Cancel own the mode.
  final bool canReturn;
  final VoidCallback onReturn;
  final VoidCallback onCancelReturn;
  final VoidCallback onConfirmReturn;

  /// Localized last return failure — inline in the return banner.
  final String? returnError;

  const _CartPanel({
    required this.cart,
    required this.qtyFocusRequest,
    required this.onRemoveLine,
    required this.onUpdateQty,
    required this.onActivateLine,
    required this.onUpdateLineDiscount,
    required this.onCustomer,
    required this.onDiscount,
    required this.onPayment,
    required this.onHold,
    required this.onHolds,
    required this.onHistory,
    required this.onClear,
    this.heldCount = 0,
    this.canReturn = false,
    required this.onReturn,
    required this.onCancelReturn,
    required this.onConfirmReturn,
    this.returnError,
  });

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final mediaH = MediaQuery.sizeOf(context).height;
    final short = mediaH < 560;
    // Compact chrome under 700px so header+customer+actions+totals fit
    // alongside a scrollable line/empty region (UX FIX #8).
    final compact = mediaH < 700;
    final unitCount =
        cart.lines.fold<double>(0, (sum, line) => sum + line.qty);
    final counts = cart.isEmpty
        ? AppStrings.t('cart_no_items', loc)
        : '${cart.lines.length} ${AppStrings.t('lines_word', loc)} · '
            '${_fmtQty(unitCount)} ${AppStrings.t('units_word', loc)}';
    final headerHeight = compact ? 64.0 : 72.0;
    final customerHeight = compact ? 48.0 : 52.0;

    return Container(
      key: const Key('pos-cart-panel'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: real POS header (UX FIX #8) — 64–76px, 20–22 title.
          SizedBox(
            height: headerHeight,
            child: Padding(
              key: const Key('pos-cart-header'),
              padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 4),
              child: Row(
                children: [
                  Text('🛒', style: TextStyle(fontSize: compact ? 22 : 24)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppStrings.t('cart_title', loc),
                          key: const Key('pos-cart-title'),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontSize: short ? 20.0 : 22.0,
                            fontWeight: FontWeight.w700,
                            height: 1.1,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          counts,
                          key: const Key('pos-cart-counts'),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: short ? 14.0 : 15.0,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.7),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: const Key('pos-clear-cart'),
                    tooltip: AppStrings.t('clear_shortcut', loc),
                    constraints:
                        const BoxConstraints(minWidth: 44, minHeight: 44),
                    padding: EdgeInsets.zero,
                    iconSize: 24,
                    onPressed: cart.isEmpty ? null : onClear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                ],
              ),
            ),
          ),
          // Customer row: dedicated 48–52px row (UX FIX #8).
          SizedBox(
            height: customerHeight,
            child: Material(
              key: const Key('pos-customer-row'),
              color: theme.cardColor,
              child: InkWell(
                onTap: onCustomer,
                child: Padding(
                  padding:
                      const EdgeInsetsDirectional.only(start: 12, end: 6),
                  child: Row(
                    children: [
                      Icon(
                        Icons.person_outline,
                        size: 22,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              cart.customer?.name ??
                                  AppStrings.t('walk_in_customer', loc),
                              key: const Key('pos-customer-name'),
                              style: theme.textTheme.bodyLarge?.copyWith(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (cart.customer?.phone != null)
                              Text(
                                cart.customer!.phone!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 13,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                          ],
                        ),
                      ),
                      SizedBox(
                        height: 44,
                        child: TextButton(
                          key: const Key('pos-select-customer'),
                          onPressed: onCustomer,
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                            ),
                            minimumSize: const Size(0, 44),
                            // styleFrom() *replaces* the button's labelLarge,
                            // so it has to be derived from the theme: a bare
                            // TextStyle has no fontFamily and the label would
                            // silently fall back to the platform font.
                            textStyle: theme.textTheme.labelLarge?.copyWith(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          child: Text(
                            AppStrings.t('customer_shortcut', loc),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          // Return-mode banner: unmistakable mode indication above the
          // lines, with the inline failure line while one exists.
          if (cart.returnMode)
            Container(
              key: const Key('pos-return-banner'),
              color: theme.colorScheme.tertiaryContainer,
              padding:
                  const EdgeInsetsDirectional.fromSTEB(12, 8, 12, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.replay,
                    size: 20,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          AppStrings.t('pos_return_mode', loc),
                          key: const Key('pos-return-banner-title'),
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                        ),
                        Text(
                          AppStrings.t('pos_return_mode_hint', loc),
                          key: const Key('pos-return-banner-hint'),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onTertiaryContainer,
                          ),
                        ),
                        if (returnError != null) ...[
                          const SizedBox(height: 4),
                          Text(
                            returnError!,
                            key: const Key('pos-return-banner-error'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.error,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          // Only the line list scrolls — header/totals/PAY stay fixed.
          Expanded(
            flex: 1,
            child: cart.isEmpty
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            '🛒',
                            key: const Key('pos-cart-empty-icon'),
                            style: TextStyle(
                              fontSize: short ? 30 : 36,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            AppStrings.t('cart_empty', loc),
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            AppStrings.t('cart_empty_hint', loc),
                            key: const Key('pos-cart-empty'),
                            textAlign: TextAlign.center,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontSize: 14,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            AppStrings.t('search_focus', loc),
                            key: const Key('pos-cart-empty-f4'),
                            style: theme.textTheme.labelLarge?.copyWith(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    key: const Key('pos-cart-lines'),
                    padding: const EdgeInsets.symmetric(
                      vertical: 6,
                      horizontal: 6,
                    ),
                    itemCount: cart.lines.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final line = cart.lines[index];
                      return _CartLineTile(
                        // State follows the *line*, not the list position —
                        // the focused qty field must stay with its line when
                        // another product is added above it.
                        key: ValueKey<String>(line.key),
                        line: line,
                        qtyFocusRequest: qtyFocusRequest,
                        onRemove: () => onRemoveLine(line.key),
                        onActivate: () => onActivateLine(line.key),
                        onQty: (q) => onUpdateQty(line.key, q),
                        onDiscount: (d) =>
                            onUpdateLineDiscount(line.key, d),
                      );
                    },
                  ),
          ),
          const Divider(height: 1),
          // Stock errors
          if (cart.stockErrors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in cart.stockErrors)
                    Text(
                      e,
                      key: const Key('pos-stock-error'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                ],
              ),
            ),
          // 2-column secondary action grid (UX FIX #8): 44–48px, 13–15px font.
          Padding(
            key: const Key('pos-cart-actions'),
            padding: compact
                ? const EdgeInsets.fromLTRB(10, 4, 10, 4)
                : const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Column(
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        context: context,
                        key: const Key('pos-discount-button'),
                        icon: Icons.percent,
                        label: AppStrings.t('discount_shortcut', loc),
                        onPressed: onDiscount,
                        short: short || compact,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        context: context,
                        key: const Key('pos-hold-button'),
                        icon: Icons.pause,
                        label: AppStrings.t('hold_shortcut', loc),
                        // Return mode owns the cart — holding it would
                        // shelve the pending return (a hold is a SALE
                        // snapshot).
                        onPressed:
                            (cart.isEmpty || cart.returnMode) ? null : onHold,
                        short: short || compact,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _actionButton(
                        context: context,
                        key: const Key('pos-holds-button'),
                        icon: Icons.list_alt,
                        label: AppStrings.t('holds_shortcut', loc),
                        onPressed: onHolds,
                        short: short || compact,
                        badgeCount: heldCount,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: _actionButton(
                        context: context,
                        key: const Key('pos-history-button'),
                        icon: Icons.history,
                        label: AppStrings.t('history_shortcut', loc),
                        onPressed: onHistory,
                        short: short || compact,
                      ),
                    ),
                  ],
                ),
                // Return entry point (permission-gated): hidden while the
                // mode is active — the banner + Confirm/Cancel own it.
                if (canReturn && !cart.returnMode) ...[
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _actionButton(
                          context: context,
                          key: const Key('pos-return-button'),
                          icon: Icons.replay,
                          label: AppStrings.t('pos_return', loc),
                          onPressed: cart.isEmpty ? null : onReturn,
                          short: short || compact,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
          // Sticky totals + PAY card (UX FIX #7/#8) — in return mode the
          // PAY slot becomes Confirm return / Cancel return.
          _PosTotalsPanel(
            cart: cart,
            onPayment: onPayment,
            onConfirmReturn: onConfirmReturn,
            onCancelReturn: onCancelReturn,
          ),
        ],
      ),
    );
  }

  static Widget _actionButton({
    required BuildContext context,
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    required bool short,
    int badgeCount = 0,
  }) {
    final height = short ? 44.0 : 46.0;
    final theme = Theme.of(context);
    return SizedBox(
      height: height,
      child: OutlinedButton.icon(
        key: key,
        onPressed: onPressed,
        icon: badgeCount > 0
            ? Badge(
                label: Text('$badgeCount'),
                backgroundColor: theme.colorScheme.primary,
                textColor: theme.colorScheme.onPrimary,
                child: Icon(icon, size: short ? 18 : 20),
              )
            : Icon(icon, size: short ? 18 : 20),
        label: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
          overflow: TextOverflow.ellipsis,
          maxLines: 1,
        ),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size(0, height),
          maximumSize: Size(double.infinity, height),
          visualDensity: VisualDensity.compact,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 14),
          side: BorderSide(color: theme.colorScheme.outline),
        ),
      ),
    );
  }
}

/// Dedicated totals card: Subtotal / Discount / TOTAL / PAY (UX FIX #7/#8).
/// In POS return mode the PAY slot becomes Confirm return / Cancel return.
class _PosTotalsPanel extends StatelessWidget {
  final PosCartState cart;
  final VoidCallback onPayment;
  final VoidCallback onConfirmReturn;
  final VoidCallback onCancelReturn;

  const _PosTotalsPanel({
    required this.cart,
    required this.onPayment,
    required this.onConfirmReturn,
    required this.onCancelReturn,
  });

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final totals = cart.totals;
    final cs = theme.colorScheme;
    final currency = AppStrings.t('currency', loc);
    final payEnabled = !cart.isEmpty && !cart.checkoutPending;

    return Material(
      key: const Key('pos-totals-panel'),
      color: theme.cardColor,
      elevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.sizeOf(context).height < 700 ? 6 : 8,
          12,
          MediaQuery.sizeOf(context).height < 700 ? 4 : 6,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            final mediaH = MediaQuery.sizeOf(context).height;
            // TOTAL 40–48 on normal desktop; floor 36 on short (UX FIX #8).
            double totalSize;
            double payHeight;
            double labelSize;
            if (mediaH < 560) {
              totalSize = 36.0;
              labelSize = 18.0;
              payHeight = 50.0;
            } else if (mediaH < 700) {
              totalSize = 40.0;
              labelSize = 18.0;
              payHeight = 56.0;
            } else {
              totalSize = w >= 400 ? 46.0 : 42.0;
              if (totalSize > 48) totalSize = 48;
              labelSize = 20.0;
              payHeight = 60.0;
            }
            final subSize = mediaH < 700 ? 14.0 : 15.0;
            final payFontSize = mediaH < 560 ? 15.0 : 17.0;
            final payIconSize = mediaH < 560 ? 20.0 : 22.0;
            final rowPad = mediaH < 700 ? 3.0 : 5.0;
            final gapAfterTotal = mediaH < 700 ? 6.0 : 8.0;

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _totalsRow(
                  label: AppStrings.t('subtotal_label', loc),
                  value: totals.subtotalDisplay,
                  valueKey: const Key('pos-subtotal-value'),
                  color: cs.onSurface.withValues(alpha: 0.78),
                  fontSize: subSize,
                  verticalPad: rowPad,
                ),
                _totalsRow(
                  label: AppStrings.t('invoice_discount', loc),
                  value: '-${totals.invoiceDiscountDisplay}',
                  valueKey: const Key('pos-discount-value'),
                  color: AppColors.warning,
                  fontSize: subSize,
                  verticalPad: rowPad,
                ),
                Divider(height: mediaH < 700 ? 10.0 : 12.0),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Flexible(
                      child: Text(
                        AppStrings.t('total_label', loc),
                        key: const Key('pos-total-label'),
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontSize: labelSize,
                          fontWeight: FontWeight.w700,
                          color: cs.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: AlignmentDirectional.centerEnd,
                        child: Text(
                          '${totals.totalDisplay} $currency',
                          key: const Key('pos-total-value'),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontSize: totalSize,
                            fontWeight: FontWeight.w800,
                            color: cs.primary,
                            height: 1.05,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: gapAfterTotal),
                SafeArea(
                  top: false,
                  child: SizedBox(
                    height: payHeight,
                    child: cart.returnMode
                        ? _returnActions(
                            theme: theme,
                            cs: cs,
                            loc: loc,
                            payHeight: payHeight,
                            payFontSize: payFontSize,
                            payIconSize: payIconSize,
                          )
                        : FilledButton(
                            key: const Key('pos-pay-button'),
                            style: FilledButton.styleFrom(
                              minimumSize: Size.fromHeight(payHeight),
                              maximumSize: Size(double.infinity, payHeight),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12),
                              textStyle: theme.textTheme.labelLarge?.copyWith(
                                fontSize: payFontSize,
                                fontWeight: FontWeight.w700,
                              ),
                              backgroundColor: cs.primary,
                              disabledBackgroundColor:
                                  cs.onSurface.withValues(alpha: 0.12),
                              disabledForegroundColor:
                                  cs.onSurface.withValues(alpha: 0.38),
                            ),
                            onPressed: payEnabled ? onPayment : null,
                            child: cart.checkoutPending
                                ? Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2.5,
                                          color: cs.onPrimary,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Flexible(
                                        child: Text(
                                          AppStrings.t('processing', loc),
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: payFontSize - 1,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.credit_card,
                                        size: payIconSize,
                                        color: payEnabled
                                            ? cs.onPrimary
                                            : cs.onSurface
                                                .withValues(alpha: 0.38),
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          '${AppStrings.t('payment_shortcut', loc)}'
                                          ' — ${totals.totalDisplay} $currency',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Return-mode actions replacing PAY: Confirm return (server prices
  /// every line) + Cancel return (no API call, cart untouched). Both are
  /// locked while the attempt is in flight.
  Widget _returnActions({
    required ThemeData theme,
    required ColorScheme cs,
    required String loc,
    required double payHeight,
    required double payFontSize,
    required double payIconSize,
  }) {
    final locked = cart.returnPending;
    return Row(
      key: const Key('pos-return-actions'),
      children: [
        Expanded(
          flex: 3,
          child: FilledButton(
            key: const Key('pos-return-confirm-button'),
            style: FilledButton.styleFrom(
              minimumSize: Size.fromHeight(payHeight),
              maximumSize: Size(double.infinity, payHeight),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontSize: payFontSize,
                fontWeight: FontWeight.w700,
              ),
              backgroundColor: cs.error,
              foregroundColor: cs.onError,
              disabledBackgroundColor: cs.onSurface.withValues(alpha: 0.12),
              disabledForegroundColor: cs.onSurface.withValues(alpha: 0.38),
            ),
            onPressed: locked ? null : onConfirmReturn,
            child: locked
                ? Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: cs.onError,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          AppStrings.t('processing', loc),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: payFontSize - 1,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  )
                : Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.replay, size: payIconSize),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          AppStrings.t('pos_return_confirm', loc),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: OutlinedButton(
            key: const Key('pos-return-cancel-button'),
            style: OutlinedButton.styleFrom(
              minimumSize: Size.fromHeight(payHeight),
              maximumSize: Size(double.infinity, payHeight),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              textStyle: theme.textTheme.labelLarge?.copyWith(
                fontSize: payFontSize - 1,
                fontWeight: FontWeight.w700,
              ),
              side: BorderSide(color: cs.outline),
            ),
            onPressed: locked ? null : onCancelReturn,
            child: Text(
              AppStrings.t('cancel', loc),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ],
    );
  }

  static Widget _totalsRow({
    required String label,
    required String value,
    required Key valueKey,
    required Color color,
    required double fontSize,
    double verticalPad = 2,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPad),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            value,
            key: valueKey,
            style: TextStyle(
              fontSize: fontSize + 1,
              fontWeight: FontWeight.w700,
              height: 1.3,
              // Digits line up down the right edge of the totals column.
              fontFeatures: const [FontFeature.tabularFigures()],
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _CartLineTile extends StatefulWidget {
  final CartLine line;
  final VoidCallback onRemove;

  /// Line tapped / qty focused → becomes the `+` / `*` target (FIX #2).
  final VoidCallback onActivate;

  /// Shared validating quantity mutation; returns true when applied
  /// (false = rejected, the caller already showed the localized toast).
  final bool Function(String quantity) onQty;
  final ValueChanged<String> onDiscount;

  /// Set when *this* line should take keyboard focus (Phase 8 FIX #1);
  /// consumed (reset) by the tile so a stale request never re-fires.
  final ValueNotifier<String?>? qtyFocusRequest;

  const _CartLineTile({
    super.key,
    required this.line,
    required this.onRemove,
    required this.onActivate,
    required this.onQty,
    required this.onDiscount,
    this.qtyFocusRequest,
  });

  @override
  State<_CartLineTile> createState() => _CartLineTileState();
}

class _CartLineTileState extends State<_CartLineTile> {
  late final TextEditingController _qty;
  late final TextEditingController _discount;
  late final FocusNode _qtyFocus;

  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(text: widget.line.quantity);
    _discount = TextEditingController(text: widget.line.lineDiscount);
    _qtyFocus = FocusNode(debugLabel: 'cart-line-qty');
    // Focusing this line's qty field makes it the shortcut target —
    // "tap an older line, type 3, press +" now always hits that line.
    _qtyFocus.addListener(_handleQtyFocus);
    widget.qtyFocusRequest?.addListener(_handleQtyFocusRequest);
    // A focus request may already be waiting for this tile (it was just
    // created by the add that issued it).
    _handleQtyFocusRequest();
  }

  void _handleQtyFocus() {
    if (_qtyFocus.hasFocus) widget.onActivate();
  }

  /// Phase 8 FIX #1: claim the post-add focus request when it names this
  /// line, then focus the quantity field once the frame is complete (the
  /// field may not have been built when the request was made).
  void _handleQtyFocusRequest() {
    final request = widget.qtyFocusRequest;
    if (request == null || request.value != widget.line.key) return;
    request.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _qtyFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant _CartLineTile old) {
    super.didUpdateWidget(old);
    if (!identical(old.qtyFocusRequest, widget.qtyFocusRequest)) {
      old.qtyFocusRequest?.removeListener(_handleQtyFocusRequest);
      widget.qtyFocusRequest?.addListener(_handleQtyFocusRequest);
      _handleQtyFocusRequest();
    }
    if (old.line.quantity != widget.line.quantity &&
        _qty.text != widget.line.quantity) {
      _qty.text = widget.line.quantity;
    }
    if (old.line.lineDiscount != widget.line.lineDiscount &&
        _discount.text != widget.line.lineDiscount) {
      _discount.text = widget.line.lineDiscount;
    }
  }

  @override
  void dispose() {
    widget.qtyFocusRequest?.removeListener(_handleQtyFocusRequest);
    _qtyFocus.removeListener(_handleQtyFocus);
    _qtyFocus.dispose();
    _qty.dispose();
    _discount.dispose();
    super.dispose();
  }

  /// +/- buttons: exact step from the committed quantity (shared minimum
  /// rule), then the shared validation funnel (stock across the bucket).
  void _bumpQty(double delta) {
    widget.onActivate();
    final text = _qtyStepText(widget.line.quantity, delta);
    if (text == null || text == widget.line.quantity) return;
    final applied = widget.onQty(text);
    _qty.text = applied ? text : widget.line.quantity;
  }

  /// Typing: apply as soon as the input is a complete, valid quantity
  /// (plain number or `10*24` expression) — silently wait while it is
  /// still incomplete, never keep an impossible quantity on screen.
  void _handleQtyChanged(String raw) {
    widget.onActivate();
    if (!parseQuantityExpression(raw).isValid) return;
    if (widget.onQty(raw)) return;
    _qty.text = widget.line.quantity;
  }

  /// Enter: strict — an invalid expression or an impossible quantity is
  /// rejected with the localized toast and the field rolls back.
  void _handleQtySubmitted(String raw) {
    widget.onActivate();
    if (!widget.onQty(raw)) _qty.text = widget.line.quantity;
  }

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final line = widget.line;
    // Selected unit label: free-text selling-unit name (Box) or a backend
    // unit code localized via unitLabel (piece → Piece/Pièce/قطعة).
    final selectedUnit = AppStrings.unitLabel(line.unitName, loc);
    final baseUnit = AppStrings.unitLabel(line.productUnit, loc);
    final baseQty = (double.tryParse(line.quantity) ?? 0) *
        (double.tryParse(line.unitMultiplier ?? '') ?? 0);
    // Base info only when a selling unit was chosen and its multiplier
    // actually represents multiple base pieces (or differs from base).
    final showBaseInfo = line.sellingUnitId != null &&
        line.unitMultiplier != null &&
        line.baseUnitPrice != null &&
        baseQty > 0;
    final mediaH = MediaQuery.sizeOf(context).height;
    final short = mediaH < 560;
    // Min content height 90; selling-unit lines need 100–120 (UX FIX #8).
    final minHeight = showBaseInfo
        ? (short ? 100.0 : 112.0)
        : (short ? 88.0 : 96.0);
    final discountValue = double.tryParse(line.lineDiscount) ?? 0;
    final discountActive = discountValue > 0;

    return Padding(
      key: Key('cart-line-${line.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Material(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: theme.dividerColor.withValues(alpha: 0.55),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    // Tapping the line selects it as the `+` / `*` target.
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onActivate,
                      child: Row(
                        children: [
                          if (line.isPack) ...[
                            Container(
                              key: Key('cart-line-pack-badge-${line.key}'),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary
                                    .withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: theme.colorScheme.primary
                                      .withValues(alpha: 0.5),
                                ),
                              ),
                              child: Text(
                                AppStrings.t('pack_badge', loc),
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Expanded(
                            child: Text(
                              line.name,
                              key: Key('cart-line-name-${line.key}'),
                              style: theme.textTheme.titleMedium?.copyWith(
                                fontSize: short ? 17.0 : 18.0,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    line.lineTotal.toStringAsFixed(2),
                    key: Key('cart-line-total-${line.key}'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: short ? 16.0 : 17.0,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  IconButton(
                    key: Key('cart-line-remove-${line.key}'),
                    tooltip: AppStrings.t('remove_line', loc),
                    constraints:
                        const BoxConstraints(minWidth: 40, minHeight: 40),
                    padding: EdgeInsets.zero,
                    iconSize: 20,
                    icon: const Icon(Icons.close),
                    onPressed: widget.onRemove,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      key: Key('cart-line-qty-dec-${line.key}'),
                      tooltip: AppStrings.t('qty_decrease', loc),
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                      padding: EdgeInsets.zero,
                      iconSize: 26,
                      icon:
                          const Icon(Icons.remove_circle_outline),
                      onPressed: (double.tryParse(_qty.text) ?? 0) <= 1
                          ? null
                          : () => _bumpQty(-1),
                    ),
                  ),
                  SizedBox(
                    width: short ? 48.0 : 56.0,
                    child: TextField(
                      key: Key('cart-line-qty-${line.key}'),
                      controller: _qty,
                      focusNode: _qtyFocus,
                      textAlign: TextAlign.center,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      style: TextStyle(
                        fontSize: short ? 15.0 : 16.0,
                        fontWeight: FontWeight.w700,
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        labelText: AppStrings.t('qty', loc),
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 12,
                        ),
                      ),
                      // Quantity expressions (`10*24` → 240) are parsed by
                      // the shared funnel in pos_quantity.dart.
                      onSubmitted: _handleQtySubmitted,
                      onChanged: _handleQtyChanged,
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      key: Key('cart-line-qty-inc-${line.key}'),
                      tooltip: AppStrings.t('qty_increase', loc),
                      constraints:
                          const BoxConstraints(minWidth: 44, minHeight: 44),
                      padding: EdgeInsets.zero,
                      iconSize: 26,
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: () => _bumpQty(1),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Dominant: selected qty × unit × selling-unit price.
                        Text(
                          '${line.quantity} $selectedUnit × ${line.unitPrice}',
                          key: Key('cart-line-summary-${line.key}'),
                          style: theme.textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontSize: short ? 14.0 : 15.0,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (line.promotionApplied)
                          // Phase 18 — the line is charging the promotion
                          // price; the original retail is struck through
                          // (display only, server recomputes at checkout).
                          Text.rich(
                            TextSpan(
                              text: AppStrings.t('promotion', loc),
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: theme.colorScheme.tertiary,
                              ),
                              children: [
                                if (line.retailPrice != null)
                                  TextSpan(
                                    text: ' · ${line.retailPrice}',
                                    style: TextStyle(
                                      decoration: TextDecoration.lineThrough,
                                      fontWeight: FontWeight.w500,
                                      color: theme.colorScheme.onSurface
                                          .withValues(alpha: 0.6),
                                    ),
                                  ),
                              ],
                            ),
                            key: Key('cart-line-promotion-${line.key}'),
                          ),
                        if (line.wholesaleApplied)
                          // Phase 17 pricing — the line crossed the whole-
                          // sale threshold (base quantity) and is charging
                          // the wholesale rate.
                          Text(
                            AppStrings.t('wholesale', loc),
                            key: Key('cart-line-wholesale-${line.key}'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        if (line.isPack &&
                            (line.componentsSummary ?? '').isNotEmpty) ...[
                          // Phase 10 — what the pack bundles (display only).
                          Text(
                            line.componentsSummary!,
                            key: Key('cart-line-pack-components-${line.key}'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        if (showBaseInfo) ...[
                          // Secondary: base-quantity equivalence (multiplier).
                          Text(
                            '${_fmtQty(baseQty)} $baseUnit',
                            key: Key('cart-line-base-qty-${line.key}'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                          // Informational only — never feeds the cart total.
                          Text(
                            '${AppStrings.t('base_price', loc)}: '
                            '${_fmtPrice(line.baseUnitPrice)} / $baseUnit',
                            key: Key('cart-line-base-price-${line.key}'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // Compact line discount 36–40px, warning when > 0 (UX FIX #8).
              SizedBox(
                height: 38,
                width: short ? 120 : 140,
                child: TextField(
                  key: Key('cart-line-discount-${line.key}'),
                  controller: _discount,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: discountActive ? FontWeight.w700 : null,
                    color: discountActive ? AppColors.warning : null,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: AppStrings.t('line_discount', loc),
                    labelStyle: TextStyle(
                      fontSize: 13,
                      color: discountActive ? AppColors.warning : null,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: discountActive
                            ? AppColors.warning
                            : theme.colorScheme.outline.withValues(alpha: 0.4),
                        width: discountActive ? 1.5 : 1,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(
                        color: discountActive
                            ? AppColors.warning
                            : theme.colorScheme.primary,
                        width: 1.5,
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                  ),
                  onSubmitted: widget.onDiscount,
                  onChanged: widget.onDiscount,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Display helpers for cart-line unit presentation (UX FIX #3).
/// Whole numbers render without decimals (10 not 10.0).
String _fmtQty(double v) => v == v.roundToDouble()
    ? v.toInt().toString()
    : v.toStringAsFixed(2);

String _fmtPrice(String? raw) {
  final v = double.tryParse(raw ?? '');
  if (v == null) return raw ?? '0';
  return v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2);
}
