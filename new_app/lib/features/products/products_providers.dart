// Riverpod providers for products & categories (Phase 5).
//
// - Debounced product search (~300ms) with stale-response guarding.
// - Server-side pagination/filter/sort params (never full-table loads).
// - Mutation methods return a display-ready error message (null = success).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'models.dart';

const Duration kSearchDebounce = Duration(milliseconds: 300);

class ProductQuery {
  final String search;
  final String? categoryId;
  final String status; // active | archived | all
  final String sortBy;
  final String sortOrder;
  final int page;
  final int pageSize;

  const ProductQuery({
    this.search = '',
    this.categoryId,
    this.status = 'active',
    this.sortBy = 'name',
    this.sortOrder = 'asc',
    this.page = 1,
    this.pageSize = 40,
  });

  ProductQuery copyWith({
    String? search,
    String? categoryId,
    bool clearCategoryId = false,
    String? status,
    String? sortBy,
    String? sortOrder,
    int? page,
    int? pageSize,
  }) {
    return ProductQuery(
      search: search ?? this.search,
      categoryId: clearCategoryId ? null : (categoryId ?? this.categoryId),
      status: status ?? this.status,
      sortBy: sortBy ?? this.sortBy,
      sortOrder: sortOrder ?? this.sortOrder,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class ProductsState {
  final ProductQuery query;
  final List<ProductModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const ProductsState({
    this.query = const ProductQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  ProductsState copyWith({
    ProductQuery? query,
    List<ProductModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return ProductsState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ProductsNotifier extends StateNotifier<ProductsState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  ProductsNotifier(this._dio, this._localeCode)
      : super(const ProductsState());

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final backend = backendErrorMessage(e);
    if (backend != null) return backend;
    final code = e.response?.statusCode;
    if (code == 401) return AppStrings.t('session_expired_login', loc);
    if (code == 403) return AppStrings.t('permission_denied', loc);
    if (code == 422) return AppStrings.t('validation_error', loc);
    return AppStrings.t('api_error_retry', loc);
  }

  Map<String, dynamic> _params(ProductQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'search': q.search.trim(),
      if (q.categoryId != null) 'category_id': q.categoryId,
      'status': q.status,
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
        '/api/v1/products',
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return; // stale response — discard
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => ProductModel.fromJson(e as Map<String, dynamic>))
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

  void setSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(kSearchDebounce, () {
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

  void setCategory(String? categoryId) {
    _debounce?.cancel();
    state = state.copyWith(
      query: categoryId == null
          ? state.query.copyWith(page: 1, clearCategoryId: true)
          : state.query.copyWith(categoryId: categoryId, page: 1),
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

  void setPageSize(int pageSize) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(pageSize: pageSize, page: 1),
      clearError: true,
    );
    load();
  }

  void refresh() {
    _debounce?.cancel();
    load();
  }

  Future<String?> createProduct(Map<String, dynamic> payload) async {
    try {
      await _dio.post('/api/v1/products', data: payload);
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> updateProduct(
    String productId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put('/api/v1/products/$productId', data: payload);
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> archiveProduct(String productId) async {
    try {
      await _dio.delete('/api/v1/products/$productId');
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

final productsProvider =
    StateNotifierProvider<ProductsNotifier, ProductsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return ProductsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Categories
// ---------------------------------------------------------------------------

class CategoriesState {
  final List<CategoryModel> items;
  final bool loading;
  final String? error;
  final String status;

  const CategoriesState({
    this.items = const [],
    this.loading = false,
    this.error,
    this.status = 'all',
  });

  CategoriesState copyWith({
    List<CategoryModel>? items,
    bool? loading,
    String? error,
    bool clearError = false,
    String? status,
  }) {
    return CategoriesState(
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      status: status ?? this.status,
    );
  }

  /// Active categories only (for product form/filter dropdowns).
  List<CategoryModel> get activeItems =>
      items.where((c) => !c.isArchived).toList();
}

class CategoriesNotifier extends StateNotifier<CategoriesState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  CategoriesNotifier(this._dio, this._localeCode)
      : super(const CategoriesState());

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final backend = backendErrorMessage(e);
    if (backend != null) return backend;
    final code = e.response?.statusCode;
    if (code == 403) return AppStrings.t('permission_denied', loc);
    if (code == 422) return AppStrings.t('validation_error', loc);
    return AppStrings.t('api_error_retry', loc);
  }

  Future<void> load({String? status}) async {
    final effectiveStatus = status ?? state.status;
    final requestId = ++_requestId;
    state = state.copyWith(
      loading: true,
      clearError: true,
      status: effectiveStatus,
    );
    try {
      final response = await _dio.get(
        '/api/v1/categories',
        queryParameters: {
          'page': 1,
          'page_size': 100,
          'status': effectiveStatus,
        },
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => CategoryModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(items: items, loading: false, clearError: true);
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, error: _message(e));
    }
  }

  Future<String?> create(String name) async {
    try {
      await _dio.post('/api/v1/categories', data: {'name': name});
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> update(String categoryId, String name) async {
    try {
      await _dio.put('/api/v1/categories/$categoryId', data: {'name': name});
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> archive(String categoryId) async {
    try {
      await _dio.delete('/api/v1/categories/$categoryId');
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }
}

final categoriesProvider =
    StateNotifierProvider<CategoriesNotifier, CategoriesState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return CategoriesNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
