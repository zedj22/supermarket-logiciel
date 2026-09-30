// Riverpod providers for the Expenses feature (Phase 13).
//
// Two halves:
//   * [ExpensesApi] — the command side (create one expense, cancel one
//     expense). Every call returns `(result, PosApiError?)` — null error
//     means success — so a dialog can show a localized failure without
//     throwing.
//   * [ExpensesNotifier] — the filtered + paginated list with its summary
//     (GET /api/v1/expenses and GET /api/v1/expenses/summary).
//
// Money stays in decimal strings end to end: the server owns the amount,
// the lifecycle status and the summary arithmetic.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'expenses_error.dart';
import 'expense_models.dart';

const String kExpensesPath = '/api/v1/expenses';

/// `yyyy-MM-dd` in the local calendar day — the server treats both bounds
/// as inclusive calendar dates (B13).
String expenseDateParam(DateTime value) =>
    DateFormat('yyyy-MM-dd').format(value.toLocal());

// ---------------------------------------------------------------------------
// List + summary
// ---------------------------------------------------------------------------

class ExpensesQuery {
  final String search;
  final String category;

  /// `null` = both, `true` = drawer only, `false` = external only.
  final bool? paidFromDrawer;
  final DateTime? dateFrom;
  final DateTime? dateTo;

  /// `posted` (default) | `cancelled` | `all`.
  final String status;
  final int page;
  final int pageSize;

  const ExpensesQuery({
    this.search = '',
    this.category = '',
    this.paidFromDrawer,
    this.dateFrom,
    this.dateTo,
    this.status = 'posted',
    this.page = 1,
    this.pageSize = AppConstants.defaultPageSize,
  });

  ExpensesQuery copyWith({
    String? search,
    String? category,
    bool? paidFromDrawer,
    DateTime? dateFrom,
    DateTime? dateTo,
    String? status,
    int? page,
    int? pageSize,
    bool clearPayment = false,
    bool clearDates = false,
  }) {
    return ExpensesQuery(
      search: search ?? this.search,
      category: category ?? this.category,
      paidFromDrawer: clearPayment ? null : (paidFromDrawer ?? this.paidFromDrawer),
      dateFrom: clearDates ? null : (dateFrom ?? this.dateFrom),
      dateTo: clearDates ? null : (dateTo ?? this.dateTo),
      status: status ?? this.status,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class ExpensesState {
  final ExpensesQuery query;
  final List<ExpenseItem> items;
  final int total;
  final int pages;
  final ExpenseSummary? summary;
  final bool loading;
  final String? error;

  const ExpensesState({
    this.query = const ExpensesQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.summary,
    this.loading = false,
    this.error,
  });

  ExpensesState copyWith({
    ExpensesQuery? query,
    List<ExpenseItem>? items,
    int? total,
    int? pages,
    ExpenseSummary? summary,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return ExpensesState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      summary: summary ?? this.summary,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ExpensesNotifier extends StateNotifier<ExpensesState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  ExpensesNotifier(this._dio, this._localeCode)
      : super(const ExpensesState());

  Map<String, dynamic> _params(ExpensesQuery q, {required bool withPaging}) {
    return {
      if (withPaging) ...{
        'page': q.page,
        'page_size': q.pageSize,
      },
      'status': q.status,
      if (q.search.trim().isNotEmpty) 'q': q.search.trim(),
      if (q.category.trim().isNotEmpty) 'category': q.category.trim(),
      if (q.paidFromDrawer != null) 'paid_from_drawer': q.paidFromDrawer,
      if (q.dateFrom != null) 'date_from': expenseDateParam(q.dateFrom!),
      if (q.dateTo != null) 'date_to': expenseDateParam(q.dateTo!),
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final listResponse = await _dio.get(
        kExpensesPath,
        queryParameters: _params(query, withPaging: true),
      );
      final summaryResponse = await _dio.get(
        '$kExpensesPath/summary',
        queryParameters: _params(query, withPaging: false),
      );
      if (requestId != _requestId) return;
      final page = ExpenseListPage.fromJson(
        listResponse.data as Map<String, dynamic>? ?? const {},
      );
      final summary = ExpenseSummary.fromJson(
        summaryResponse.data as Map<String, dynamic>? ?? const {},
      );
      state = state.copyWith(
        items: page.items,
        total: page.total,
        pages: page.pages,
        summary: summary,
        loading: false,
        clearError: true,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        loading: false,
        error: expensesApiMessage(e, _localeCode()),
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

  void setCategory(String value) {
    state = state.copyWith(
      query: state.query.copyWith(category: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setPaidFromDrawer(bool? value) {
    state = state.copyWith(
      query: state.query.copyWith(
        paidFromDrawer: value,
        page: 1,
        clearPayment: value == null,
      ),
      clearError: true,
    );
    load();
  }

  void setDateFrom(DateTime? value) {
    state = state.copyWith(
      query: state.query.copyWith(dateFrom: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setDateTo(DateTime? value) {
    state = state.copyWith(
      query: state.query.copyWith(dateTo: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setStatus(String value) {
    state = state.copyWith(
      query: state.query.copyWith(status: value, page: 1),
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
      query: const ExpensesQuery(status: 'posted'),
      clearError: true,
    );
    load();
  }

  void refresh() => load();
}

final expensesProvider =
    StateNotifierProvider<ExpensesNotifier, ExpensesState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return ExpensesNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Command side (create / cancel)
// ---------------------------------------------------------------------------

class ExpensesApi {
  ExpensesApi(this._dio, this._localeCode);

  final Dio _dio;
  final String Function() _localeCode;

  /// `POST /api/v1/expenses` — 201 with `idempotent_replay` (GATE 10).
  Future<(ExpenseItem?, PosApiError?)> create({
    required Map<String, dynamic> payload,
  }) async {
    try {
      final response = await _dio.post(kExpensesPath, data: payload);
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (ExpenseItem.fromJson(data), null);
    } on DioException catch (e) {
      return (null, expensesApiError(e, _localeCode()));
    }
  }

  /// `POST /api/v1/expenses/{id}/cancel` — posted → cancelled (GATE 1).
  Future<(ExpenseItem?, PosApiError?)> cancel({
    required String expenseId,
    required String reason,
  }) async {
    try {
      final response = await _dio.post(
        '$kExpensesPath/$expenseId/cancel',
        data: {'reason': reason},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (ExpenseItem.fromJson(data), null);
    } on DioException catch (e) {
      return (null, expensesApiError(e, _localeCode()));
    }
  }
}

final expensesApiProvider = Provider<ExpensesApi>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return ExpensesApi(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
