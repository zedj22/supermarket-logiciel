// Riverpod providers for the purchases list, purchase detail, and
// purchase lifecycle mutations (Phase 11).
//
// Mirrors the clients/suppliers conventions: debounced search with
// stale-response guarding, server-side pagination + status/supplier
// filters, and mutations that return a localized error object
// (null = success). Money stays in decimal strings end to end; Flutter
// never computes valuation (PMP) — document totals only.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'purchase_models.dart';
import 'purchases_error.dart';

const Duration kPurchasesSearchDebounce = Duration(milliseconds: 300);
const String kPurchasesPath = '/api/v1/purchases';

class PurchasesQuery {
  final String search;

  /// `''` = all statuses, otherwise `draft` | `received` | `cancelled`.
  final String status;

  /// Supplier filter (`null` = all suppliers).
  final String? supplierId;
  final int page;
  final int pageSize;

  const PurchasesQuery({
    this.search = '',
    this.status = '',
    this.supplierId,
    this.page = 1,
    this.pageSize = 40,
  });

  PurchasesQuery copyWith({
    String? search,
    String? status,
    String? supplierId,
    bool clearSupplier = false,
    int? page,
    int? pageSize,
  }) {
    return PurchasesQuery(
      search: search ?? this.search,
      status: status ?? this.status,
      supplierId: clearSupplier ? null : (supplierId ?? this.supplierId),
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class PurchasesState {
  final PurchasesQuery query;
  final List<PurchaseModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const PurchasesState({
    this.query = const PurchasesQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  PurchasesState copyWith({
    PurchasesQuery? query,
    List<PurchaseModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return PurchasesState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PurchasesNotifier extends StateNotifier<PurchasesState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  PurchasesNotifier(
    this._dio,
    this._localeCode, {
    PurchasesQuery initialQuery = const PurchasesQuery(),
  }) : super(PurchasesState(query: initialQuery));

  Map<String, dynamic> _params(PurchasesQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'q': q.search.trim(),
      if (q.status.isNotEmpty) 'status': q.status,
      if (q.supplierId != null) 'supplier_id': q.supplierId,
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        kPurchasesPath,
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PurchaseModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(
        items: items,
        total: data['total'] as int? ?? 0,
        pages: data['pages'] as int? ?? 1,
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        loading: false,
        error: purchasesApiMessage(e, _localeCode()),
      );
    }
  }

  void setSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(kPurchasesSearchDebounce, () {
      state = state.copyWith(
        query: state.query.copyWith(search: value, page: 1),
      );
      load();
    });
  }

  void setStatus(String value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(status: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setSupplierFilter(String? supplierId) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(
        supplierId: supplierId,
        clearSupplier: supplierId == null,
        page: 1,
      ),
      clearError: true,
    );
    load();
  }

  void setPage(int page) {
    _debounce?.cancel();
    state = state.copyWith(query: state.query.copyWith(page: page));
    load();
  }

  void refresh() {
    _debounce?.cancel();
    load();
  }

  /// POST /api/v1/purchases — `receive: true` posts atomically.
  ///
  /// Returns the created document (or null) plus a localized error.
  Future<(PurchaseModel?, PosApiError?)> create(
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _dio.post(kPurchasesPath, data: payload);
      refresh();
      final model = PurchaseModel.fromJson(
        response.data as Map<String, dynamic>,
      );
      return (model, null);
    } on DioException catch (e) {
      return (null, purchasesApiError(e, _localeCode()));
    }
  }

  /// PUT /api/v1/purchases/{id} — partial edit (draft only).
  Future<PosApiError?> update(
    String id,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put('$kPurchasesPath/$id', data: payload);
      refresh();
      return null;
    } on DioException catch (e) {
      return purchasesApiError(e, _localeCode());
    }
  }

  /// POST /api/v1/purchases/{id}/receive — draft → received.
  ///
  /// Idempotency is the backend FOR UPDATE state guard: a duplicate
  /// returns 409 PURCHASE_ALREADY_RECEIVED (stock never doubles).
  Future<PosApiError?> receive(String id) async {
    try {
      await _dio.post('$kPurchasesPath/$id/receive');
      refresh();
      return null;
    } on DioException catch (e) {
      return purchasesApiError(e, _localeCode());
    }
  }

  /// POST /api/v1/purchases/{id}/cancel — received → cancelled.
  Future<PosApiError?> cancel(String id) async {
    try {
      await _dio.post('$kPurchasesPath/$id/cancel');
      refresh();
      return null;
    } on DioException catch (e) {
      return purchasesApiError(e, _localeCode());
    }
  }

  /// DELETE /api/v1/purchases/{id} — hard-delete a DRAFT (audited).
  Future<PosApiError?> deleteDraft(String id) async {
    try {
      await _dio.delete('$kPurchasesPath/$id');
      refresh();
      return null;
    } on DioException catch (e) {
      return purchasesApiError(e, _localeCode());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final purchasesProvider =
    StateNotifierProvider<PurchasesNotifier, PurchasesState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PurchasesNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Purchase detail (header + lines, re-read after every mutation)
// ---------------------------------------------------------------------------

class PurchaseDetailNotifier extends StateNotifier<AsyncValue<PurchaseModel?>> {
  final Dio _dio;
  final String _id;

  PurchaseDetailNotifier(this._dio, this._id)
      : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final response = await _dio.get('$kPurchasesPath/$_id');
      state = AsyncValue.data(
        PurchaseModel.fromJson(response.data as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
    }
  }
}

final purchaseDetailProvider = StateNotifierProvider.family<
    PurchaseDetailNotifier, AsyncValue<PurchaseModel?>, String>(
  (ref, id) {
    final dio = ref.watch(apiClientProvider).dio;
    return PurchaseDetailNotifier(dio, id);
  },
);
