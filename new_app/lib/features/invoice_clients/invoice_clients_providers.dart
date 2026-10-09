// Riverpod providers for invoice (fiscal) clients (Phase 8).
//
// Mirrors the suppliers provider conventions: debounced search with
// stale-response guarding, server-side pagination, and mutations that
// return a localized error object (null = success).
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../facturation/facturation_models.dart';
import '../facturation/facturation_providers.dart' show kInvoiceClientsPath;
import 'invoice_clients_error.dart';

const Duration kInvoiceClientsSearchDebounce = Duration(milliseconds: 300);

class InvoiceClientsQuery {
  final String search;
  final bool includeArchived;
  final int page;
  final int pageSize;

  const InvoiceClientsQuery({
    this.search = '',
    this.includeArchived = false,
    this.page = 1,
    this.pageSize = 40,
  });

  InvoiceClientsQuery copyWith({
    String? search,
    bool? includeArchived,
    int? page,
    int? pageSize,
  }) {
    return InvoiceClientsQuery(
      search: search ?? this.search,
      includeArchived: includeArchived ?? this.includeArchived,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class InvoiceClientsState {
  final InvoiceClientsQuery query;
  final List<InvoiceClientModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const InvoiceClientsState({
    this.query = const InvoiceClientsQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  InvoiceClientsState copyWith({
    InvoiceClientsQuery? query,
    List<InvoiceClientModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return InvoiceClientsState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class InvoiceClientsNotifier extends StateNotifier<InvoiceClientsState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  InvoiceClientsNotifier(
    this._dio,
    this._localeCode, {
    InvoiceClientsQuery initialQuery = const InvoiceClientsQuery(),
  }) : super(InvoiceClientsState(query: initialQuery));

  Map<String, dynamic> _params(InvoiceClientsQuery q) {
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
        kInvoiceClientsPath,
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map(
            (e) => InvoiceClientModel.fromJson(e as Map<String, dynamic>),
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
        error: invoiceClientsApiMessage(e, _localeCode()),
      );
    }
  }

  void setSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(kInvoiceClientsSearchDebounce, () {
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

  /// POST /api/v1/invoice-clients — null on success, error otherwise.
  Future<PosApiError?> createClient(Map<String, dynamic> payload) async {
    try {
      await _dio.post(kInvoiceClientsPath, data: payload);
      refresh();
      return null;
    } on DioException catch (e) {
      return invoiceClientsApiError(e, _localeCode());
    }
  }

  /// PUT /api/v1/invoice-clients/{id} — partial update.
  Future<PosApiError?> updateClient(
    String id,
    Map<String, dynamic> payload,
  ) async {
    try {
      await _dio.put('$kInvoiceClientsPath/$id', data: payload);
      refresh();
      return null;
    } on DioException catch (e) {
      return invoiceClientsApiError(e, _localeCode());
    }
  }

  /// DELETE /api/v1/invoice-clients/{id} (soft archive; 200 + body).
  Future<PosApiError?> archiveClient(String id) async {
    try {
      await _dio.delete('$kInvoiceClientsPath/$id');
      refresh();
      return null;
    } on DioException catch (e) {
      return invoiceClientsApiError(e, _localeCode());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final invoiceClientsProvider =
    StateNotifierProvider<InvoiceClientsNotifier, InvoiceClientsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return InvoiceClientsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
