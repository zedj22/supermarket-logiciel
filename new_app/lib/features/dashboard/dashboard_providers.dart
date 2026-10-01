// Riverpod provider for the Phase 14 dashboard (§7).
//
// One round trip per load: `GET /api/v1/dashboard` with the shared
// period (`date_from`/`date_to`, default = today). Snapshot KPIs ignore
// the period server-side; `recent_sales`/`top_products` follow it (§7).
// No client-side caching (G28) — a stale KPI is worse than a 100 ms one.
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/locale_provider.dart';
import '../auth/auth_provider.dart';
import '../reports/reports_error.dart';
import '../reports/reports_providers.dart';
import 'dashboard_models.dart';

const String kDashboardPath = '/api/v1/dashboard';

class DashboardState {
  final DashboardReport? data;
  final bool loading;
  final String? error;

  const DashboardState({this.data, this.loading = false, this.error});
}

class DashboardController extends StateNotifier<DashboardState> {
  DashboardController(this._dio, this._localeCode, this._readFilter)
      : super(const DashboardState());

  final Dio _dio;
  final String Function() _localeCode;
  final ReportFilter Function() _readFilter;

  int _requestId = 0;
  bool _initialized = false;

  bool get initialized => _initialized;

  Future<void> load() async {
    _initialized = true;
    final requestId = ++_requestId;
    state = DashboardState(data: state.data, loading: true);
    try {
      final response = await _dio.get(
        kDashboardPath,
        queryParameters: _readFilter().rangeParams(),
      );
      if (requestId != _requestId) return;
      final json = response.data as Map<String, dynamic>? ?? const {};
      state = DashboardState(data: DashboardReport.fromJson(json));
    } on DioException catch (e) {
      if (requestId != _requestId) return;
      state = DashboardState(
        data: state.data,
        error: reportsApiMessage(e, _localeCode()),
      );
    }
  }

  void refresh() => load();
}

final dashboardProvider =
    StateNotifierProvider<DashboardController, DashboardState>((ref) {
  final dio = ref.watch(apiClientProvider).dio;
  final controller = DashboardController(
    dio,
    () => ref.read(localeProvider).flutterLocale.languageCode,
    () => ref.read(reportFilterProvider),
  );
  // The dashboard follows the shared period selector (§7: default =
  // today, presets/range change both surfaces consistently).
  ref.listen(reportFilterProvider, (previous, next) {
    if (previous != next && controller.initialized) controller.load();
  });
  return controller;
});
