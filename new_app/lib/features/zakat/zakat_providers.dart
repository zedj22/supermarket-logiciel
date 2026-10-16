// Riverpod providers for the Zakat feature.
//
// Shape: one [zakatContextProvider] seeds the screen (store identity,
// official nisab reference, imported inventory totals, AR/AP ledgers),
// one [zakatFormProvider] holds the calculator flow (stateless preview →
// optional save → optional payment) and one [zakatHistoryProvider] pages
// through saved snapshots. Money stays in decimal strings end to end:
// the server owns every figure and the client never multiplies.
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'zakat_error.dart';
import 'zakat_models.dart';

const String kZakatPath = '/api/v1/zakat';

/// Page size used by the history table (server max is 100).
const int kZakatPageSize = 40;

/// One opaque `client_request_id` per save/payment attempt — reused on
/// retry so a network blip replays idempotently instead of double-saving.
String zakatClientRequestId() =>
    '${DateTime.now().microsecondsSinceEpoch}-${Random().nextInt(1 << 32)}';

// ---------------------------------------------------------------------------
// Context (screen seed)
// ---------------------------------------------------------------------------

class ZakatContextState {
  const ZakatContextState({this.data, this.loading = false, this.error});

  final ZakatContext? data;
  final bool loading;
  final String? error;

  ZakatContextState copyWith({
    ZakatContext? data,
    bool? loading,
    String? error,
  }) {
    return ZakatContextState(
      data: data ?? this.data,
      loading: loading ?? this.loading,
      error: error,
    );
  }
}

class ZakatContextNotifier extends StateNotifier<ZakatContextState> {
  ZakatContextNotifier(this._dio, this._localeCode)
      : super(const ZakatContextState());

  final Dio _dio;
  final String Function() _localeCode;

  int _requestId = 0;

  Future<void> load() async {
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, error: null);
    try {
      final response = await _dio.get('$kZakatPath/context');
      if (requestId != _requestId) return;
      state = ZakatContextState(
        data: ZakatContext.fromJson(
          response.data as Map<String, dynamic>? ?? const {},
        ),
        loading: false,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = ZakatContextState(
        data: state.data,
        loading: false,
        error: zakatApiMessage(e, _localeCode()),
      );
    }
  }
}

final zakatContextProvider =
    StateNotifierProvider<ZakatContextNotifier, ZakatContextState>((ref) {
  return ZakatContextNotifier(
    ref.watch(apiClientProvider).dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Calculator form (preview + save)
// ---------------------------------------------------------------------------

class ZakatFormState {
  const ZakatFormState({
    this.result,
    this.busy = false,
    this.saving = false,
    this.error,
    this.saved,
    this.lastInput,
  });

  /// Last stateless preview (`POST /zakat/calculate`).
  final ZakatCalculateResponse? result;
  final bool busy;
  final bool saving;
  final String? error;

  /// Last successfully saved snapshot (201 body) — enables payment/PDF.
  final ZakatCalculationDetail? saved;

  /// Exact payload last sent (so PDF/save reuse the same inputs).
  final ZakatCalculationInput? lastInput;

  ZakatFormState copyWith({
    ZakatCalculateResponse? result,
    bool? busy,
    bool? saving,
    String? error,
    ZakatCalculationDetail? saved,
    ZakatCalculationInput? lastInput,
    bool clearError = false,
    bool clearSaved = false,
  }) {
    return ZakatFormState(
      result: result ?? this.result,
      busy: busy ?? this.busy,
      saving: saving ?? this.saving,
      error: clearError ? null : (error ?? this.error),
      saved: clearSaved ? null : (saved ?? this.saved),
      lastInput: lastInput ?? this.lastInput,
    );
  }
}

class ZakatFormNotifier extends StateNotifier<ZakatFormState> {
  ZakatFormNotifier(this._dio, this._localeCode) : super(const ZakatFormState());

  final Dio _dio;
  final String Function() _localeCode;

  int _requestId = 0;

  /// Stateless preview — nothing is saved server-side.
  Future<void> calculate(ZakatCalculationInput input) async {
    final requestId = ++_requestId;
    state = state.copyWith(busy: true, clearError: true, lastInput: input);
    try {
      final response = await _dio.post(
        '$kZakatPath/calculate',
        data: input.toJson(),
      );
      if (requestId != _requestId) return;
      state = state.copyWith(
        busy: false,
        result: ZakatCalculateResponse.fromJson(
          response.data as Map<String, dynamic>? ?? const {},
        ),
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        busy: false,
        error: zakatApiMessage(e, _localeCode()),
      );
    }
  }

  /// Save the CURRENT preview as an immutable snapshot. Requires a prior
  /// successful [calculate] with the same inputs (the server re-runs the
  /// formula from the stored payload).
  Future<ZakatCalculationDetail?> save(ZakatCalculationInput input) async {
    if (state.saving) return null;
    state = state.copyWith(saving: true, clearError: true, lastInput: input);
    try {
      final response = await _dio.post(
        kZakatPath,
        data: <String, dynamic>{
          'client_request_id': zakatClientRequestId(),
          'calculation': input.toJson(),
        },
      );
      if (!mounted) return null;
      final detail = ZakatCalculationDetail.fromJson(
        response.data as Map<String, dynamic>? ?? const {},
      );
      state = state.copyWith(saving: false, saved: detail);
      return detail;
    } on DioException catch (e) {
      if (!mounted) return null;
      state = state.copyWith(
        saving: false,
        error: zakatApiMessage(e, _localeCode()),
      );
      return null;
    }
  }

  /// Record one payment against a saved snapshot; the detail response
  /// carries the refreshed payments list.
  Future<ZakatCalculationDetail?> recordPayment({
    required String calculationId,
    required String amount,
    required String method,
    String? paidAt,
    String? note,
  }) async {
    if (state.saving) return null;
    state = state.copyWith(saving: true, clearError: true);
    try {
      final response = await _dio.post(
        '$kZakatPath/$calculationId/payment',
        data: <String, dynamic>{
          'client_request_id': zakatClientRequestId(),
          'amount': amount,
          'method': method,
          if (paidAt != null && paidAt.isNotEmpty) 'paid_at': paidAt,
          if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
        },
      );
      if (!mounted) return null;
      final detail = ZakatCalculationDetail.fromJson(
        response.data as Map<String, dynamic>? ?? const {},
      );
      state = state.copyWith(saving: false, saved: detail);
      return detail;
    } on DioException catch (e) {
      if (!mounted) return null;
      state = state.copyWith(
        saving: false,
        error: zakatApiMessage(e, _localeCode()),
      );
      return null;
    }
  }

  void clearResult() => state = const ZakatFormState();

  void clearSaved() => state = state.copyWith(clearSaved: true);
}

final zakatFormProvider =
    StateNotifierProvider<ZakatFormNotifier, ZakatFormState>((ref) {
  return ZakatFormNotifier(
    ref.watch(apiClientProvider).dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

// ---------------------------------------------------------------------------
// Saved-calculation history
// ---------------------------------------------------------------------------

class ZakatHistoryState {
  const ZakatHistoryState({
    this.items = const <ZakatCalculationSummary>[],
    this.total = 0,
    this.page = 1,
    this.pages = 1,
    this.loading = false,
    this.loadingMore = false,
    this.error,
  });

  final List<ZakatCalculationSummary> items;
  final int total;
  final int page;
  final int pages;
  final bool loading;
  final bool loadingMore;
  final String? error;

  bool get hasMore => page < pages;

  ZakatHistoryState copyWith({
    List<ZakatCalculationSummary>? items,
    int? total,
    int? page,
    int? pages,
    bool? loading,
    bool? loadingMore,
    String? error,
    bool clearError = false,
  }) {
    return ZakatHistoryState(
      items: items ?? this.items,
      total: total ?? this.total,
      page: page ?? this.page,
      pages: pages ?? this.pages,
      loading: loading ?? this.loading,
      loadingMore: loadingMore ?? this.loadingMore,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ZakatHistoryNotifier extends StateNotifier<ZakatHistoryState> {
  ZakatHistoryNotifier(this._dio, this._localeCode)
      : super(const ZakatHistoryState());

  final Dio _dio;
  final String Function() _localeCode;

  int _requestId = 0;

  Future<void> load({bool refresh = false}) async {
    final requestId = ++_requestId;
    // Append mode requests the NEXT page; refresh restarts at page 1.
    final requestPage = refresh ? 1 : state.page + 1;
    if (refresh || state.items.isEmpty) {
      state = state.copyWith(loading: true, clearError: true);
    } else {
      state = state.copyWith(loadingMore: true, clearError: true);
    }
    try {
      final response = await _dio.get(
        kZakatPath,
        queryParameters: <String, dynamic>{
          'page': requestPage,
          'page_size': kZakatPageSize,
        },
      );
      if (requestId != _requestId) return;
      final json = response.data as Map<String, dynamic>? ?? const {};
      final page = ZakatCalculationPage.fromJson(json);
      state = ZakatHistoryState(
        items: refresh
            ? page.items
            : <ZakatCalculationSummary>[...state.items, ...page.items],
        total: page.total,
        page: requestPage,
        pages: page.pages,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = state.copyWith(
        loading: false,
        loadingMore: false,
        error: zakatApiMessage(e, _localeCode()),
      );
    }
  }

  /// Next page (append) — no-op at the end.
  Future<void> loadMore() async {
    if (state.loading || state.loadingMore || !state.hasMore) return;
    await load();
  }

  void refresh() {
    state = state.copyWith(page: 1);
    load(refresh: true);
  }
}

final zakatHistoryProvider =
    StateNotifierProvider<ZakatHistoryNotifier, ZakatHistoryState>((ref) {
  return ZakatHistoryNotifier(
    ref.watch(apiClientProvider).dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});

/// One saved snapshot's full detail (`GET /zakat/{id}`).
class ZakatDetailState {
  const ZakatDetailState({this.data, this.loading = false, this.error});

  final ZakatCalculationDetail? data;
  final bool loading;
  final String? error;

  ZakatDetailState copyWith({
    ZakatCalculationDetail? data,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return ZakatDetailState(
      data: data ?? this.data,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ZakatDetailNotifier extends StateNotifier<ZakatDetailState> {
  ZakatDetailNotifier(this._dio, this._localeCode)
      : super(const ZakatDetailState());

  final Dio _dio;
  final String Function() _localeCode;

  int _requestId = 0;

  Future<void> load(String calculationId) async {
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final response = await _dio.get('$kZakatPath/$calculationId');
      if (requestId != _requestId) return;
      state = ZakatDetailState(
        data: ZakatCalculationDetail.fromJson(
          response.data as Map<String, dynamic>? ?? const {},
        ),
        loading: false,
      );
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = ZakatDetailState(
        data: state.data,
        loading: false,
        error: zakatApiMessage(e, _localeCode()),
      );
    }
  }

  void clear() => state = const ZakatDetailState();
}

/// Factory: one detail controller per opened snapshot id — the pane
/// triggers `load` from its initState (no hidden fetch on creation).
final zakatDetailProvider = StateNotifierProvider.family<
    ZakatDetailNotifier, ZakatDetailState, String>((ref, calculationId) {
  return ZakatDetailNotifier(
    ref.watch(apiClientProvider).dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
