// Riverpod providers for the Promotions feature (Phase 18).
//
// Two halves:
//   * [PromotionsApi] — the command side (create one promotion over many
//     products, replace its membership, flip active ⇄ inactive). Every
//     call returns `(result, PosApiError?)` — null error means success —
//     so a dialog can show a localized failure without throwing.
//   * [PromotionsNotifier] — the filtered + paginated list
//     (GET /api/v1/promotions).
//
// Money stays in decimal strings end to end: the server owns `value`, the
// active flag and the membership set. The client never derives an
// effective promotional price — that rides on the product responses
// (`ProductModel.promotion.price`).
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'promotion_models.dart';
import 'promotions_error.dart';

const String kPromotionsPath = '/api/v1/promotions';

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

class PromotionsQuery {
  final String search;

  /// `null` = all, `true` = active only, `false` = inactive only.
  final bool? isActive;
  final int page;
  final int pageSize;

  const PromotionsQuery({
    this.search = '',
    this.isActive,
    this.page = 1,
    this.pageSize = AppConstants.defaultPageSize,
  });

  PromotionsQuery copyWith({
    String? search,
    bool? isActive,
    int? page,
    int? pageSize,
    bool clearActive = false,
  }) {
    return PromotionsQuery(
      search: search ?? this.search,
      isActive: clearActive ? null : (isActive ?? this.isActive),
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class PromotionsState {
  final PromotionsQuery query;
  final List<PromotionItem> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const PromotionsState({
    this.query = const PromotionsQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  PromotionsState copyWith({
    PromotionsQuery? query,
    List<PromotionItem>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return PromotionsState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PromotionsNotifier extends StateNotifier<PromotionsState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  PromotionsNotifier(this._dio, this._localeCode)
      : super(const PromotionsState());

  Map<String, dynamic> _params(PromotionsQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'q': q.search.trim(),
      if (q.isActive != null) 'is_active': q.isActive,
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        kPromotionsPath,
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final page = PromotionListPage.fromJson(
        response.data as Map<String, dynamic>? ?? const {},
      );
      state = state.copyWith(
        items: page.items,
        total: page.total,
        pages: page.pages,
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        loading: false,
        error: promotionsApiMessage(e, _localeCode()),
      );
    }
  }

  void setSearch(String value) {
    state = state.copyWith(
      query: state.query.copyWith(search: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setIsActive(bool? value) {
    state = state.copyWith(
      query: state.query.copyWith(
        isActive: value,
        page: 1,
        clearActive: value == null,
      ),
      clearError: true,
    );
    load();
  }

  void setPage(int page) {
    state = state.copyWith(query: state.query.copyWith(page: page));
    load();
  }

  void clearFilters() {
    state = state.copyWith(
      query: const PromotionsQuery(),
      clearError: true,
    );
    load();
  }

  void refresh() => load();
}

final promotionsProvider =
    StateNotifierProvider<PromotionsNotifier, PromotionsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PromotionsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Command side (create / update / toggle)
// ---------------------------------------------------------------------------

class PromotionsApi {
  PromotionsApi(this._dio, this._localeCode);

  final Dio _dio;
  final String Function() _localeCode;

  /// `POST /api/v1/promotions` — 201, bulk apply in ONE transaction
  /// (GATE: all-or-nothing; `client_request_id` makes a retry replay).
  Future<(PromotionItem?, PosApiError?)> create({
    required Map<String, dynamic> payload,
  }) async {
    try {
      final response = await _dio.post(kPromotionsPath, data: payload);
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (PromotionItem.fromJson(data), null);
    } on DioException catch (e) {
      return (null, promotionsApiError(e, _localeCode()));
    }
  }

  /// `PUT /api/v1/promotions/{id}` — partial update; `product_ids`
  /// replaces the membership set in one transaction.
  Future<(PromotionItem?, PosApiError?)> update({
    required String promotionId,
    required Map<String, dynamic> payload,
  }) async {
    try {
      final response = await _dio.put(
        '$kPromotionsPath/$promotionId',
        data: payload,
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (PromotionItem.fromJson(data), null);
    } on DioException catch (e) {
      return (null, promotionsApiError(e, _localeCode()));
    }
  }

  /// `POST /api/v1/promotions/{id}/toggle` — active ⇄ inactive.
  Future<(PromotionItem?, PosApiError?)> toggle({
    required String promotionId,
  }) async {
    try {
      final response =
          await _dio.post('$kPromotionsPath/$promotionId/toggle');
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (PromotionItem.fromJson(data), null);
    } on DioException catch (e) {
      return (null, promotionsApiError(e, _localeCode()));
    }
  }
}

final promotionsApiProvider = Provider<PromotionsApi>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return PromotionsApi(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
