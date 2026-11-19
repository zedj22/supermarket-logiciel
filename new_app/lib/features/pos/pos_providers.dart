// Riverpod providers for POS checkout (Phase 8 Step 3).
//
// - Cart state, debounced product search, barcode scan
// - Holds / favorites / customer search / sale history
// - Idempotent checkout: ONE client_request_id per attempt, reused on retry
// - Cart is cleared ONLY after the server confirms success
import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/scan_diagnostics.dart';
import '../../core/sell_unit_pricing.dart';
import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../devices/device_identity.dart';
import '../packs/pack_models.dart';
import '../products/models.dart';
import 'pos_error_message.dart';
import 'pos_models.dart';

const Duration kPosSearchDebounce = Duration(milliseconds: 250);

/// Phase E — opaque loyalty QR payload prefix (`KLICK:C:<customer uuid>`).
/// The code carries no personal data; matching happens case-insensitively
/// on this prefix only, exactly like the backend lookup.
const String kLoyaltyQrPrefix = 'KLICK:C:';

// ---------------------------------------------------------------------------
// Device id (holds filter + X-Device-ID)
// ---------------------------------------------------------------------------
//
// Promoted to the app-level `deviceIdProvider` in
// `features/devices/device_identity.dart` (Phase 16 §23.2). The storage key
// (`pos_device_id`), the `pos-<millis>-<rand>` format and this provider's
// type are unchanged — Phase 14/15 call sites read it exactly as before.

final posDeviceIdProvider = deviceIdProvider;

void _logCartQuantityWrite({
  required String reason,
  required CartLine line,
  required String? previous,
  required String? next,
  int? scanCorrelationId,
}) {
  scanDiag('cart-quantity-write', {
    'reason': reason,
    'lineKey': line.key,
    'productId': line.productId ?? '-',
    'variantId': line.variantId ?? '-',
    'sellingUnitId': line.sellingUnitId ?? '-',
    'previous': previous ?? '-',
    'next': next ?? '-',
    'corr': scanCorrelationId ?? '-',
  });
}

// ---------------------------------------------------------------------------
// Cart state
// ---------------------------------------------------------------------------

class PosCartState {
  final List<CartLine> lines;
  final String invoiceDiscount;
  final PosCustomer? customer;
  final bool checkoutPending;
  final String? lastError;
  final CheckoutResult? lastResult;
  final String? pendingClientRequestId;
  final List<String> stockErrors;
  final String? notice;

  /// POS return mode: the cart is being reviewed as an INDEPENDENT
  /// return (`pos_return` permission). Lines are never touched by the
  /// mode itself — cancel / mode flips leave the cart exactly as the
  /// cashier built it. `clearCart` (and any state reset) exits the mode.
  final bool returnMode;

  /// A `POST /api/v1/returns` attempt is in flight (mirrors
  /// [checkoutPending]: the UI shows a spinner and blocks a second
  /// submit; the cart is kept until the server confirms).
  final bool returnPending;

  /// Idempotency key of the current return attempt — ONE id per attempt,
  /// reused on retry, cleared when the mode is entered/exited (exactly
  /// the checkout rule with `pendingClientRequestId`).
  final String? pendingReturnClientRequestId;

  /// Key of the cart line the cashier touched last (added / edited).
  /// Drives the POS quantity shortcuts (`+` / `*`), which act on the last
  /// active line. Null after clear/checkout; a stale key (line removed)
  /// falls back to the newest remaining line.
  final String? lastActiveKey;

  const PosCartState({
    this.lines = const [],
    this.invoiceDiscount = '0',
    this.customer,
    this.checkoutPending = false,
    this.lastError,
    this.lastResult,
    this.pendingClientRequestId,
    this.stockErrors = const [],
    this.notice,
    this.returnMode = false,
    this.returnPending = false,
    this.pendingReturnClientRequestId,
    this.lastActiveKey,
  });

  bool get isEmpty => lines.isEmpty;

  /// Line targeted by the quantity shortcuts: the last active line when it
  /// is still in the cart, else the newest line (or null when empty).
  CartLine? get lastActiveLine {
    if (lines.isEmpty) return null;
    final key = lastActiveKey;
    if (key != null) {
      for (final line in lines) {
        if (line.key == key) return line;
      }
    }
    return lines.last;
  }

  CartTotals get totals {
    var subtotal = 0.0;
    for (final line in lines) {
      subtotal += line.qty * line.price;
    }
    // Client-side line discounts already reduce payable per line for display;
    // invoice_discount is separate (never merged into line_discount).
    var lineDiscounts = 0.0;
    for (final line in lines) {
      lineDiscounts += line.discountAmount;
    }
    final afterLines = subtotal - lineDiscounts;
    final inv = double.tryParse(invoiceDiscount) ?? 0;
    final invClamped = inv.clamp(0.0, afterLines < 0 ? 0.0 : afterLines);
    final total = afterLines - invClamped;
    return CartTotals(
      subtotal: subtotal - lineDiscounts,
      invoiceDiscount: invClamped,
      total: total < 0 ? 0 : total,
      lineCount: lines.length,
    );
  }

  bool get hasInvoiceDiscount {
    final inv = double.tryParse(invoiceDiscount) ?? 0;
    return inv > 0;
  }

  bool get hasAnyDiscount {
    if (hasInvoiceDiscount) return true;
    for (final line in lines) {
      if (line.discountAmount > 0) return true;
    }
    return false;
  }

  PosCartState copyWith({
    List<CartLine>? lines,
    String? invoiceDiscount,
    PosCustomer? customer,
    bool clearCustomer = false,
    bool? checkoutPending,
    String? lastError,
    bool clearError = false,
    CheckoutResult? lastResult,
    bool clearResult = false,
    String? pendingClientRequestId,
    bool clearRequestId = false,
    List<String>? stockErrors,
    bool clearStockErrors = false,
    String? notice,
    bool clearNotice = false,
    bool? returnMode,
    bool? returnPending,
    String? pendingReturnClientRequestId,
    bool clearPendingReturnRequestId = false,
    String? lastActiveKey,
    bool clearLastActiveKey = false,
  }) {
    return PosCartState(
      lines: lines ?? this.lines,
      invoiceDiscount: invoiceDiscount ?? this.invoiceDiscount,
      customer: clearCustomer ? null : (customer ?? this.customer),
      checkoutPending: checkoutPending ?? this.checkoutPending,
      lastError: clearError ? null : (lastError ?? this.lastError),
      lastResult: clearResult ? null : (lastResult ?? this.lastResult),
      pendingClientRequestId: clearRequestId
          ? null
          : (pendingClientRequestId ?? this.pendingClientRequestId),
      stockErrors:
          clearStockErrors ? const [] : (stockErrors ?? this.stockErrors),
      notice: clearNotice ? null : (notice ?? this.notice),
      returnMode: returnMode ?? this.returnMode,
      returnPending: returnPending ?? this.returnPending,
      pendingReturnClientRequestId: clearPendingReturnRequestId
          ? null
          : (pendingReturnClientRequestId ??
              this.pendingReturnClientRequestId),
      lastActiveKey: clearLastActiveKey
          ? null
          : (lastActiveKey ?? this.lastActiveKey),
    );
  }
}

class PosCartNotifier extends StateNotifier<PosCartState> {
  final Dio _dio;
  final String Function() _localeCode;
  final Future<String> Function() _deviceId;

  PosCartNotifier(this._dio, this._localeCode, this._deviceId)
      : super(const PosCartState());

  // Localized primary message; backend detail is never the cashier-facing
  // text (UX FIX #12 — FIX #5).
  String _message(DioException e) => posApiMessage(e, _localeCode());

  void addLine(
    CartLine line, {
    String reason = 'add-line',
    int? scanCorrelationId,
  }) {
    final existing = state.lines.indexWhere((l) => l.key == line.key);
    if (existing >= 0) {
      final current = state.lines[existing];
      final mergedQuantity = '${(current.qty + line.qty)}';
      // Method 2 — merging one more unit into an auto-priced line must
      // re-derive its bundle discount for the NEW quantity; a normal line
      // keeps the established "merge resets the manual discount" rule.
      final autoPlan = current.autoPricing;
      final merged = current.copyWith(
        quantity: mergedQuantity,
        lineDiscount: autoPlan == null
            ? '0'
            : autoSellUnitDiscount(autoPlan, mergedQuantity),
      );
      _logCartQuantityWrite(
        reason: reason,
        line: merged,
        previous: current.quantity,
        next: merged.quantity,
        scanCorrelationId: scanCorrelationId,
      );
      final lines = [...state.lines];
      lines[existing] = merged;
      state = state.copyWith(
        lines: lines,
        clearStockErrors: true,
        clearError: true,
        clearNotice: true,
        lastActiveKey: line.key,
      );
    } else {
      _logCartQuantityWrite(
        reason: reason,
        line: line,
        previous: null,
        next: line.quantity,
        scanCorrelationId: scanCorrelationId,
      );
      state = state.copyWith(
        lines: [...state.lines, line],
        clearStockErrors: true,
        clearError: true,
        clearNotice: true,
        lastActiveKey: line.key,
      );
    }
  }

  /// Applies the cashier's manual line TOTAL (double-click on a line's
  /// total, see [showLineTotalDialog]).
  ///
  /// The money itself is never a new field: [CartLine.withManualTotal]
  /// expresses it as the line DISCOUNT (gross − total) — the single value
  /// the payload, the backend validation, the invoice and the returns
  /// already read — and keeps [CartLine.manualTotal] as the pin that makes
  /// a later quantity change re-derive from the cashier's number.
  ///
  /// Refused, with the state untouched, when [total] is not a positive
  /// finite amount or exceeds the line's gross: a total ABOVE the gross
  /// would need a negative discount, which the backend rejects
  /// (`line_discount must be >= 0`). A custom line is the exception — its
  /// price IS its total, so raising it is legitimate.
  void setLineTotal(String key, String total) {
    final value = double.tryParse(total);
    if (value == null || !value.isFinite || value <= 0) return;
    var applied = false;
    final lines = state.lines.map((line) {
      if (line.key != key) return line;
      if (!line.customLine && value > line.lineGross + 0.0001) return line;
      applied = true;
      return line.withManualTotal(posPlainAmount(value));
    }).toList();
    if (!applied) return;
    state = state.copyWith(
      lines: lines,
      lastActiveKey: key,
      clearError: true,
      // A manual total is a cashier decision, not a stock problem: the
      // existing stock snapshots stay untouched.
      clearStockErrors: true,
    );
  }

  /// Adds a POS "quick custom item": a price-only line with no catalog
  /// product, no stock and quantity 1 (see [CartLine.customLine]).
  ///
  /// Nothing is created in the catalog and no stock moves — the sale
  /// payload carries `custom_name` instead of a product id and the server
  /// snapshots it on the sale line. Every line gets its own [customRef], so
  /// several custom items can sit in one cart without merging through
  /// [CartLine.key].
  void addCustomLine({required String name, required String total}) {
    final value = double.tryParse(total);
    if (value == null || !value.isFinite || value <= 0) return;
    final line = CartLine(
      name: name,
      quantity: '1',
      unitPrice: posPlainAmount(value),
      customLine: true,
      customRef: _nextCustomRef(),
    );
    addLine(line, reason: 'custom-item');
  }

  /// Monotonic suffix so two custom items added in the same microsecond
  /// still get distinct references.
  int _customSeq = 0;

  String _nextCustomRef() =>
      '${DateTime.now().microsecondsSinceEpoch}-${_customSeq++}';

  void updateLine(
    String key, {
    String? quantity,
    String? lineDiscount,
    String reason = 'update-line',
    int? scanCorrelationId,
  }) {
    if (quantity != null) {
      for (final line in state.lines) {
        if (line.key == key) {
          _logCartQuantityWrite(
            reason: reason,
            line: line,
            previous: line.quantity,
            next: quantity,
            scanCorrelationId: scanCorrelationId,
          );
          break;
        }
      }
    }
    final lines = state.lines
        .map((l) => l.key == key
            ? (l.customLine
                // A custom line is quantity-1 by definition (no catalog
                // product, no stock to decrement), and its amount is the
                // manual-total path (setLineTotal) — never a discount. A
                // qty or discount edit is therefore a no-op on it.
                ? l
                : l.copyWith(
                    quantity: quantity,
                    // Method 2 — an automatic bundle discount is DERIVED,
                    // never typed: a discount-only edit (the cart's
                    // discount field / any other discount funnel) is
                    // refused for an auto line. A quantity change still
                    // re-derives it in copyWith, and the internal merge
                    // path (addLine) passes both a quantity and the
                    // derived amount, so it is unaffected.
                    lineDiscount:
                        l.autoPriced && quantity == null ? null : lineDiscount,
                  ))
            : l)
        .toList();
    final exists = state.lines.any((l) => l.key == key);
    final next = state.copyWith(lines: lines, clearStockErrors: true);
    // Editing a line makes it the active one for the `+` / `*` shortcuts.
    state = exists ? next.copyWith(lastActiveKey: key) : next;
  }

  /// Re-reads each product line's stock snapshot from a freshly loaded
  /// catalog.
  ///
  /// [CartLine.availableStock] is stamped at add-to-cart time, so a
  /// purchase received while the line sits in the cart (or any stock
  /// change made from Products/Stock) leaves the cart validating against
  /// a quantity that no longer exists: a real restock blocks additions
  /// that are now legal, and a sale made elsewhere silently allows
  /// over-adding.
  ///
  /// [stocks] maps productId -> fresh quantity. Pack lines, variant
  /// lines and products that are not in the loaded catalog page keep
  /// their snapshot — the SERVER stays authoritative at checkout either
  /// way (`sale.py` rejects insufficient stock regardless of this).
  ///
  /// Returns the keys of lines whose snapshot got SMALLER, so the caller
  /// can tell the cashier the cart may now exceed what is on the shelf.
  List<String> syncAvailableStock(Map<String, String> stocks) {
    if (stocks.isEmpty || state.lines.isEmpty) return const [];

    final decreased = <String>[];
    var changed = false;
    final lines = <CartLine>[];
    for (final line in state.lines) {
      final productId = line.productId;
      final fresh = productId == null ||
              line.packId != null ||
              line.variantId != null
          ? null
          : stocks[productId];
      if (fresh == null || fresh == line.availableStock) {
        lines.add(line);
        continue;
      }
      final before = double.tryParse(line.availableStock ?? '') ?? 0;
      final after = double.tryParse(fresh) ?? 0;
      if (after < before) decreased.add(line.key);
      lines.add(line.copyWith(availableStock: fresh));
      changed = true;
    }
    if (!changed) return const [];
    state = state.copyWith(lines: lines);
    return decreased;
  }

  void removeLine(String key) {
    for (final line in state.lines) {
      if (line.key == key) {
        _logCartQuantityWrite(
          reason: 'remove-line',
          line: line,
          previous: line.quantity,
          next: null,
        );
        break;
      }
    }
    final remaining = state.lines.where((l) => l.key != key).toList();
    // Deleting the active line hands the `+` / `*` shortcuts to the newest
    // remaining line (never a stale key); an emptied cart clears it.
    final wasActive = state.lastActiveKey == key;
    scanDiag('cart-remove', {
      'linesBefore': state.lines.length,
      'linesAfter': remaining.length,
      'wasActive': wasActive,
    });
    state = state.copyWith(
      lines: remaining,
      clearStockErrors: true,
      lastActiveKey: wasActive && remaining.isNotEmpty
          ? remaining.last.key
          : state.lastActiveKey,
      clearLastActiveKey: wasActive && remaining.isEmpty,
    );
  }

  /// Marks [key] as the line the `+` / `*` shortcuts and the qty field
  /// target (qty-field focus / line tap / edit — UX FIX #12).
  void setActiveLine(String key) {
    if (state.lastActiveKey == key) return;
    if (!state.lines.any((l) => l.key == key)) return;
    state = state.copyWith(lastActiveKey: key);
  }

  void setInvoiceDiscount(String value) {
    state = state.copyWith(invoiceDiscount: value, clearError: true);
  }

  void setCustomer(PosCustomer? customer) {
    state = customer == null
        ? state.copyWith(clearCustomer: true)
        : state.copyWith(customer: customer);
  }

  /// Clears the cart. `reason` names the programmatic cause for the
  /// diagnostics trail (`checkout`, `hold-create`, `hold-load`,
  /// `return-confirm`, `clear-dialog`) — every path that replaces the
  /// cart state wholesale must declare itself here or at its call site,
  /// so an unexpected `qtyBefore=-` (no line matched by CartLine.key on
  /// the next add) can be traced to the reset that emptied the cart.
  void clearCart({String reason = 'clear'}) {
    scanDiag('cart-reset', {
      'reason': reason,
      'linesBefore': state.lines.length,
    });
    for (final line in state.lines) {
      _logCartQuantityWrite(
        reason: reason,
        line: line,
        previous: line.quantity,
        next: null,
      );
    }
    state = const PosCartState();
  }

  void clearNotice() {
    state = state.copyWith(clearNotice: true, clearError: true);
  }

  void clearResult() {
    state = state.copyWith(clearResult: true);
  }

  /// Enter / exit the POS return mode. The cart lines are never touched:
  /// a cancel (or a mode flip in either direction) must leave the cart
  /// exactly as the cashier built it. Any stale return attempt id is
  /// dropped so a fresh mode session always starts a NEW idempotency
  /// attempt server-side.
  void setReturnMode(bool enabled) {
    if (state.returnMode == enabled) return;
    state = state.copyWith(
      returnMode: enabled,
      clearPendingReturnRequestId: true,
      clearError: true,
      clearStockErrors: true,
      clearNotice: true,
    );
  }

  /// Return-attempt bookkeeping: marks the attempt pending and returns
  /// the ONE `client_request_id` to send — reused on retry (same attempt),
  /// exactly like the checkout rule.
  String beginReturnAttempt() {
    final clientRequestId = state.pendingReturnClientRequestId ??
        'pos-ret-${DateTime.now().millisecondsSinceEpoch}-'
            '${Random().nextInt(0x7fffffff)}';
    state = state.copyWith(
      returnPending: true,
      clearError: true,
      clearStockErrors: true,
      pendingReturnClientRequestId: clientRequestId,
    );
    return clientRequestId;
  }

  /// A return attempt failed: drop the pending flag but KEEP the
  /// `client_request_id`, so the cashier's retry replays idempotently
  /// server-side (the backend dedupes on that id).
  void failReturnAttempt() {
    state = state.copyWith(returnPending: false);
  }

  /// Checkout with idempotency: reuse pendingClientRequestId on retry.
  /// Clears cart ONLY on confirmed success (2xx).
  ///
  /// `loyaltyRewardPercent` submits the PERCENT only (never a monetary
  /// value or a balance — the server derives both); 0 omits the key so
  /// the payload stays byte-identical for non-loyalty checkouts.
  Future<CheckoutResult?> checkout({
    required PaymentMethod method,
    required double paid,
    double loyaltyRewardPercent = 0,
  }) async {
    if (state.lines.isEmpty || state.checkoutPending) return null;

    // Reuse the same id for retries of the same attempt.
    final clientRequestId = state.pendingClientRequestId ??
        'pos-${DateTime.now().millisecondsSinceEpoch}-'
            '${Random().nextInt(0x7fffffff)}';

    state = state.copyWith(
      checkoutPending: true,
      clearError: true,
      clearStockErrors: true,
      pendingClientRequestId: clientRequestId,
    );

    final deviceId = await _deviceId();
    final payload = <String, dynamic>{
      'client_request_id': clientRequestId,
      'payment_method': method.apiValue,
      'paid': paid.toStringAsFixed(2),
      'invoice_discount': '${double.tryParse(state.invoiceDiscount) ?? 0}',
      // Sales API contract: ids/qty/price only (display metadata stays
      // in the hold snapshot - see CartLine.toJson / toSaleJson).
      'items': state.lines.map((l) => l.toSaleJson()).toList(),
      if (state.customer != null) 'customer_id': state.customer!.id,
      if (loyaltyRewardPercent > 0)
        'loyalty_reward_percent': loyaltyRewardPercent,
      'device_id': deviceId,
    };

    try {
      final response = await _dio.post(
        '/api/v1/sales',
        data: payload,
        options: Options(headers: {'X-Device-ID': deviceId}),
      );
      final parsed = CheckoutResult.fromJson(
        response.data as Map<String, dynamic>,
      );
      // Attach line names from cart lines before clear (for override dialog).
      // `line_index` is the position in the request `items[]` array, which is
      // exactly the cart order — pack and product lines resolve the same way.
      final namesByLine = <String, String>{
        for (var i = 0; i < state.lines.length; i++)
          '$i': state.lines[i].name,
      };
      final namesById = <String, String>{
        for (final line in state.lines) line.key: line.name,
      };
      String? nameFor(PriceOverrideModel o) {
        final identity =
            o.packId != null ? 'pack:${o.packId}' : o.productId;
        if (identity != null) {
          final byId = namesById[identity];
          if (byId != null) return byId;
        }
        return namesByLine['${o.lineIndex}'];
      }

      final namedOverrides = <PriceOverrideModel>[];
      for (final o in parsed.priceOverrides) {
        final name = nameFor(o);
        namedOverrides.add(name == null ? o : o.withProductName(name));
      }
      final result = parsed.priceOverrides.isEmpty
          ? parsed
          : parsed.withPriceOverrides(namedOverrides);
      // Success → clear cart + request id (not because of overrides —
      // because the sale committed). Keep result for override/receipt UI.
      scanDiag('cart-reset', {
        'reason': 'checkout',
        'linesBefore': state.lines.length,
      });
      for (final line in state.lines) {
        _logCartQuantityWrite(
          reason: 'checkout',
          line: line,
          previous: line.quantity,
          next: null,
        );
      }
      state = PosCartState(lastResult: result);
      return result;
    } on DioException catch (e) {
      final msg = _message(e);
      final isStock = e.response?.statusCode == 409;
      final stockErrors = <String>[];
      if (isStock) {
        final data = e.response?.data;
        final err = data is Map ? data['error'] : null;
        final details = err is Map ? err['details'] : null;
        if (details is Map) {
          final lines = details['lines'];
          if (lines is List) {
            for (final raw in lines) {
              if (raw is Map) {
                final m = raw['message'] ?? raw['error'] ?? '';
                if (m is String && m.isNotEmpty) stockErrors.add(m);
              }
            }
          }
          final top = details['message'];
          if (top is String && top.isNotEmpty) stockErrors.add(top);
        }
      }
      // Keep cart + same client_request_id for safe retry.
      state = state.copyWith(
        checkoutPending: false,
        lastError: msg,
        stockErrors: stockErrors.isEmpty && isStock
            ? [msg]
            : stockErrors,
        clearRequestId: false,
      );
      return null;
    }
  }

  Future<String?> createHold({String? note}) async {
    if (state.lines.isEmpty) {
      // Never hand a raw translation key to a toast headline (FIX #5).
      return AppStrings.t('empty_cart_title', _localeCode());
    }
    final deviceId = await _deviceId();
    try {
      final payload = <String, dynamic>{
        'device_id': deviceId,
        'customer_id': state.customer?.id,
        // Full display snapshot (CartLine.toJson): restore shows product
        // names from the snapshot without any catalog lookup (FIX #10B).
        'items': state.lines.map((l) => l.toJson()).toList(),
        'invoice_discount': '${double.tryParse(state.invoiceDiscount) ?? 0}',
        if (note != null && note.isNotEmpty) 'note': note,
      };
      await _dio.post(
        '/api/v1/pos/holds',
        data: payload,
      );
      clearCart(reason: 'hold-create');
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  void loadHold(HoldModel hold) {
    scanDiag('cart-reset', {
      'reason': 'hold-load',
      'linesBefore': state.lines.length,
      'linesAfter': hold.items.length,
    });
    for (final line in state.lines) {
      _logCartQuantityWrite(
        reason: 'hold-load-replace',
        line: line,
        previous: line.quantity,
        next: null,
      );
    }
    for (final line in hold.items) {
      _logCartQuantityWrite(
        reason: 'hold-load-restore',
        line: line,
        previous: null,
        next: line.quantity,
      );
    }
    state = PosCartState(
      lines: hold.items,
      invoiceDiscount: hold.invoiceDiscount,
      notice: 'hold_restored',
      // Restored lines: the newest one is the active target for `+` / `*`.
      lastActiveKey: hold.items.isEmpty ? null : hold.items.last.key,
    );
  }
}

final posCartProvider =
    StateNotifierProvider<PosCartNotifier, PosCartState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PosCartNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(posDeviceIdProvider.future),
  );
});

// ---------------------------------------------------------------------------
// Product catalog browse (paginated) + debounced search
// ---------------------------------------------------------------------------

/// Catalog endpoint — the paginated products API (`page`/`page_size` ≤ 100,
/// `search`, `category_id`, `status`), returning `items/total/page/pages`.
/// The bounded `/products/search` endpoint (limit ≤ 50, no offset) cannot
/// paginate and is reserved for exact-barcode pickers elsewhere.
const String kPosCatalogPath = '/api/v1/products';

/// Page size for every POS catalog request. Matches the backend
/// `MAX_PAGE_SIZE` (100) — the catalog is scrolled incrementally, never
/// bulk-fetched, so this must NOT be raised to "fill the screen".
const int kPosCatalogPageSize = 100;

/// How close to the end of the scrollable the cashier must be before the
/// next page is requested.
const int kPosCatalogLoadMoreThreshold = 600;

class PosSearchState {
  /// Raw search-field text (results update after the debounce).
  final String query;

  /// Category filter — `null` = the full active catalog.
  final String? categoryId;

  /// Rows loaded so far, in backend order. Append-only across pages;
  /// replaced wholesale only by a page-1 load (initial/search/category).
  final List<ProductModel> items;

  /// 1-based page currently at the end of [items] (0 = nothing loaded).
  final int currentPage;
  final int pageSize;

  /// Server-reported totals for the CURRENT query/category.
  final int total;
  final int pages;
  final bool hasMore;

  /// Page-1 replacement load (initial load, debounced search, category
  /// switch). The list stays visible while it refreshes.
  final bool loading;

  /// Next-page append in flight — bottom spinner only.
  final bool loadingMore;

  /// Page-1 failure (catalog replaced by an error state, as before).
  final String? error;

  /// Append failure — loaded rows stay on screen; scrolling again retries.
  final String? loadMoreError;

  const PosSearchState({
    this.query = '',
    this.categoryId,
    this.items = const [],
    this.currentPage = 0,
    this.pageSize = kPosCatalogPageSize,
    this.total = 0,
    this.pages = 0,
    this.hasMore = false,
    this.loading = false,
    this.loadingMore = false,
    this.error,
    this.loadMoreError,
  });

  PosSearchState copyWith({
    String? query,
    String? categoryId,
    bool clearCategory = false,
    List<ProductModel>? items,
    int? currentPage,
    int? pageSize,
    int? total,
    int? pages,
    bool? hasMore,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
    String? loadMoreError,
    bool clearLoadMoreError = false,
  }) {
    return PosSearchState(
      query: query ?? this.query,
      categoryId:
          clearCategory ? null : (categoryId ?? this.categoryId),
      items: items ?? this.items,
      currentPage: currentPage ?? this.currentPage,
      pageSize: pageSize ?? this.pageSize,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      hasMore: hasMore ?? this.hasMore,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
      loadMoreError:
          clearLoadMoreError ? null : (loadMoreError ?? this.loadMoreError),
    );
  }
}

class PosSearchNotifier extends StateNotifier<PosSearchState> {
  final Dio _dio;
  final String Function() _localeCode;
  final int _pageSize;
  Timer? _debounce;

  /// The pending/typed search text. [PosSearchState.query] instead holds
  /// the query the VISIBLE items were loaded with (set together with the
  /// rows on a completed page-1 load, cleared by [clear]) — so a keystroke
  /// updates ONLY this field and never notifies listeners: a wedge burst
  /// typing a barcode must not rebuild the whole POS screen once per
  /// digit. The debounced [load] still runs on this text, and a submit
  /// that misses re-runs [load] with exactly what the cashier typed.
  String _query = '';

  /// Monotonic token bumped whenever the RESULT SET changes (search text,
  /// category, reset, page-1 reload). In-flight responses from an older
  /// generation are discarded — a slow page-2 can never append rows into a
  /// newer search, and a slow page-1 never overwrites fresher results.
  int _generation = 0;

  PosSearchNotifier(
    this._dio,
    this._localeCode, {
    int pageSize = kPosCatalogPageSize,
  })  : _pageSize = pageSize,
        super(PosSearchState(pageSize: pageSize));

  // Localized primary (UX FIX #12 — FIX #5): backend text is never the
  // message the cashier reads.
  String _message(DioException e) => posApiMessage(e, _localeCode());

  /// The search text this notifier tracks — the pending typed text, which
  /// equals the loaded query once a page-1 load with it completes. What
  /// [seedSearchField] restores on rebuild: the field and the notifier
  /// always describe the same term, including a burst whose debounce had
  /// not fired when the page State was disposed.
  String get trackedQuery => _query;

  void setQuery(String value) {
    // Bump at CALL time: a page-1 load or append already in flight must be
    // dropped the moment the text changes, not when the debounce fires.
    _generation++;
    _query = value;
    // Touch state ONLY when clearing an on-screen search error (typing
    // must visibly dismiss it). Every other keystroke stays inside this
    // notifier — per-digit notifications rebuilt the entire POS screen
    // once per scanned character.
    if (state.error != null || state.loadMoreError != null) {
      state = state.copyWith(clearError: true, clearLoadMoreError: true);
    }
    _debounce?.cancel();
    _debounce = Timer(kPosSearchDebounce, load);
  }

  void setCategory(String? categoryId) {
    _generation++;
    state = categoryId == null
        ? state.copyWith(
            clearCategory: true,
            clearError: true,
            clearLoadMoreError: true,
          )
        : state.copyWith(
            categoryId: categoryId,
            clearError: true,
            clearLoadMoreError: true,
          );
    load();
  }

  void clear() {
    _debounce?.cancel();
    _generation++;
    _query = '';
    state = PosSearchState(pageSize: _pageSize);
  }

  /// A completed scan submit resolves ITS OWN code (the canonical barcode
  /// lookup) — the pending digit-search debounce would only fire mid-chain
  /// as a wasted catalog request racing the resolve. The typed text stays
  /// in [_query]: a lookup miss still re-runs [load] with it.
  void cancelPendingSearch() => _debounce?.cancel();

  /// Continuous-scan hygiene: drop the typed text, the pending debounce
  /// and any in-flight search WITHOUT touching the loaded rows — a scan
  /// that never disturbed the panel must not refetch the catalog (the
  /// browse list already on screen stays exactly as it is).
  void resetQuery() {
    _debounce?.cancel();
    _generation++;
    _query = '';
    if (state.query.isNotEmpty) {
      state = state.copyWith(query: '');
    }
  }

  Map<String, dynamic> _pageParams(int page, String query) {
    final q = query.trim();
    return <String, dynamic>{
      'page': page,
      'page_size': state.pageSize,
      'status': 'active',
      if (q.isNotEmpty) 'search': q,
      if (state.categoryId != null) 'category_id': state.categoryId,
    };
  }

  Future<Map<String, dynamic>> _fetch(int page, String query) async {
    final response = await _dio.get(
      kPosCatalogPath,
      queryParameters: _pageParams(page, query),
    );
    final data = response.data;
    return data is Map ? Map<String, dynamic>.from(data) : const {};
  }

  static List<ProductModel> _parseItems(Map<String, dynamic> data) =>
      (data['items'] as List<dynamic>? ?? const [])
          .map((e) => ProductModel.fromJson(e as Map<String, dynamic>))
          .toList();

  static int _parseTotal(Map<String, dynamic> data, int fallback) {
    final total = data['total'];
    return total is int ? total : fallback;
  }

  static int _parsePages(Map<String, dynamic> data, int total, int pageSize) {
    final pages = data['pages'];
    if (pages is int) return pages;
    if (pageSize <= 0) return 0;
    return (total + pageSize - 1) ~/ pageSize;
  }

  /// Page-1 replacement: initial load, debounced search, category switch.
  /// Fetches with the pending [_query] and lands [PosSearchState.query]
  /// TOGETHER with the items — the state query always describes exactly
  /// the rows on screen (the "was the panel disturbed?" signal a scan's
  /// post-add hygiene reads).
  Future<void> load() async {
    _debounce?.cancel();
    final query = _query;
    final generation = ++_generation;
    state = state.copyWith(
      loading: true,
      // A replacement supersedes any in-flight append.
      loadingMore: false,
      clearError: true,
      clearLoadMoreError: true,
    );
    try {
      final data = await _fetch(1, query);
      if (generation != _generation) return;
      final items = _parseItems(data);
      final total = _parseTotal(data, items.length);
      final pages = _parsePages(data, total, state.pageSize);
      state = state.copyWith(
        items: items,
        query: query,
        currentPage: 1,
        total: total,
        pages: pages,
        hasMore: pages > 1,
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (generation != _generation) return;
      state = state.copyWith(loading: false, error: _message(e));
    }
  }

  /// Append the next page. Guarded: one append in flight at a time, nothing
  /// to append once [PosSearchState.hasMore] is false, and a stale response
  /// (result set changed while it was in flight) is dropped, not merged.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    final generation = _generation;
    final page = state.currentPage + 1;
    state = state.copyWith(loadingMore: true, clearLoadMoreError: true);
    try {
      final data = await _fetch(page, state.query);
      if (generation != _generation) return;
      final incoming = _parseItems(data);
      final merged = <ProductModel>[...state.items];
      final seen = <String>{for (final p in merged) p.id};
      for (final p in incoming) {
        if (seen.add(p.id)) merged.add(p); // dedupe by stable product id
      }
      final total = _parseTotal(data, state.total);
      final pages = _parsePages(data, total, state.pageSize);
      state = state.copyWith(
        items: merged,
        currentPage: page,
        total: total,
        pages: pages,
        hasMore: page < pages,
        loadingMore: false,
      );
    } on DioException catch (e) {
      if (generation != _generation) return;
      // Keep the rows already on screen; the footer shows this and the next
      // scroll near the end retries.
      state = state.copyWith(loadingMore: false, loadMoreError: _message(e));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final posSearchProvider =
    StateNotifierProvider<PosSearchNotifier, PosSearchState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PosSearchNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Customer search
// ---------------------------------------------------------------------------

class CustomerSearchState {
  final String query;
  final List<PosCustomer> items;
  final bool loading;
  final String? error;

  const CustomerSearchState({
    this.query = '',
    this.items = const [],
    this.loading = false,
    this.error,
  });
}

class CustomerSearchNotifier extends StateNotifier<CustomerSearchState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  CustomerSearchNotifier(this._dio, this._localeCode)
      : super(const CustomerSearchState());

  // Localized primary (UX FIX #12 — FIX #5): backend text is never the
  // message the cashier reads.
  String _message(DioException e) => posApiMessage(e, _localeCode());

  void setQuery(String value) {
    state = CustomerSearchState(
      query: value,
      items: state.items,
      loading: true,
    );
    _debounce?.cancel();
    _debounce = Timer(kPosSearchDebounce, load);
  }

  Future<void> load() async {
    final q = state.query.trim();
    final requestId = ++_requestId;
    state = CustomerSearchState(
      query: q,
      items: state.items,
      loading: true,
    );
    try {
      // Phase E: a loyalty QR payload (`KLICK:C:<uuid>`) typed/scanned into
      // this field goes to the loyalty lookup (opaque handle, no PII) —
      // both endpoints answer the same CustomerListResponse shape, so the
      // list below is unchanged.
      final isQr = q.toUpperCase().startsWith(kLoyaltyQrPrefix);
      final response = await _dio.get(
        isQr ? '/api/v1/loyalty/lookup' : '/api/v1/customers/search',
        queryParameters: {
          if (q.isNotEmpty) 'q': q,
          'page_size': 20,
        },
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PosCustomer.fromJson(e as Map<String, dynamic>))
          .toList();
      state = CustomerSearchState(query: q, items: items);
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = CustomerSearchState(
        query: q,
        items: const [],
        error: _message(e),
      );
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final customerSearchProvider =
    StateNotifierProvider<CustomerSearchNotifier, CustomerSearchState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return CustomerSearchNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Holds list
// ---------------------------------------------------------------------------

class HoldsState {
  final List<HoldModel> items;
  final bool loading;
  final String? error;

  const HoldsState({
    this.items = const [],
    this.loading = false,
    this.error,
  });
}

class HoldsNotifier extends StateNotifier<HoldsState> {
  final Dio _dio;
  final String Function() _localeCode;
  final Future<String> Function() _deviceId;

  HoldsNotifier(this._dio, this._localeCode, this._deviceId)
      : super(const HoldsState());

  // Localized primary (UX FIX #12 — FIX #5): backend text is never the
  // message the cashier reads.
  String _message(DioException e) => posApiMessage(e, _localeCode());

  Future<void> load() async {
    state = HoldsState(items: state.items, loading: true);
    try {
      final deviceId = await _deviceId();
      final response = await _dio.get(
        '/api/v1/pos/holds',
        queryParameters: {'device_id': deviceId},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => HoldModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = HoldsState(items: items);
    } on DioException catch (e) {
      state = HoldsState(error: _message(e));
    }
  }

  Future<String?> delete(String holdId) async {
    try {
      await _dio.delete('/api/v1/pos/holds/$holdId');
      state = HoldsState(
        items: state.items.where((h) => h.id != holdId).toList(),
      );
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }
}

final holdsProvider =
    StateNotifierProvider<HoldsNotifier, HoldsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return HoldsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(posDeviceIdProvider.future),
  );
});

// ---------------------------------------------------------------------------
// Favorites
// ---------------------------------------------------------------------------

class FavoritesState {
  final List<FavoriteModel> items;
  final bool loading;
  final String? error;

  const FavoritesState({
    this.items = const [],
    this.loading = false,
    this.error,
  });
}

class FavoritesNotifier extends StateNotifier<FavoritesState> {
  final Dio _dio;
  final String Function() _localeCode;

  FavoritesNotifier(this._dio, this._localeCode)
      : super(const FavoritesState());

  // Localized primary (UX FIX #12 — FIX #5): backend text is never the
  // message the cashier reads.
  String _message(DioException e) => posApiMessage(e, _localeCode());

  Future<void> load() async {
    state = FavoritesState(items: state.items, loading: true);
    try {
      final response = await _dio.get('/api/v1/pos/favorites');
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => FavoriteModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = FavoritesState(items: items);
    } on DioException catch (e) {
      state = FavoritesState(error: _message(e));
    }
  }

  Future<String?> toggle(String productId, {required bool currentlyFavorited}) async {
    try {
      if (currentlyFavorited) {
        await _dio.delete('/api/v1/pos/favorites/$productId');
      } else {
        await _dio.post('/api/v1/pos/favorites/$productId');
      }
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }
}

final favoritesProvider =
    StateNotifierProvider<FavoritesNotifier, FavoritesState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return FavoritesNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Catalog view mode (grid | list) — presentation only, never reloads catalog
// ---------------------------------------------------------------------------

const String kPosCatalogViewModeKey = 'pos_catalog_view_mode';

enum PosCatalogViewMode { grid, list }

class PosCatalogViewNotifier extends StateNotifier<PosCatalogViewMode> {
  PosCatalogViewNotifier() : super(PosCatalogViewMode.grid) {
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kPosCatalogViewModeKey);
    if (raw == 'list') {
      state = PosCatalogViewMode.list;
    } else {
      state = PosCatalogViewMode.grid;
    }
  }

  Future<void> setMode(PosCatalogViewMode mode) async {
    state = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPosCatalogViewModeKey, mode.name);
  }
}

final posCatalogViewModeProvider =
    StateNotifierProvider<PosCatalogViewNotifier, PosCatalogViewMode>((ref) {
  return PosCatalogViewNotifier();
});

// ---------------------------------------------------------------------------
// POS layout switch (standard | reversed) — presentation only
// ---------------------------------------------------------------------------

/// Swaps the product catalog and the cart panel. Pure presentation: the
/// cart notifier, prices, discounts, stock validation and checkout all
/// stay exactly as they are — this flag only decides which side each
/// panel sits on (and which line renderer the cart uses).
const String kPosLayoutSwitchKey = 'pos_layout_switch';

enum PosScreenLayout { standard, reversed }

class PosLayoutSwitchNotifier extends StateNotifier<PosScreenLayout> {
  PosLayoutSwitchNotifier() : super(PosScreenLayout.standard) {
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(kPosLayoutSwitchKey);
    if (raw == PosScreenLayout.reversed.name) {
      state = PosScreenLayout.reversed;
    }
  }

  Future<void> setLayout(PosScreenLayout layout) async {
    state = layout;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kPosLayoutSwitchKey, layout.name);
  }

  Future<void> toggle() => setLayout(
        state == PosScreenLayout.standard
            ? PosScreenLayout.reversed
            : PosScreenLayout.standard,
      );
}

final posLayoutSwitchProvider =
    StateNotifierProvider<PosLayoutSwitchNotifier, PosScreenLayout>((ref) {
  return PosLayoutSwitchNotifier();
});

// ---------------------------------------------------------------------------
// Sale history
// ---------------------------------------------------------------------------

class SaleHistoryState {
  final List<SaleHistoryItem> items;
  final int total;
  final int page;
  final bool loading;
  final String? error;

  const SaleHistoryState({
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.loading = false,
    this.error,
  });
}

class SaleHistoryNotifier extends StateNotifier<SaleHistoryState> {
  final Dio _dio;
  final String Function() _localeCode;

  SaleHistoryNotifier(this._dio, this._localeCode)
      : super(const SaleHistoryState());

  // Localized primary (UX FIX #12 — FIX #5): backend text is never the
  // message the cashier reads.
  String _message(DioException e) => posApiMessage(e, _localeCode());

  Future<void> load({int page = 1}) async {
    state = SaleHistoryState(
      items: state.items,
      total: state.total,
      page: page,
      loading: true,
    );
    try {
      final response = await _dio.get(
        '/api/v1/sales',
        queryParameters: {'page': page, 'page_size': 50},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => SaleHistoryItem.fromJson(e as Map<String, dynamic>))
          .toList();
      state = SaleHistoryState(
        items: items,
        total: data['total'] as int? ?? items.length,
        page: data['page'] as int? ?? page,
      );
    } on DioException catch (e) {
      state = SaleHistoryState(error: _message(e), page: page);
    }
  }
}

final saleHistoryProvider =
    StateNotifierProvider<SaleHistoryNotifier, SaleHistoryState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return SaleHistoryNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Packs in the POS catalog list
// ---------------------------------------------------------------------------

/// Active packs shown ALONGSIDE products in the POS catalog — same search
/// field, same list/grid, same add-to-cart flow.
///
/// The query is NOT entered twice: the provider mirrors the SETTLED query of
/// [posSearchProvider] (which owns the debounce), so the two lists always
/// describe the same term and a keystroke still triggers exactly one
/// debounced catalog refresh. `GET /api/v1/packs` already matches pack name
/// or barcode server-side, so pack search is the catalog search.
class PosCatalogPacksState {
  final String query;
  final List<PackModel> items;
  final bool loading;
  final String? error;

  const PosCatalogPacksState({
    this.query = '',
    this.items = const [],
    this.loading = false,
    this.error,
  });

  PosCatalogPacksState copyWith({
    String? query,
    List<PackModel>? items,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return PosCatalogPacksState(
      query: query ?? this.query,
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PosCatalogPacksNotifier extends StateNotifier<PosCatalogPacksState> {
  final Dio _dio;

  /// Bumped on every refresh; a slower earlier response never overwrites a
  /// newer result set (same rule as [PosSearchNotifier]).
  int _generation = 0;

  PosCatalogPacksNotifier(this._dio) : super(const PosCatalogPacksState());

  /// Mirror the settled catalog query. Identical query → no request, so a
  /// product reload (F5, post-add refresh) never re-fetches the packs.
  void syncQuery(String query) {
    if (query == state.query) return;
    state = state.copyWith(query: query);
    load();
  }

  Future<void> load() async {
    final query = state.query.trim();
    final generation = ++_generation;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        '/api/v1/packs',
        queryParameters: {
          'page': 1,
          'page_size': 50,
          'status': 'active',
          if (query.isNotEmpty) 'search': query,
        },
      );
      if (generation != _generation) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PackModel.fromJson(e as Map<String, dynamic>))
          // Only packs the cashier may actually sell; archived / inactive
          // rows stay out of the catalog exactly like archived products.
          .where((p) => p.isSaleable)
          .toList();
      state = state.copyWith(items: items, loading: false, clearError: true);
    } on DioException catch (e) {
      if (generation != _generation) return;
      // A failed pack fetch NEVER breaks the product panel: products keep
      // working and the last pack rows stay untouched.
      state = state.copyWith(loading: false, error: '$e');
    }
  }
}

final posCatalogPacksProvider = StateNotifierProvider<
    PosCatalogPacksNotifier, PosCatalogPacksState>((ref) {
  final notifier = PosCatalogPacksNotifier(ref.watch(apiClientProvider).dio);
  // ONE source of truth for the query: the debounced product search.
  ref.listen<String>(posSearchProvider.select((s) => s.query), (_, next) {
    notifier.syncQuery(next);
  });
  Future<void>.microtask(notifier.load);
  return notifier;
});
