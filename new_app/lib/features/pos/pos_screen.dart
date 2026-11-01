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
// Shift+F6 add customer, F7 invoice discount, Shift+F7 use loyalty
// points, SPACE payment (legacy F8 removed), F9 hold,
// F10 held sales, F11 history, F12 clear (confirm), + add one unit /
// - remove one unit / * enter a new quantity for the last active cart
// line, Escape clears search (or hands focus back to the workspace) —
// never the cart. F1–F5/Ctrl+N live one level up in the nav shell so the
// map is the same on every screen (lib/core/app_shortcuts.dart); the local
// bindings below cover everything POS owns. The Shift combinations never
// collide with the plain F-key row (SingleActivator matches modifiers
// exactly), are declined while a query/field is actually being typed
// (posFocusRouting) and go inert behind any modal dialog (their route
// scopes sit outside this page's CallbackShortcuts).
//
// `+`, `-`, `*` (UX FIX #12 / Phase 8 FIX #1–#3): claimed while the POS
// search field or a cart quantity field has focus (typing them there
// acts on the active line, never inserts the char); any other text field
// keeps normal typing. Quantity typing accepts expressions (`10*24` →
// 240); every mutation is parsed, stock-validated and applied through
// pos_quantity.dart (one shared rule).
//
// Add → active line: a successful add (new or merged line) makes that
// line active, so `+` / `-` / `*` keep working without the mouse. NO
// quantity field is auto-focused by an add (Phase 8 FIX #1 retired) —
// a qty field takes focus only when the cashier clicks/taps it.
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/amount_entry.dart';
import '../../core/barcode_scanner.dart';
import '../../core/barcode/barcode_normalizer.dart';
import '../../core/colors.dart';
import '../../core/keyboard.dart';
import '../../core/number_format.dart';
import '../../core/numeric_text.dart';
import '../../core/scan_diagnostics.dart';
import '../../core/search_field_state.dart';
import '../../core/shortcut_badge.dart';
import '../../core/shortcuts.dart';
import '../../core/strings.dart';
import '../../core/widgets/h_scroll_view.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../auth/permission_helpers.dart';
import '../clients/clients_providers.dart';
import '../clients/customer_form_dialog.dart';
import '../clients/customer_models.dart';
import '../loyalty/loyalty_models.dart';
import '../loyalty/loyalty_providers.dart';
import '../packs/pack_models.dart';
import '../products/models.dart';
import '../products/product_form_dialog.dart';
import '../products/products_providers.dart';
import '../products/quantity_dialog.dart';
import '../products/selling_unit_picker.dart';
import '../products/variant_picker.dart';
import '../returns/return_providers.dart';
import '../settings/pos_settings_provider.dart';
import '../settings/scan_settings_provider.dart';
import '../settings/settings_provider.dart';
import '../shell/shortcuts_help_dialog.dart';
import '../stock/adjust_dialog.dart';
import '../stock/inventory_models.dart';
import 'customer_picker_dialog.dart';
import 'holds_dialog.dart';
import 'invoice_discount_dialog.dart';
import 'loyalty_discount_dialog.dart';
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

/// Result of the canonical barcode resolve: [hit] recognized and handed to
/// the existing add flow; [miss] a DEFINITIVE lookup miss (the server
/// answered — no product/variant/selling unit carries the code); [error]
/// the lookup or the follow-up product fetch failed (transient — never a
/// "no such barcode" verdict, so it can never raise the unknown-barcode
/// scan action).
enum _ScanResolve { hit, miss, error }

class _PosScreenState extends ConsumerState<PosScreen> {
  final FocusNode _focusNode = FocusNode();
  final FocusNode _searchFocusNode = FocusNode();
  final TextEditingController _searchController = TextEditingController();

  /// Key of the cart line whose quantity field should show the committed
  /// quantity again once the current frame lands — set by a scan that was
  /// submitted from that field (the merge is still resolving, so the
  /// field must not be overwritten mid-flight: a wedge burst typed on top
  /// of the barcode would lose its committed prefix). Consumed by the
  /// matching [_CartLineTile]; a scan arriving before the reset lands is
  /// detected by [_CartLineTileState._runBase], never by the field text.
  final ValueNotifier<String?> _clearQtyTextRequest =
      ValueNotifier<String?>(null);

  /// Key of the cart line arrow navigation (_moveActiveLine) should bring
  /// fully into view — consumed by the matching [_CartLineTile] the moment
  /// it exists: by a mounted listener immediately, or by initState when
  /// the lazy standard list builds the target only AFTER the jump laid its
  /// region out. A plain selected-transition reveal can never fire there
  /// (the tile mounts already selected, so didUpdateWidget never runs).
  final ValueNotifier<String?> _revealRequest = ValueNotifier<String?>(null);
  bool _cartDrawerOpen = false;

  /// Cart-panel chrome compaction level (0..2), driven post-frame by the
  /// lines-region probe so a full cart row always fits above the fixed
  /// footer on short viewports (the footer never obscures the last row).
  int _chromeLevel = 0;

  /// One scan-action dialog at a time: while the unknown-barcode Add
  /// Product form or the out-of-stock Adjust Stock dialog is open, a
  /// repeated scan (or a field-path submit) never stacks a second dialog.
  /// The gateway already blocks bursts behind a modal route — this also
  /// covers submits that reach the resolve path with a dialog on screen.
  bool _scanActionDialogOpen = false;

  /// One dialog per shortcut action — [Shift+F6] (add customer) and
  /// [Shift+F7] (use points) are key-down bound, so a double press inside
  /// one frame (before the dialog route's focus scope takes over) must not
  /// stack two dialogs or run two redemption writes. Mirrors
  /// [_scanActionDialogOpen]; released in a finally so a thrown/successful
  /// flow can never leave the shortcut dead.
  bool _customerFormOpen = false;
  bool _redemptionOpen = false;

  /// Standard cart list scroll position — [_moveActiveLine] jumps it to the
  /// matching end when a FIRST arrow press enters the list from the
  /// unselected state (the lazy list may not have built the target tile
  /// yet); every other reveal is Scrollable.ensureVisible inside the tile.
  final ScrollController _linesController = ScrollController();

  /// Last POS return-mode failure (localized message + raw backend
  /// detail) — shown inline in the return banner and as a toast. Kept
  /// out of the cart provider on purpose: checkout's `lastError` listener
  /// would otherwise double-toast it, and the return flow already has its
  /// own banner surface.
  PosApiError? _returnError;

  /// Quick-sale re-entry guard: SPACE can auto-repeat and the checkout
  /// pipeline has awaits (loyalty preview settle, POST) before the cart
  /// empties — one in-flight quick sale swallows every repeat until the
  /// attempt finishes. `PosCartNotifier.checkout` keeps its own
  /// `checkoutPending` gate; this flag additionally covers the window
  /// BEFORE checkout is even entered.
  bool _quickSaleBusy = false;

  /// This screen's page-level shortcut hooks, published to the nav shell.
  late final PageShortcuts _pageShortcuts;

  /// App-level scan target (core/barcode_scanner.dart): while this screen
  /// is the live route and no text field has focus, a wedge burst
  /// (digits + Enter) resolves through the canonical scan path — the
  /// same [_handleLineScan] the focused-field submits use.
  late final BarcodeScanHandler _scanHandler;

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
    // Global barcode capture: scans land here even with the workspace
    // unfocused (never stealing a key a focused field or dialog owns).
    _scanHandler = BarcodeScanHandler(
      context: context,
      name: 'pos',
      onScan: _handleLineScan,
      allowWhileEditingFor: (editable) =>
          editable.controller == _searchController ||
          editable.focusNode.debugLabel == 'cart-line-qty',
      allowIncompletePassThrough: true,
      allowReplacementPassThrough: true,
    );
    BarcodeScannerGateway.instance.register(_scanHandler);
    // The catalog query outlives this page State: restore the box so the
    // visible input and the tracked catalog term always describe the same
    // search (the notifier's text covers a burst whose debounce had not
    // fired when this State was disposed).
    seedSearchField(
      _searchController,
      ref.read(posSearchProvider.notifier).trackedQuery,
    );
    Future.microtask(() async {
      // Await the catalog first: the cart's per-line stock snapshots are
      // re-seeded from what actually loads (a purchase received while the
      // cart held lines must not leave them validating stale numbers).
      await ref.read(posSearchProvider.notifier).load();
      ref.read(favoritesProvider.notifier).load();
      ref.read(holdsProvider.notifier).load();
      _syncCartStocks();
    });
  }

  @override
  void dispose() {
    // Stop claiming global scans first — a half-torn-down screen must
    // never receive (or block) another burst.
    BarcodeScannerGateway.instance.unregister(_scanHandler);
    if (identical(PageShortcutsRegistry.current, _pageShortcuts)) {
      PageShortcutsRegistry.current = null;
    }
    _focusNode.dispose();
    _searchFocusNode.dispose();
    _searchController.dispose();
    _clearQtyTextRequest.dispose();
    _revealRequest.dispose();
    _linesController.dispose();
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
    _syncCartStocks();
  }

  /// Re-reads every cart line's stock snapshot from the catalog that was
  /// just loaded, then warns the cashier when a line's available quantity
  /// SHRANK (the cart may now exceed what is on the shelf).
  ///
  /// Called after each catalog load — screen activation and F5 — because
  /// stock can move while this page is away (purchases received on the
  /// Purchases screen, sales run elsewhere). Lines whose product is not
  /// in the loaded page keep their snapshot; the server stays
  /// authoritative at checkout either way.
  void _syncCartStocks() {
    if (!mounted) return;
    final stocks = <String, String>{
      for (final product in ref.read(posSearchProvider).items)
        product.id: product.quantity,
    };
    if (stocks.isEmpty) return;
    final decreasedKeys =
        ref.read(posCartProvider.notifier).syncAvailableStock(stocks);
    if (decreasedKeys.isEmpty || !mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('pos_cart_stock_changed', loc),
      kind: PosToastKind.warning,
      key: const Key('pos-cart-stock-changed-toast'),
    );
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

  Future<void> _handleShortcut(LogicalKeyboardKey key) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final cart = ref.read(posCartProvider);
    final canDiscount = ref.read(hasPermissionProvider('pos_discount'));

    if (key == LogicalKeyboardKey.f6) {
      final customer = await showCustomerPickerDialog(context);
      if (customer != null) {
        ref.read(posCartProvider.notifier).setCustomer(customer);
      }
      _restoreSearchFocusAfterDialog();
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
    // uses — one flow, one message. With Quick sale (Space) ON the SAME
    // key completes the sale directly through the existing checkout
    // pipeline (see [_quickSale]); the focus predicate above then declines
    // in EVERY editable context, so Space keeps its normal typing meaning
    // in the search box, quantity fields and any dialog input.
    if (key == LogicalKeyboardKey.space) {
      if (ref.read(posSettingsProvider).quickSaleWithSpace) {
        await _quickSale();
      } else {
        await _openPayment();
      }
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
        // Clear Cart empties the CART only. The catalog, the search query,
        // favorites and the view mode stay exactly as the cashier left
        // them — no search reset, no refetch, no navigation.
        ref.read(posCartProvider.notifier).clearCart(reason: 'clear-dialog');
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
      reason: 'shortcut-increment',
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
      reason: 'shortcut-decrement',
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
      reason: 'quantity-dialog',
      onError: _showQtyError,
    );
  }

  /// Delete — remove the selected (last active) cart line through the SAME
  /// [removeLine] path its remove button uses — no extra confirmation, no
  /// second removal implementation. No quantity-field focus is required:
  /// selection alone (`lastActiveKey`, falling back to the newest line)
  /// names the target. Claimed only while NO text input has focus
  /// ([TextFreeKeyActivator]), so Delete keeps editing search, quantity,
  /// discount and every dialog/picker field.
  void _removeActiveLine() {
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
    ref.read(posCartProvider.notifier).removeLine(line.key);
  }

  /// Up/Down — move the selected cart line by [delta] (−1 = up, +1 = down).
  ///
  /// Selection is CLAMPED at both ends: the first press from the
  /// unselected state enters the list (Down → first line, Up → last line),
  /// every further press walks exactly one line and stops at the ends; an
  /// empty cart is a no-op. The moved-to tile reveals itself when it
  /// becomes selected (geometry check inside [_CartLineTile] — a fully
  /// visible row never moves, a row above the fold top-aligns, a row below
  /// it bottom-aligns). The standard list builds tiles lazily: an entering
  /// jump can cross the whole list, so the matching END is scrolled to
  /// first, and a mid-list step that lands outside the built window lays
  /// the target's estimated region out first ([_jumpNearTarget]) — the
  /// dense table builds every row eagerly and needs neither jump. Focus
  /// never moves — the activator only fires outside text editing, so the
  /// barcode field keeps it.
  void _moveActiveLine(int delta) {
    final cart = ref.read(posCartProvider);
    final lines = cart.lines;
    if (lines.isEmpty) return;
    final keys = [for (final line in lines) line.key];
    final active = cart.lastActiveKey;
    var index = active == null ? -1 : keys.indexOf(active);
    final dense =
        ref.read(posLayoutSwitchProvider) == PosScreenLayout.reversed;
    final controller = _linesController;
    if (index < 0) {
      index = delta > 0 ? 0 : keys.length - 1;
      if (!dense && controller.hasClients) {
        // Lay out the END the entering selection starts from so the target
        // tile EXISTS for its reveal in the very next frame.
        controller.jumpTo(delta > 0
            ? controller.position.minScrollExtent
            : controller.position.maxScrollExtent);
      }
    } else {
      final next = index + delta;
      index = next < 0 ? 0 : (next >= keys.length ? keys.length - 1 : next);
      if (!dense && controller.hasClients) {
        _jumpNearTarget(controller.position, index, keys.length);
      }
    }
    final target = keys[index];
    // Publish BEFORE the state change: a mounted target consumes it
    // synchronously and reveals itself post-frame; an un-built target
    // claims it in initState once the jump above put its region on screen.
    _revealRequest.value = target;
    ref.read(posCartProvider.notifier).setActiveLine(target);
  }

  /// Standard lazy list: a normal one-row step can land OUTSIDE the built
  /// window (a freshly preselected line far below the fold never mounts,
  /// so no tile-level ensureVisible could ever run for it). Lay out the
  /// target's region first — an average-row-height estimate, good enough
  /// because the tile's own ensureVisible refines it once the row exists
  /// and every further press recomputes from the new position. Inside the
  /// built window nothing moves (those tiles reveal themselves minimally).
  static void _jumpNearTarget(
      ScrollPosition position, int index, int count) {
    if (count <= 0 || !position.hasContentDimensions) return;
    final avg =
        (position.maxScrollExtent + position.viewportDimension) / count;
    if (avg <= 0) return;
    final target = index * avg + avg / 2;
    const cache = 250.0; // ListView's default cacheExtent
    if (target >= position.pixels - cache &&
        target <= position.pixels + position.viewportDimension + cache) {
      return; // Already within the built region — tiles can reveal.
    }
    position.jumpTo((target - position.viewportDimension / 2)
        .clamp(position.minScrollExtent, position.maxScrollExtent));
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
      reason: 'quantity-field-or-step-button',
      scanCorrelationId: lastScanCorr,
      onError: _showQtyError,
    );
  }

  /// Enter in search: a complete scan (or typed barcode) resolves through
  /// the canonical exact barcode lookup FIRST — the debounced catalog the
  /// keystrokes raced is irrelevant, so a scanner's Enter that lands
  /// before the debounce still adds the right product exactly once. When
  /// the lookup misses, a fresh text search covers name / SKU / barcode
  /// exact matches and the documented first-result fallback; nothing found
  /// anywhere raises a clear not-found toast instead of silence. A single
  /// Enter can never double-add (re-entry guard).
  bool _submitSearchInFlight = false;

  Future<void> _submitSearch() async {
    if (_submitSearchInFlight) return;
    final rawQuery = _searchController.text.trim();
    final query = normalizeBarcode(rawQuery);
    if (query.isEmpty) return;
    if (rawQuery != query) {
      _searchController.value = TextEditingValue(
        text: query,
        selection: TextSelection.collapsed(offset: query.length),
      );
    }
    // ORIGIN event for the focused-search path: the next resolve /
    // receive hop correlates to this submit. `len` > 13 after a scan
    // session would reveal a STALE prefix concatenated onto the next
    // code (a burst split across fields).
    lastScanCorr = scanDiag('search-submit', {
      'target': 'pos',
      'len': query.length,
      'suffix3': scanDiagSuffix3(query),
    });
    final scanCorrelationId = lastScanCorr;
    if (rawQuery != query) {
      scanDiag('scan-normalization', {
        'target': 'pos',
        'corr': lastScanCorr,
        'rawLength': rawQuery.length,
        'normalizedLength': query.length,
        'normalized': true,
        'origin': 'focused-search',
      });
    }
    if (query.toUpperCase().startsWith(kLoyaltyQrPrefix)) {
      await _submitLoyaltyLookup(query);
      return;
    }
    _submitSearchInFlight = true;
    try {
      // This submit resolves the code itself — the pending digit-search
      // debounce would only fire mid-chain as a wasted catalog request
      // racing the resolve (and a panel churn right before the add). The
      // typed text stays: a lookup miss re-runs load() with exactly it.
      ref.read(posSearchProvider.notifier).cancelPendingSearch();
      final resolve = await _resolveAndAddBarcode(
        query,
        scanCorrelationId: scanCorrelationId,
      );
      if (resolve == _ScanResolve.hit) return;
      // Fresh results for THIS query (cancels the pending debounce), then
      // exact name/SKU/barcode match. The documented first-result fallback
      // applies to TYPED text only — a pure-digit query is a scan shape,
      // and after the canonical lookup missed it, fuzzy-adding the first
      // catalog row would put the WRONG product in the cart. Numeric SKUs
      // still resolve through the exact-match loop above.
      await ref.read(posSearchProvider.notifier).load();
      final products = ref.read(posSearchProvider).items;
      ProductModel? exact;
      for (final p in products) {
        if (p.barcode == query || p.name == query || p.sku == query) {
          exact = p;
          break;
        }
      }
      if (exact == null && products.isNotEmpty && !_scanShaped(query)) {
        exact = products.first;
      }
      if (exact != null) {
        // Search-input add (the focused search field consumed the input —
        // typed text or a wedge burst that landed there): the field keeps
        // focus for the next code; never auto-focus a qty field.
        await _addProduct(
          exact,
          fromScan: true,
          scanCorrelationId: scanCorrelationId,
        );
        _clearSearchAfterAdd();
      } else {
        await _handleUnknownBarcode(
          query,
          definitiveMiss: resolve == _ScanResolve.miss,
        );
      }
    } finally {
      _submitSearchInFlight = false;
    }
  }

  /// A pure digit run — the shape a keyboard-wedge scanner types (EAN-8 /
  /// UPC-A / EAN-13 …). Distinguishes "scan of an unknown code" (never
  /// fuzzy-match it) from typed text ("bre" + Enter → first result).
  static bool _scanShaped(String query) =>
      RegExp(r'^\d+$').hasMatch(query);

  /// Canonical exact barcode resolve (string-preserving, server-side
  /// selling-unit → variant → product). [_ScanResolve.hit] when the code
  /// was recognized and handed to the existing add flow (which applies the
  /// archived / out-of-stock / picker rules); [_ScanResolve.miss] on a
  /// definitive lookup miss; [_ScanResolve.error] when the lookup or the
  /// follow-up fetch failed — callers fall back to text search, and only
  /// a true miss may raise the unknown-barcode scan action.
  Future<_ScanResolve> _resolveAndAddBarcode(
    String code, {
    int? scanCorrelationId,
  }) async {
    final lookup =
        await ref.read(barcodeLookupProvider.notifier).lookup(code);
    final productId = lookup?.found == true ? lookup?.productId : null;
    if (!mounted || productId == null) {
      scanDiag('scan-resolve', {
        'outcome':
            !mounted ? 'stale' : (lookup == null ? 'error' : 'miss'),
        'corr': lastScanCorr,
        'len': code.length,
        'suffix3': scanDiagSuffix3(code),
      });
      if (!mounted) return _ScanResolve.miss;
      return lookup == null ? _ScanResolve.error : _ScanResolve.miss;
    }
    scanDiag('scan-resolve', {
      'outcome': 'hit',
      'corr': lastScanCorr,
      'productId': productId,
      'len': code.length,
      'suffix3': scanDiagSuffix3(code),
    });
    try {
      final dio = ref.read(apiClientProvider).dio;
      // Round-trip triage: all three decision fetches depend only on the
      // resolved product id, so they START together — the add costs one
      // more sequential round trip (the product response, the only gate
      // that can carry a fresh price/stock/promotion for the cart) instead
      // of three. The lookup above still runs alone first: its productId
      // keys everything here.
      final productFuture = dio.get('/api/v1/products/$productId');
      final variantsFuture = _fetchActiveVariants(productId);
      final unitsFuture = _fetchActiveSellingUnits(productId);
      final response = await productFuture;
      final product =
          ProductModel.fromJson(response.data as Map<String, dynamic>);
      if (!mounted) {
        // recognized — never fall through
        return _ScanResolve.hit;
      }
      // Gateway/qty-field scan add: the scan input keeps focus (see
      // [_clearSearchAfterAdd]); the qty field is never auto-focused.
      await _addProduct(
        product,
        fromScan: true,
        scanCorrelationId: scanCorrelationId,
        variantsFuture: variantsFuture,
        unitsFuture: unitsFuture,
      );
      _clearSearchAfterAdd();
      return _ScanResolve.hit;
    } on DioException {
      scanDiag('scan-resolve', {
        'outcome': 'error',
        'corr': lastScanCorr,
        'len': code.length,
        'suffix3': scanDiagSuffix3(code),
      });
      return _ScanResolve.error;
    }
  }

  /// Continuous-scanning hygiene: a processed scan leaves the barcode field
  /// empty and focused, so the next wedge burst types a fresh code instead
  /// of concatenating onto the previous one.
  void _clearSearchAfterAdd() {
    if (!mounted) return;
    _searchController.clear();
    final notifier = ref.read(posSearchProvider.notifier);
    final search = ref.read(posSearchProvider);
    // The panel only needs a reload when what it shows no longer IS the
    // browse list: a search query consumed text (state.query — which lands
    // together with its rows, so it reads exactly "the visible items are
    // filtered"), or nothing has loaded yet (initial load still in flight
    // or a previous error). Otherwise the browse rows on screen are
    // exactly what this clear must leave visible — a scan that never
    // disturbed the search must NOT refetch the whole catalog (that was a
    // full page-1 request per scanned barcode).
    if (search.query.isNotEmpty || search.items.isEmpty) {
      notifier.clear();
      // The clear above resets the catalog state to an EMPTY result set
      // (no query, no items) — without an immediate reload the product
      // panel sticks on the "No matching products" empty state until the
      // cashier navigates away and back. Reload the normal product list
      // right away (same clear + load pairing Escape already uses).
      unawaited(notifier.load());
    } else {
      // Undisturbed: keep the browse rows, drop the typed text / pending
      // debounce / in-flight search instead.
      notifier.resetQuery();
    }
    // One physical scan must complete in exactly ONE consumer: if the qty
    // field currently holds a burst-in-progress (or any focused field
    // holds uncommitted input), the post-add search refocus would yank the
    // remaining digits of the in-flight burst out of their current field
    // mid-stream (the real-device `qty-submit len=7` split: prefix into
    // search, suffix into qty — or vice versa). Skip the refocus; the
    // scan session's field keeps the digits it already has.
    if (_focusInterruptedByInput()) {
      scanDiag('focus-yank', {'outcome': 'blocked-input'});
      return;
    }
    _searchFocusNode.requestFocus();
  }

  void _showBarcodeNotFound() {
    if (!mounted) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    showPosToast(
      context,
      message: AppStrings.t('product_not_found', loc),
      kind: PosToastKind.error,
      key: const Key('pos-barcode-not-found-toast'),
    );
  }

  /// A scan landed in a focused cart quantity field (the next scan of a
  /// continuous session — the cashier may have clicked a qty field
  /// mid-session): forward the code to the same canonical resolve path.
  /// Unknown codes get the configured unknown-barcode action (or the
  /// clear not-found toast); recognized codes reuse every cart rule
  /// (merge-increment, stock guard, pickers).
  Future<void> _handleLineScan(String code) async {
    final scanCorrelationId = lastScanCorr;
    // First statement, synchronously: every dispatch (gateway or field
    // path) leaves a receive trace here, correlated to its origin.
    scanDiag('scan-receive', {
      'corr': lastScanCorr,
      'len': code.length,
      'suffix3': scanDiagSuffix3(code),
    });
    // Same rule as the submit path: this scan resolves its own code — a
    // digit-search debounce left over from an earlier focus change must
    // not fire mid-resolve as a wasted catalog request.
    ref.read(posSearchProvider.notifier).cancelPendingSearch();
    final resolve = await _resolveAndAddBarcode(
      code,
      scanCorrelationId: scanCorrelationId,
    );
    if (resolve == _ScanResolve.hit) return;
    await _handleUnknownBarcode(
      code,
      definitiveMiss: resolve == _ScanResolve.miss,
    );
  }

  /// An unknown code reached the end of the resolve path: the configured
  /// Behavior A (Add Product form with the barcode prefilled) fires only
  /// when the setting is ON, the code is a real scan shape (a digit run
  /// of barcode length — never a partial fragment or typed text, same
  /// fingerprint the gateway dispatches) and the miss was DEFINITIVE (a
  /// network failure is never a "no such product" verdict). Everything
  /// else keeps the established not-found toast.
  Future<void> _handleUnknownBarcode(
    String code, {
    required bool definitiveMiss,
  }) async {
    if (!mounted) return;
    final openAddProduct = ref
            .read(scanSettingsProvider)
            .openAddProductOnUnknownBarcode &&
        kBarcodeScanShape.hasMatch(code) &&
        definitiveMiss;
    if (openAddProduct) {
      await _openAddProductForScan(code);
      return;
    }
    _showBarcodeNotFound();
  }

  /// Behavior A: the existing add-product form with the scanned code in
  /// the barcode field (create mode — the form's own validation applies
  /// unchanged). Serialized through [_scanActionDialogOpen] so a repeated
  /// scan never stacks a second dialog; barcode/search focus is restored
  /// after close so scanning resumes immediately.
  Future<void> _openAddProductForScan(String code) async {
    if (!mounted || _scanActionDialogOpen) return;
    _scanActionDialogOpen = true;
    try {
      await showProductFormDialog(context, barcode: code);
    } finally {
      _scanActionDialogOpen = false;
    }
    if (mounted) _searchFocusNode.requestFocus();
  }

  /// Behavior B: the existing Adjust Stock dialog for a scan-driven add
  /// that stock rejected (base ≤ 0 at the gates below, or the merge
  /// guard's out-of-stock verdict via [_scanStockErrorHandler]). Only
  /// ever called from those confirmed stock rejections — never for
  /// network errors or unrelated validation failures. Serialized through
  /// [_scanActionDialogOpen]; a submitted adjustment reloads the catalog
  /// and the cart's stock snapshots so the next scan sees the new
  /// quantity (the callers' [_clearSearchAfterAdd] then restores the
  /// scan input).
  Future<void> _openAdjustStockForScan({
    required ProductModel product,
    VariantModel? variant,
  }) async {
    if (!mounted || _scanActionDialogOpen) return;
    _scanActionDialogOpen = true;
    try {
      final result = await showAdjustDialog(
        context,
        product: InventoryItemModel(
          productId: product.id,
          name: product.name,
          barcode: product.barcode,
          unit: product.unit,
          quantity: product.quantity,
          cost: product.cost,
          price: product.price,
          categoryId: product.categoryId,
          isArchived: product.isArchived,
        ),
        variantId: variant?.id,
        variantName: variant?.name,
      );
      if (result == null || !mounted) return;
      await ref.read(posSearchProvider.notifier).load();
      if (mounted) _syncCartStocks();
    } finally {
      _scanActionDialogOpen = false;
    }
  }

  /// Phase E — barcode wedge scans a loyalty QR into the product search:
  /// the opaque `KLICK:C:<uuid>` payload resolves server-side to exactly
  /// one customer (404 = toast, multi-match only on the defensive path →
  /// disambiguation picker).
  Future<void> _submitLoyaltyLookup(String query) async {
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    final dio = ref.read(apiClientProvider).dio;
    try {
      final response = await dio.get(
        '/api/v1/loyalty/lookup',
        queryParameters: {'q': query},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PosCustomer.fromJson(e as Map<String, dynamic>))
          .toList();
      if (!mounted) return;
      if (items.length == 1) {
        ref.read(posCartProvider.notifier).setCustomer(items.single);
        _searchController.clear();
        ref.read(posSearchProvider.notifier).clear();
        // Same pairing as [_clearSearchAfterAdd]: a clear without a
        // reload would leave the product panel stuck empty after the
        // loyalty QR was scanned into the search field.
        unawaited(ref.read(posSearchProvider.notifier).load());
        _searchFocusNode.requestFocus();
        return;
      }
      if (items.length > 1) {
        final customer = await showCustomerPickerDialog(context);
        if (customer != null && mounted) {
          ref.read(posCartProvider.notifier).setCustomer(customer);
        }
        _restoreSearchFocusAfterDialog();
        return;
      }
      showPosToast(
        context,
        message: AppStrings.t('loyalty_qr_not_found', loc),
        kind: PosToastKind.error,
        key: const Key('pos-loyalty-qr-not-found-toast'),
      );
    } on DioException catch (e) {
      if (!mounted) return;
      showPosToast(
        context,
        message: posApiMessage(e, loc),
        kind: PosToastKind.error,
        key: const Key('pos-loyalty-qr-error-toast'),
      );
    }
  }

  /// [variantsFuture] / [unitsFuture]: prefetched choice lookups for the
  /// scan path (both were started with the product fetch, see
  /// [_resolveAndAddBarcode] — they collapse the add from three sequential
  /// round trips to one). A catalog/manual add fetches them here exactly
  /// as before. If the cashier WAITS in the variant picker the prefetched
  /// unit snapshot is arbitrarily old, so that path discards it and
  /// refetches after the dialog — the fresh-fetch contract unchanged.
  Future<void> _addProduct(
    ProductModel product, {
    bool fromScan = false,
    int? scanCorrelationId,
    Future<_ChoicesLookup<VariantModel>>? variantsFuture,
    Future<_ChoicesLookup<SellingUnitModel>>? unitsFuture,
  }) async {
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
      // Behavior B — a confirmed stock rejection on a scan-driven add
      // raises the existing Adjust Stock dialog (setting ON); otherwise
      // the established out-of-stock toast, unchanged.
      if (fromScan &&
          ref
              .read(scanSettingsProvider)
              .openAdjustStockOnOutOfStockScan) {
        await _openAdjustStockForScan(product: product);
        return;
      }
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
    final variantLookup =
        await (variantsFuture ?? _fetchActiveVariants(product.id));
    if (variantLookup.error != null) {
      _showLookupError(product, variantLookup.error!, fromScan: fromScan);
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
      // The cashier waited in a dialog: the unit snapshot started together
      // with the scan is now arbitrarily old — refetch it fresh below.
      unitsFuture = null;
    }

    // FIX #8: selected variant with stock ≤ 0 → block before unit picker.
    if (variant != null && (double.tryParse(variant.quantity) ?? 0) <= 0) {
      if (!mounted) return;
      // Behavior B, variant scope — the dialog adjusts THIS variant.
      if (fromScan &&
          ref
              .read(scanSettingsProvider)
              .openAdjustStockOnOutOfStockScan) {
        await _openAdjustStockForScan(product: product, variant: variant);
        return;
      }
      showPosToast(
        context,
        message: AppStrings.t('cannot_add_out_of_stock', loc),
        kind: PosToastKind.error,
        key: const Key('pos-out-of-stock-error'),
      );
      return;
    }

    // Fetch selling units once for this product to decide dialog vs direct.
    final unitLookup =
        await (unitsFuture ?? _fetchActiveSellingUnits(product.id));
    if (unitLookup.error != null) {
      _showLookupError(product, unitLookup.error!, fromScan: fromScan);
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

    // Behavior B for the merge-aware cart guard: a scan-driven add that
    // the shared stock rule rejected for INSUFFICIENT stock (the exact
    // `out_of_stock` verdict — an invalid or too-large input keeps the
    // single [_showQtyError] funnel) opens Adjust Stock when the setting
    // is ON. [variant] is final here (every picker above resolved).
    // Non-scan adds keep the plain toast funnel ([qtyErrorHandler] null).
    final PosQuantityErrorHandler? qtyErrorHandler = !fromScan
        ? null
        : (message, isStockError) {
            final loc = ref.read(localeProvider).flutterLocale.languageCode;
            if (isStockError &&
                message == AppStrings.t('out_of_stock', loc) &&
                ref
                    .read(scanSettingsProvider)
                    .openAdjustStockOnOutOfStockScan) {
              unawaited(
                _openAdjustStockForScan(product: product, variant: variant),
              );
              return;
            }
            _showQtyError(message, isStockError);
          };

    // Selling units configure the BASE product only; a variant line must
    // never carry a selling_unit_id — the backend rejects that combination
    // (422 `selling_unit_id cannot be combined with variant_id`). Variants
    // have their own price and stock pool, so skip the selling-unit picker
    // whenever a variant was chosen and flow down the variant-only path
    // (weighted variant → amount dialog with variant price/stock; anything
    // else → direct add qty 1 with variant price/stock).
    if (units.isEmpty || variant != null) {
      // Weight/length product with no selling-unit choice — the cashier
      // must say HOW MUCH (kg/g/m or DA): show the entry dialog instead of
      // silently adding qty 1 (non-weight units keep the direct add below;
      // cancelling the dialog adds nothing).
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
          fromScan: fromScan,
          scanCorrelationId: scanCorrelationId,
          onError: qtyErrorHandler,
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
        fromScan: fromScan,
        scanCorrelationId: scanCorrelationId,
        onError: qtyErrorHandler,
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
      fromScan: fromScan,
      scanCorrelationId: scanCorrelationId,
      onError: qtyErrorHandler,
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
  ///
  /// [fromScan] carries the ORIGIN of the add that hit the failed lookup:
  /// the retry action re-enters [_addProduct] through the exact same flow,
  /// so a scanner-driven add retried from the toast must stay scanner-
  /// driven — its eventual `_addCartLine` must keep treating it as a scan
  /// add (catalog refresh + no focus movement).
  void _showLookupError(
    ProductModel product,
    Object error, {
    bool fromScan = false,
  }) {
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
      onAction: () => _addProduct(product, fromScan: fromScan),
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
    // Scanner/search-driven add (gateway dispatch or the focused search
    // field): after the add the scan input keeps focus — the line's qty
    // field must NEVER be auto-focused, or the next wedge burst lands in
    // it and can be partially submitted as a quantity (`qty-submit len=7`
    // fragments on real hardware). Catalog/manual adds behave the same:
    // NO cart-line quantity field is ever auto-focused after an add —
    // focus moves to a qty field only when the cashier clicks/taps it.
    bool fromScan = false,
    int? scanCorrelationId,
    // Quantity-error funnel override — Behavior B intercepts a confirmed
    // scan-driven `out_of_stock` rejection here (see the handler built in
    // [_addProduct]); null keeps the single [_showQtyError] toast funnel.
    PosQuantityErrorHandler? onError,
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
    String? qtyBefore;
    for (final existing in ref.read(posCartProvider).lines) {
      if (existing.key == line.key) {
        qtyBefore = existing.quantity;
        break;
      }
    }
    final applied = applyAddingLine(
      notifier: ref.read(posCartProvider.notifier),
      cart: ref.read(posCartProvider),
      newLine: line,
      rawInput: quantity,
      loc: loc,
      reason: fromScan ? 'scan-add' : 'manual-add',
      scanCorrelationId: scanCorrelationId,
      onError: onError ?? _showQtyError,
    );
    final cartAfter = ref.read(posCartProvider);
    String? qtyAfter;
    for (final existing in cartAfter.lines) {
      if (existing.key == line.key) {
        qtyAfter = existing.quantity;
        break;
      }
    }
    scanDiag('cart-add', {
      'corr': scanCorrelationId ?? lastScanCorr,
      'productId': productId ?? packId ?? '-',
      'variantId': variantId ?? '-',
      'sellingUnitId': sellingUnitId ?? '-',
      'requested': quantity,
      'stock': availableStock ?? 'unknown',
      'applied': applied,
      // `qtyBefore=-` is NOT a lookup failure: it means NO line with this
      // CartLine.key existed before the add (fresh line — the cart had
      // been reset/cleared elsewhere, or this resolves to a different
      // variant/unit identity than the line the cashier remembers).
      'lineFound': qtyBefore != null,
      'qtyBefore': qtyBefore ?? '-',
      'qtyAfter': qtyAfter ?? '-',
      'cartLines': cartAfter.lines.length,
    });
    // Phase 8 FIX #1 retired: NO quantity field is auto-focused after any
    // add — scanner-driven or catalog/manual. The cashier stays where they
    // are (the scan input keeps focus; a manual add leaves focus on the
    // search field / wherever the click landed) and a qty field takes
    // focus only on an explicit click/tap. The written line still becomes
    // the `+`/`*` target: addLine/updateLine set `lastActiveKey`
    // themselves, so no focus move is needed for that. The line is still
    // REVEALED without focus: dense-table ensureVisible used to ride the
    // post-add focus request; the reveal request gives the same visibility
    // (claimed synchronously by a mounted tile or in initState by the
    // just-built one) while the qty field is never auto-focused.
    if (applied && mounted) {
      _revealRequest.value = line.key;
    }
  }

  /// Restores focus to the product search field after a POS-owned dialog
  /// closes (customer picker or its Quick-Add form, loyalty redemption).
  /// The popped DialogRoute still owns the
  /// primary focus for the remainder of the current frame, so a synchronous
  /// `requestFocus()` would land in the popped route's FocusScope and the
  /// scanner gateway would then reject wedge scans (`focus-popup-route` /
  /// `focus-outside-screen`). Scheduling the request on the NEXT frame runs
  /// it after the route transition completes; the `mounted` guard covers a
  /// widget disposed while the dialog was open. Called on pick AND cancel —
  /// the cashier returns to scanning either way.
  void _restoreSearchFocusAfterDialog() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.requestFocus();
    });
  }

  /// Shared focus gate for the Shift-combo dialog shortcuts (Shift+F6 /
  /// Shift+F7): claim the key from the bare workspace and from the IDLE
  /// barcode field — the autofocused home, i.e. exactly the states Delete
  /// claims — and decline it while a query or any other text field is
  /// ACTUALLY being typed in (one shared posFocusRouting() answer, same
  /// rule as Space/Delete). Dialog inputs never consult this: their route
  /// scopes sit outside this page's CallbackShortcuts, so a dialog's text
  /// field already owns the key before this layer is reached.
  bool _shortcutMayClaimFocus() => switch (posFocusRouting()) {
        PosFocusRouting.noEditable || PosFocusRouting.searchIdle => true,
        _ => false,
      };

  /// Shift+F6 — the customer picker's Quick Add, reachable WITHOUT opening
  /// the picker: the same [showCustomerFormDialog], the same RBAC gate the
  /// picker's own button uses (`customer_manage` — the backend POST needs
  /// it), the same outcome. On a successful create the customer is
  /// selected for THIS sale (the loyalty session follows through the same
  /// `setCustomer` watcher the picker path uses), the customer-search data
  /// is refreshed so F6 shows the new record, and focus returns to the
  /// barcode field. Cancel / failed create changes nothing.
  Future<void> _addCustomerShortcut() async {
    if (_customerFormOpen) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;
    if (!ref.read(hasPermissionProvider('customer_manage'))) {
      showPosToast(
        context,
        message: AppStrings.t('permission_denied', loc),
        kind: PosToastKind.warning,
      );
      return;
    }
    _customerFormOpen = true;
    CustomerModel? created;
    try {
      created = await showCustomerFormDialog(context);
    } finally {
      _customerFormOpen = false;
    }
    if (!mounted) return;
    if (created != null) {
      ref.read(posCartProvider.notifier).setCustomer(PosCustomer(
            id: created.id,
            name: created.name,
            phone: created.phone,
            balance: double.tryParse(created.balance) ?? 0,
            isArchived: created.isArchived,
          ));
      // Same refresh the picker's quick-add performs: reset the query so
      // the reloaded list actually contains the fresh record.
      final search = ref.read(customerSearchProvider.notifier);
      search.setQuery('');
      await search.load();
      if (!mounted) return;
    }
    _restoreSearchFocusAfterDialog();
  }

  /// The ONE redemption entry — the `pos-loyalty-discount-button` action
  /// and its Shift+F7 shortcut both run through here, so the eligibility
  /// gate, the dialog and the post-close focus restore can never diverge:
  /// the predicate is the button's disabled condition re-read from the
  /// providers (server-owned `canSelectReward`, non-empty non-return cart,
  /// session not loading/in error). A disabled button presses nothing, so
  /// the shortcut declines the same way; [_redemptionOpen] keeps a key
  /// auto-repeat or a double press in one frame from stacking a second
  /// dialog (the dialog itself applies the discount only on Confirm).
  Future<void> _openLoyaltyRedemption() async {
    if (_redemptionOpen) return;
    final cart = ref.read(posCartProvider);
    final loyalty = ref.read(posLoyaltyProvider);
    final enabled = !cart.returnMode &&
        !cart.isEmpty &&
        !loyalty.loading &&
        loyalty.error == null &&
        loyalty.canSelectReward;
    if (!enabled) return;
    _redemptionOpen = true;
    try {
      await showLoyaltyDiscountDialog(context);
    } finally {
      _redemptionOpen = false;
    }
    if (!mounted) return;
    _restoreSearchFocusAfterDialog();
  }

  Future<void> _pickCustomer() async {
    final customer = await showCustomerPickerDialog(context);
    if (!mounted) return;
    if (customer != null) {
      ref.read(posCartProvider.notifier).setCustomer(customer);
    }
    _restoreSearchFocusAfterDialog();
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
    // Settle the server preview BEFORE the dialog opens — closes the
    // debounce race between the cashier picking a percent and pressing
    // PAY, so the amount-due row shown in the dialog (and every payment
    // validation against it) matches exactly what checkout will use.
    final loyalty = ref.read(posLoyaltyProvider);
    if (loyalty.customerId != null && loyalty.rewardPercent > 0) {
      await ref.read(posLoyaltyProvider.notifier).previewNow();
    }
    if (!mounted) return;
    final result = await showPaymentDialog(context);
    if (result != null && mounted) {
      await _afterCheckoutSuccess(result);
    }
  }

  /// Quick sale (Space) — completes the CURRENT valid sale directly, with
  /// NO payment dialog, as a full CASH payment of the amount due.
  ///
  /// Semantics (documented in the settings help text and the shortcuts
  /// map): the sale is charged in full, exactly like confirming the
  /// payment dialog as cash with the amount due entered. There is no
  /// way to tender less or choose another method from this path — a
  /// partial/credit sale would need the dialog — and nothing is ever
  /// invented: the same [PaymentMath.validate] rules the dialog runs gate
  /// the attempt, and the SAME `PosCartNotifier.checkout` pipeline
  /// persists the sale (server re-validation, idempotency, stock,
  /// inventory, loyalty, receipt) and clears the cart on success. Return
  /// mode still owns SPACE (confirming the return, never charging).
  Future<void> _quickSale() async {
    final cart = ref.read(posCartProvider);
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
    // One attempt at a time: SPACE auto-repeat and any second press while
    // the preview settle / POST is in flight are swallowed here, before
    // the pipeline can even be entered twice.
    if (_quickSaleBusy || cart.checkoutPending) return;
    final loc = ref.read(localeProvider).flutterLocale.languageCode;

    // Settle the server preview FIRST — the amount due (and therefore the
    // cash amount submitted) must be the authoritative figure, exactly as
    // _openPayment does before the dialog reads it.
    final loyalty = ref.read(posLoyaltyProvider);
    if (loyalty.customerId != null && loyalty.rewardPercent > 0) {
      await ref.read(posLoyaltyProvider.notifier).previewNow();
    }
    if (!mounted) return;
    final settled = ref.read(posCartProvider);
    final rewardDiscount = ref.read(posLoyaltyProvider).previewMatches
        ? ref.read(posLoyaltyProvider).preview!.rewardDiscount
        : 0.0;
    final due = PaymentMath.amountDueOf(
      total: settled.totals.total,
      rewardDiscount: rewardDiscount,
    );
    // Fail safely: the exact rules the payment dialog would run, for the
    // cash / paid-in-full choice this shortcut makes. An invalid state
    // (empty after a race, total 0, …) surfaces as a toast — the cashier
    // falls back to PAY for anything unusual.
    final errorKey = PaymentMath.validate(
      method: PaymentMethod.cash,
      total: settled.totals.total,
      paid: due,
      hasCustomer: settled.customer != null,
      canDiscount: ref.read(hasPermissionProvider('pos_discount')) ||
          !settled.hasAnyDiscount,
      canCredit: ref.read(hasPermissionProvider('pos_credit_sale')),
      rewardDiscount: rewardDiscount,
    );
    if (errorKey != null) {
      if (!mounted) return;
      showPosToast(
        context,
        message: AppStrings.t(errorKey, loc),
        kind: PosToastKind.error,
      );
      return;
    }

    setState(() => _quickSaleBusy = true);
    CheckoutResult? result;
    try {
      result = await ref.read(posCartProvider.notifier).checkout(
            method: PaymentMethod.cash,
            paid: due,
            // Percent only — never a money value or a balance; the server
            // re-prices and re-validates the reward (payment_dialog.dart
            // contract).
            loyaltyRewardPercent:
                ref.read(posLoyaltyProvider).rewardPercent,
          );
    } finally {
      _quickSaleBusy = false;
    }
    if (!mounted) return;
    if (result != null) {
      await _afterCheckoutSuccess(result);
    } else {
      final failed = ref.read(posCartProvider);
      showPosToast(
        context,
        message: failed.lastError ?? AppStrings.t('sale_failed', loc),
        kind: PosToastKind.error,
      );
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
    notifier.clearCart(reason: 'return-confirm');
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
      detail: _loyaltyReceiptDetail(result, loc),
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

  /// Success-toast detail: invoice number plus the server-reported loyalty
  /// summary when the sale carried any (reward discount, earned points,
  /// earned cashback). Pure presentation — every value comes from the
  /// response.
  String _loyaltyReceiptDetail(CheckoutResult result, String loc) {
    final details = <String>[result.invoiceNumber];
    final currency = AppStrings.t('currency', loc);
    final discount = loyaltyNum(result.loyaltyRedeemedValue);
    if (discount > 0) {
      // Bidi: Arabic labels natural; each grouped value is its own LTR
      // isolate (the toast renders the joined detail in a forced-LTR
      // paragraph, which still reverses digits after an Arabic label —
      // W7 — unless the amount itself is isolated).
      details.add(
        '${AppStrings.t('loyalty_redeemed', loc)}: '
        '${bidiIsolateLtr('${PaymentMath.money(discount)} $currency')}',
      );
    }
    final earned = loyaltyNum(result.loyaltyPointsEarned);
    if (earned > 0) {
      details.add(
        '${AppStrings.t('loyalty_points_earned', loc)}: '
        '${bidiIsolateLtr(formatLoyaltyPoints(earned))} '
        '${AppStrings.t('loyalty_points', loc)}',
      );
    }
    final cashback = loyaltyNum(result.loyaltyCashbackEarned);
    if (cashback > 0) {
      details.add(
        '${AppStrings.t('loyalty_cashback_earned', loc)}: '
        '${bidiIsolateLtr('${PaymentMath.money(cashback)} $currency')}',
      );
    }
    return details.join(' · ');
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
      // Clear Cart empties the CART only. The catalog, the search query,
      // favorites and the view mode stay exactly as the cashier left
      // them — no search reset, no refetch, no navigation.
      ref.read(posCartProvider.notifier).clearCart(reason: 'clear-dialog');
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
    // Layout switch (standard | reversed) — presentation only; the cart
    // provider and every checkout path are identical in both modes.
    final screenLayout = ref.watch(posLayoutSwitchProvider);
    final reversedLayout = screenLayout == PosScreenLayout.reversed;
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
      // Phase E — keep the session loyalty state in lock-step with the
      // cart: attaching/detaching a customer swaps the loyalty context,
      // a total change (lines, qty, invoice discount) refreshes the
      // server preview.  Checkout/return reset the cart, so the customer
      // detach below also clears any redeem input in one place.
      final loyalty = ref.read(posLoyaltyProvider.notifier);
      if (next.customer?.id != previous?.customer?.id) {
        unawaited(loyalty.setCustomerById(next.customer?.id));
      }
      if (next.totals.total != previous?.totals.total ||
          next.customer?.id != previous?.customer?.id) {
        loyalty.setCartTotal(next.totals.total);
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
      // Reversed mode renders the lines as one compact table; standard
      // mode keeps the existing card list untouched.
      dense: reversedLayout,
      cart: cart,
      linesController: _linesController,
      compaction: _chromeLevel,
      onCompactionChange: (level) {
        if (level == _chromeLevel) return;
        setState(() => _chromeLevel = level);
      },
      clearQtyTextRequest: _clearQtyTextRequest,
      revealRequest: _revealRequest,
      onRemoveLine: (key) =>
          ref.read(posCartProvider.notifier).removeLine(key),
      // Single validating qty path (UX FIX #12 — FIX #6).
      onUpdateQty: _updateLineQty,
      // A scan in a focused qty field routes to the canonical barcode
      // resolve (same add rules) instead of the quantity parser.
      onScanLine: _handleLineScan,
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
      onRedemption: _openLoyaltyRedemption,
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
          child: LayoutBuilder(
            builder: (context, toolbarConstraints) {
              // Phase 10 — packs / bundles picker (own dialog, own search).
              final packsButton = OutlinedButton.icon(
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
              );
              // Phase 17 §18 — the keyboard map needs a discoverable entry
              // point next to the tools it describes.
              final shortcutsButton = IconButton(
                key: const Key('pos-shortcuts-button'),
                tooltip: AppStrings.t('shortcuts_title', loc),
                onPressed: () => showShortcutsDialog(context),
                icon: const Icon(Icons.keyboard),
                visualDensity: VisualDensity.compact,
                constraints: const BoxConstraints(
                  minWidth: 38,
                  minHeight: 38,
                ),
              );
              final compactToggle = _ViewModeToggle(
                mode: viewMode,
                compact: true,
                onChanged: (m) =>
                    ref.read(posCatalogViewModeProvider.notifier).setMode(m),
              );
              // FIX #3 rule reused by the layout switch: the same
              // "full labels when the workspace allows it" threshold,
              // so the toolbar never overflows by adding a control.
              // Measure the panel the workspace ACTUALLY occupies: in
              // reversed mode it holds the narrow cartWidth slot, not
              // (window - cartWidth).
              final workspaceWidth = layout == PosLayoutMode.narrow
                  ? MediaQuery.sizeOf(context).width
                  : (reversedLayout
                      ? cartWidth
                      : MediaQuery.sizeOf(context).width - cartWidth);
              final tightWorkspace =
                  layout != PosLayoutMode.narrow && workspaceWidth < 500;
              final layoutToggleFull = _LayoutSwitchToggle(
                layout: screenLayout,
                onChanged: (l) => ref
                    .read(posLayoutSwitchProvider.notifier)
                    .setLayout(l),
              );
              final layoutToggleCompact = _LayoutSwitchToggle(
                layout: screenLayout,
                compact: true,
                onChanged: (l) => ref
                    .read(posLayoutSwitchProvider.notifier)
                    .setLayout(l),
              );

              // Tight workspace (human QA: "RenderFlex overflowed by 59
              // pixels" on this toolbar at a 1127px window): the same
              // controls wrap instead of overflowing, and the view-mode
              // switch drops to its compact icon form. The threshold
              // grows with the text scale — at 1.3x full labels needed
              // ~70px more room than 580px granted.
              final toolbarTextUp = () {
                final s = MediaQuery.textScalerOf(context).scale(1.0);
                return s > 1.0 ? s : 1.0;
              }();
              if (toolbarConstraints.maxWidth < 580 * toolbarTextUp) {
                return Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width:
                          toolbarConstraints.maxWidth.clamp(160.0, 280.0),
                      child: searchField,
                    ),
                    packsButton,
                    shortcutsButton,
                    compactToggle,
                    layoutToggleCompact,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 180),
                      child: searchField,
                    ),
                  ),
                  const SizedBox(width: 8),
                  packsButton,
                  const SizedBox(width: 8),
                  shortcutsButton,
                  const SizedBox(width: 8),
                  // FIX #3: full labels when workspace allows; icons+tooltip
                  // when tight. Both toggles are scale-shrinkable
                  // (Flexible + FittedBox): at large text scales their
                  // intrinsic width pushed this Row past its box by a
                  // fraction of a pixel — they now yield instead.
                  if (tightWorkspace)
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: compactToggle,
                      ),
                    )
                  else
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: ConstrainedBox(
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
                      ),
                    ),
                  const SizedBox(width: 8),
                  // Layout switch sits with the display-mode control it
                  // complements; full label only when even the worst case
                  // (full view-mode labels + min search width) still fits.
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: toolbarConstraints.maxWidth >=
                              (tightWorkspace ? 560 : 700)
                          ? layoutToggleFull
                          : layoutToggleCompact,
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        Expanded(child: productCatalog),
      ],
    );

    // The two panel ALLOCATIONS exchange roles with the layout switch —
    // not just their positions. Standard: the workspace holds the large
    // (expanded) panel and the cart the narrow fixed cartWidth slot.
    // Reversed: the cart — with its complete chrome (header, customer
    // row, lines, action buttons, totals, PAY) — takes the large panel,
    // and the product workspace (search, favorites, filters, catalog)
    // takes the narrow cartWidth slot. One widget per slot, swapped
    // whole: the cart panel and workspace are moved intact.
    final expandedWorkspace = Expanded(child: workspace);
    final expandedCart = Expanded(child: cartPanel);
    final narrowWorkspace = SizedBox(width: cartWidth, child: workspace);
    final narrowCart = SizedBox(width: cartWidth, child: cartPanel);

    Widget body;
    switch (layout) {
      case PosLayoutMode.wide:
      case PosLayoutMode.medium:
        body = Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: reversedLayout
              ? [
                  expandedCart,
                  const VerticalDivider(width: 1),
                  narrowWorkspace,
                ]
              : [
                  expandedWorkspace,
                  const VerticalDivider(width: 1),
                  narrowCart,
                ],
        );
      case PosLayoutMode.narrow:
        // When the cart drawer is open it owns the full height so the
        // fixed cart chrome (totals + action buttons + pay) never overflows
        // on short viewports (600×500). Workspace returns when closed.
        // The open drawer is identical in both modes (the catalog is not
        // on screen to swap); the closed stack reverses the cart bar and
        // the workspace, mirroring the wide/medium left↔right swap.
        if (_cartDrawerOpen) {
          body = Column(
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
                      // Bidi: Arabic "Total:" label natural; the grouped
                      // total is one LTR isolate (W7).
                      child: Text(
                        '${AppStrings.t('total_label', loc)}: '
                        '${bidiIsolateLtr(cart.totals.totalDisplay)}',
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
          );
        } else {
          final totalBar = SizedBox(
            height: 56,
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    // Bidi: Arabic label natural; grouped total is
                    // one LTR isolate (W7).
                    child: Text(
                      '${AppStrings.t('total_label', loc)}: '
                      '${bidiIsolateLtr(cart.totals.totalDisplay)}',
                      style: theme.textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('toggle-cart'),
                  tooltip: AppStrings.t('pos', loc),
                  onPressed: () => setState(() => _cartDrawerOpen = true),
                  icon: const Icon(Icons.shopping_cart),
                ),
              ],
            ),
          );
          body = reversedLayout
              ? Column(children: [totalBar, Expanded(child: workspace)])
              : Column(children: [Expanded(child: workspace), totalBar]);
        }
    }

    // Global shortcuts — Escape never clears cart; F12 requires confirm.
    // F4 / Ctrl+F focus search; after dialogs close, search remains the
    // sensible default focus for barcode/keyboard-first cashier flow.
    // SPACE pays (Phase 17 §18, replaces legacy F8) but only while no text
    // field is being TYPED in — TextFreeKeyActivator declines it while an
    // EditableText has primary focus unless allowWhileEditing says the
    // focused field is not editing (see spaceMayClaimFocusedField): the
    // cart QUANTITY field (a cashier may click one — the pay key can
    // never corrupt a quantity) and the EMPTY barcode field (the
    // barcode-ready home state where the cashier selects rows: SPACE must
    // still open the payment window there). A typed search query, a line
    // discount and every dialog/picker/payment input keep SPACE as
    // ordinary text.
    // `+` / `-` / `*` act on the last active cart line: they are claimed
    // from every non-dialog field (search, quantity, discount) — one
    // shared focus router (posFocusRouting) decides — and Delete removes
    // the selected line the same way its remove button does: only while no
    // text input is being edited (empty barcode field or no field at all —
    // deleteMayClaimFocusedField), so every field with text keeps its own
    // Delete editing.
    // While a dialog route is open its focus scope owns the keys, so none
    // of them reach this layer — including Escape, which therefore stays
    // safe to bind here (dialogs keep their own route-level dismiss).
    // FocusScope (inside this CallbackShortcuts, above the workspace node):
    // on desktop, a click on any NON-EDITABLE area (empty cart-panel or
    // catalog space) makes EditableText unfocus the focused text field, and
    // FocusNode.unfocus() parks primary focus at the NEAREST enclosing
    // FocusScopeNode. Without an in-page scope that scope was the
    // ModalRoute's own FocusScope — an ANCESTOR of this CallbackShortcuts —
    // so every key event dispatched from a node ABOVE the page and none of
    // these bindings (+ / - / *, Delete, SPACE) were ever reached, while the
    // selected line (lastActiveKey) stayed untouched. The in-page scope
    // keeps that parked focus INSIDE this subtree, so shortcuts keep routing
    // through this single handler with no selection or focus coupling, and
    // dialogs keep owning their keys (their route scopes sit outside this
    // subtree, unchanged).
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.f4): _focusSearch,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _focusSearch,
        const SingleActivator(LogicalKeyboardKey.f5): _refreshWorkspace,
        const SingleActivator(LogicalKeyboardKey.escape): _handleEscape,
        const SingleActivator(LogicalKeyboardKey.f6): () =>
            _handleShortcut(LogicalKeyboardKey.f6),
        // Shift+F6 — add customer (the picker's Quick Add as a direct
        // shortcut next to F6). Exact modifier match: plain F6 never fires
        // it and vice versa (SingleActivator requires every modifier to be
        // EXACTLY as declared). includeRepeats off: a held combo cannot
        // stack forms; the focus gate declines while a query/field is
        // being typed (dialogs are out of reach by scope — see above).
        const SingleActivator(
          LogicalKeyboardKey.f6,
          shift: true,
          includeRepeats: false,
        ): () {
          if (_shortcutMayClaimFocus()) _addCustomerShortcut();
        },
        const SingleActivator(LogicalKeyboardKey.f7): () =>
            _handleShortcut(LogicalKeyboardKey.f7),
        // Shift+F7 — use loyalty points: the redemption button's own flow
        // ([_openLoyaltyRedemption]) behind the key adjacent to F7 (invoice
        // discount). Same exact-modifier / no-repeat / focus-gate rules as
        // Shift+F6; the disabled button's eligibility is re-checked inside.
        const SingleActivator(
          LogicalKeyboardKey.f7,
          shift: true,
          includeRepeats: false,
        ): () {
          if (_shortcutMayClaimFocus()) _openLoyaltyRedemption();
        },
        // SPACE replaces F8 (Phase 17 §18 — "SPACE replaces F8 for payment").
        // While a POS-owned NON-TYPING field is focused the activator
        // claims the key anyway (allowWhileEditing) — the callback is
        // IDENTICAL, only the event precedence changes: handled key ⇒ the
        // focused text input never sees the space character. With Quick
        // sale (Space) ON the claim is WITHDRAWN from every editable
        // context: an immediate sale must never fire under the cashier's
        // fingers mid-typing, so Space keeps its ordinary text meaning in
        // the search box, quantity/discount fields and any dialog input,
        // and the quick-sale path only answers from the bare workspace.
        TextFreeKeyActivator(
          LogicalKeyboardKey.space,
          allowWhileEditing: () =>
              !ref.read(posSettingsProvider).quickSaleWithSpace &&
              spaceMayClaimFocusedField(),
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
        // Delete → remove the SELECTED line (selection alone — no quantity
        // focus needed, the idle barcode field counts as "no editing").
        // KeyDown only: key auto-repeat can never chain into deleting the
        // line that became active after the first press.
        TextFreeKeyActivator(
          LogicalKeyboardKey.delete,
          allowWhileEditing: deleteMayClaimFocusedField,
        ): _removeActiveLine,
        // Up/Down — move the SELECTED cart line (selection navigation, not
        // text carets). The keys are ALWAYS claimed on this page and the
        // callback applies arrowMayClaimFocusedField: from the workspace,
        // the idle barcode field (right after a catalog add focus stays
        // off the cart — arrows must answer the very next press, no cart
        // click) OR a cart quantity field the cashier clicked the
        // selection walks; while a typed query, a line discount or any
        // other editable holds focus the press is swallowed — the
        // selection never walks — instead of bubbling into the framework's
        // single-line vertical-caret action, which asserts on
        // non-left-aligned inputs (the centered qty field). Left/Right
        // remain ordinary caret movement, and the dialogs' route scopes
        // (option picker) keep their own arrows — one activation per key
        // event, TextFreeKeyActivator matches key-down only.
        TextFreeKeyActivator(
          LogicalKeyboardKey.arrowUp,
          allowWhileEditing: () => true,
        ): () {
          if (arrowMayClaimFocusedField()) _moveActiveLine(-1);
        },
        TextFreeKeyActivator(
          LogicalKeyboardKey.arrowDown,
          allowWhileEditing: () => true,
        ): () {
          if (arrowMayClaimFocusedField()) _moveActiveLine(1);
        },
      },
      child: FocusScope(
        child: Focus(
          autofocus: true,
          focusNode: _focusNode,
          child: Scaffold(
            key: const Key('pos-screen'),
            body: body,
          ),
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

/// POS layout switch — flips the product catalog and the cart panel to
/// each other's side (presentation only: same cart provider, same
/// checkout). The label shows the CURRENT mode and the tooltip names the
/// action, so a cashier always knows what a click does; it is a real
/// focusable button, so Tab + Enter work like on every other toolbar
/// control.
class _LayoutSwitchToggle extends StatelessWidget {
  const _LayoutSwitchToggle({
    required this.layout,
    required this.onChanged,
    this.compact = false,
  });

  final PosScreenLayout layout;
  final ValueChanged<PosScreenLayout> onChanged;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final reversed = layout == PosScreenLayout.reversed;
    final modeLabel = AppStrings.t(
      reversed ? 'pos_layout_reversed' : 'pos_layout_standard',
      loc,
    );
    final tooltip = '${AppStrings.t('pos_layout_switch', loc)} · $modeLabel';
    final icon = Icon(
      reversed ? Icons.swap_horiz : Icons.splitscreen,
      size: 18,
      color: reversed ? theme.colorScheme.primary : theme.colorScheme.outline,
    );

    if (compact) {
      return IconButton(
        key: const Key('pos-layout-switch'),
        tooltip: tooltip,
        onPressed: () => onChanged(
          reversed ? PosScreenLayout.standard : PosScreenLayout.reversed,
        ),
        icon: icon,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(
          minWidth: 38,
          minHeight: 38,
        ),
      );
    }

    return Tooltip(
      message: tooltip,
      child: TextButton(
        key: const Key('pos-layout-switch'),
        onPressed: () => onChanged(
          reversed ? PosScreenLayout.standard : PosScreenLayout.reversed,
        ),
        style: TextButton.styleFrom(
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          minimumSize: const Size(0, 38),
          backgroundColor: reversed
              ? theme.colorScheme.primary.withValues(alpha: 0.14)
              : Colors.transparent,
          foregroundColor: reversed
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface,
          side: BorderSide(
            color: reversed
                ? theme.colorScheme.primary.withValues(alpha: 0.5)
                : theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            icon,
            const SizedBox(width: 4),
            Text(
              modeLabel,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: theme.textTheme.labelLarge?.copyWith(
                fontSize: 14,
                color: reversed
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
                fontWeight: reversed ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
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
      return numericText(
        formatGrouped(product.price),
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
          child: numericText(
            formatGrouped(product.price),
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
        numericText(
          formatGrouped(promo.price),
          key: Key('pos-product-price-${product.id}'),
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(width: 4),
        Flexible(
          child: numericText(
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
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
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
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
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

    // HScrollView (not a bare horizontal ListView): a mouse wheel has no
    // horizontal delta, so without the bridge and the thumb a long
    // favorites strip silently runs off the right edge with no way to
    // reach the rest of it on a desktop POS.
    return HScrollView(
      key: const Key('pos-favorites-row'),
      height: 72,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < favorites.length; index++) ...[
            if (index > 0) const SizedBox(width: 8),
            _FavoriteChip(
              favorite: favorites[index],
              onTap: onTapFavorite,
            ),
          ],
        ],
      ),
    );
  }
}

class _FavoriteChip extends StatelessWidget {
  const _FavoriteChip({required this.favorite, required this.onTap});

  final FavoriteModel favorite;
  final void Function(FavoriteModel) onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      key: Key('pos-favorite-${favorite.productId}'),
      avatar: const Icon(Icons.star, size: 16),
      label: Text(
        favorite.productName ?? favorite.productId,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onPressed: () => onTap(favorite),
    );
  }
}

/// Measures the cart lines region after layout and drives the cart
/// panel's chrome compaction level ([_CartPanel.compaction]).
///
/// The invariant: the lines region must always be at least one full row
/// tall — otherwise the last visible row sits under the fixed tail
/// (actions + totals/PAY) and reads as clipped/obscured. Below the
/// measured row floor it asks for one more compaction level (max 2); above
/// the floor + 120px of slack it relaxes one (hysteresis — one level is
/// worth ~40–70px, so the band can never flap). The tail box itself
/// never shrinks with compaction (topHeight is untouched), so no level
/// can introduce a RenderFlex overflow; at absurd sizes the floor is
/// unreachable and the panel degrades to exactly its previous behavior.
///
/// The floor is the tallest element keyed `cart-line-*` in the lines
/// subtree (the row-level box of every built tile); with no built tile
/// it falls back to a layout-class estimate (standard ≈ 170, dense
/// reversed ≈ 66 at 1.0 text scale).
class _LinesFloorProbe extends StatefulWidget {
  const _LinesFloorProbe({
    required this.dense,
    required this.level,
    required this.onLevel,
    required this.child,
  });

  final bool dense;
  final int level;
  final ValueChanged<int> onLevel;
  final Widget child;

  @override
  State<_LinesFloorProbe> createState() => _LinesFloorProbeState();
}

class _LinesFloorProbeState extends State<_LinesFloorProbe> {
  /// Re-armed after every measurement: the region can shrink WITHOUT a
  /// widget rebuild (scroll-to-end settling, drawer animations), so a
  /// post-frame hook scheduled only from [build] would go blind exactly
  /// when the floor is at risk. Re-arming never forces a frame of its
  /// own — the chain parks until someone else paints.
  bool _pending = false;

  @override
  Widget build(BuildContext context) {
    _arm();
    return widget.child;
  }

  void _arm() {
    if (_pending || !mounted) return;
    _pending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = false;
      if (!mounted) return;
      _measure();
      _arm();
    });
  }

  void _measure() {
    if (!mounted) return;
    // The floor applies to the SCROLL VIEWPORT, not this wrapper: the
    // dense layout parks fixed column chrome above the list, which would
    // otherwise masquerade as extra row room. No keyed viewport = empty
    // state = no row to protect.
    Element? viewportEl;
    void find(Element e) {
      if (viewportEl != null) return;
      final k = e.widget.key;
      if (k is ValueKey && k.value == 'pos-cart-lines') {
        viewportEl = e;
        return;
      }
      e.visitChildren(find);
    }

    find(context as Element);
    final box = viewportEl?.renderObject;
    if (box is! RenderBox || !box.hasSize) return;
    final linesH = box.size.height;

    // Row floor: tallest `cart-line-*` keyed box across the built
    // tiles (the tile's own Padding carries the key at row level).
    var rowMax = 0.0;
    void walk(Element e) {
      final k = e.widget.key;
      if (k is ValueKey &&
          k.value is String &&
          (k.value as String).startsWith('cart-line-')) {
        final r = e.renderObject;
        if (r is RenderBox && r.hasSize && r.size.height > rowMax) {
          rowMax = r.size.height;
        }
      }
      e.visitChildren(walk);
    }

    walk(context as Element);
    final floor = rowMax > 0 ? rowMax : (widget.dense ? 66.0 : 170.0);

    var next = widget.level;
    if (linesH < floor - 0.5) {
      if (next < 2) next += 1;
    } else if (linesH > floor + 120) {
      if (next > 0) next -= 1;
    }
    if (next != widget.level) widget.onLevel(next);
  }
}

class _CartPanel extends StatelessWidget {
  final PosCartState cart;
  final void Function(String) onRemoveLine;

  /// Reversed layout: the lines render as one compact, single-row-per-line
  /// table (selection · name · unit price · qty · total · discount ·
  /// remove) inside a vertically scrolling body with a shared horizontal
  /// region — instead of the standard stacked card list.
  final bool dense;

  /// Line key whose qty field should show the committed quantity again
  /// once the current frame lands — set by a scan submitted FROM that
  /// field. The merge is still resolving when Enter returns, so the field
  /// must not be overwritten mid-flight: a burst typed on top of the
  /// still-visible barcode would lose its committed prefix. Consumed by
  /// the matching tile post-frame; a burst typed before the reset lands
  /// is detected by its run base, never by the field text.
  final ValueNotifier<String?> clearQtyTextRequest;

  /// Line key arrow navigation wants revealed fully in view — consumed by
  /// the matching tile (listener while it is already mounted, initState
  /// when the lazy list builds it right after a jump; see
  /// _PosScreenState._moveActiveLine).
  final ValueNotifier<String?> revealRequest;

  /// Returns true when the quantity was applied (false = rejected, a toast
  /// was already shown by the shared validation funnel).
  final bool Function(String key, String quantity) onUpdateQty;

  /// A keyboard-wedge scan landed in a line's focused qty field — the POS
  /// scan path (canonical barcode resolve + cart rules).
  final ValueChanged<String> onScanLine;

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

  /// Redemption entry shared by the Use Points button and Shift+F7 — the
  /// state's ONE [_openLoyaltyRedemption] flow (eligibility gate + dialog
  /// + focus restore), so keyboard and mouse can never diverge.
  final VoidCallback onRedemption;
  final int heldCount;

  /// POS return mode — the footer Return button (permission-gated) enters
  /// the mode; the banner + totals-panel Confirm/Cancel own the mode.
  final bool canReturn;
  final VoidCallback onReturn;
  final VoidCallback onCancelReturn;
  final VoidCallback onConfirmReturn;

  /// Localized last return failure — inline in the return banner.
  final String? returnError;

  /// Parent-owned standard list scroll position — the State jumps it when
  /// an entering arrow press (_PosScreenState._moveActiveLine) lands on a
  /// tile the lazy list has not built yet; the dense table builds every
  /// row eagerly and never needs it.
  final ScrollController linesController;

  /// Progressive chrome compaction level (0 = full layout; ≥1 merged
  /// action row + inline TOTAL + tightest rhythm; ≥2 merged
  /// Subtotal/Discount band): raised by the lines-region probe while the
  /// region would drop below one full cart row (short viewports), lowered
  /// again when there is ample room. Owned by the POS screen state.
  final int compaction;

  /// Reports the next compaction level decided by the lines probe.
  final ValueChanged<int> onCompactionChange;

  const _CartPanel({
    required this.cart,
    required this.linesController,
    this.compaction = 0,
    required this.onCompactionChange,
    this.dense = false,
    required this.clearQtyTextRequest,
    required this.revealRequest,
    required this.onRemoveLine,
    required this.onUpdateQty,
    required this.onScanLine,
    required this.onActivateLine,
    required this.onUpdateLineDiscount,
    required this.onCustomer,
    required this.onDiscount,
    required this.onPayment,
    required this.onHold,
    required this.onHolds,
    required this.onHistory,
    required this.onClear,
    required this.onRedemption,
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
        // Bidi: each numeric segment is an LTR isolate so the grouped
        // unit count never swaps with the Arabic words (W7).
        : '${bidiIsolateLtr('${cart.lines.length}')} '
            '${AppStrings.t('lines_word', loc)} · '
            '${bidiIsolateLtr(_fmtQty(unitCount))} '
            '${AppStrings.t('units_word', loc)}';
    // OS text scaling (Windows DPI display scaling): the fixed chrome rows
    // were budgeted for 1.0 — beyond that they GROW with the text so the
    // title/counts and the customer name/phone never overflow their box
    // (unclipped Flex paint) onto the rows below. At 1.0 the factor is
    // exactly 1, so existing layouts, goldens and geometry tests stand.
    final ts = MediaQuery.textScalerOf(context).scale(1.0);
    final textUp = ts > 1.0 ? ts : 1.0;
    final headerHeight = (dense
            ? (short ? 50.0 : 56.0)
            : compact
                ? 64.0
                : 72.0) *
        textUp;
    // A selected customer keeps the SAME essential content (name, phone,
    // change-customer action) in the dense 44px footprint — walk-in keeps
    // the roomy 48/52 row. Attaching a customer must never steal vertical
    // space from the cart lines region below (customer-attached clipping).
    final customerHeight =
        (dense || cart.customer != null ? 44.0 : compact ? 48.0 : 52.0) *
            textUp;

    return Container(
      key: const Key('pos-cart-panel'),
      color: theme.colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header: real POS header (UX FIX #8) — 64–76px, 20–22 title.
          // Dense (reversed) compacts it to 52–56 so the lines region
          // below gets more of the panel (see [_denseCartLines]).
          SizedBox(
            height: headerHeight,
            child: Padding(
              key: const Key('pos-cart-header'),
              padding: dense
                  ? const EdgeInsetsDirectional.fromSTEB(10, 2, 8, 2)
                  : const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 4),
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
                        numericText(
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
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            if (cart.customer?.phone != null)
                              Text(
                                cart.customer!.phone!,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 13,
                                ),
                                maxLines: 1,
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
                          // Label + the F6 key chip: the badge carries the
                          // REAL binding (PosShortcutKeys — the same table
                          // the shortcuts map shows), so the key text no
                          // longer has to live inside the localized string.
                          child: ShortcutBadgeLabel(
                            AppStrings.t('customer_shortcut', loc),
                            keys: PosShortcutKeys.chooseCustomer,
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
            // Post-frame probe: measures this region and the tallest built
            // cart row, then escalates/lowers the chrome compaction level
            // so a full row always fits above the fixed footer (the
            // loyalty/totals block never obscures the last visible row).
            child: _LinesFloorProbe(
              dense: dense,
              level: compaction,
              onLevel: onCompactionChange,
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
                : dense
                    ? _denseCartLines(theme: theme, loc: loc)
                    : ListView.separated(
                    key: const Key('pos-cart-lines'),
                    controller: linesController,
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
                        // Selection drives the row's highlight (primary
                        // tint + border, check-circle in the dense table)
                        // and the arrow-key reveal.
                        selected: line.key == cart.lastActiveKey,
                        revealRequest: revealRequest,
                        onRemove: () => onRemoveLine(line.key),
                        onActivate: () => onActivateLine(line.key),
                        onQty: (q) => onUpdateQty(line.key, q),
                        onDiscount: (d) =>
                            onUpdateLineDiscount(line.key, d),
                        onScan: onScanLine,
                        clearQtyTextRequest: clearQtyTextRequest,
                      );
                    },
                  ),
            ),
          ),
          // EXPLICIT checkout-section budget: the fixed chrome above the
          // lines (header + customer row + divider + optional return
          // banner) is computed from the same flags that rendered it, so
          // the section below the lines (divider, stock errors, actions,
          // totals/PAY) can never claim more than what remains. A taller
          // customer row (or a stock-error list) shrinks the scrollable
          // lines region to >= 0 instead of overflowing the panel bottom,
          // covering the last rows and the PAY button (customer-attached
          // clipping). LayoutBuilder as a non-flex Column child receives
          // the panel's own (full) height bound.
          LayoutBuilder(
            builder: (context, tailConstraints) {
              final topHeight = headerHeight +
                  customerHeight +
                  1.0 + // divider under the customer row
                  (cart.returnMode ? 80.0 : 0.0); // banner + error line
              final maxH = tailConstraints.maxHeight;
              final tailMax = maxH.isFinite
                  ? (maxH - topHeight > 0.0 ? maxH - topHeight : 0.0)
                  : double.infinity;
              // Secondary actions — defined once, assembled as the 2×2
              // grid (compaction 0) or as ONE compact row (compaction
              // ≥ 1): the freed 44–52px band goes straight to the cart
              // lines region on short viewports. Same keys, callbacks,
              // badges and per-mode sizing in both arrangements.
              final discountAction = _actionButton(
                context: context,
                key: const Key('pos-discount-button'),
                icon: Icons.percent,
                label: AppStrings.t('discount_shortcut', loc),
                onPressed: onDiscount,
                short: short || compact,
                dense: dense,
                accent: AppColors.warning,
                shortcut: PosShortcutKeys.invoiceDiscount,
              );
              final holdAction = _actionButton(
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
                dense: dense,
                accent: AppColors.actionHold,
                shortcut: PosShortcutKeys.hold,
              );
              final holdsAction = _actionButton(
                context: context,
                key: const Key('pos-holds-button'),
                icon: Icons.list_alt,
                label: AppStrings.t('holds_shortcut', loc),
                onPressed: onHolds,
                short: short || compact,
                dense: dense,
                badgeCount: heldCount,
                shortcut: PosShortcutKeys.holds,
              );
              final historyAction = _actionButton(
                context: context,
                key: const Key('pos-history-button'),
                icon: Icons.history,
                label: AppStrings.t('history_shortcut', loc),
                onPressed: onHistory,
                short: short || compact,
                dense: dense,
                accent: AppColors.actionHistory,
                shortcut: PosShortcutKeys.history,
              );
              final returnAction = _actionButton(
                context: context,
                key: const Key('pos-return-button'),
                icon: Icons.replay,
                label: AppStrings.t('pos_return', loc),
                onPressed: cart.isEmpty ? null : onReturn,
                short: short || compact,
                dense: dense,
                accent: AppColors.actionReturn,
                // The one solid chip: entering return
                // mode must stay an unmissable red.
                solid: true,
              );
              // Loyalty redemption entry (server-owned eligibility): the
              // same ONE dot every loyalty state change rebuilds — the
              // button only hands a confirmed, eligible cart to the
              // discount dialog; the session's own canSelectReward is
              // the gate (never a client guess). Disabled in return
              // mode (a return earns nothing) and on an empty cart
              // (nothing to discount — same convention as HOLD/RETURN).
              final loyaltyAction = Consumer(
                builder: (context, ref, _) {
                  final loyalty = ref.watch(posLoyaltyProvider);
                  final enabled = !cart.returnMode &&
                      !cart.isEmpty &&
                      !loyalty.loading &&
                      loyalty.error == null &&
                      loyalty.canSelectReward;
                  return _actionButton(
                    context: context,
                    key: const Key('pos-loyalty-discount-button'),
                    icon: Icons.stars,
                    label: AppStrings.t('loyalty_redeem', loc),
                    // ONE flow for mouse and keyboard: the Shift+F7 shortcut
                    // calls this same method (via onRedemption), which
                    // re-runs this exact predicate (the watched `enabled`
                    // above only decides the painted disabled state).
                    onPressed: enabled ? onRedemption : null,
                    short: short || compact,
                    dense: dense,
                    accent: AppColors.success,
                    shortcut: PosShortcutKeys.useLoyaltyPoints,
                  );
                },
              );
              return ConstrainedBox(
                constraints: BoxConstraints(maxHeight: tailMax),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
                    // 2-column secondary action grid (UX FIX #8): 44–48px, 13–15px
                    // font. Dense (reversed) compacts it: 40px buttons (36 on short
                    // screens), 4px row gaps, 2px block padding — the checkout
                    // chrome must leave the lines region as much height as possible.
                    Padding(
                      key: const Key('pos-cart-actions'),
                      padding: dense
                          ? const EdgeInsets.fromLTRB(8, 2, 8, 2)
                          : compact
                              ? const EdgeInsets.fromLTRB(10, 4, 10, 4)
                              : const EdgeInsets.fromLTRB(10, 6, 10, 6),
                      child: Column(
                        children: [
                          if (compaction >= 1)
                            // One compact row: the four secondary actions
                            // share a band so the fixed tail yields its
                            // second row to the cart lines. The redemption
                            // chip FOLDS INTO this band (never a row of its
                            // own at compaction ≥ 1) so the entry point
                            // costs the tight viewports not a single pixel.
                            Row(
                              children: [
                                Expanded(child: discountAction),
                                const SizedBox(width: 8),
                                Expanded(child: holdAction),
                                const SizedBox(width: 8),
                                Expanded(child: holdsAction),
                                const SizedBox(width: 8),
                                Expanded(child: historyAction),
                                if (!cart.returnMode) ...[
                                  const SizedBox(width: 8),
                                  Expanded(child: loyaltyAction),
                                ],
                              ],
                            )
                          else ...[
                            Row(
                              children: [
                                Expanded(child: discountAction),
                                const SizedBox(width: 8),
                                Expanded(child: holdAction),
                              ],
                            ),
                            SizedBox(height: dense ? (short ? 2 : 4) : 8),
                            Row(
                              children: [
                                Expanded(child: holdsAction),
                                const SizedBox(width: 8),
                                Expanded(child: historyAction),
                              ],
                            ),
                          ],
                          // Return entry point (permission-gated): hidden while the
                          // mode is active — the banner + Confirm/Cancel own it.
                          // At compaction 0 the redemption chip shares this row
                          // beside it (or rides alone without the return
                          // permission); the whole row is withheld in return
                          // mode — that sale earns nothing.
                          if (!cart.returnMode && (canReturn || compaction < 1)) ...[
                            SizedBox(height: dense ? (short ? 2 : 4) : 8),
                            Row(
                              children: [
                                if (canReturn) ...[
                                  Expanded(child: returnAction),
                                  const SizedBox(width: 8),
                                ],
                                if (compaction < 1)
                                  Expanded(child: loyaltyAction),
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
                      dense: dense,
                      compaction: compaction,
                      onPayment: onPayment,
                      onConfirmReturn: onConfirmReturn,
                      onCancelReturn: onCancelReturn,
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  /// Reversed-layout cart body: one compact header + one single-row line
  /// per cart entry.
  ///
  /// Structure (wheel behaviour depends on it — see HScrollView docs): the
  /// horizontal region WRAPS header + vertical list, so a wheel over a row
  /// is claimed by the inner vertical view first, while a wheel over the
  /// header (outside the vertical list's hit path) falls through to the
  /// horizontal bridge. The header lives INSIDE the table so the columns
  /// stay aligned: the table FILLS the panel the reversed cart now owns
  /// (the name column absorbs the extra width) and only keeps the
  /// [kPosDenseRowWidth] minimum + sideways scroll when the panel is
  /// narrower than the column set (e.g. 900×700 reversed).
  /// The parent provides the bounded height (lines-region Expanded).
  ///
  /// `alwaysShowScrollbar: true` pins the HScrollView structure from the
  /// FIRST build: without it, the Scrollbar mounting a frame after the
  /// layout flips (thumb appears on overflow — a 692px-minimum table in a
  /// narrow panel) remounts every line tile and drops the keyboard focus
  /// FIX #1 just placed in the new line's qty field. The thumb only
  /// PAINTS while the table actually overflows horizontally (see
  /// HScrollView), and the [kPosDenseThumbGutter] strip reserves the
  /// bottom of the region for it — so a row scrolled flush to the end of
  /// the list never sits under the thumb, the divider, or the fixed
  /// action/totals/PAY section below. The parent provides the bounded
  /// height (lines-region Expanded): header + customer row + actions +
  /// totals are all fixed/ intrinsic Column siblings, so the region
  /// receives exactly the remaining height and the checkout section can
  /// never overlay the rows.
  Widget _denseCartLines({required ThemeData theme, required String loc}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final tableWidth = constraints.maxWidth.isFinite &&
                constraints.maxWidth > kPosDenseRowWidth
            ? constraints.maxWidth
            : kPosDenseRowWidth;
        return HScrollView(
          alwaysShowScrollbar: true,
          child: SizedBox(
            width: tableWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _denseCartHeader(theme: theme, loc: loc),
                const Divider(height: 1),
                Expanded(
                  child: SingleChildScrollView(
                    key: const Key('pos-cart-lines'),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final line in cart.lines)
                          _CartLineTile(
                            // Same keys as the standard list — the State
                            // (qty / discount controllers) is keyed by the
                            // line.
                            key: ValueKey<String>(line.key),
                            line: line,
                            dense: true,
                            selected: line.key == cart.lastActiveKey,
                            clearQtyTextRequest: clearQtyTextRequest,
                            revealRequest: revealRequest,
                            onRemove: () => onRemoveLine(line.key),
                            onActivate: () => onActivateLine(line.key),
                            onQty: (q) => onUpdateQty(line.key, q),
                            onDiscount: (d) =>
                                onUpdateLineDiscount(line.key, d),
                            onScan: onScanLine,
                          ),
                      ],
                    ),
                  ),
                ),
                // Reserved strip at the bottom of the HScrollView region:
                // the horizontal scrollbar thumb (an overlay) paints here
                // instead of over the last visible row, and the final row
                // scrolls clear of the divider/actions/totals below.
                const SizedBox(height: kPosDenseThumbGutter),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Column headers for the dense table — same paddings and segment
  /// widths as the dense line row so every column lines up.
  Widget _denseCartHeader({required ThemeData theme, required String loc}) {
    // Readability: 14px semibold column labels (was 12px bold) — headers
    // are glance-text the cashier reads while scanning rows.
    final style = theme.textTheme.labelMedium?.copyWith(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
    );

    Widget segment(String labelKey, double width, {TextAlign? align}) =>
        SizedBox(
          width: width,
          child: Text(
            AppStrings.t(labelKey, loc),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: align,
            style: style,
          ),
        );

    return Padding(
      // Test hook: the header cells share one style; find them via this.
      key: const Key('pos-dense-header'),
      // Compact in dense mode: every vertical pixel here is one the
      // cart lines cannot use.
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
      child: Row(
        children: [
          const SizedBox(width: kPosDenseSelectWidth),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              AppStrings.t('name', loc),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style,
            ),
          ),
          const SizedBox(width: 8),
          segment('unit_price', kPosDensePriceWidth, align: TextAlign.center),
          const SizedBox(width: 8),
          segment('qty', kPosDenseQtyWidth, align: TextAlign.center),
          const SizedBox(width: 8),
          segment('total_label', kPosDenseTotalWidth, align: TextAlign.end),
          const SizedBox(width: 8),
          segment('line_discount', kPosDenseDiscountWidth),
          const SizedBox(width: 8),
          const SizedBox(width: kPosDenseRemoveWidth),
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
    bool dense = false,
    int badgeCount = 0,
    Color? accent,
    bool solid = false,
    String? shortcut,
  }) {
    // Dense (reversed) rows: 40px (36 on short screens) instead of the
    // standard 44–46 — labels stay identical, only the chrome is
    // compacted so the cart lines get the height back. [shortcut] is the
    // key chip beside the label (PosShortcutKeys — the same table the
    // shortcuts map documents); it never changes the button's height.
    final height = dense
        ? (short ? 36.0 : 40.0)
        : short
            ? 44.0
            : 46.0;
    final theme = Theme.of(context);
    // Semantic action colors: an accent paints a SUBTLE TINT wash of its
    // hue over the panel ([AppColors.tint] × brightness) with the hue
    // itself as the border and an [AppColors.onTint] label — outlined,
    // never an opaque slab (solid fills were tried and rolled back: heavy
    // and flat against the totals card). [solid] keeps the ONE action that
    // must read as a filled chip — RETURN: the accent solid, white label,
    // mutedAction disabled fill. No accent = the plain outlined look (the
    // holds list is neutral by design). Disabled tint releases its wash
    // (transparent) with the outline softened toward the surface.
    final tintBg = accent == null || solid
        ? null
        : AppColors.tint(accent, theme.brightness);
    final tintFg = accent == null || solid
        ? null
        : AppColors.onTint(accent, theme.brightness);
    final style = OutlinedButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: Size(0, height),
      maximumSize: Size(double.infinity, height),
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: theme.textTheme.labelLarge?.copyWith(fontSize: 14),
      side: accent == null ? BorderSide(color: theme.colorScheme.outline) : null,
      foregroundColor: accent == null
          ? null
          : solid
              ? Colors.white
              : tintFg,
      backgroundColor: accent == null
          ? null
          : solid
              ? accent
              : tintBg,
      // styleFrom() keeps an explicit backgroundColor in EVERY state —
      // the solid chip dims to the muted mix, the tint wash releases.
      disabledBackgroundColor: accent == null
          ? null
          : solid
              ? AppColors.mutedAction(accent, theme.colorScheme.surface)
              : Colors.transparent,
      disabledForegroundColor: accent == null
          ? null
          : theme.colorScheme.onSurface.withValues(alpha: 0.38),
    ).copyWith(
      side: accent == null
          ? null
          : WidgetStateProperty.resolveWith<BorderSide>((states) =>
              states.contains(WidgetState.disabled)
                  ? BorderSide(
                      color: theme.colorScheme.outline.withValues(alpha: 0.6),
                    )
                  : BorderSide(color: accent)),
    );
    return SizedBox(
      height: height,
      child: OutlinedButton.icon(
        key: key,
        onPressed: onPressed,
        style: style,
        icon: badgeCount > 0
            ? Badge(
                label: Text('$badgeCount'),
                backgroundColor: theme.colorScheme.primary,
                textColor: theme.colorScheme.onPrimary,
                child: Icon(icon, size: dense || short ? 18 : 20),
              )
            : Icon(icon, size: dense || short ? 18 : 20),
        label: ShortcutBadgeLabel(
          label,
          keys: shortcut,
          compact: dense || short,
          labelStyle: theme.textTheme.labelLarge?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Dedicated totals card: Subtotal / Discount / TOTAL / PAY (UX FIX #7/#8).
/// In POS return mode the PAY slot becomes Confirm return / Cancel return.
class _PosTotalsPanel extends ConsumerStatefulWidget {
  final PosCartState cart;

  /// Dense (reversed) cart: trims the panel's vertical padding/row gaps so
  /// the cart lines region above gets the height back. TOTAL and PAY stay
  /// prominent — only breathing room is removed.
  final bool dense;

  /// Chrome compaction level from the cart-panel probe (0 = full layout;
  /// ≥1 merged action row, inline TOTAL and tightest rhythm; ≥2 merged
  /// Subtotal/Discount band). Presentation only — every value, key and
  /// interaction is identical at all levels. Loyalty does NOT live in this
  /// panel anymore (it rides the workspace sidebar card).
  final int compaction;

  final VoidCallback onPayment;
  final VoidCallback onConfirmReturn;
  final VoidCallback onCancelReturn;

  const _PosTotalsPanel({
    required this.cart,
    this.dense = false,
    this.compaction = 0,
    required this.onPayment,
    required this.onConfirmReturn,
    required this.onCancelReturn,
  });

  @override
  ConsumerState<_PosTotalsPanel> createState() => _PosTotalsPanelState();
}

class _PosTotalsPanelState extends ConsumerState<_PosTotalsPanel> {
  @override
  Widget build(BuildContext context) {
    final cart = widget.cart;
    final onPayment = widget.onPayment;
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final totals = cart.totals;
    final cs = theme.colorScheme;
    final currency = AppStrings.t('currency', loc);
    final payEnabled = !cart.isEmpty && !cart.checkoutPending;

    // Loyalty session (server-owned numbers — see posLoyaltyProvider).
    final loyalty = ref.watch(posLoyaltyProvider);
    // SPACE pays (default) but is a DIRECT quick sale while that operator
    // setting is ON — the PAY badge must follow the key's real meaning,
    // exactly like the shortcuts map's Space row does.
    final quickSale = ref.watch(posSettingsProvider).quickSaleWithSpace;
    final payShortcut = quickSale ? null : PosShortcutKeys.payment;
    final showLoyalty =
        !cart.returnMode && cart.customer != null && loyalty.hasCustomer;
    // Only a preview that matches the CURRENT total + selected percent
    // may drive displayed money; anything else shows the plain total.
    final preview = loyalty.previewMatches ? loyalty.preview : null;
    final rewardDiscount = preview?.rewardDiscount ?? 0.0;
    final amountDue =
        PaymentMath.amountDueOf(total: totals.total, rewardDiscount: rewardDiscount);
    // A GENUINE (preview-matched) loyalty discount restyles the money:
    // the original total is struck through and demoted, and the effective
    // price row below it goes green and larger. Presentation only — every
    // value, key and provider number stays byte-identical, and a stale
    // or suppressed preview (previewMatches false) renders the plain
    // total with no strike anywhere.
    final loyaltyApplied = showLoyalty && rewardDiscount > 0;

    return Material(
      key: const Key('pos-totals-panel'),
      color: theme.cardColor,
      elevation: 4,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: Padding(
        // §4 height budget: the stacked TOTAL (+~25px of label above the
        // amount) is paid for by leaner chrome here — the bottom region
        // must NOT grow against the cart lines (customer-attached
        // clipping, last-row fits). Dense keeps its own tighter rhythm.
        padding: EdgeInsets.fromLTRB(
          12,
          widget.dense
              ? 4
              : MediaQuery.sizeOf(context).height < 700
                  ? 4
                  : 6,
          12,
          widget.dense
              ? 2
              : MediaQuery.sizeOf(context).height < 700
                  ? 4
                  : 4,
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
              // §6: the dominant figure is 44–48 on normal desktops — 44
              // in the narrow cart panel, 48 on wide layouts.
              totalSize = w >= 400 ? 48.0 : 44.0;
              labelSize = 20.0;
              payHeight = 60.0;
            }
            final tightest = widget.compaction >= 1;
            final subSize = tightest
                ? 13.0
                : mediaH < 700
                    ? 14.0
                    : 15.0;
            final payFontSize = mediaH < 560 ? 15.0 : 17.0;
            final payIconSize = mediaH < 560 ? 20.0 : 22.0;
            // Dense (reversed): row padding, divider and post-TOTAL gap
            // yield their breathing room to the cart lines above (even
            // more so on short screens); the TOTAL size and PAY height
            // are untouched (both prominent). Compaction ≥ 1 pins every
            // rhythm knob to its tightest value regardless of window.
            final rowPad = tightest
                ? 1.0
                : widget.dense
                    ? (mediaH < 560 ? 1.0 : 3.0)
                    : mediaH < 700
                        ? 2.0
                        : 3.0;
            final gapAfterTotal = tightest
                ? 2.0
                : widget.dense
                    ? (mediaH < 560 ? 2.0 : 6.0)
                    : mediaH < 700
                        ? 4.0
                        : 6.0;
            final dividerH = tightest
                ? 4.0
                : widget.dense
                    ? (mediaH < 560 ? 4.0 : 8.0)
                    : mediaH < 700
                        ? 8.0
                        : 10.0;

            // §4/§6: the label sits immediately ABOVE the dominant amount,
            // both right-aligned to the money edge — a stacked focal block.
            // `height: 1.0` keeps the label's line box to its font size.
            // Compaction ≥ 1 puts the label INLINE at the start of the same
            // band (amount still right at the money edge) — same keys,
            // same values, ~20px handed back to the lines region.
            final totalLabel = Text(
              AppStrings.t('total_label', loc),
              key: const Key('pos-total-label'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontSize: labelSize,
                height: 1.0,
                fontWeight: FontWeight.w700,
                color: cs.onSurface,
              ),
            );
            final totalAmount = FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerEnd,
              child: numericText(
                '${totals.totalDisplay} $currency',
                key: const Key('pos-total-value'),
                style: theme.textTheme.headlineSmall?.copyWith(
                  // Struck + demoted only while a genuine loyalty
                  // discount is live; the full figure stays on screen.
                  fontSize: loyaltyApplied ? totalSize * 0.56 : totalSize,
                  fontWeight: FontWeight.w800,
                  color: loyaltyApplied
                      ? cs.onSurface.withValues(alpha: 0.55)
                      : cs.primary,
                  height: 1.05,
                  decoration: loyaltyApplied
                      ? TextDecoration.lineThrough
                      : TextDecoration.none,
                  decorationColor: loyaltyApplied
                      ? cs.onSurface.withValues(alpha: 0.65)
                      : null,
                  decorationThickness: 1.6,
                ),
              ),
            );
            final totalStack = widget.compaction >= 1
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: totalLabel),
                      const SizedBox(width: 8),
                      Flexible(child: totalAmount),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      totalLabel,
                      totalAmount,
                    ],
                  );

            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Subtotal stays clean — loyalty lives in the workspace
                // sidebar card (balance/rewards never ride these rows).
                // Compaction ≥ 2 folds the discount into the same band on
                // the tightest screens — both value keys and both amounts
                // unchanged.
                if (widget.compaction >= 2)
                  Padding(
                    padding: EdgeInsets.symmetric(vertical: rowPad),
                    child: Row(
                      children: [
                        Flexible(
                          child: Text(
                            AppStrings.t('subtotal_label', loc),
                            style: TextStyle(
                              fontSize: subSize,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        numericText(
                          totals.subtotalDisplay,
                          key: const Key('pos-subtotal-value'),
                          style: TextStyle(
                            fontSize: subSize + 1,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                            color: cs.onSurface.withValues(alpha: 0.78),
                          ),
                        ),
                        const SizedBox(width: 14),
                        Flexible(
                          child: Text(
                            AppStrings.t('invoice_discount', loc),
                            style: TextStyle(
                              fontSize: subSize,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        numericText(
                          '-${totals.invoiceDiscountDisplay}',
                          key: const Key('pos-discount-value'),
                          style: TextStyle(
                            fontSize: subSize + 1,
                            fontWeight: FontWeight.w700,
                            height: 1.3,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                            color: AppColors.warning,
                          ),
                        ),
                      ],
                    ),
                  )
                else ...[
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
                ],
                Divider(height: dividerH),
                // Loyalty rides the workspace sidebar card — this panel
                // keeps only Subtotal / Discount / TOTAL / PAY.
                totalStack,
                SizedBox(height: gapAfterTotal),
                if (loyaltyApplied)
                  // The EFFECTIVE price: green, larger than the struck
                  // original above it, same key/value contract as before.
                  _loyaltyAmountDueRow(
                    label: AppStrings.t('amount_due', loc),
                    value: PaymentMath.money(amountDue),
                    labelSize: subSize,
                    valueSize: totalSize * 0.72,
                    verticalPad: rowPad,
                  ),
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
                              // PAY rides the THEME accent (solid blue in
                              // every theme) — the screen-wide primary the
                              // rest of the app already speaks. The bold
                              // label clears 3:1 (large-text AA) on each
                              // theme's primary; disabled colors unchanged.
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
                                        // Bidi contract: the Arabic shortcut
                                        // label and the amount+currency unit
                                        // are separate widgets — the label
                                        // stays RTL, the money renders as one
                                        // LTR unit (`20 235.00 DA`). The key
                                        // chip and the dash ride the label
                                        // group; the chip measures itself
                                        // before it is laid out, so it can
                                        // never squeeze the amount.
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          mainAxisAlignment:
                                              MainAxisAlignment.center,
                                          children: [
                                            Flexible(
                                              child: ShortcutBadgeLabel(
                                                AppStrings.t(
                                                  'payment_shortcut',
                                                  loc,
                                                ),
                                                keys: payShortcut,
                                                tone: ShortcutBadgeTone
                                                    .onColor,
                                                dash: true,
                                              ),
                                            ),
                                            const SizedBox(width: 6),
                                            // Non-flex sibling: the money
                                            // always takes its FULL
                                            // intrinsic width — the bidi
                                            // box assertion must see the
                                            // whole `20 235.00 DA`, never an
                                            // ellipsized slice of it.
                                            numericText(
                                              '${totals.totalDisplay} $currency',
                                              key: const Key(
                                                'pos-pay-amount',
                                              ),
                                              overflow:
                                                  TextOverflow.ellipsis,
                                            ),
                                          ],
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
    final cart = widget.cart;
    final onConfirmReturn = widget.onConfirmReturn;
    final onCancelReturn = widget.onCancelReturn;
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

  /// The effective price after a genuine loyalty discount: green
  /// (`AppColors.success`, the same money-green the redemption dialog
  /// speaks) and larger than the struck-through original above it.
  /// Value and key are byte-identical to the plain totals row — this
  /// hook restyles presentation only.
  static Widget _loyaltyAmountDueRow({
    required String label,
    required String value,
    required double labelSize,
    required double valueSize,
    double verticalPad = 2,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: verticalPad),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: labelSize,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          numericText(
            value,
            key: const Key('pos-loyalty-amount-due'),
            style: TextStyle(
              fontSize: valueSize,
              fontWeight: FontWeight.w800,
              height: 1.1,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: AppColors.success,
            ),
          ),
        ],
      ),
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
          numericText(
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

/// True when an automatic focus move (the post-add qty refocus, the
/// post-add search refocus) would interrupt a field that holds
/// uncommitted input right now.
///
/// Two cases, matching the two field paths a wedge burst can land in:
///  * a cart line qty field (debugLabel `cart-line-qty`) holding a
///    pure-digit run longer than any legal quantity — committed
///    quantities never exceed [kPosQuantityMax], and a burst appends at
///    least 6 more digits — is a burst mid-typing;
///  * any other focused field (search, dialog) with non-empty text is
///    uncommitted input (a query or a burst being typed).
bool _focusInterruptedByInput() {
  if (!editableTextHasFocus()) return false;
  final focus = FocusManager.instance.primaryFocus;
  final context = focus?.context;
  final editable = context?.widget is EditableText
      ? context?.widget as EditableText
      : context?.findAncestorWidgetOfExactType<EditableText>();
  final text = editable?.controller.text ?? '';
  if (focus?.debugLabel == 'cart-line-qty') {
    final value = double.tryParse(text);
    return value != null && value > kPosQuantityMax;
  }
  return text.isNotEmpty;
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

  /// A keyboard-wedge scan landed in this line's focused qty field (the
  /// next scan of a continuous session): the digit run is a barcode, not a
  /// quantity — handed to the POS scan path instead of the qty parser.
  final ValueChanged<String>? onScan;

  /// Set when a scan submitted from *this* line's qty field is still
  /// resolving: once the frame that produced it lands, the field shows
  /// the committed quantity again. Never reset synchronously at submit —
  /// a wedge burst typed in the flight window appends to whatever is on
  /// screen, and its Enter strip is anchored at [_CartLineTileState.
  /// _runBase], not at the displayed text.
  final ValueNotifier<String?>? clearQtyTextRequest;

  /// Set when arrow navigation wants *this* line revealed fully in view;
  /// consumed (reset) by the tile so the request survives until the lazy
  /// list has actually built this row (mounting claims it via initState).
  final ValueNotifier<String?>? revealRequest;

  const _CartLineTile({
    super.key,
    required this.line,
    required this.onRemove,
    required this.onActivate,
    required this.onQty,
    required this.onDiscount,
    this.onScan,
    this.clearQtyTextRequest,
    this.revealRequest,
    this.dense = false,
    this.selected = false,
  });

  /// Reversed-layout single-row rendering (see [_CartPanel._denseCartLines]);
  /// false keeps the standard stacked card untouched.
  final bool dense;

  /// Whether this line is the cart's current shortcut target
  /// (lastActiveKey). Drives the selection marker and tint — the dense
  /// row's check-circle, the standard row's highlighted card border — and
  /// the arrow-key reveal.
  final bool selected;

  @override
  State<_CartLineTile> createState() => _CartLineTileState();
}

class _CartLineTileState extends State<_CartLineTile> {
  late final TextEditingController _qty;
  late final TextEditingController _discount;
  late final FocusNode _qtyFocus;

  /// The qty text as last seen by the typing handlers — the pre-edit
  /// content the next keystroke extends. Kept aligned with the displayed
  /// text at every programmatic write (see [_commitQtyText]) so an
  /// appended digit can be told apart from a fresh replacement (see
  /// [_isDigitAppend]).
  String _lastQtyText = '';

  /// The text the CURRENT digit run started from — what a wedge burst is
  /// typed on top of. An external quantity merge that lands mid-run (a
  /// previous scan resolving while this burst is being typed) bumps the
  /// committed quantity but must NOT change this base: Enter still strips
  /// it off the submitted run to recover the barcode suffix. Reset by
  /// every non-append keystroke and every programmatic write.
  String _runBase = '';

  /// The field text the last scan submit consumed — set together with the
  /// clear request, checked by the post-frame clear: the committed
  /// quantity is restored only while the field still shows this exact
  /// text (nothing typed over it during the flight window).
  String? _pendingScanText;

  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(text: widget.line.quantity);
    _logQtyFieldWrite(
      reason: 'field-mount',
      previous: null,
      next: widget.line.quantity,
    );
    _discount = TextEditingController(text: widget.line.lineDiscount);
    _commitQtyText(_qty.text);
    _qtyFocus = FocusNode(debugLabel: 'cart-line-qty');
    // Focusing this line's qty field makes it the shortcut target —
    // "tap an older line, type 3, press +" now always hits that line.
    _qtyFocus.addListener(_handleQtyFocus);
    widget.clearQtyTextRequest?.addListener(_handleClearQtyTextRequest);
    // A clear request may already be waiting for this tile (a scan
    // submitted from this field resolved while the tile was rebuilding).
    _handleClearQtyTextRequest();
    widget.revealRequest?.addListener(_handleRevealRequest);
    // A reveal request may already be waiting for this tile (the lazy list
    // often builds it only after _moveActiveLine's jump laid its region
    // out — the tile mounts already selected, so the selected-transition
    // reveal in didUpdateWidget can never be the one to claim it). Post-add
    // reveals (barcode or catalog add) claim it the same way.
    _handleRevealRequest();
    // Deliberately NO reveal here: a tile is often built ALREADY selected
    // (an add preselects its new line), and jumping the list on every mount
    // would scroll older rows past the fold edge — a later tap on their
    // header then lands outside the viewport clip. Reveals belong to
    // selection CHANGES (didUpdateWidget) and the post-add / arrow
    // reveal request, exactly as before.
  }

  void _handleQtyFocus() {
    if (_qtyFocus.hasFocus) widget.onActivate();
  }

  /// Arrow navigation named THIS line: consume the request, then reveal
  /// the row against the committed selection rebuild. Fires both from a
  /// mounted listener (tile already in the tree) and from initState (lazy
  /// list just built it after the jump) — the post-frame check re-reads
  /// `widget.selected` so a stale request whose selection has meanwhile
  /// moved on is dropped instead of yanking the list elsewhere.
  void _handleRevealRequest() {
    final request = widget.revealRequest;
    if (request == null || request.value != widget.line.key) return;
    request.value = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !widget.selected) return;
      _revealNow();
    });
  }

  @override
  void didUpdateWidget(covariant _CartLineTile old) {
    super.didUpdateWidget(old);
    if (!identical(old.revealRequest, widget.revealRequest)) {
      old.revealRequest?.removeListener(_handleRevealRequest);
      widget.revealRequest?.addListener(_handleRevealRequest);
      _handleRevealRequest();
    }
    if (!identical(old.clearQtyTextRequest, widget.clearQtyTextRequest)) {
      old.clearQtyTextRequest?.removeListener(_handleClearQtyTextRequest);
      widget.clearQtyTextRequest?.addListener(_handleClearQtyTextRequest);
      _handleClearQtyTextRequest();
    }
    if (old.line.quantity != widget.line.quantity &&
        _qty.text != widget.line.quantity) {
      // Phase 8 FIX #3: never wipe a mid-burst digit run. A concurrent
      // add (another line's scan, a slow lookup resolving) changes this
      // line's committed quantity while the qty field holds a pure-digit
      // run that has NOT been touched since it was last committed — the
      // run is the cashier's burst-in-progress, not stale field text.
      // Clobbering it here replaces the burst's prefix with the new
      // committed quantity, and the remaining digits then submit as a
      // FOREIGN suffix (the real-device second vector: base '2' +
      // '4202402' -> qty-submit len=7). Expression text (any non-digit
      // content) still syncs — it can never be a scan run.
      final text = _qty.text;
      // A run IN PROGRESS has text that differs from the run's base
      // ([_runBase] still holds the committed quantity the digits were
      // typed on); a pristine committed display has base == text and
      // must keep syncing normally (the `+` shortcut, dialogs, external
      // quantity changes).
      final midRun = text.isNotEmpty &&
          text == _lastQtyText &&
          text != _runBase &&
          RegExp(r'^\d+$').hasMatch(text) &&
          text != widget.line.quantity;
      if (midRun) {
        // Keep the run AND its original base: [_scanCodeOfSubmission]
        // strips the text the run STARTED from, and a merge that landed
        // mid-burst intentionally does not re-anchor it (the run's prefix
        // is still the old committed quantity the digits were typed on).
        scanDiag('qty-sync', {
          'outcome': 'run-kept',
          'committed': widget.line.quantity,
          'runLen': text.length,
        });
      } else {
        // Unconditional sync (matches the pre-fix behavior): an expression
        // like `10*24` and every other valid quantity the user typed must
        // resolve to the computed value on screen as soon as the cart
        // commit lands. The digit-run tracker ([_runBase]) can go stale
        // under this write, so it is committed too — a run typed AFTER a
        // merge still has to append to the now-committed quantity, never
        // to the barcode prefix this sync just discarded.
        _writeQtyText(widget.line.quantity, reason: 'cart-state-sync');
        _commitQtyText(_qty.text);
      }
    }
    if (old.line.lineDiscount != widget.line.lineDiscount &&
        _discount.text != widget.line.lineDiscount) {
      _discount.text = widget.line.lineDiscount;
    }
    // Arrow-key selection moved HERE: reveal the newly selected row once
    // this rebuild has committed (taps also trigger it — their row is
    // visible, so the geometry check is a no-op there).
    if (widget.selected && !old.selected) _revealIfOffscreen();
  }

  /// Bring the selected row fully into its scroll view: a row that is
  /// already fully visible never moves; a row above the fold top-aligns
  /// ([ScrollPositionAlignmentPolicy.keepVisibleAtStart]) and a row below
  /// the fold bottom-aligns (keepVisibleAtEnd) — each scrolls the MINIMUM
  /// distance that reveals the row. Runs post-frame so the selection
  /// rebuild has laid the row out first; the horizontal dense-table
  /// ancestor (if any) is revealed by the same ensureVisible walk the
  /// post-add focus path already relies on.
  void _revealIfOffscreen() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _revealNow();
    });
  }

  /// Geometry half of [_revealIfOffscreen] against a committed frame —
  /// also called directly by [_handleRevealRequest] from its own post-frame
  /// callback (the selection rebuild has landed by then).
  void _revealNow() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached) return;
    final scrollableBox =
        Scrollable.maybeOf(context)?.context.findRenderObject();
    if (scrollableBox is! RenderBox || !scrollableBox.attached) return;
    final tile = MatrixUtils.transformRect(
      box.getTransformTo(scrollableBox),
      Offset.zero & box.size,
    );
    final view = Offset.zero & scrollableBox.size;
    if (tile.top >= view.top && tile.bottom <= view.bottom) return;
    // Instant jump — an animated glide would make the scrollable drop
    // every pointer event until it settles.
    Scrollable.ensureVisible(
      context,
      duration: Duration.zero,
      alignmentPolicy: tile.top < view.top
          ? ScrollPositionAlignmentPolicy.keepVisibleAtStart
          : ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
    );
  }

  @override
  void dispose() {
    widget.revealRequest?.removeListener(_handleRevealRequest);
    widget.clearQtyTextRequest?.removeListener(_handleClearQtyTextRequest);
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
    _writeQtyText(
      applied ? text : widget.line.quantity,
      reason: applied ? 'quantity-step' : 'quantity-step-rejected',
    );
    _commitQtyText(_qty.text);
  }

  /// Typing: apply as soon as the input is a complete, valid quantity
  /// (plain number or `10*24` expression) — silently wait while it is
  /// still incomplete, never keep an impossible quantity on screen.
  ///
  /// Two digit-run rules keep a keyboard-wedge burst from ever being
  /// parsed as a quantity (repeated-scan regression):
  ///  * a full barcode-length run ([kPosBarcodeScanInput]) waits for
  ///    Enter untouched — the existing rule;
  ///  * an ACCUMULATING digit run (each keystroke appending one digit to
  ///    the previous one — exactly how a wedge types a barcode into this
  ///    focused field, and equally how a human types a multi-digit
  ///    quantity digit by digit) also waits: live-parsing it set the line
  ///    quantity to partial barcode prefixes and fired the stock guard
  ///    once a prefix overshot the stock ("Out of stock" while stock was
  ///    available). Enter is the decision point — see
  ///    [_handleQtySubmitted].
  void _handleQtyChanged(String raw) {
    widget.onActivate();
    final previous = _lastQtyText;
    _lastQtyText = raw;
    // Any live edit ends the in-flight scan window: once the field holds
    // something else, a later submit of the old burst text would be a
    // fresh event, never a duplicate delivery (the dedup key in
    // _handleQtySubmitted). The scheduled clear keeps its own captured
    // text, so this never blinds it.
    if (_pendingScanText != null && raw != _pendingScanText) {
      _pendingScanText = null;
    }
    if (BarcodeScannerGateway.instance.isPassThroughRunFor(_qty)) {
      scanDiag('qty-input-deferred', {
        'reason': 'scanner-pass-through',
        'productId': widget.line.productId ?? '-',
        'variantId': widget.line.variantId ?? '-',
        'sellingUnitId': widget.line.sellingUnitId ?? '-',
        'previous': widget.line.quantity,
        'next': widget.line.quantity,
        'len': raw.length,
        'corr': lastScanCorr ?? '-',
      });
      return;
    }
    if (kPosBarcodeScanInput.hasMatch(raw.trim())) return;
    if (_isDigitAppend(previous, raw)) return;
    if (!parseQuantityExpression(raw).isValid) {
      // Fresh edit, not yet a quantity (e.g. '10*'): the run base is the
      // text this edit replaced.
      _runBase = previous;
      return;
    }
    if (widget.onQty(raw)) {
      // Applied: the tracker must not keep the typed text (a next
      // keystroke would look like an append of it and be deferred) — AND
      // it must not go EMPTY (a next keystroke then failed the append
      // check and a barcode prefix parsed as a quantity: the repeated-
      // scan jump to 14/15). Commit the NORMALIZED value the cart just
      // received and put it on screen immediately: a programmatic write
      // fires no onChanged, and didUpdateWidget sees equal text (no-op).
      final applied = parseQuantityExpression(raw).text;
      _writeQtyText(applied, reason: 'quantity-input-applied');
      _commitQtyText(applied);
      return;
    }
    _writeQtyText(widget.line.quantity, reason: 'quantity-input-rejected');
    _commitQtyText(_qty.text);
  }

  void _writeQtyText(String next, {required String reason}) {
    final previous = _qty.text;
    _logQtyFieldWrite(reason: reason, previous: previous, next: next);
    _qty.text = next;
  }

  void _logQtyFieldWrite({
    required String reason,
    required String? previous,
    required String? next,
  }) {
    scanDiag('qty-field-write', {
      'reason': reason,
      'lineKey': widget.line.key,
      'productId': widget.line.productId ?? '-',
      'variantId': widget.line.variantId ?? '-',
      'sellingUnitId': widget.line.sellingUnitId ?? '-',
      'previous': previous ?? '-',
      'next': next ?? '-',
      'corr': lastScanCorr ?? '-',
    });
  }

  /// A programmatic write to the qty field ends any digit run: the
  /// append tracker and the run base now describe what is shown.
  void _commitQtyText(String text) {
    _lastQtyText = text;
    _runBase = text;
  }

  /// A scan submitted from THIS field is still resolving (or missed): once
  /// the next frame lands, show the committed quantity again — but only
  /// while the field still holds the text that scan consumed. A wedge
  /// burst typed into the flight window owns the field until ITS Enter
  /// (Enter strips [_runBase] off the run, so the burst never depends on
  /// the displayed text); wiping the field under it would corrupt the run.
  void _handleClearQtyTextRequest() {
    final request = widget.clearQtyTextRequest;
    if (request == null || request.value != widget.line.key) return;
    request.value = null;
    final consumed = _pendingScanText;
    if (consumed == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_qty.text != consumed) {
        // Something typed over the burst text in the flight window (or a
        // sync already restored it) — never wipe live content.
        scanDiag('qty-clear', {
          'outcome': 'skipped',
          'textLen': _qty.text.length,
          'consumedLen': consumed.length,
        });
        return;
      }
      scanDiag('qty-clear', {
        'outcome': 'restored',
        'committedLen': widget.line.quantity.length,
      });
      _writeQtyText(widget.line.quantity, reason: 'scan-post-frame-clear');
      _commitQtyText(_qty.text);
      _pendingScanText = null;
    });
  }

  /// True when [raw] extends [previous] by exactly one appended digit —
  /// the fingerprint of an in-progress digit run (wedge burst or hand
  /// typing). Such a run is not yet a quantity; it sits untouched until
  /// Enter decides.
  static bool _isDigitAppend(String previous, String raw) {
    if (raw.length != previous.length + 1) return false;
    if (!raw.startsWith(previous)) return false;
    return RegExp(r'^\d+$').hasMatch(raw);
  }

  /// The barcode a wedge burst typed into this focused field, or null
  /// when the submitted text is not a scan.
  ///
  /// The caret parks at the END of the committed quantity after every
  /// add, so a burst types its digits ON TOP of that quantity (`2` +
  /// `8718114202402`): the scan is the barcode-shaped SUFFIX, and
  /// stripping it is unambiguous — committed quantity (≥ 1 digit) plus
  /// barcode (≥ 6 digits) always exceeds [kPosQuantityMax], so such a
  /// run can never be a quantity. The base is the text the run STARTED
  /// from ([_runBase]) — a previous scan's merge may have landed (and
  /// bumped the committed quantity) while this burst was still being
  /// typed. A whole-replace barcode-shaped text (no committed prefix)
  /// keeps the original rule.
  String? _scanCodeOfSubmission(String raw) {
    final text = raw.trim();
    final base = _runBase.isNotEmpty ? _runBase : widget.line.quantity;
    if (base.isNotEmpty &&
        text.length > base.length &&
        text.startsWith(base)) {
      final suffix = text.substring(base.length);
      if (kPosBarcodeScanInput.hasMatch(suffix)) return suffix;
    }
    if (kPosBarcodeScanInput.hasMatch(text)) return text;
    return null;
  }

  /// Enter: strict — an invalid expression or an impossible quantity is
  /// rejected with the localized toast and the field rolls back.
  void _handleQtySubmitted(String raw) {
    final trimmed = raw.trim();
    // Scanner wedge in the focused qty field (post-add focus): the digit
    // run is a barcode, not a quantity — forward it to the scan path
    // (canonical lookup + cart rules). The field is NOT reset here: a
    // burst typed into the flight window owns the text on screen until
    // ITS Enter, and Enter strips the run base off the submitted text
    // ([_scanCodeOfSubmission]) — never the displayed text. The committed
    // quantity is restored post-frame by [_handleClearQtyTextRequest],
    // and only while nothing typed over it in the meantime.
    final scanCode = _scanCodeOfSubmission(trimmed);
    if (scanCode != null) {
      if (trimmed == _pendingScanText) {
        // Duplicate delivery of a scan that is still resolving (repeated
        // Enter / re-delivered performAction inside the clear window —
        // CR+LF terminators, key repeat): the clear request is already
        // pending; one physical scan may never dispatch twice.
        scanDiag('qty-submit', {
          'branch': 'dup-suppressed',
          'len': trimmed.length,
        });
        widget.clearQtyTextRequest?.value = widget.line.key; // re-arm
        return;
      }
      _pendingScanText = trimmed;
      widget.clearQtyTextRequest?.value = widget.line.key;
      // ORIGIN event for the qty-field path. `baseLen` > 0 means the
      // field held a committed quantity prefix (normal burst-on-quantity);
      // `textLen` longer than base + 13 would reveal foreign digits
      // concatenated into the run.
      lastScanCorr = scanDiag('qty-submit', {
        'branch': 'scan',
        'len': scanCode.length,
        'textLen': trimmed.length,
        'baseLen': trimmed.length - scanCode.length,
        'suffix3': scanDiagSuffix3(scanCode),
      });
      widget.onScan?.call(scanCode);
      return;
    }
    widget.onActivate();
    if (widget.onQty(raw)) {
      // Normalize synchronously (see _handleQtyChanged's applied branch):
      // the tracker and the screen must show the committed value before
      // any next keystroke — an expression like `10*24` never leaves
      // `10*24` on screen or in the tracker while the rebuild is pending.
      final applied = parseQuantityExpression(raw).text;
      _writeQtyText(applied, reason: 'quantity-submit-applied');
      _commitQtyText(applied);
      scanDiag('qty-submit', {
        'branch': 'quantity-applied',
        'len': trimmed.length,
        'text': applied,
      });
      return;
    }
    scanDiag('qty-submit', {
      'branch': 'quantity-rejected',
      'len': trimmed.length,
    });
    _writeQtyText(widget.line.quantity, reason: 'quantity-submit-rejected');
    _commitQtyText(_qty.text);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.dense) return _buildDenseRow(context);
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

    return Padding(
      key: Key('cart-line-${line.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      child: Material(
        // Selection highlight (same tints the dense row already uses):
        // without a marker the arrow walk would move an invisible cursor.
        color: widget.selected
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : theme.cardColor,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          constraints: BoxConstraints(minHeight: minHeight),
          padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.55)
                  : theme.dividerColor.withValues(alpha: 0.55),
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
                  numericText(
                    formatGroupedFixed(line.lineTotal, 2),
                    key: Key('cart-line-total-${line.key}'),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontSize: short ? 16.0 : 17.0,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  _removeButton(loc: loc),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  _qtyDecButton(loc: loc),
                  _qtyField(loc: loc, short: short),
                  _qtyIncButton(loc: loc),
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
                          numericText(
                            '${_fmtQty(baseQty)} $baseUnit',
                            key: Key('cart-line-base-qty-${line.key}'),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13,
                              color: theme.colorScheme.onSurface
                                  .withValues(alpha: 0.7),
                            ),
                          ),
                          // Informational only — never feeds the cart total.
                          // Bidi: Arabic "Base price:" label natural; the
                          // grouped price is one LTR isolate (W7).
                          Text(
                            '${AppStrings.t('base_price', loc)}: '
                            '${bidiIsolateLtr(_fmtPrice(line.baseUnitPrice))} '
                            '/ $baseUnit',
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
              _discountField(loc: loc, width: short ? 120 : 140),
            ],
          ),
        ),
      ),
    );
  }

  /// Shared cell widgets — the standard card and the reversed-layout dense
  /// row build the exact same qty/discount/remove controls (same keys,
  /// same controllers), so behaviour and tests hold in both layouts.

  Widget _qtyDecButton({required String loc}) {
    final line = widget.line;
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        key: Key('cart-line-qty-dec-${line.key}'),
        tooltip: AppStrings.t('qty_decrease', loc),
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        iconSize: 26,
        icon: const Icon(Icons.remove_circle_outline),
        onPressed:
            (double.tryParse(_qty.text) ?? 0) <= 1 ? null : () => _bumpQty(-1),
      ),
    );
  }

  /// The shared qty field. The dense row pins it to 52px (44+52+44 = the
  /// 140px qty column); the card keeps the short/tall 48/56 widths.
  Widget _qtyField({
    required String loc,
    required bool short,
    double? width,
  }) {
    final line = widget.line;
    return SizedBox(
      width: width ?? (short ? 48.0 : 56.0),
      child: TextField(
        key: Key('cart-line-qty-${line.key}'),
        controller: _qty,
        focusNode: _qtyFocus,
        textAlign: TextAlign.center,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        style: TextStyle(
          fontSize: short ? 15.0 : 16.0,
          fontWeight: FontWeight.w700,
        ),
        decoration: InputDecoration(
          isDense: true,
          labelText: AppStrings.t('qty', loc),
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
        ),
        // Quantity expressions (`10*24` → 240) are parsed by the shared
        // funnel in pos_quantity.dart.
        onSubmitted: _handleQtySubmitted,
        onChanged: _handleQtyChanged,
      ),
    );
  }

  Widget _qtyIncButton({required String loc}) {
    final line = widget.line;
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        key: Key('cart-line-qty-inc-${line.key}'),
        tooltip: AppStrings.t('qty_increase', loc),
        constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        padding: EdgeInsets.zero,
        iconSize: 26,
        icon: const Icon(Icons.add_circle_outline),
        onPressed: () => _bumpQty(1),
      ),
    );
  }

  Widget _removeButton({required String loc}) {
    final line = widget.line;
    return IconButton(
      key: Key('cart-line-remove-${line.key}'),
      tooltip: AppStrings.t('remove_line', loc),
      constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
      padding: EdgeInsets.zero,
      iconSize: 20,
      icon: const Icon(Icons.close),
      onPressed: widget.onRemove,
    );
  }

  /// Compact line discount field (36–40px tall, warning colour when > 0).
  /// [width] lets the dense row pin the 136px discount column; the card
  /// keeps the short/tall 120/140 widths.
  Widget _discountField({required String loc, required double width}) {
    final theme = Theme.of(context);
    final line = widget.line;
    final discountActive = (double.tryParse(line.lineDiscount) ?? 0) > 0;
    return SizedBox(
      height: 38,
      width: width,
      child: TextField(
        key: Key('cart-line-discount-${line.key}'),
        controller: _discount,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
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
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        ),
        onSubmitted: widget.onDiscount,
        onChanged: widget.onDiscount,
      ),
    );
  }

  /// Reversed-layout dense row: one horizontal line — selection marker,
  /// name (+pack badge / stock warning / promo / wholesale markers),
  /// unit price + equivalence, qty stepper, line total, discount, remove.
  /// Column widths match [_CartPanel._denseCartHeader]'s segments.
  Widget _buildDenseRow(BuildContext context) {
    final loc = Localizations.localeOf(context).languageCode;
    final theme = Theme.of(context);
    final line = widget.line;
    final selectedUnit = AppStrings.unitLabel(line.unitName, loc);
    final baseUnit = AppStrings.unitLabel(line.productUnit, loc);
    final baseQty = (double.tryParse(line.quantity) ?? 0) *
        (double.tryParse(line.unitMultiplier ?? '') ?? 0);
    final showBaseInfo = line.sellingUnitId != null &&
        line.unitMultiplier != null &&
        line.baseUnitPrice != null &&
        baseQty > 0;
    final available = double.tryParse(line.availableStock ?? '');
    final overStock = available != null && line.qty > available;

    return Padding(
      key: Key('cart-line-${line.key}'),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Material(
        color: widget.selected
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : theme.cardColor,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: widget.selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.55)
                  : theme.dividerColor.withValues(alpha: 0.45),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: kPosDenseSelectWidth,
                child: Icon(
                  widget.selected ? Icons.check_circle : Icons.circle_outlined,
                  key: Key(
                    widget.selected
                        ? 'cart-line-selected-${line.key}'
                        : 'cart-line-unselected-${line.key}',
                  ),
                  size: 16,
                  color: widget.selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(width: 6),
              // Name (tappable → activates the line for the shortcuts)
              // plus pack badge / stock-warning / promo / wholesale rows.
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onActivate,
                  child: Row(
                    children: [
                      if (line.isPack) ...[
                        Container(
                          key: Key('cart-line-pack-badge-${line.key}'),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary
                                .withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.5),
                            ),
                          ),
                          child: Text(
                            AppStrings.t('pack_badge', loc),
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontSize: 11,
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              line.name,
                              key: Key('cart-line-name-${line.key}'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            if (overStock ||
                                line.promotionApplied ||
                                line.wholesaleApplied)
                              Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Row(
                                  children: [
                                    if (overStock) ...[
                                      Icon(
                                        Icons.warning_amber_rounded,
                                        size: 13,
                                        color: AppColors.warning,
                                      ),
                                      const SizedBox(width: 3),
                                      Flexible(
                                        child: Text(
                                          '${AppStrings.t('stock', loc)}: '
                                          '${_fmtQty(available)}',
                                          key: Key(
                                              'cart-line-stock-warning-${line.key}'),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.labelSmall
                                              ?.copyWith(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w700,
                                            color: AppColors.warning,
                                          ),
                                        ),
                                      ),
                                    ],
                                    if (line.promotionApplied)
                                      Tooltip(
                                        message: line.retailPrice != null
                                            ? '${AppStrings.t('promotion', loc)} · ${line.retailPrice}'
                                            : AppStrings.t('promotion', loc),
                                        child: Icon(
                                          Icons.local_offer,
                                          size: 13,
                                          key: Key(
                                              'cart-line-promotion-${line.key}'),
                                          color: theme.colorScheme.tertiary,
                                        ),
                                      ),
                                    if (line.wholesaleApplied) ...[
                                      const SizedBox(width: 4),
                                      Tooltip(
                                        message:
                                            AppStrings.t('wholesale', loc),
                                        child: Icon(
                                          Icons.sell,
                                          size: 13,
                                          key: Key(
                                              'cart-line-wholesale-${line.key}'),
                                          color: theme.colorScheme.primary,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Unit price + selected-unit label (+ base-qty equivalence).
              SizedBox(
                width: kPosDensePriceWidth,
                child: Tooltip(
                  message: showBaseInfo
                      ? '${AppStrings.t('base_price', loc)}: '
                          '${bidiIsolateLtr(_fmtPrice(line.baseUnitPrice))} / $baseUnit'
                      : '${AppStrings.t('unit_price', loc)}: '
                          '${bidiIsolateLtr(line.unitPrice)}',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      numericText(
                        line.unitPrice,
                        key: Key('cart-line-price-${line.key}'),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        selectedUnit,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 12,
                          color: theme.colorScheme.onSurface
                              .withValues(alpha: 0.65),
                        ),
                      ),
                      if (showBaseInfo)
                        numericText(
                          '${_fmtQty(baseQty)} $baseUnit',
                          key: Key('cart-line-base-qty-${line.key}'),
                          style: theme.textTheme.labelSmall?.copyWith(
                            fontSize: 12,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.6),
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: kPosDenseQtyWidth,
                child: Row(
                  children: [
                    _qtyDecButton(loc: loc),
                    _qtyField(loc: loc, short: false, width: 52),
                    _qtyIncButton(loc: loc),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: kPosDenseTotalWidth,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: numericText(
                    formatGroupedFixed(line.lineTotal, 2),
                    key: Key('cart-line-total-${line.key}'),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _discountField(
                loc: loc,
                width: kPosDenseDiscountWidth,
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: kPosDenseRemoveWidth,
                child: _removeButton(loc: loc),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// Reversed-layout cart table geometry (Klick POS layout switch). The
// dense header row and every dense line row share these widths so the
// columns stay aligned while the whole table (header included) moves as
// one unit inside the panel's HScrollView. Gap sequence:
// select(18) 6 name(≥130) 8 price(84) 8 qty(140) 8 total(86) 8
// discount(136) 8 remove(40) → 692px MINIMUM table width: the table
// fills any wider panel the reversed cart owns (the name column absorbs
// the extra) and only scrolls sideways below this floor.
const double kPosDenseSelectWidth = 18;
const double kPosDensePriceWidth = 84;
const double kPosDenseQtyWidth = 140;
const double kPosDenseTotalWidth = 86;
const double kPosDenseDiscountWidth = 136;
const double kPosDenseRemoveWidth = 40;
const double kPosDenseRowWidth = 692;
/// Reserved strip at the bottom of the dense table's region: the
/// horizontal scrollbar thumb paints over it (the thumb is an overlay at
/// the HScrollView's bottom edge), and the last cart row scrolls fully
/// clear of the divider + fixed action/totals/PAY section below.
const double kPosDenseThumbGutter = 8;

/// Display helpers for cart-line unit presentation (UX FIX #3).
/// Whole numbers render without decimals (10 not 10.0). Integer digits are
/// space-grouped for readability (presentation only — the cart still holds
/// raw numeric strings).
String _fmtQty(double v) => formatGrouped(
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2),
    );

String _fmtPrice(String? raw) {
  final v = double.tryParse(raw ?? '');
  if (v == null) return raw ?? '0';
  return formatGrouped(
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(2),
  );
}
