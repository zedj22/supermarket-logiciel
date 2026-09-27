// Riverpod providers for packs / bundles (Phase 10).
//
// Same shape as products_providers: debounced search, server-side
// pagination/filter, mutations returning a localized message (null =
// success), plus read-only detail + availability queries.
//
// Permissions reuse the Phase 4 product scopes (GATE 11): `product_view`
// to read, `product_create` / `product_update` / `product_archive` to
// write. No new scope exists for packs.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/strings.dart';
import '../../l10n/locale_provider.dart';
import '../../network/api_client.dart';
import '../auth/auth_provider.dart';
import '../products/products_providers.dart';
import 'pack_models.dart';

/// Backend error codes introduced by Phase 10 → localized primary message.
///
/// Codes are mapped BEFORE the raw backend text (Phase 9 contract): the
/// English `message` only ever travels as the secondary detail line.
String? packApiCodeMessage(String? code, String loc) {
  switch (code) {
    case 'PACK_INACTIVE':
      return AppStrings.t('pack_inactive', loc);
    case 'PACK_STOCK_INSUFFICIENT':
      return AppStrings.t('pack_stock_insufficient', loc);
    case 'PACK_COMPONENT_DUPLICATE':
      return AppStrings.t('pack_component_duplicate', loc);
    default:
      return null;
  }
}

class PackQuery {
  final String search;
  final String status; // active | archived | all
  final int page;
  final int pageSize;

  const PackQuery({
    this.search = '',
    this.status = 'active',
    this.page = 1,
    this.pageSize = 40,
  });

  PackQuery copyWith({
    String? search,
    String? status,
    int? page,
    int? pageSize,
  }) {
    return PackQuery(
      search: search ?? this.search,
      status: status ?? this.status,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class PacksState {
  final PackQuery query;
  final List<PackModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const PacksState({
    this.query = const PackQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  PacksState copyWith({
    PackQuery? query,
    List<PackModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return PacksState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PacksNotifier extends StateNotifier<PacksState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  PacksNotifier(this._dio, this._localeCode) : super(const PacksState());

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final byCode = packApiCodeMessage(backendErrorCode(e), loc);
    if (byCode != null) return byCode;
    final backend = backendErrorMessage(e);
    if (backend != null) return backend;
    final code = e.response?.statusCode;
    if (code == 401) return AppStrings.t('session_expired_login', loc);
    if (code == 403) return AppStrings.t('permission_denied', loc);
    if (code == 422) return AppStrings.t('validation_error', loc);
    return AppStrings.t('api_error_retry', loc);
  }

  Map<String, dynamic> _params(PackQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'search': q.search.trim(),
      'status': q.status,
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        '/api/v1/packs',
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return; // stale response — discard
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PackModel.fromJson(e as Map<String, dynamic>))
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

  /// Pack detail with resolved components (null on failure).
  Future<PackModel?> fetchDetail(String packId) async {
    try {
      final response = await _dio.get('/api/v1/packs/$packId');
      return PackModel.fromJson(response.data as Map<String, dynamic>);
    } on DioException {
      return null;
    }
  }

  /// Read-only component stock position — never reserves or mutates.
  Future<PackAvailabilityModel?> fetchAvailability(
    String packId, {
    String quantity = '1',
  }) async {
    try {
      final response = await _dio.get(
        '/api/v1/packs/$packId/availability',
        queryParameters: {'quantity': quantity},
      );
      return PackAvailabilityModel.fromJson(
        response.data as Map<String, dynamic>,
      );
    } on DioException {
      return null;
    }
  }

  Future<String?> create(Map<String, dynamic> payload) async {
    try {
      await _dio.post('/api/v1/packs', data: payload);
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  Future<String?> update(String packId, Map<String, dynamic> payload) async {
    try {
      await _dio.put('/api/v1/packs/$packId', data: payload);
      await load();
      return null;
    } on DioException catch (e) {
      return _message(e);
    }
  }

  /// Soft archive (GATE 8) — the pack stays referential for old sales.
  Future<String?> archive(String packId) async {
    try {
      await _dio.delete('/api/v1/packs/$packId');
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

final packsProvider =
    StateNotifierProvider<PacksNotifier, PacksState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PacksNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

/// Standalone pack search for the POS picker — its own provider so the
/// management screen's query state is never disturbed by cashier search.
class PackPickerState {
  final String query;
  final List<PackModel> items;
  final bool loading;
  final String? error;

  const PackPickerState({
    this.query = '',
    this.items = const [],
    this.loading = false,
    this.error,
  });
}

class PackPickerNotifier extends StateNotifier<PackPickerState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  PackPickerNotifier(this._dio, this._localeCode)
      : super(const PackPickerState());

  String _message(DioException e) {
    final loc = _localeCode();
    if (isConnectionError(e)) {
      return AppStrings.t('network_error_retry', loc);
    }
    final backend = backendErrorMessage(e);
    if (backend != null) return backend;
    return AppStrings.t('api_error_retry', loc);
  }

  void setQuery(String value) {
    state = PackPickerState(
      query: value,
      items: state.items,
      loading: true,
    );
    _debounce?.cancel();
    _debounce = Timer(kSearchDebounce, load);
  }

  Future<void> load() async {
    final q = state.query.trim();
    final requestId = ++_requestId;
    state = PackPickerState(
      query: state.query,
      items: state.items,
      loading: true,
    );
    try {
      final response = await _dio.get(
        '/api/v1/packs',
        queryParameters: {
          'page': 1,
          'page_size': 50,
          'status': 'active',
          if (q.isNotEmpty) 'search': q,
        },
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => PackModel.fromJson(e as Map<String, dynamic>))
          .where((p) => p.isSaleable)
          .toList();
      state = PackPickerState(query: state.query, items: items);
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = PackPickerState(query: state.query, error: _message(e));
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final packPickerProvider =
    StateNotifierProvider<PackPickerNotifier, PackPickerState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PackPickerNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
