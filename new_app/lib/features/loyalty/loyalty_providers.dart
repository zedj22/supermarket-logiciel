// Loyalty providers (reward redesign).
//
// Three surfaces, one rule everywhere: the SERVER owns every number.
//
//  * [posLoyaltyProvider] — the POS session's loyalty state (selected
//    customer's balances, the debounced cart preview, the reward percent
//    the cashier selected).  It deliberately lives OUTSIDE PosCartState:
//    the cart is snapshotted/restored through holds, while loyalty state
//    must always reflect the live server for the currently attached
//    customer.
//  * [loyaltySettingsProvider] — GET/PUT /api/v1/loyalty/settings
//    (SETTINGS_MANAGE), mirroring the store SettingsNotifier.
//  * [loyaltyBalanceProvider] / [loyaltyHistoryProvider] — customer-scoped
//    read models for the clients screen, mirroring debtHistoryProvider's
//    load-once + explicit refresh semantics.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../clients/clients_error.dart';
import '../pos/pos_error_message.dart';
import 'loyalty_models.dart';

// ---------------------------------------------------------------------------
// POS session loyalty state
// ---------------------------------------------------------------------------

@immutable
class PosLoyaltyState {
  const PosLoyaltyState({
    this.customerId,
    this.balance,
    this.preview,
    this.rewardPercent = 0,
    this.exceeds = false,
    this.loading = false,
    this.error,
    this.cartTotal = 0,
  });

  /// The currently attached customer (mirrors `PosCartState.customer.id`).
  final String? customerId;

  /// `GET /customers/{id}/loyalty` snapshot; null until loaded.
  final LoyaltyBalance? balance;

  /// Authoritative `POST /loyalty/preview` for [cartTotal] +
  /// [rewardPercent]; null while there is nothing valid to show (no
  /// customer, empty cart, percent above the cap, or a failed preview).
  final LoyaltyPreview? preview;

  /// Reward discount percent the cashier selected (0 = none; the server
  /// re-validates everything at checkout).
  final double rewardPercent;

  /// True when [rewardPercent] exceeds a known server cap — the preview
  /// is suppressed (no predictable-422 spam) and the UI shows the
  /// localized hint; checkout still sends the percent and lets the
  /// server reject.
  final bool exceeds;

  /// A balance fetch is in flight.
  final bool loading;

  /// Last localized failure (balance or preview).
  final String? error;

  /// Cart total the preview is computed against (after invoice discount).
  final double cartTotal;

  bool get hasCustomer => customerId != null;

  /// Server-derived discount for the current selection (0 = none).
  double get rewardDiscount => preview?.rewardDiscount ?? 0;

  /// Whole rewards the customer can spend right now — from the matching
  /// preview when possible (authoritative for this cart), else the
  /// balance snapshot.
  int get availableRewards => previewMatches
      ? preview!.availableRewards
      : (balance?.availableRewards ?? 0);

  /// True when at least one reward (100 points) is available.
  bool get hasRewardAvailable => availableRewards > 0;

  /// Owner-configured cap for the percent selector (0 = parked or
  /// points disabled).
  double get maxRewardDiscountPercent =>
      previewOnCurrentCart ? preview!.maxRewardDiscountPercent : 0;

  /// The preview was computed for the cart total currently on screen
  /// (money compared with a half-cent tolerance — the request serializes
  /// at 2dp).
  bool get previewOnCurrentCart =>
      preview != null && (preview!.grossTotal - cartTotal).abs() < 0.005;

  /// The preview matches BOTH the current total and the currently
  /// selected percent — safe to drive displayed money from it.
  bool get previewMatches =>
      preview != null &&
      preview!.rewardPercent == rewardPercent &&
      previewOnCurrentCart;

  PosLoyaltyState copyWith({
    String? customerId,
    LoyaltyBalance? balance,
    LoyaltyPreview? preview,
    double? rewardPercent,
    bool? exceeds,
    bool? loading,
    String? error,
    double? cartTotal,
    bool clearCustomer = false,
    bool clearBalance = false,
    bool clearPreview = false,
    bool clearError = false,
  }) {
    return PosLoyaltyState(
      customerId: clearCustomer ? null : (customerId ?? this.customerId),
      balance: clearBalance ? null : (balance ?? this.balance),
      preview: clearPreview ? null : (preview ?? this.preview),
      rewardPercent: rewardPercent ?? this.rewardPercent,
      exceeds: exceeds ?? this.exceeds,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      cartTotal: cartTotal ?? this.cartTotal,
    );
  }
}

class PosLoyaltyNotifier extends StateNotifier<PosLoyaltyState> {
  PosLoyaltyNotifier(this._dio, this._localeCode)
      : super(const PosLoyaltyState());

  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;

  String _message(DioException e) => posApiMessage(e, _localeCode());

  /// The cart attached/detached a customer: reset the session state and
  /// load the new customer's balances + preview. Never leaves stale
  /// points from a previous customer in the state.
  Future<void> setCustomerById(String? id) async {
    _debounce?.cancel();
    if (id == null) {
      state = PosLoyaltyState(cartTotal: state.cartTotal);
      return;
    }
    state = PosLoyaltyState(customerId: id, cartTotal: state.cartTotal, loading: true);
    await _loadBalance(id);
    await _previewNow();
  }

  /// The cart total changed (lines, qty, invoice discount): refresh the
  /// preview (debounced while the cashier keeps scanning) or drop it when
  /// the cart became empty.
  void setCartTotal(double total) {
    if (total == state.cartTotal) return;
    state = state.copyWith(cartTotal: total);
    if (state.customerId == null) return;
    if (total <= 0) {
      _debounce?.cancel();
      state = state.copyWith(clearPreview: true, exceeds: false);
      return;
    }
    _schedulePreview();
  }

  /// Reward percent selection from the totals panel (dropdown options
  /// are pre-validated against the server cap; a stale cap keeps the
  /// typed selection — checkout stays authoritative — but drops the
  /// preview instead of spamming predictable 422s).
  void setRewardPercent(double percent) {
    final value = percent > 0 ? percent : 0.0;
    state = state.copyWith(rewardPercent: value);
    if (state.customerId == null) return;
    if (value > 0) {
      final cap = _knownCap();
      if (cap != null && value > cap) {
        _debounce?.cancel();
        state = state.copyWith(exceeds: true, clearPreview: true);
        return;
      }
    }
    if (state.exceeds) state = state.copyWith(exceeds: false);
    if (state.cartTotal <= 0) {
      _debounce?.cancel();
      state = state.copyWith(clearPreview: true);
      return;
    }
    _schedulePreview();
  }

  /// Clear the selection (no reward on this sale).
  void clearReward() => setRewardPercent(0);

  /// Known server cap for the percent: the latest matching preview's
  /// `max_reward_discount_percent` (0 when points are disabled).
  double? _knownCap() {
    if (!state.previewOnCurrentCart) return null;
    return state.preview!.maxRewardDiscountPercent;
  }

  void _schedulePreview() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      unawaited(_previewNow());
    });
  }

  /// Awaited before the payment dialog opens: closes the debounce race
  /// between the cashier typing points and pressing PAY.
  Future<void> previewNow() async {
    _debounce?.cancel();
    await _previewNow();
  }

  /// Re-read balances + preview (after a void/return clawback with the
  /// customer still attached). No-op without a customer.
  Future<void> reload() async {
    final id = state.customerId;
    if (id == null) return;
    await _loadBalance(id);
    await _previewNow();
  }

  Future<void> _loadBalance(String id) async {
    try {
      final response = await _dio.get('/api/v1/customers/$id/loyalty');
      if (state.customerId != id) return;
      state = state.copyWith(
        balance: LoyaltyBalance.fromJson(
          response.data as Map<String, dynamic>? ?? const {},
        ),
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (state.customerId != id) return;
      state = state.copyWith(loading: false, error: _message(e));
    }
  }

  Future<void> _previewNow() async {
    final id = state.customerId;
    final total = state.cartTotal;
    final percent = state.rewardPercent;
    if (id == null || total <= 0) return;
    try {
      final response = await _dio.post(
        '/api/v1/loyalty/preview',
        data: {
          'customer_id': id,
          'gross_total': total.toStringAsFixed(2),
          'reward_percent': percent,
        },
      );
      // Discard stale answers (customer/total/percent moved on meanwhile).
      if (!_stillCurrent(id, total, percent)) return;
      state = state.copyWith(
        preview: LoyaltyPreview.fromJson(
          response.data as Map<String, dynamic>? ?? const {},
        ),
        exceeds: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (!_stillCurrent(id, total, percent)) return;
      state = state.copyWith(clearPreview: true, error: _message(e));
    }
  }

  bool _stillCurrent(String id, double total, double percent) =>
      state.customerId == id &&
      state.cartTotal == total &&
      state.rewardPercent == percent;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final posLoyaltyProvider =
    StateNotifierProvider<PosLoyaltyNotifier, PosLoyaltyState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PosLoyaltyNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Loyalty settings (GET/PUT /api/v1/loyalty/settings)
// ---------------------------------------------------------------------------

enum LoyaltySettingsStatus {
  idle,
  loading,
  loaded,
  saving,
  error,
}

@immutable
class LoyaltySettingsState {
  const LoyaltySettingsState({
    this.status = LoyaltySettingsStatus.idle,
    this.settings,
    this.errorMessage,
    this.failedDuringSave = false,
  });

  final LoyaltySettingsStatus status;
  final LoyaltySettings? settings;
  final String? errorMessage;
  final bool failedDuringSave;

  bool get isLoading => status == LoyaltySettingsStatus.loading;
  bool get isSaving => status == LoyaltySettingsStatus.saving;
  bool get hasError => status == LoyaltySettingsStatus.error;

  LoyaltySettingsState copyWith({
    LoyaltySettingsStatus? status,
    LoyaltySettings? settings,
    String? errorMessage,
    bool? failedDuringSave,
    bool clearSettings = false,
    bool clearError = false,
  }) {
    return LoyaltySettingsState(
      status: status ?? this.status,
      settings: clearSettings ? null : (settings ?? this.settings),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      failedDuringSave:
          failedDuringSave ?? (clearError ? false : this.failedDuringSave),
    );
  }
}

class LoyaltySettingsNotifier extends StateNotifier<LoyaltySettingsState> {
  LoyaltySettingsNotifier(this._dio, this._localeCode)
      : super(const LoyaltySettingsState());

  final Dio _dio;
  final String Function() _localeCode;

  /// `GET /loyalty/settings`. A failed load keeps whatever was previously
  /// loaded so a transient blip does not blank the form.
  Future<void> load() async {
    if (state.status == LoyaltySettingsStatus.loading ||
        state.status == LoyaltySettingsStatus.saving) {
      return;
    }
    state = state.copyWith(
      status: LoyaltySettingsStatus.loading,
      clearError: true,
    );
    try {
      final response = await _dio.get(LoyaltySettings.settingsPath);
      final data = response.data as Map<String, dynamic>? ?? const {};
      state = state.copyWith(
        status: LoyaltySettingsStatus.loaded,
        settings: LoyaltySettings.fromJson(data),
        clearError: true,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        status: LoyaltySettingsStatus.error,
        errorMessage: _extractError(e),
        failedDuringSave: false,
      );
    }
  }

  /// `PUT /loyalty/settings`. Returns `true` only on a 2xx answer.
  Future<bool> save(LoyaltySettings next) async {
    state = state.copyWith(
      status: LoyaltySettingsStatus.saving,
      clearError: true,
    );
    try {
      final response = await _dio.put(
        LoyaltySettings.settingsPath,
        data: next.toJson(),
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      state = state.copyWith(
        status: LoyaltySettingsStatus.loaded,
        settings: LoyaltySettings.fromJson(data),
        clearError: true,
      );
      return true;
    } on DioException catch (e) {
      state = state.copyWith(
        status: LoyaltySettingsStatus.error,
        errorMessage: _extractError(e),
        failedDuringSave: true,
      );
      return false;
    }
  }

  void clearError() {
    if (!state.hasError || state.settings == null) return;
    state = state.copyWith(
      status: LoyaltySettingsStatus.loaded,
      clearError: true,
    );
  }

  String _extractError(DioException e) => posApiMessage(e, _localeCode());
}

final loyaltySettingsProvider =
    StateNotifierProvider<LoyaltySettingsNotifier, LoyaltySettingsState>(
        (ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return LoyaltySettingsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Customer-scoped balances + history (clients screen)
// ---------------------------------------------------------------------------

@immutable
class LoyaltyCustomerBalanceState {
  const LoyaltyCustomerBalanceState({
    required this.customerId,
    this.balance,
    this.loading = false,
    this.error,
  });

  final String customerId;
  final LoyaltyBalance? balance;
  final bool loading;
  final String? error;

  LoyaltyCustomerBalanceState copyWith({
    LoyaltyBalance? balance,
    bool? loading,
    String? error,
    bool clearBalance = false,
    bool clearError = false,
  }) {
    return LoyaltyCustomerBalanceState(
      customerId: customerId,
      balance: clearBalance ? null : (balance ?? this.balance),
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class LoyaltyCustomerBalanceNotifier
    extends StateNotifier<LoyaltyCustomerBalanceState> {
  LoyaltyCustomerBalanceNotifier(this._dio, String customerId, this._localeCode)
      : super(LoyaltyCustomerBalanceState(customerId: customerId)) {
    load();
  }

  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  Future<void> load({bool silent = false}) async {
    final requestId = ++_requestId;
    state = state.copyWith(
      loading: true,
      clearError: silent,
    );
    try {
      final response = await _dio.get(
        '/api/v1/customers/${state.customerId}/loyalty',
      );
      if (requestId != _requestId) return;
      state = state.copyWith(
        balance: LoyaltyBalance.fromJson(
          response.data as Map<String, dynamic>? ?? const {},
        ),
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        loading: false,
        error: clientsApiMessage(e, _localeCode()),
      );
    }
  }

  void refresh() => load(silent: true);
}

/// NON-autoDispose (loads exactly once per id, refreshed explicitly by the
/// pane — same contract as `debtHistoryProvider`).
final loyaltyBalanceProvider = StateNotifierProvider.family<
    LoyaltyCustomerBalanceNotifier, LoyaltyCustomerBalanceState, String>(
  (ref, customerId) {
    final dio = ref.watch(apiClientProvider).dio;
    return LoyaltyCustomerBalanceNotifier(
      dio,
      customerId,
      () => ref.read(localeProvider).flutterLocale.languageCode,
    );
  },
);

@immutable
class LoyaltyHistoryState {
  const LoyaltyHistoryState({
    required this.customerId,
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  final String customerId;
  final List<LoyaltyLedgerEntry> items;
  final int total;
  final int page;
  final int pages;
  final bool loading;
  final String? error;

  LoyaltyHistoryState copyWith({
    List<LoyaltyLedgerEntry>? items,
    int? total,
    int? page,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return LoyaltyHistoryState(
      customerId: customerId,
      items: items ?? this.items,
      total: total ?? this.total,
      page: page ?? this.page,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class LoyaltyHistoryNotifier extends StateNotifier<LoyaltyHistoryState> {
  LoyaltyHistoryNotifier(this._dio, String customerId, this._localeCode)
      : super(LoyaltyHistoryState(customerId: customerId)) {
    load();
  }

  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  Future<void> load({int? page}) async {
    final targetPage = page ?? state.page;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, page: targetPage, clearError: true);
    try {
      final response = await _dio.get(
        '/api/v1/customers/${state.customerId}/loyalty/history',
        queryParameters: {'page': targetPage, 'page_size': 20},
      );
      if (requestId != _requestId) return;
      final pageData = LoyaltyHistoryPage.fromJson(
        response.data as Map<String, dynamic>? ?? const {},
      );
      state = state.copyWith(
        items: pageData.items,
        total: pageData.total,
        pages: pageData.pages,
        page: pageData.page,
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        loading: false,
        error: clientsApiMessage(e, _localeCode()),
      );
    }
  }

  void setPage(int page) => load(page: page);

  void refresh() => load(page: state.page);
}

/// NON-autoDispose — see [loyaltyBalanceProvider].
final loyaltyHistoryProvider = StateNotifierProvider.family<
    LoyaltyHistoryNotifier, LoyaltyHistoryState, String>(
  (ref, customerId) {
    final dio = ref.watch(apiClientProvider).dio;
    return LoyaltyHistoryNotifier(
      dio,
      customerId,
      () => ref.read(localeProvider).flutterLocale.languageCode,
    );
  },
);
