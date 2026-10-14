// Riverpod providers for the Audit Log feature (Slice B).
//
// Mirrors the Expenses list pattern (`expenses_providers.dart`): one
// StateNotifier owns the query, the filtered + paginated page (GET
// /api/v1/audit) and the server-computed summary for the SAME filter
// window (GET /api/v1/audit/summary). Every filter the UI offers is a
// parameter the API accepts — there is no client-side filtering.
//
// Both requests are fired together and the summary is NEVER inferred
// from the visible page: the cards show what the server counted over
// the whole filtered window.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import 'audit_error.dart';
import 'audit_models.dart';

/// `yyyy-MM-dd` in the local calendar day — the API accepts ISO
/// datetimes and treats a bare date as local midnight, matching the
/// expenses date-range convention.
String auditDateParam(DateTime value) =>
    DateFormat('yyyy-MM-dd').format(value.toLocal());

class AuditQuery {
  final String search;

  /// `''` = all — canonical backend codes, never localized.
  final String module;
  final String action;
  final String outcome;
  final String entityType;
  final DateTime? dateFrom;
  final DateTime? dateTo;
  final int page;
  final int pageSize;

  const AuditQuery({
    this.search = '',
    this.module = '',
    this.action = '',
    this.outcome = '',
    this.entityType = '',
    this.dateFrom,
    this.dateTo,
    this.page = 1,
    this.pageSize = AppConstants.defaultPageSize,
  });

  AuditQuery copyWith({
    String? search,
    String? module,
    String? action,
    String? outcome,
    String? entityType,
    DateTime? dateFrom,
    DateTime? dateTo,
    int? page,
    int? pageSize,
    bool clearDates = false,
  }) {
    return AuditQuery(
      search: search ?? this.search,
      module: module ?? this.module,
      action: action ?? this.action,
      outcome: outcome ?? this.outcome,
      entityType: entityType ?? this.entityType,
      dateFrom: clearDates ? null : (dateFrom ?? this.dateFrom),
      dateTo: clearDates ? null : (dateTo ?? this.dateTo),
      page: page ?? this.page,
      pageSize: pageSize ?? this.pageSize,
    );
  }
}

class AuditState {
  final AuditQuery query;
  final List<AuditEvent> items;
  final int total;
  final int pages;
  final AuditSummary? summary;
  final bool loading;
  final String? error;

  const AuditState({
    this.query = const AuditQuery(),
    this.items = const [],
    this.total = 0,
    this.pages = 1,
    this.summary,
    this.loading = false,
    this.error,
  });

  AuditState copyWith({
    AuditQuery? query,
    List<AuditEvent>? items,
    int? total,
    int? pages,
    AuditSummary? summary,
    bool? loading,
    String? error,
    bool clearError = false,
  }) {
    return AuditState(
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

class AuditNotifier extends StateNotifier<AuditState> {
  final Dio _dio;
  final String Function() _localeCode;
  int _requestId = 0;

  AuditNotifier(this._dio, this._localeCode) : super(const AuditState());

  Map<String, dynamic> _params(AuditQuery q, {required bool withPaging}) {
    return {
      if (withPaging) ...{
        'page': q.page,
        'page_size': q.pageSize,
      },
      if (q.search.trim().isNotEmpty) 'q': q.search.trim(),
      if (q.module.isNotEmpty) 'module': q.module,
      if (q.action.isNotEmpty) 'action': q.action,
      if (q.outcome.isNotEmpty) 'outcome': q.outcome,
      if (q.entityType.trim().isNotEmpty) 'entity_type': q.entityType.trim(),
      if (q.dateFrom != null) 'date_from': auditDateParam(q.dateFrom!),
      if (q.dateTo != null) 'date_to': auditDateParam(q.dateTo!),
    };
  }

  Future<void> load() async {
    final query = state.query;
    final requestId = ++_requestId;
    state = state.copyWith(loading: true, clearError: true);
    try {
      final listResponse = await _dio.get(
        kAuditPath,
        queryParameters: _params(query, withPaging: true),
      );
      final summaryResponse = await _dio.get(
        '$kAuditPath/summary',
        queryParameters: _params(query, withPaging: false),
      );
      if (requestId != _requestId) return;
      final page = AuditListPage.fromJson(
        listResponse.data as Map<String, dynamic>? ?? const {},
      );
      final summary = AuditSummary.fromJson(
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
        error: auditApiMessage(e, _localeCode()),
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

  void setModule(String value) {
    state = state.copyWith(
      query: state.query.copyWith(module: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setAction(String value) {
    state = state.copyWith(
      query: state.query.copyWith(action: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setOutcome(String value) {
    state = state.copyWith(
      query: state.query.copyWith(outcome: value, page: 1),
      clearError: true,
    );
    load();
  }

  void setEntityType(String value) {
    state = state.copyWith(
      query: state.query.copyWith(entityType: value, page: 1),
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

  void setPage(int page) {
    state = state.copyWith(query: state.query.copyWith(page: page));
    load();
  }

  void clearFilters() {
    state = state.copyWith(
      query: const AuditQuery(),
      clearError: true,
    );
    load();
  }

  void refresh() => load();
}

final auditProvider =
    StateNotifierProvider<AuditNotifier, AuditState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  return AuditNotifier(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
  );
});
