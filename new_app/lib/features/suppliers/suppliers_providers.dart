// Riverpod providers for suppliers, supplier ledger, and supplier
// payments (Phase 11).
//
// Mirrors the clients provider conventions: debounced search with
// stale-response guarding, server-side pagination, and mutations that
// return a localized error object (null = success). Money stays in
// decimal strings end to end.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'suppliers_error.dart';
import 'supplier_models.dart';

const Duration kSuppliersSearchDebounce = Duration(milliseconds: 300);
const String kSuppliersPath = '/api/v1/suppliers';

class SuppliersQuery {
  final String search;
  final bool includeArchived;
  final int page;
  final int pageSize;

  const SuppliersQuery({
    this.search = '',
    this.includeArchived = false,
    this.page = 1,
    this.pageSize = 40,
  });

  SuppliersQuery copyWith({
    String? search,
    bool? includeArchived,
    int? page,
    int? pageSize,
  }) {
    return SuppliersQuery(
      search: search ?? this.search,
      includeArchived: includeArchived ?? this.includeArchived,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class SuppliersState {
  final SuppliersQuery query;
  final List<SupplierModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const SuppliersState({
    this.query = const SuppliersQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  SuppliersState copyWith({
    SuppliersQuery? query,
    List<SupplierModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return SuppliersState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SuppliersNotifier extends StateNotifier<SuppliersState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  SuppliersNotifier(
    this._dio,
    this._localeCode, {
    SuppliersQuery initialQuery = const SuppliersQuery(),
  }) : super(SuppliersState(query: initialQuery));

  Map<String, dynamic> _params(SuppliersQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'q': q.search.trim(),
      if (q.includeArchived) 'include_archived': true,
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        kSuppliersPath,
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => SupplierModel.fromJson(e as Map<String, dynamic>))
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
        error: suppliersApiMessage(e, _localeCode()),
      );
    }
  }

  void setSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(kSuppliersSearchDebounce, () {
      state = state.copyWith(
        query: state.query.copyWith(search: value, page: 1),
      );
      load();
    });
  }

  void setIncludeArchived(bool value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(includeArchived: value, page: 1),
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

  /// POST /api/v1/suppliers — null on success, localized error otherwise.
  Future<PosApiError?> createSupplier(Map<String, dynamic> payload) async {
    try {
      await _dio.post(kSuppliersPath, data: payload);
      refresh();
      return null;
    } on DioException catch (e) {
      return suppliersApiError(e, _localeCode());
    }
  }

  /// PUT /api/v1/suppliers/{id} — null on success, localized error otherwise.
  Future<PosApiError?> updateSupplier(
    String id,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put('$kSuppliersPath/$id', data: payload);
      refresh();
      return null;
    } on DioException catch (e) {
      return suppliersApiError(e, _localeCode());
    }
  }

  /// DELETE /api/v1/suppliers/{id} (soft archive; 409 on balance != 0).
  Future<PosApiError?> archiveSupplier(String id) async {
    try {
      await _dio.delete('$kSuppliersPath/$id');
      refresh();
      return null;
    } on DioException catch (e) {
      return suppliersApiError(e, _localeCode());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final suppliersProvider =
    StateNotifierProvider<SuppliersNotifier, SuppliersState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return SuppliersNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Supplier detail (single record, re-read after every mutation)
// ---------------------------------------------------------------------------

class SupplierDetailNotifier extends StateNotifier<AsyncValue<SupplierModel?>> {
  final Dio _dio;
  final String _id;

  SupplierDetailNotifier(this._dio, this._id)
      : super(const AsyncValue.loading()) {
    load();
  }

  /// GET /api/v1/suppliers/{id}.
  ///
  /// `silent: true` refreshes in the background WITHOUT clearing the
  /// current snapshot to `loading` — used when the detail pane (re)opens,
  /// so a payable created since the last visit replaces the cached value
  /// without a spinner flash (QA fix round, Bug 1).
  Future<void> load({bool silent = false}) async {
    if (!silent) {
      state = const AsyncValue.loading();
    }
    try {
      final response = await _dio.get('$kSuppliersPath/$_id');
      state = AsyncValue.data(
        SupplierModel.fromJson(response.data as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
    }
  }
}

final supplierDetailProvider = StateNotifierProvider.family<
    SupplierDetailNotifier, AsyncValue<SupplierModel?>, String>(
  (ref, id) {
    final dio = ref.watch(apiClientProvider).dio;
    return SupplierDetailNotifier(dio, id);
  },
);

// ---------------------------------------------------------------------------
// Supplier payables ledger (paginated, per supplier)
// ---------------------------------------------------------------------------

class SupplierLedgerState {
  final String supplierId;
  final List<SupplierLedgerEntryModel> items;
  final int total;
  final int page;
  final int pages;
  final bool loading;
  final String? error;

  const SupplierLedgerState({
    required this.supplierId,
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  SupplierLedgerState copyWith({
    List<SupplierLedgerEntryModel>? items,
    int? total,
    int? page,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return SupplierLedgerState(
      supplierId: supplierId,
      items: items ?? this.items,
      total: total ?? this.total,
      page: page ?? this.page,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class SupplierLedgerNotifier extends StateNotifier<SupplierLedgerState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  SupplierLedgerNotifier(this._dio, String supplierId, this._localeCode)
      : super(SupplierLedgerState(supplierId: supplierId)) {
    load();
  }

  Future<void> load({int? page}) async {
    final targetPage = page ?? state.page;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, page: targetPage, clearError: true);
    try {
      final response = await _dio.get(
        '$kSuppliersPath/${state.supplierId}/ledger',
        queryParameters: {'page': targetPage, 'page_size': 20},
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map(
            (e) =>
                SupplierLedgerEntryModel.fromJson(e as Map<String, dynamic>),
          )
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
        error: suppliersApiMessage(e, _localeCode()),
      );
    }
  }

  void setPage(int page) => load(page: page);

  void refresh() => load(page: state.page);
}

final supplierLedgerProvider = StateNotifierProvider.family<
    SupplierLedgerNotifier, SupplierLedgerState, String>(
  (ref, supplierId) {
    final dio = ref.watch(apiClientProvider).dio;
    return SupplierLedgerNotifier(
      dio,
      supplierId,
      () => ref.read(localeProvider).flutterLocale.languageCode,
    );
  },
);

// ---------------------------------------------------------------------------
// Supplier payment (POST /api/v1/suppliers/{id}/payments)
// ---------------------------------------------------------------------------

class SupplierPaymentNotifier {
  final Dio _dio;
  final String Function() _localeCode;

  SupplierPaymentNotifier(this._dio, this._localeCode);

  /// Records a payment. Returns the result or a localized error.
  Future<(SupplierPaymentResult?, PosApiError?)> pay(
    String supplierId,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _dio.post(
        '$kSuppliersPath/$supplierId/payments',
        data: payload,
      );
      final result = SupplierPaymentResult.fromJson(
        response.data as Map<String, dynamic>,
      );
      return (result, null);
    } on DioException catch (e) {
      return (null, suppliersApiError(e, _localeCode()));
    }
  }
}

final supplierPaymentProvider = Provider<SupplierPaymentNotifier>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return SupplierPaymentNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
