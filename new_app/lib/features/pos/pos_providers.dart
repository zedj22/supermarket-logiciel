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

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../devices/device_identity.dart';
import '../products/models.dart';
import 'pos_error_message.dart';
import 'pos_models.dart';

const Duration kPosSearchDebounce = Duration(milliseconds: 250);

// ---------------------------------------------------------------------------
// Device id (holds filter + X-Device-ID)
// ---------------------------------------------------------------------------
//
// Promoted to the app-level `deviceIdProvider` in
// `features/devices/device_identity.dart` (Phase 16 §23.2). The storage key
// (`pos_device_id`), the `pos-<millis>-<rand>` format and this provider's
// type are unchanged — Phase 14/15 call sites read it exactly as before.

final posDeviceIdProvider = deviceIdProvider;

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

  void addLine(CartLine line) {
    final existing = state.lines.indexWhere((l) => l.key == line.key);
    if (existing >= 0) {
      final current = state.lines[existing];
      final merged = current.copyWith(
        quantity:
            '${(current.qty + line.qty)}',
        lineDiscount: '0',
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
      state = state.copyWith(
        lines: [...state.lines, line],
        clearStockErrors: true,
        clearError: true,
        clearNotice: true,
        lastActiveKey: line.key,
      );
    }
  }

  void updateLine(String key, {String? quantity, String? lineDiscount}) {
    final lines = state.lines
        .map((l) => l.key == key
            ? l.copyWith(quantity: quantity, lineDiscount: lineDiscount)
            : l)
        .toList();
    final exists = state.lines.any((l) => l.key == key);
    final next = state.copyWith(lines: lines, clearStockErrors: true);
    // Editing a line makes it the active one for the `+` / `*` shortcuts.
    state = exists ? next.copyWith(lastActiveKey: key) : next;
  }

  void removeLine(String key) {
    final remaining = state.lines.where((l) => l.key != key).toList();
    // Deleting the active line hands the `+` / `*` shortcuts to the newest
    // remaining line (never a stale key); an emptied cart clears it.
    final wasActive = state.lastActiveKey == key;
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

  void clearCart() {
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
  Future<CheckoutResult?> checkout({
    required PaymentMethod method,
    required double paid,
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
      // in the hold snapshot — see CartLine.toJson / toSaleJson).
      'items': state.lines.map((l) => l.toSaleJson()).toList(),
      if (state.customer != null) 'customer_id': state.customer!.id,
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
      clearCart();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  void loadHold(HoldModel hold) {
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

  void setQuery(String value) {
    _generation++;
    state = state.copyWith(
      query: value,
      clearError: true,
      clearLoadMoreError: true,
    );
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
    state = PosSearchState(pageSize: _pageSize);
  }

  Map<String, dynamic> _pageParams(int page) {
    final q = state.query.trim();
    return <String, dynamic>{
      'page': page,
      'page_size': state.pageSize,
      'status': 'active',
      if (q.isNotEmpty) 'search': q,
      if (state.categoryId != null) 'category_id': state.categoryId,
    };
  }

  Future<Map<String, dynamic>> _fetch(int page) async {
    final response = await _dio.get(
      kPosCatalogPath,
      queryParameters: _pageParams(page),
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
  Future<void> load() async {
    _debounce?.cancel();
    final generation = ++_generation;
    state = state.copyWith(
      loading: true,
      // A replacement supersedes any in-flight append.
      loadingMore: false,
      clearError: true,
      clearLoadMoreError: true,
    );
    try {
      final data = await _fetch(1);
      if (generation != _generation) return;
      final items = _parseItems(data);
      final total = _parseTotal(data, items.length);
      final pages = _parsePages(data, total, state.pageSize);
      state = state.copyWith(
        items: items,
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
      final data = await _fetch(page);
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
      final response = await _dio.get(
        '/api/v1/customers/search',
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
