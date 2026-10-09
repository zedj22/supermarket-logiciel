// Riverpod providers for facturation documents and the document
// editor helpers (Phase 8).
//
// Mirrors the purchases provider conventions: debounced search with
// stale-response guarding, server-side pagination + filters, and
// mutations that return a localized error object (null = success).
// Money stays in decimal strings end to end; fiscal totals come from
// the server (preview / create / get), never from Flutter arithmetic.
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'facturation_error.dart';
import 'facturation_models.dart';

const Duration kFacturationSearchDebounce = Duration(milliseconds: 300);
const String kFacturesPath = '/api/v1/factures';
const String kInvoiceClientsPath = '/api/v1/invoice-clients';

class FacturationQuery {
  final String search;

  /// `''` = all doc types, otherwise `FAC` | `DEV` | `PRO` | `BC` | `BL`.
  final String docType;

  /// Year filter (`null` = all years).
  final int? year;

  /// Invoice-client filter (`null` = all clients).
  final String? clientId;
  final int page;
  final int pageSize;

  const FacturationQuery({
    this.search = '',
    this.docType = '',
    this.year,
    this.clientId,
    this.page = 1,
    this.pageSize = 40,
  });

  FacturationQuery copyWith({
    String? search,
    String? docType,
    int? year,
    bool clearYear = false,
    String? clientId,
    bool clearClient = false,
    int? page,
    int? pageSize,
  }) {
    return FacturationQuery(
      search: search ?? this.search,
      docType: docType ?? this.docType,
      year: clearYear ? null : (year ?? this.year),
      clientId: clearClient ? null : (clientId ?? this.clientId),
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class FacturationState {
  final FacturationQuery query;
  final List<InvoiceDocumentSummaryModel> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const FacturationState({
    this.query = const FacturationQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  FacturationState copyWith({
    FacturationQuery? query,
    List<InvoiceDocumentSummaryModel>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return FacturationState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class FacturationNotifier extends StateNotifier<FacturationState> {
  final Dio _dio;
  final String Function() _localeCode;
  Timer? _debounce;
  int _requestId = 0;

  FacturationNotifier(
    this._dio,
    this._localeCode, {
    FacturationQuery initialQuery = const FacturationQuery(),
  }) : super(FacturationState(query: initialQuery));

  Map<String, dynamic> _params(FacturationQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.search.trim().isNotEmpty) 'q': q.search.trim(),
      if (q.docType.isNotEmpty) 'doc_type': q.docType,
      if (q.year != null) 'year': q.year,
      if (q.clientId != null) 'client_id': q.clientId,
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        kFacturesPath,
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final data = response.data as Map<String, dynamic>;
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map(
            (e) => InvoiceDocumentSummaryModel.fromJson(
              e as Map<String, dynamic>,
            ),
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
        error: facturationApiMessage(e, _localeCode()),
      );
    }
  }

  void setSearch(String value) {
    _debounce?.cancel();
    _debounce = Timer(kFacturationSearchDebounce, () {
      state = state.copyWith(
        query: state.query.copyWith(search: value, page: 1),
      );
      load();
    });
  }

  void setDocType(String value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: state.query.copyWith(docType: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setYear(int? value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: value == null
          ? state.query.copyWith(clearYear: true, page: 1)
          : state.query.copyWith(year: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setClientFilter(String? value) {
    _debounce?.cancel();
    state = state.copyWith(
      query: value == null
          ? state.query.copyWith(clearClient: true, page: 1)
          : state.query.copyWith(clientId: value, page: 1),
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

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }
}

final facturationProvider =
    StateNotifierProvider<FacturationNotifier, FacturationState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return FacturationNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Document detail (single record, re-read after every mutation)
// ---------------------------------------------------------------------------

class FacturationDetailNotifier
    extends StateNotifier<AsyncValue<InvoiceDocumentModel?>> {
  final Dio _dio;
  final String _id;

  FacturationDetailNotifier(this._dio, this._id)
      : super(const AsyncValue.loading()) {
    load();
  }

  Future<void> load({bool silent = false}) async {
    if (!silent) {
      state = const AsyncValue.loading();
    }
    try {
      final response = await _dio.get('$kFacturesPath/$_id');
      state = AsyncValue.data(
        InvoiceDocumentModel.fromJson(response.data as Map<String, dynamic>),
      );
    } on DioException catch (e) {
      state = AsyncValue.error(e, StackTrace.current);
    }
  }
}

final facturationDetailProvider = StateNotifierProvider.family<
    FacturationDetailNotifier, AsyncValue<InvoiceDocumentModel?>, String>(
  (ref, id) {
    final dio = ref.watch(apiClientProvider).dio;
    return FacturationDetailNotifier(dio, id);
  },
);

// ---------------------------------------------------------------------------
// Document mutations (create / preview / update / PDF)
// ---------------------------------------------------------------------------

class FacturationDocumentNotifier {
  final Dio _dio;
  final String Function() _localeCode;

  FacturationDocumentNotifier(this._dio, this._localeCode);

  /// POST /api/v1/factures — returns the created document or an error.
  Future<(InvoiceDocumentModel?, PosApiError?)> create(
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _dio.post(kFacturesPath, data: payload);
      return (
        InvoiceDocumentModel.fromJson(response.data as Map<String, dynamic>),
        null,
      );
    } on DioException catch (e) {
      return (null, facturationApiError(e, _localeCode()));
    }
  }

  /// POST /api/v1/factures/preview — dry-run calculation (no write).
  Future<(InvoiceDocumentPreviewModel?, PosApiError?)> preview(
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _dio.post('$kFacturesPath/preview', data: payload);
      return (
        InvoiceDocumentPreviewModel.fromJson(
          response.data as Map<String, dynamic>,
        ),
        null,
      );
    } on DioException catch (e) {
      return (null, facturationApiError(e, _localeCode()));
    }
  }

  /// PUT /api/v1/factures/{id} — partial update of mutable fields.
  Future<(InvoiceDocumentModel?, PosApiError?)> update(
    String id,
    Map<String, dynamic> payload,
  ) async {
    try {
      final response = await _dio.put('$kFacturesPath/$id', data: payload);
      return (
        InvoiceDocumentModel.fromJson(response.data as Map<String, dynamic>),
        null,
      );
    } on DioException catch (e) {
      return (null, facturationApiError(e, _localeCode()));
    }
  }
}

final facturationDocumentProvider = Provider<FacturationDocumentNotifier>((
  ref,
) {
  final dio = ref.watch(apiClientProvider).dio;
  return FacturationDocumentNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
