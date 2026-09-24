// Riverpod providers for inventory (Phase 7).
//
// - Debounced search (~300ms) with stale-response guarding.
// - Server-side pagination/filter/sort.
// - adjust() returns a display-ready error message (null = success).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'inventory_models.dart';

const Duration kInventorySearchDebounce = Duration(milliseconds: 300);

class InventoryQuery {
  final String search;
  final String status; // active | archived | all
  final bool lowStockOnly;
  final String sortBy;
  final String sortOrder;
  final int page;
  final int pageSize;

  const InventoryQuery({
    this.search = '',
    this.status = 'active',
    this.lowStockOnly = false,
    this.sortBy = 'name',
    this.sortOrder = 'asc',
    this.page = 1,
    this.pageSize = 40,
  });

  InventoryQuery copyWith({
    String? search,
    String? status,
    bool? lowStockOnly,
    String? sortBy,
    String? sortOrder,
    int? page,
    int? pageSize,
  }) {
    return InventoryQuery(
      search: search ?? this.search,
      status: status ?? this.status,
      lowStockOnly: lowStockOnly ?? this.lowStockOnly,
      sortBy: sortBy ?? this.sortBy,
      sortOrder: sortOrder ?? this.sortOrder,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class InventoryState {
  final InventoryQuery query;
  final List<InventoryItemModel> items;
  final int total;
  final int pages;
  final String totalStockValue;
  final bool loading;
  final String? error;

  const InventoryState({
    this.query = const InventoryQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.totalStockValue = '0',
    this.loading = false,
    this.error,
  });

  InventoryState copyWith({
    InventoryQuery? query,
    List<InventoryItemModel>? items,
    int? total,
    int? pages,
    String? totalStockValue,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return InventoryState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      totalStockValue: totalStockValue ?? this.totalStockValue,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class InventoryNotifier extends StateNotifier<InventoryState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  InventoryNotifier(this._dio, this._localeCode)
      : super(const InventoryState());

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    // Prefer the real backend message (structured envelope or FastAPI detail).
    final backend = backendErrorMessage(e);
    if (backend != null && backend.isNotEmpty) return backend;
    final code = e.response?.statusCode;
    if (code == 401) return AppStrings.t('session_expired_login', loc);
    if (code == 403) return AppStrings.t('permission_denied', loc);
    if (code == 422) return AppStrings.t('validation_error', loc);
    return AppStrings.t('api_error_retry', loc);
  }

  Map<String, dynamic> _params(InventoryQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'search': q.search.trim(),
      'status': q.status,
      if (q.lowStockOnly) 'low_stock': true,
      'sort_by': q.sortBy,
      'sort_order': q.sortOrder,
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        '/api/v1/inventory',
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => InventoryItemModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(
        items: items,
        total: data['total'] as int? ?? 0,
        pages: data['pages'] as int? ?? 1,
        totalStockValue: '${data['total_stock_value'] ?? 0}',
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, error: _message(e));
    }
  }

  void setSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(kInventorySearchDebounce, () {
      state = state.copyWith(
        query: state.query.copyWith(search: value, page: 1),
      );
      load();
    });
  }

  void setStatus(String status) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(status: status, page: 1),
      clearError: true,
    );
    load();
  }

  void setLowStockOnly(bool value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(lowStockOnly: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setSort(String sortBy, String sortOrder) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(sortBy: sortBy, sortOrder: sortOrder, page: 1),
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

  /// POST /api/v1/inventory/adjust — returns null on success, error message otherwise.
  Future<String?> adjust(Map<String, dynamic> payload) async {
    try {
      await _dio.post('/api/v1/inventory/adjust', data: payload);
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final inventoryProvider =
    StateNotifierProvider<InventoryNotifier, InventoryState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return InventoryNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Movement journal
// ---------------------------------------------------------------------------

class MovementsQuery {
  final String? productId;
  final String? movementType;
  final int page;
  final int pageSize;

  const MovementsQuery({
    this.productId,
    this.movementType,
    this.page = 1,
    this.pageSize = 40,
  });

  MovementsQuery copyWith({
    String? productId,
    bool clearProductId = false,
    String? movementType,
    bool clearMovementType = false,
    int? page,
    int? pageSize,
  }) {
    return MovementsQuery(
      productId: clearProductId ? null : (productId ?? this.productId),
      movementType:
          clearMovementType ? null : (movementType ?? this.movementType),
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class MovementsState {
  final MovementsQuery query;
  final List<InventoryMovementModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const MovementsState({
    this.query = const MovementsQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  MovementsState copyWith({
    MovementsQuery? query,
    List<InventoryMovementModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return MovementsState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class MovementsNotifier extends StateNotifier<MovementsState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  MovementsNotifier(this._dio, this._localeCode)
      : super(const MovementsState());

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final backend = backendErrorMessage(e);
    if (backend != null) return backend;
    final code = e.response?.statusCode;
    if (code == 403) return AppStrings.t('permission_denied', loc);
    return AppStrings.t('api_error_retry', loc);
  }

  Future<void> load() async {
    final q = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final path = q.productId != null
          ? '/api/v1/inventory/movements/${q.productId}'
          : '/api/v1/inventory/movements';
      final response = await _dio.get(
        path,
        queryParameters: {
          'page': q.page,
          'page_size': q.pageSize,
          if (q.productId == null && q.movementType != null)
            'movement_type': q.movementType,
          if (q.productId != null && q.movementType != null)
            'movement_type': q.movementType,
        },
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => InventoryMovementModel.fromJson(e as Map<String, dynamic>))
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
      state = state.copyWith(loading: false, error: _message(e));
    }
  }

  void setProductId(String? productId) {
    state = state.copyWith(
      query: productId == null
          ? state.query.copyWith(page: 1, clearProductId: true)
          : state.query.copyWith(productId: productId, page: 1),
      clearError: true,
      items: const [],
    );
    load();
  }

  void setMovementType(String? movementType) {
    state = state.copyWith(
      query: movementType == null
          ? state.query.copyWith(page: 1, clearMovementType: true)
          : state.query.copyWith(movementType: movementType, page: 1),
      clearError: true,
    );
    load();
  }

  void setPage(int page) {
    state = state.copyWith(query: state.query.copyWith(page: page));
    load();
  }

  void refresh() => load();
}

final movementsProvider =
    StateNotifierProvider<MovementsNotifier, MovementsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return MovementsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Product stock detail
// ---------------------------------------------------------------------------

class ProductDetailNotifier
    extends StateNotifier<AsyncValue<InventoryProductDetailModel?>> {
  final Dio _dio;
  final String Function() _localeCode;

  ProductDetailNotifier(this._dio, this._localeCode)
      : super(const AsyncValue.data(null));

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final backend = backendErrorMessage(e);
    if (backend != null) return backend;
    return AppStrings.t('api_error_retry', loc);
  }

  Future<String?> load(String productId) async {
    state = const AsyncValue.loading();
    try {
      final response = await _dio.get('/api/v1/inventory/$productId');
      state = AsyncValue.data(
        InventoryProductDetailModel.fromJson(
          response.data as Map<String, dynamic>,
        ),
      );
      return null;
    } on DioException catch (e) {
      final msg = _message(e);
      state = AsyncValue.error(e, StackTrace.current);
      return msg;
    }
  }

  void clear() => state = const AsyncValue.data(null);
}

final productStockDetailProvider = StateNotifierProvider<
    ProductDetailNotifier, AsyncValue<InventoryProductDetailModel?>>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return ProductDetailNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
