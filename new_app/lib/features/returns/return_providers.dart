// Riverpod providers for the Returns / Voids feature (Phase 12).
//
// Two halves:
//   * [ReturnsApi] — the command side (post a return, void a sale, read
//     one document, list a sale's returns, search products). Every call
//     returns `(result, PosApiError?)` — null error means success — so a
//     dialog can show a localized failure without throwing.
//   * [ReturnsNotifier] — the paginated history list with invoice/reason
//     filters (GET /api/v1/returns).
//
// Money stays in decimal strings end to end: the server owns the refund.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'return_error_message.dart';
import 'return_models.dart';

const String kReturnsPath = '/api/v1/returns';
const String kSalesPath = '/api/v1/sales';
const String kProductsPath = '/api/v1/products';

// ---------------------------------------------------------------------------
// History list
// ---------------------------------------------------------------------------

class ReturnsQuery {
  final String invoiceNumber;
  final String reason;
  final String saleId;
  final int page;
  final int pageSize;

  const ReturnsQuery({
    this.invoiceNumber = '',
    this.reason = '',
    this.saleId = '',
    this.page = 1,
    this.pageSize = 20,
  });

  ReturnsQuery copyWith({
    String? invoiceNumber,
    String? reason,
    String? saleId,
    int? page,
    int? pageSize,
  }) {
    return ReturnsQuery(
      invoiceNumber: invoiceNumber ?? this.invoiceNumber,
      reason: reason ?? this.reason,
      saleId: saleId ?? this.saleId,
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class ReturnsState {
  final ReturnsQuery query;
  final List<ReturnDoc> items;
  final int total;
  final int pages;
  final bool loading;
  final String? error;

  const ReturnsState({
    this.query = const ReturnsQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.loading = false,
    this.error,
  });

  ReturnsState copyWith({
    ReturnsQuery? query,
    List<ReturnDoc>? items,
    int? total,
    int? pages,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return ReturnsState(
      query: query ?? this.query,
      items: items ?? this.items,
      total: total ?? this.total,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ReturnsNotifier extends StateNotifier<ReturnsState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  ReturnsNotifier(this._dio, this._localeCode)
      : super(const ReturnsState());

  Map<String, dynamic> _params(ReturnsQuery q) {
    return {
      'page': q.page,
      'page_size': q.pageSize,
      if (q.invoiceNumber.trim().isNotEmpty)
        'invoice_number': q.invoiceNumber.trim(),
      if (q.reason.trim().isNotEmpty) 'reason': q.reason.trim(),
      if (q.saleId.trim().isNotEmpty) 'sale_id': q.saleId.trim(),
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get(
        kReturnsPath,
        queryParameters: _params(query),
      );
      if (requestId != _requestId) return;
      final page = ReturnListPage.fromJson(
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
        error: returnsApiMessage(e, _localeCode()),
      );
    }
  }

  void setInvoiceNumber(String value) {
    state = state.copyWith(
      query: state.query.copyWith(invoiceNumber: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setReason(String value) {
    state = state.copyWith(
      query: state.query.copyWith(reason: value, page: 1),
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

final returnsProvider =
    StateNotifierProvider<ReturnsNotifier, ReturnsState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return ReturnsNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Command side (create / void / detail / lookups)
// ---------------------------------------------------------------------------

class ReturnsApi {
  ReturnsApi(this._dio, this._localeCode);

  final Dio _dio;
  final String Function() _localeCode;

  /// `POST /api/v1/returns` — server prices every line (GATE 5).
  Future<(ReturnCreateResult?, PosApiError?)> create({
    required Map<String, dynamic> payload,
  }) async {
    try {
      final response = await _dio.post(kReturnsPath, data: payload);
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (ReturnCreateResult.fromJson(data), null);
    } on DioException catch (e) {
      return (null, returnsApiError(e, _localeCode()));
    }
  }

  /// `POST /api/v1/sales/{sale_id}/void` — one-way (GATE 1).
  Future<(VoidResult?, PosApiError?)> voidSale({
    required String saleId,
    required String reason,
    String? deviceId,
  }) async {
    try {
      final response = await _dio.post(
        '$kSalesPath/$saleId/void',
        data: {'reason': reason},
        options: deviceId == null
            ? null
            : Options(headers: {'X-Device-ID': deviceId}),
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (VoidResult.fromJson(data), null);
    } on DioException catch (e) {
      return (null, returnsApiError(e, _localeCode()));
    }
  }

  /// `GET /api/v1/returns/{return_id}` — detail / reprint.
  Future<(ReturnDoc?, PosApiError?)> get(String returnId) async {
    try {
      final response = await _dio.get('$kReturnsPath/$returnId');
      final data = response.data as Map<String, dynamic>? ?? const {};
      return (ReturnDoc.fromJson(data), null);
    } on DioException catch (e) {
      return (null, returnsApiError(e, _localeCode()));
    }
  }

  /// Returns already posted against one sale.
  ///
  /// The remaining returnable quantity per source line is SERVER-DERIVED
  /// (GATE 22): sold quantity from the invoice, already-returned quantity
  /// from these documents — never a client-side guess.
  Future<(List<ReturnDoc>?, PosApiError?)> forSale(String saleId) async {
    try {
      final response = await _dio.get(
        kReturnsPath,
        queryParameters: {'sale_id': saleId, 'page_size': 100},
      );
      final page = ReturnListPage.fromJson(
        response.data as Map<String, dynamic>? ?? const {},
      );
      return (page.items, null);
    } on DioException catch (e) {
      return (null, returnsApiError(e, _localeCode()));
    }
  }

  /// Bounded product search for the independent return flow.
  Future<(List<ReturnProductCandidate>, PosApiError?)> searchProducts(
    String term,
  ) async {
    final query = term.trim();
    if (query.isEmpty) return ((<ReturnProductCandidate>[]), null);
    try {
      final response = await _dio.get(
        kProductsPath,
        queryParameters: {'search': query, 'page_size': 20},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final items = (data['items'] as List<dynamic>? ?? const [])
          .map(
            (e) =>
                ReturnProductCandidate.fromJson(e as Map<String, dynamic>),
          )
          .toList();
      return (items, null);
    } on DioException catch (e) {
      return (<ReturnProductCandidate>[], returnsApiError(e, _localeCode()));
    }
  }

  /// `GET /api/v1/products/barcode-lookup?barcode=…` — the canonical scan
  /// path (selling unit → variant → product). Returns `(null, null)` when
  /// the barcode is unknown: the caller decides the not-found feedback.
  Future<(ReturnBarcodeHit?, PosApiError?)> barcodeLookup(
    String barcode,
  ) async {
    final code = barcode.trim();
    if (code.isEmpty) return ((null), null);
    try {
      final response = await _dio.get(
        '$kProductsPath/barcode-lookup',
        queryParameters: {'barcode': code},
      );
      final data = response.data as Map<String, dynamic>? ?? const {};
      final hit = ReturnBarcodeHit.fromJson(data);
      return (hit.found ? hit : null, null);
    } on DioException catch (e) {
      return (null, returnsApiError(e, _localeCode()));
    }
  }
}

final returnsApiProvider = Provider<ReturnsApi>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return ReturnsApi(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
