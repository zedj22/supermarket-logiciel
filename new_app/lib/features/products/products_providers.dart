// Riverpod providers for products & categories (Phase 5).
//
// - Debounced product search (~300ms) with stale-response guarding.
// - Server-side pagination/filter/sort params (never full-table loads).
// - Mutation methods return a display-ready error message (null = success).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import 'models.dart';

const Duration kSearchDebounce = Duration(milliseconds: 300);

/// Page-size choices offered by the catalog footer. The backend caps
/// `page_size` at `MAX_PAGE_SIZE = 100`, so 100 is the largest option.
const List<int> kProductPageSizeOptions = [25, 50, 100];

/// SharedPreferences key for the catalog page-size preference.
const String kProductsPageSizeKey = 'products_page_size';

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
    this.pageSize = 100,
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
  bool _loadStarted = false;

  ProductsNotifier(this._dio, this._localeCode)
      : super(const ProductsState()) {
    _restorePageSize();
  }

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

  /// Applies the persisted page-size preference. Fire-and-forget from
  /// the constructor: on a real device it lands within milliseconds —
  /// before any response could apply — and it never blocks [load]
  /// itself (a test harness without a prefs backend never completes
  /// it, where the built-in default simply stands). If a request built
  /// for the old size is already under way once the preference lands,
  /// it is invalidated and refetched, so items and page counts always
  /// match the active page size.
  Future<void> _restorePageSize() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt(kProductsPageSizeKey);
      if (saved == null ||
          !kProductPageSizeOptions.contains(saved) ||
          saved == state.query.pageSize) {
        return;
      }
      final started = _loadStarted;
      state = state.copyWith(
        query: state.query.copyWith(pageSize: saved, page: 1),
      );
      if (started) {
        // A request for the old size may be in flight or applied.
        _requestId++;
        load();
      }
    } catch (_) {
      // No prefs backend — keep the built-in default page size.
    }
  }

  Future<void> _persistPageSize(int pageSize) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(kProductsPageSizeKey, pageSize);
    } catch (_) {
      // No prefs backend — the preference simply is not remembered.
    }
  }

  Future<void> load() {
    _loadStarted = true;
    return _load();
  }

  Future<void> _load({bool clampedRetry = false}) async {
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
      final pages = data['pages'] as int? ?? 1;
      state = state.copyWith(
        items: items,
        total: data['total'] as int? ?? 0,
        pages: pages,
        loading: false,
        clearError: true,
      );
      if (!clampedRetry && query.page > pages) {
        // A refresh/filtered result shrank below the page the user was
        // on: land on the last real page instead of an empty window —
        // one bounded retry, never a clamp loop.
        state = state.copyWith(
          query: state.query.copyWith(page: pages < 1 ? 1 : pages),
        );
        await _load(clampedRetry: true);
      }
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

  /// Immediate search (scan / Enter path): cancels the debounce, applies
  /// the query and loads page 1 right now.
  Future<void> searchNow(String value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(search: value, page: 1),
      clearError: true,
    );
    return load();
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
    _persistPageSize(pageSize);
    load();
  }

  /// Route-activation hook (the screen's `initState`, rebuilt on every
  /// visit while this provider survives navigation): returning to the
  /// catalog starts a FRESH workspace instead of replaying the previous
  /// session — search/filters/page back to the defaults, the pending
  /// debounce cancelled and any in-flight response for the old query
  /// invalidated by the stale-response guard (`_requestId` bump).
  /// [ProductQuery.pageSize] survives: it is a display preference, not
  /// a filter. Dialogs and detail panels never unmount the route, so
  /// they never trigger this reset.
  void resetForActivation() {
    _debounce?.cancel();
    _requestId++;
    state = ProductsState(
      query: ProductQuery(pageSize: state.query.pageSize),
    );
  }

  void refresh() {
    _debounce?.cancel();
    load();
  }

  /// POST /api/v1/products — returns the created product on success so
  /// callers (e.g. the purchase editor's quick-add) can select it
  /// immediately; `(null, errorMessage)` on failure.
  Future<(ProductModel?, String?)> createProduct(
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _dio.post('/api/v1/products', data: payload);
      await load();
      final created = ProductModel.fromJson(
        response.data as Map<String, dynamic>,
      );
      return (created, null);
    } on DioException catch (e) {
      return (null, _message(e));
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

  /// Persist a stock change through the audited inventory journal.
  ///
  /// `PUT /products/{id}` deliberately has no `quantity` field (Phase 7 —
  /// stock only ever moves via an adjustment), so this is the one path a
  /// product form can use to actually save a quantity. `operation: set`
  /// takes the NEW absolute base-unit stock and requires a reason.
  ///
  /// Unlike `inventoryProvider.adjust()` this never touches the inventory
  /// list: an editor holding `inventory_adjust` but not `inventory_view`
  /// would otherwise get a false 403 here.
  Future<String?> setStock(
    String productId,
    String quantity,
    String reason,
  ) async {
    try {
      await _dio.post(
        '/api/v1/inventory/adjust',
        data: {
          'product_id': productId,
          'operation': 'set',
          'quantity': quantity,
          'reason': reason,
        },
      );
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

// ---------------------------------------------------------------------------
// Variants (Phase 6) — loaded on demand per product (no N+1 on list)
// ---------------------------------------------------------------------------

class VariantsState {
  final String? productId;
  final List<VariantModel> items;
  final bool loading;
  final String? error;

  const VariantsState({
    this.productId,
    this.items = const [],
    this.loading = false,
    this.error,
  });

  VariantsState copyWith({
    String? productId,
    List<VariantModel>? items,
    bool? loading,
    String? error,
    bool clearError = false,
    bool clearProduct = false,
  }) {
    return VariantsState(
      productId: clearProduct ? null : (productId ?? this.productId),
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class VariantsNotifier extends StateNotifier<VariantsState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  VariantsNotifier(this._dio, this._localeCode)
      : super(const VariantsState());

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

  /// 409 on a permanent delete always means "referenced by business
  /// records" — mapped to the localized archive-instead guidance.
  String _deleteMessage(DioException e) {
    if (e.response?.statusCode == 409) {
      return AppStrings.t('delete_blocked_in_use', _localeCode());
    }
    return _message(e);
  }

  Future<void> load(String productId, {bool includeArchived = false}) async {
    final requestId = ++_requestId;
    state = state.copyWith(
      productId: productId,
      loading: true,
      clearError: true,
      items: const [],
    );
    try {
      final response = await _dio.get(
        '/api/v1/products/$productId/variants',
        queryParameters: {'include_archived': includeArchived},
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => VariantModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(items: items, loading: false, clearError: true);
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, error: _message(e));
    } catch (_) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, items: const []);
    }
  }

  Future<String?> create(
    String productId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.post('/api/v1/products/$productId/variants', data: payload);
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> update(
    String productId,
    String variantId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put(
        '/api/v1/products/$productId/variants/$variantId',
        data: payload,
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> archive(String productId, String variantId) async {
    try {
      await _dio.delete('/api/v1/products/$productId/variants/$variantId');
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  /// Physically deletes the variant (backend refuses with a localized
  /// message when sales/purchases/invoices/inventory reference it).
  Future<String?> deletePermanently(String productId, String variantId) async {
    try {
      await _dio.delete(
        '/api/v1/products/$productId/variants/$variantId',
        queryParameters: const {'permanent': 'true'},
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _deleteMessage(e);
    }
  }
}

final variantsProvider =
    StateNotifierProvider<VariantsNotifier, VariantsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return VariantsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Selling units (Phase 6)
// ---------------------------------------------------------------------------

class SellingUnitsState {
  final String? productId;
  final List<SellingUnitModel> items;
  final bool loading;
  final String? error;

  const SellingUnitsState({
    this.productId,
    this.items = const [],
    this.loading = false,
    this.error,
  });

  SellingUnitsState copyWith({
    String? productId,
    List<SellingUnitModel>? items,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return SellingUnitsState(
      productId: productId ?? this.productId,
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  SellingUnitModel? get baseUnit {
    for (final u in items) {
      if (u.isBaseUnit && !u.isArchived) return u;
    }
    return null;
  }
}

class SellingUnitsNotifier extends StateNotifier<SellingUnitsState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  SellingUnitsNotifier(this._dio, this._localeCode)
      : super(const SellingUnitsState());

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

  /// 409 on a permanent delete always means "referenced by business
  /// records" — mapped to the localized archive-instead guidance.
  String _deleteMessage(DioException e) {
    if (e.response?.statusCode == 409) {
      return AppStrings.t('delete_blocked_in_use', _localeCode());
    }
    return _message(e);
  }

  Future<void> load(String productId, {bool includeArchived = false}) async {
    final requestId = ++_requestId;
    state = state.copyWith(
      productId: productId,
      loading: true,
      clearError: true,
      items: const [],
    );
    try {
      final response = await _dio.get(
        '/api/v1/products/$productId/selling-units',
        queryParameters: {'include_archived': includeArchived},
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => SellingUnitModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(items: items, loading: false, clearError: true);
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, error: _message(e));
    } catch (_) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, items: const []);
    }
  }

  Future<String?> create(
    String productId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.post(
        '/api/v1/products/$productId/selling-units',
        data: payload,
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> update(
    String productId,
    String unitId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put(
        '/api/v1/products/$productId/selling-units/$unitId',
        data: payload,
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> archive(String productId, String unitId) async {
    try {
      await _dio.delete('/api/v1/products/$productId/selling-units/$unitId');
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  /// Physically deletes the selling unit (backend refuses with a
  /// localized message when packs or invoices reference it).
  Future<String?> deletePermanently(String productId, String unitId) async {
    try {
      await _dio.delete(
        '/api/v1/products/$productId/selling-units/$unitId',
        queryParameters: const {'permanent': 'true'},
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _deleteMessage(e);
    }
  }
}

final sellingUnitsProvider =
    StateNotifierProvider<SellingUnitsNotifier, SellingUnitsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return SellingUnitsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Purchase units + packaging state (Phase 6 architectural correction)
// ---------------------------------------------------------------------------

class PurchaseUnitsState {
  final String? productId;
  final List<PurchaseUnitModel> items;
  final bool loading;
  final String? error;

  const PurchaseUnitsState({
    this.productId,
    this.items = const [],
    this.loading = false,
    this.error,
  });

  PurchaseUnitsState copyWith({
    String? productId,
    List<PurchaseUnitModel>? items,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return PurchaseUnitsState(
      productId: productId ?? this.productId,
      items: items ?? this.items,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }

  PurchaseUnitModel? get defaultUnit {
    for (final u in items) {
      if (u.isDefault && !u.isArchived) return u;
    }
    return null;
  }
}

class PurchaseUnitsNotifier extends StateNotifier<PurchaseUnitsState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  PurchaseUnitsNotifier(this._dio, this._localeCode)
      : super(const PurchaseUnitsState());

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

  /// 409 on a permanent delete always means "referenced by business
  /// records" — mapped to the localized archive-instead guidance.
  String _deleteMessage(DioException e) {
    if (e.response?.statusCode == 409) {
      return AppStrings.t('delete_blocked_in_use', _localeCode());
    }
    return _message(e);
  }

  Future<void> load(String productId, {bool includeArchived = false}) async {
    final requestId = ++_requestId;
    state = state.copyWith(
      productId: productId,
      loading: true,
      clearError: true,
      items: const [],
    );
    try {
      final response = await _dio.get(
        '/api/v1/products/$productId/purchase-units',
        queryParameters: {'include_archived': includeArchived},
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PurchaseUnitModel.fromJson(e as Map<String, dynamic>))
          .toList();
      state = state.copyWith(items: items, loading: false, clearError: true);
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, error: _message(e));
    } catch (_) {
      if (requestId != _requestId) return;
      state = state.copyWith(loading: false, items: const []);
    }
  }

  Future<String?> create(
    String productId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.post(
        '/api/v1/products/$productId/purchase-units',
        data: payload,
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> update(
    String productId,
    String unitId,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put(
        '/api/v1/products/$productId/purchase-units/$unitId',
        data: payload,
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> archive(String productId, String unitId) async {
    try {
      await _dio.delete('/api/v1/products/$productId/purchase-units/$unitId');
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  /// Physically deletes the purchase unit (backend refuses with a
  /// localized message when purchases, inventory, or sealed stock
  /// reference it).
  Future<String?> deletePermanently(String productId, String unitId) async {
    try {
      await _dio.delete(
        '/api/v1/products/$productId/purchase-units/$unitId',
        queryParameters: const {'permanent': 'true'},
      );
      await load(productId, includeArchived: true);
      return null;
    } on DioException catch (e) {
      return _deleteMessage(e);
    }
  }
}

final purchaseUnitsProvider =
    StateNotifierProvider<PurchaseUnitsNotifier, PurchaseUnitsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PurchaseUnitsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

class PackagingStateModel {
  final String productId;
  final String totalBaseQty;
  final String looseBaseQty;
  final List<Map<String, dynamic>> fullPackages;

  const PackagingStateModel({
    required this.productId,
    required this.totalBaseQty,
    required this.looseBaseQty,
    required this.fullPackages,
  });

  factory PackagingStateModel.fromJson(Map<String, dynamic> json) {
    return PackagingStateModel(
      productId: json['product_id'] as String? ?? '',
      totalBaseQty: '${json['total_base_qty'] ?? 0}',
      looseBaseQty: '${json['loose_base_qty'] ?? 0}',
      fullPackages: (json['full_packages'] as List<dynamic>? ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }
}

class PackagingStateNotifier extends StateNotifier<PackagingStateModel?> {
  final Dio _dio;
  final String Function() _localeCode;

  PackagingStateNotifier(this._dio, this._localeCode) : super(null);

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
    try {
      final response = await _dio.get(
        '/api/v1/products/$productId/packaging-state',
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      state = PackagingStateModel.fromJson(data);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> receive(
    String productId,
    String purchaseUnitId,
    String quantity,
  ) async {
    try {
      final response = await _dio.post(
        '/api/v1/products/$productId/packaging-state/receive',
        data: {
          'purchase_unit_id': purchaseUnitId,
          'quantity': quantity,
        },
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      state = PackagingStateModel.fromJson(data);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> sellBase(String productId, String baseQuantity) async {
    try {
      final response = await _dio.post(
        '/api/v1/products/$productId/packaging-state/sell',
        data: {'base_quantity': baseQuantity},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      state = PackagingStateModel.fromJson(data);
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }
}

final packagingStateProvider =
    StateNotifierProvider<PackagingStateNotifier, PackagingStateModel?>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PackagingStateNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Barcode lookup (Phase 8 ready)
// ---------------------------------------------------------------------------

class BarcodeLookupNotifier extends StateNotifier<BarcodeLookupModel?> {
  final Dio _dio;
  final String Function() _localeCode;

  BarcodeLookupNotifier(this._dio, this._localeCode) : super(null);

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final backend = backendErrorMessage(e);
    if (backend != null) return backend;
    return AppStrings.t('api_error_retry', loc);
  }

  Future<BarcodeLookupModel?> lookup(String barcode) async {
    state = null;
    try {
      final response = await _dio.get(
        '/api/v1/products/barcode-lookup',
        queryParameters: {'barcode': barcode},
      );
      final model = BarcodeLookupModel.fromJson(
        response.data as Map<String, dynamic>,
      );
      state = model;
      return model;
    } on DioException {
      return null;
    }
  }

  Future<String?> lookupWithError(String barcode) async {
    state = null;
    try {
      final response = await _dio.get(
        '/api/v1/products/barcode-lookup',
        queryParameters: {'barcode': barcode},
      );
      state = BarcodeLookupModel.fromJson(
        response.data as Map<String, dynamic>,
      );
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  void clear() => state = null;
}

final barcodeLookupProvider =
    StateNotifierProvider<BarcodeLookupNotifier, BarcodeLookupModel?>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return BarcodeLookupNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
