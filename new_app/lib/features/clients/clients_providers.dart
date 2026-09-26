// Riverpod providers for customers, debt history, and debt summary
// (Phase 9).
//
// Mirrors the inventory provider conventions: debounced search with
// stale-response guarding, server-side pagination, and mutations that
// return a localized error object (null = success). Money stays in
// decimal strings end to end.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'clients_error.dart';
import 'customer_models.dart';

const Duration kCustomersSearchDebounce = Duration(milliseconds: 300);
const String kCustomersPath = '/api/v1/customers';

class CustomersQuery {
  final String search;
  final bool includeArchived;

  /// Only customers with an outstanding balance (debts screen).
  final bool hasDebt;
  final int page;
  final int pageSize;

  const CustomersQuery({
    this.search = '',
    this.includeArchived = false,
    this.hasDebt = false,
    this.page = 1,
    this.pageSize = 40,
  });

  CustomersQuery copyWith({
    String? search,
    bool? includeArchived,
    bool? hasDebt,
    int? page,
    int? pageSize,
  }) {
    return CustomersQuery(
      search: search ?? this.search,
      includeArchived: includeArchived ?? this.includeArchived,
      hasDebt: hasDebt ?? this.hasDebt,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class CustomersState {
  final CustomersQuery query;
  final List<CustomerModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const CustomersState({
    this.query = const CustomersQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  CustomersState copyWith({
    CustomersQuery? query,
    List<CustomerModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return CustomersState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class CustomersNotifier extends StateNotifier<CustomersState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  CustomersNotifier(
    this._dio,
    this._localeCode, {
    CustomersQuery initialQuery = const CustomersQuery(),
  }) : super(CustomersState(query: initialQuery));

  Map<String, dynamic> _params(CustomersQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'q': q.search.trim(),
      if (q.includeArchived) 'include_archived': true,
      if (q.hasDebt) 'has_debt': true,
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        kCustomersPath,
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => CustomerModel.fromJson(e as Map<String, dynamic>))
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
        error: clientsApiMessage(e, _localeCode()),
      );
    }
  }

  void setSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(kCustomersSearchDebounce, () {
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

  void setHasDebt(bool value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(hasDebt: value, page: 1),
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

  /// POST /api/v1/customers — null on success, localized error otherwise.
  Future<PosApiError?> createCustomer(Map<String, dynamic> payload) async {
    try {
      await _dio.post(kCustomersPath, data: payload);
      refresh();
      return null;
    } on DioException catch (e) {
      return clientsApiError(e, _localeCode());
    }
  }

  /// PUT /api/v1/customers/{id} — null on success, localized error otherwise.
  Future<PosApiError?> updateCustomer(
    String id,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put('$kCustomersPath/$id', data: payload);
      refresh();
      return null;
    } on DioException catch (e) {
      return clientsApiError(e, _localeCode());
    }
  }

  /// DELETE /api/v1/customers/{id} (soft archive).
  Future<PosApiError?> archiveCustomer(String id) async {
    try {
      await _dio.delete('$kCustomersPath/$id');
      refresh();
      return null;
    } on DioException catch (e) {
      return clientsApiError(e, _localeCode());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final customersProvider =
    StateNotifierProvider<CustomersNotifier, CustomersState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return CustomersNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

/// Debtors list (debts screen): a SEPARATE instance pre-set to
/// `has_debt=true` so the clients screen's query state is never mutated
/// by navigation between the two screens.
final debtorsProvider =
    StateNotifierProvider<CustomersNotifier, CustomersState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return CustomersNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    initialQuery: const CustomersQuery(hasDebt: true),
  );
});

// ---------------------------------------------------------------------------
// Customer detail (single record, re-read after every mutation)
// ---------------------------------------------------------------------------

class CustomerDetailNotifier extends StateNotifier<AsyncValue<CustomerModel?>> {
  final Dio _dio;
  final String _id;

  CustomerDetailNotifier(this._dio, this._id)
      : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load() async {
    state = const AsyncValue.loading();
    try {
      final response = await _dio.get('$kCustomersPath/$_id');
      state = AsyncValue.data(
        CustomerModel.fromJson(response.data as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
    }
  }
}

final customerDetailProvider = StateNotifierProvider.family<
    CustomerDetailNotifier, AsyncValue<CustomerModel?>, String>(
  (ref, id) {
    final dio = ref.watch(apiClientProvider).dio;
    return CustomerDetailNotifier(dio, id);
  },
);

// ---------------------------------------------------------------------------
// Debt history (paginated, per customer)
// ---------------------------------------------------------------------------

class DebtHistoryState {
  final String customerId;
  final List<DebtEntryModel> items;
  final int total;
  final int page;
  final int pages;
  final bool loading;
  final String? error;

  const DebtHistoryState({
    required this.customerId,
    this.items = const [],
    this.total = 0,
    this.page = 1,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  DebtHistoryState copyWith({
    List<DebtEntryModel>? items,
    int? total,
    int? page,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return DebtHistoryState(
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

class DebtHistoryNotifier extends StateNotifier<DebtHistoryState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  DebtHistoryNotifier(this._dio, String customerId, this._localeCode)
      : super(DebtHistoryState(customerId: customerId)) {
    load();
  }

  Future<void> load({int? page}) async {
    final targetPage = page ?? state.page;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, page: targetPage, clearError: true);
    try {
      final response = await _dio.get(
        '$kCustomersPath/${state.customerId}/debts',
        queryParameters: {'page': targetPage, 'page_size': 20},
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map((e) => DebtEntryModel.fromJson(e as Map<String, dynamic>))
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
        error: clientsApiMessage(e, _localeCode()),
      );
    }
  }

  void setPage(int page) => load(page: page);

  void refresh() => load(page: state.page);
}

final debtHistoryProvider = StateNotifierProvider.family<
    DebtHistoryNotifier, DebtHistoryState, String>(
  (ref, customerId) {
    final dio = ref.watch(apiClientProvider).dio;
    return DebtHistoryNotifier(
      dio,
      customerId,
      () => ref.read(localeProvider).flutterLocale.languageCode,
    );
  },
);

// ---------------------------------------------------------------------------
// Debt payment (POST /api/v1/customers/{id}/pay)
// ---------------------------------------------------------------------------

class DebtPaymentNotifier {
  final Dio _dio;
  final String Function() _localeCode;

  DebtPaymentNotifier(this._dio, this._localeCode);

  /// Records a payment. Returns the result or a localized error.
  Future<(DebtPaymentResult?, PosApiError?)> pay(
    String customerId,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _dio.post(
        '$kCustomersPath/$customerId/pay',
        data: payload,
      );
      final result = DebtPaymentResult.fromJson(
        response.data as Map<String, dynamic>,
      );
      return (result, null);
    } on DioException catch (e) {
      return (null, clientsApiError(e, _localeCode()));
    }
  }
}

final debtPaymentProvider = Provider<DebtPaymentNotifier>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return DebtPaymentNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// AR summary (GET /api/v1/debts/summary)
// ---------------------------------------------------------------------------

class DebtSummaryState {
  final DebtSummaryModel? summary;
  final bool loading;
  final String? error;

  const DebtSummaryState({this.summary, this.loading = false, this.error});

  DebtSummaryState copyWith({
    DebtSummaryModel? summary,
    bool? loading,
    String? error,
    bool clearError = false,
    bool clearSummary = false,
  }) {
    return DebtSummaryState(
      summary: clearSummary ? null : (summary ?? this.summary),
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class DebtSummaryNotifier extends StateNotifier<DebtSummaryState> {
  final Dio _dio;
  final String Function() _localeCode;

  DebtSummaryNotifier(this._dio, this._localeCode)
      : super(const DebtSummaryState()) {
    load();
  }

  Future<void> load() async {
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get('/api/v1/debts/summary');
      state = state.copyWith(
        summary: DebtSummaryModel.fromJson(
          response.data as Map<String, dynamic>,
        ),
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      state = state.copyWith(
        loading: false,
        error: clientsApiMessage(e, _localeCode()),
      );
    }
  }

  void refresh() => load();
}

final debtSummaryProvider =
    StateNotifierProvider<DebtSummaryNotifier, DebtSummaryState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return DebtSummaryNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
